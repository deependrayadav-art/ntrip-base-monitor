#!/usr/bin/env python3
# Minimal NTRIP v2 client for VRS mounts: connects, sends the request, then
# streams an NMEA GGA position (VRS casters won't broadcast until they get one),
# re-sending it every few seconds, and captures the raw stream to <out_file>.
# Prints "HTTP=<code> BYTES=<n>" so check_ntrip.sh can reuse its framing/metrics
# logic unchanged. Falls back gracefully (writes what it got) on any error.
#
# Args: ip port mount user pass timeout "lat,lon" out_file
import sys, socket, base64, time, datetime

ip, port, mount, user, pw, timeout, latlon, out = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5],
    float(sys.argv[6]), sys.argv[7], sys.argv[8],
)

def gga():
    lat, lon = (float(x) for x in latlon.split(","))
    ns, ew = ("N" if lat >= 0 else "S"), ("E" if lon >= 0 else "W")
    lat, lon = abs(lat), abs(lon)
    latd, lond = int(lat), int(lon)
    body = (f"GPGGA,{datetime.datetime.utcnow():%H%M%S.00},"
            f"{latd:02d}{(lat-latd)*60:07.4f},{ns},"
            f"{lond:03d}{(lon-lond)*60:07.4f},{ew},1,12,0.8,220.0,M,45.0,M,,")
    cs = 0
    for ch in body:
        cs ^= ord(ch)
    return f"${body}*{cs:02X}\r\n".encode()

auth = base64.b64encode(f"{user}:{pw}".encode()).decode()
req = (f"GET /{mount} HTTP/1.1\r\nHost: {ip}:{port}\r\n"
       f"Ntrip-Version: Ntrip/2.0\r\nUser-Agent: NTRIP base-monitor/1.0\r\n"
       f"Authorization: Basic {auth}\r\nAccept: */*\r\nConnection: close\r\n\r\n").encode()

data = b""
code = "000"
try:
    s = socket.create_connection((ip, port), timeout=timeout)
    s.sendall(req)
    try:
        s.sendall(gga())
    except Exception:
        pass
    s.settimeout(timeout)
    start = last = time.time()
    header_done = False
    buf = b""
    while time.time() - start < timeout:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        if not header_done:
            buf += chunk
            if b"\r\n\r\n" in buf:
                head, rest = buf.split(b"\r\n\r\n", 1)
                first = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
                parts = first.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    code = parts[1]
                elif "200" in first:      # "ICY 200 OK" (NTRIP v1)
                    code = "200"
                data += rest
                header_done = True
        else:
            data += chunk
        if time.time() - last > 5:        # keep the VRS stream alive
            try:
                s.sendall(gga())
            except Exception:
                pass
            last = time.time()
    s.close()
except Exception as e:
    sys.stderr.write(str(e))

open(out, "wb").write(data)
print(f"HTTP={code} BYTES={len(data)}")
