#!/usr/bin/env python3
"""
CORS & device details prefill watcher.

Reads the "CORS and device details" sheet through its Apps Script bridge and, for
each row that has a CORS ID + Password, fills the derived columns:
  - Android ID         <- HFCL user_login_history: latest 16-hex mac_address for the User
  - RTK Start Date     <- SOI portal (fetch_expiry.process)
  - Validity Upto      <- SOI portal
  - Validity Remarks   <- SOI portal
  - RTCM Bytes Health  <- NTRIP probe of the NetworkVRS caster (port 2101; works on GitHub runners)

Columns are located by HEADER NAME (order-independent). A row's expensive pass
(portal + RTCM) runs only while its RTCM cell is blank (the "processed" marker);
Android ID is re-checked while blank so it fills as devices upgrade to 9.0.1+.

Env: PREFILL_APPS_URL, PREFILL_APPS_SECRET, HFCL_URI
"""
import os, re, json, socket, base64, time, datetime, urllib.request, urllib.parse, sys
import pg8000.native

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fetch_expiry import process as portal_process   # bundled alongside

APPS_URL = os.environ["PREFILL_APPS_URL"]
APPS_SECRET = os.environ["PREFILL_APPS_SECRET"]
HFCL_URI = os.environ.get("HFCL_URI", "")

VRS_IP, VRS_PORT, VRS_MOUNT, VRS_GGA = "103.205.244.106", 2101, "RTCM_VRS", "30.2407,74.9528"
HEX16 = re.compile(r"^[0-9a-fA-F]{16}$")
LIMIT = int(os.environ.get("PREFILL_LIMIT", "25"))   # max expensive (portal+RTCM) rows per run


def sheet_read():
    u = f"{APPS_URL}?read=1&secret={urllib.parse.quote(APPS_SECRET)}"
    with urllib.request.urlopen(u, timeout=60) as r:
        return json.load(r).get("rows", [])


def sheet_write(updates):
    if not updates:
        return {"written": 0}
    body = json.dumps({"secret": APPS_SECRET, "updates": updates}).encode()
    req = urllib.request.Request(APPS_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.load(r)


def hfcl_conn():
    u = urllib.parse.urlparse(HFCL_URI)
    return pg8000.native.Connection(
        user=urllib.parse.unquote(u.username), password=urllib.parse.unquote(u.password),
        host=u.hostname, port=u.port, database=u.path.lstrip("/"))


def android_ids(users):
    """Batch: {user_name -> latest 16-hex mac_address} for the given survey users."""
    out = {}
    users = sorted({u for u in users if u})
    if not HFCL_URI or not users:
        return out
    try:
        con = hfcl_conn()
        rows = con.run(
            "select m.user_name, h.mac_address "
            "from user_login_history h join user_master m on m.user_id=h.user_id "
            "where m.user_name = any(:u) and h.mac_address ~ '^[0-9a-fA-F]{16}$' "
            "order by h.login_time desc", u=users)
        con.close()
        for name, mac in rows:            # ordered newest-first -> first seen wins
            out.setdefault(name, mac)
    except Exception as e:
        print(f"  WARN android lookup failed: {e}")
    return out


def _gga():
    lat, lon = (float(x) for x in VRS_GGA.split(","))
    ns, ew = ("N" if lat >= 0 else "S"), ("E" if lon >= 0 else "W")
    lat, lon = abs(lat), abs(lon); latd, lond = int(lat), int(lon)
    body = (f"GPGGA,{datetime.datetime.utcnow():%H%M%S.00},{latd:02d}{(lat-latd)*60:07.4f},{ns},"
            f"{lond:03d}{(lon-lond)*60:07.4f},{ew},1,12,0.8,220.0,M,45.0,M,,")
    cs = 0
    for ch in body:
        cs ^= ord(ch)
    return f"${body}*{cs:02X}\r\n".encode()


def rtcm_probe(user, pw, timeout=8):
    auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
    req = (f"GET /{VRS_MOUNT} HTTP/1.1\r\nHost: {VRS_IP}:{VRS_PORT}\r\nNtrip-Version: Ntrip/2.0\r\n"
           f"User-Agent: cors-prefill/1.0\r\nAuthorization: Basic {auth}\r\nAccept: */*\r\n"
           f"Connection: close\r\n\r\n").encode()
    data, code = b"", "000"
    try:
        s = socket.create_connection((VRS_IP, VRS_PORT), timeout=timeout); s.sendall(req)
        try: s.sendall(_gga())
        except Exception: pass
        s.settimeout(timeout); start = last = time.time(); hdr = False; buf = b""
        while time.time() - start < timeout:
            try: chunk = s.recv(4096)
            except socket.timeout: break
            if not chunk: break
            if not hdr:
                buf += chunk
                if b"\r\n\r\n" in buf:
                    head, rest = buf.split(b"\r\n\r\n", 1)
                    first = head.split(b"\r\n", 1)[0].decode("latin-1", "replace"); parts = first.split()
                    if len(parts) >= 2 and parts[1].isdigit(): code = parts[1]
                    elif "200" in first: code = "200"
                    data += rest; hdr = True
            else:
                data += chunk
            if time.time() - last > 5:
                try: s.sendall(_gga())
                except Exception: pass
                last = time.time()
        s.close()
    except Exception:
        pass
    return code, len(data)


def rtcm_health(user, pw):
    code, n = rtcm_probe(user, pw)
    if code == "200" and n > 0:
        return f"Yes - healthy ({n:,} B/6s)"
    if code == "401":
        return "No - 401 (auth failed)"
    return f"No - HTTP {code} ({n} B)"


def main():
    rows = sheet_read()
    if not rows:
        print("empty sheet"); return
    hdr = [str(c).strip().lower() for c in rows[0]]

    def col(name):
        try: return hdr.index(name.lower())
        except ValueError: return -1
    C = {k: col(k) for k in ["user", "cors id", "password", "android id",
                             "rtk start date", "validity upto", "rtcm bytes health", "validity remarks"]}
    missing = [k for k, v in C.items() if v < 0]
    if missing:
        print(f"ERROR: sheet missing columns {missing}"); return

    def g(row, idx):
        return str(row[idx]).strip() if 0 <= idx < len(row) and row[idx] is not None else ""

    updates = []
    # Which rows need work
    full_rows, android_users = [], set()
    for i, row in enumerate(rows[1:], start=2):
        cors, pw, user = g(row, C["cors id"]), g(row, C["password"]), g(row, C["user"])
        if not cors or not pw:
            continue
        if not g(row, C["rtcm bytes health"]):
            full_rows.append((i, cors, pw, user, row))
        if not g(row, C["android id"]) and user:
            android_users.add(user)

    aid_map = android_ids(android_users)

    # Android ID (cheap; re-checked while blank)
    for i, row in enumerate(rows[1:], start=2):
        if g(row, C["android id"]) or not g(row, C["user"]):
            continue
        aid = aid_map.get(g(row, C["user"]))
        if aid:
            updates.append({"row": i, "col": C["android id"] + 1, "value": aid})

    # Expensive pass: portal validity + RTCM, only while RTCM is blank (capped per run)
    for i, cors, pw, user, row in full_rows[:LIMIT]:
        cid = cors.replace(" ", "")
        try:
            res = portal_process(cid, pw)
        except Exception as e:
            res = {"validity": "", "rtk_start": "", "remark": f"portal error: {type(e).__name__}"}
        if not g(row, C["rtk start date"]) and res.get("rtk_start"):
            updates.append({"row": i, "col": C["rtk start date"] + 1, "value": res["rtk_start"]})
        if not g(row, C["validity upto"]) and res.get("validity"):
            updates.append({"row": i, "col": C["validity upto"] + 1, "value": res["validity"]})
        if not g(row, C["validity remarks"]) and res.get("remark"):
            updates.append({"row": i, "col": C["validity remarks"] + 1, "value": res["remark"]})
        updates.append({"row": i, "col": C["rtcm bytes health"] + 1, "value": rtcm_health(cid, pw)})
        print(f"  row {i} {cors}: portal={res.get('status','?')} rtcm queued")

    r = sheet_write(updates) if updates else {"written": 0}
    print(f"[{datetime.datetime.utcnow().isoformat()}] full_rows={len(full_rows)} "
          f"android_hits={len(aid_map)} cells_written={r.get('written', 0)}")


if __name__ == "__main__":
    main()
