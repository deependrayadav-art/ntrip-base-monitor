#!/usr/bin/env python3
"""One-time batch probe of NTRIP subscriptions.

Reads a JSON array of accounts from the SUBS_JSON env var and, for each,
opens an NTRIP connection to caster ip:port/mount using that account's
credentials to determine whether the CORS subscription is active.

Signal used:
  - caster returns 401/403  -> subscription rejected (INACTIVE, or account
                               in-use / connection-limit -- see caveat)
  - caster returns 200/ICY  -> credentials accepted (subscription ACTIVE);
                               RTCM frames flowing additionally confirm the
                               mount is live and the account can pull data
  - SOURCETABLE / 404       -> auth not conclusively checked, mount not serving
  - no TCP response         -> caster/host unreachable

Never prints passwords. Emits results.json and results.csv.
"""
import base64, csv, json, os, socket, sys, time

READ_SECS = 6.0          # max seconds to read stream per probe
FRAMES_UP = 3            # RTCM frames that confirm a live stream
SPACING = 3.5           # seconds between accounts (caster rate-limits bursts)
RETRY_AFTER = 6.0        # retry delay on 401/unreachable
CONNECT_TIMEOUT = 12.0

# Approx positions to feed a VRS as GGA so it emits corrections.
GGA_BY_REGION = {"MP": (23.2599, 77.4126), "Punjab": (30.2406, 74.9529)}


def nmea_gga(lat, lon):
    def dm(v, is_lat):
        h = ("N" if v >= 0 else "S") if is_lat else ("E" if v >= 0 else "W")
        v = abs(v); d = int(v); m = (v - d) * 60
        return f"{d:02d}{m:09.6f}" if is_lat else f"{d:03d}{m:09.6f}", h
    latv, ns = dm(lat, True); lonv, ew = dm(lon, False)
    body = f"GPGGA,120000.00,{latv},{ns},{lonv},{ew},1,10,1.0,100.0,M,45.0,M,,"
    cs = 0
    for ch in body:
        cs ^= ord(ch)
    return f"${body}*{cs:02X}\r\n"


def count_rtcm(b):
    n = len(b); i = 0; f = 0
    while i < n - 5:
        if b[i] == 0xD3 and (b[i + 1] & 0xFC) == 0:
            L = ((b[i + 1] & 0x03) << 8) | b[i + 2]
            nxt = i + 3 + L + 3
            if 0 < L <= 1023 and nxt <= n:
                f += 1; i = nxt; continue
        i += 1
    return f


def probe_once(ip, port, mount, user, pw, region):
    """Returns dict: http_line, code, bytes, frames, is_sourcetable, err."""
    res = {"http_line": "", "code": 0, "bytes": 0, "frames": 0,
           "is_sourcetable": False, "err": ""}
    try:
        s = socket.create_connection((ip, int(port)), timeout=CONNECT_TIMEOUT)
    except Exception as e:
        res["err"] = f"connect: {type(e).__name__}"
        return res
    try:
        auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
        req = (f"GET /{mount} HTTP/1.1\r\n"
               f"Host: {ip}:{port}\r\n"
               f"Ntrip-Version: Ntrip/2.0\r\n"
               f"User-Agent: NTRIP subs-probe/1.0\r\n"
               f"Authorization: Basic {auth}\r\n"
               f"Accept: */*\r\n"
               f"Connection: close\r\n\r\n")
        s.sendall(req.encode())
        s.settimeout(READ_SECS)
        buf = b""
        deadline = time.time() + READ_SECS
        sent_gga = False
        while time.time() < deadline:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                break
            except Exception:
                break
            if not chunk:
                break
            buf += chunk
            # Parse status line as soon as we have it.
            if not res["http_line"] and b"\n" in buf:
                first = buf.split(b"\n", 1)[0].decode("latin1", "replace").strip()
                res["http_line"] = first
                up = first.upper()
                for cand in ("401", "403", "404", "200"):
                    if cand in up:
                        res["code"] = int(cand); break
                if "SOURCETABLE" in up:
                    res["is_sourcetable"] = True
                if "401" in up or "403" in up:
                    break  # auth rejected, no point reading further
                # Send GGA once for VRS-style mounts to trigger corrections.
                if not sent_gga and region in GGA_BY_REGION:
                    try:
                        s.sendall(nmea_gga(*GGA_BY_REGION[region]).encode())
                    except Exception:
                        pass
                    sent_gga = True
            if count_rtcm(buf) >= FRAMES_UP:
                break
        res["bytes"] = len(buf)
        res["frames"] = count_rtcm(buf)
        if b"SOURCETABLE" in buf[:64]:
            res["is_sourcetable"] = True
        if not res["http_line"] and buf:
            res["http_line"] = buf[:40].decode("latin1", "replace").strip()
    finally:
        try:
            s.close()
        except Exception:
            pass
    return res


def classify(r):
    """Map a probe result to a subscription verdict."""
    if r["frames"] >= FRAMES_UP:
        return "ACTIVE", "streaming RTCM (%d frames, %d bytes)" % (r["frames"], r["bytes"])
    if r["code"] in (401, 403):
        return "INACTIVE", "HTTP %d — credentials rejected (or account in use / conn-limit)" % r["code"]
    if r["is_sourcetable"]:
        return "MOUNT_DOWN", "caster returned SOURCETABLE — mount not broadcasting; sub status unconfirmed"
    if r["code"] == 404:
        return "MOUNT_NOT_FOUND", "HTTP 404 — mount not on caster"
    if r["code"] == 200 or (r["http_line"] and "200" in r["http_line"]):
        return "ACTIVE", "auth accepted (200) but no RTCM captured (mount idle / VRS needs fix / brief read)"
    if r["err"].startswith("connect") or (r["bytes"] == 0 and not r["http_line"]):
        return "UNREACHABLE", r["err"] or "no HTTP response"
    return "UNKNOWN", "line=%r bytes=%d frames=%d" % (r["http_line"], r["bytes"], r["frames"])


def main():
    accts = json.loads(os.environ["SUBS_JSON"])
    print(f"Probing {len(accts)} accounts...", flush=True)
    out = []
    for idx, a in enumerate(accts, 1):
        user = a.get("user", ""); pw = a.get("pass", "")
        ip = a.get("ip", ""); port = a.get("port", 2101)
        mount = a.get("mount", ""); region = a.get("region", "")
        r = probe_once(ip, port, mount, user, pw, region)
        verdict, detail = classify(r)
        # One retry for ambiguous/transient rejections.
        if verdict in ("INACTIVE", "UNREACHABLE"):
            time.sleep(RETRY_AFTER)
            r2 = probe_once(ip, port, mount, user, pw, region)
            v2, d2 = classify(r2)
            if v2 == "ACTIVE" or (verdict == "UNREACHABLE" and v2 != "UNREACHABLE"):
                r, verdict, detail = r2, v2, d2 + " (on retry)"
            else:
                detail = d2 + " (confirmed on retry)"
        rec = {"region": region, "app_user": a.get("app_user", ""),
               "user": user, "ip": ip, "port": port, "mount": mount,
               "db_active": a.get("db_active"),
               "verdict": verdict, "http_line": r["http_line"],
               "bytes": r["bytes"], "frames": r["frames"], "detail": detail}
        out.append(rec)
        print(f"[{idx:>3}/{len(accts)}] {region:6} {mount:22} {user:28} -> {verdict} ({r['frames']}f {r['bytes']}b) {r['http_line'][:30]}", flush=True)
        time.sleep(SPACING)

    json.dump(out, open("results.json", "w"), indent=1)
    with open("results.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0].keys()))
        w.writeheader(); w.writerows(out)

    from collections import Counter
    print("\n=== SUMMARY ===", flush=True)
    for k, v in Counter(x["verdict"] for x in out).most_common():
        print(f"  {k}: {v}", flush=True)


if __name__ == "__main__":
    main()
