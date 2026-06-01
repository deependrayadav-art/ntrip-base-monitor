#!/usr/bin/env python3
"""Decode a captured RTCM sample (stream.bin) and print available data points.
Usage: decode_rtcm.py <seconds> <mount-label>"""
import sys, math, io
from collections import Counter
from pyrtcm import RTCMReader

secs = int(sys.argv[1]); label = sys.argv[2]
data = open("stream.bin", "rb").read()
print(f"\n===== RTCM DECODE: {label}  ({len(data)} bytes, ~{secs}s) =====")
if len(data) < 30:
    print("  (no/too little stream data — mount likely DOWN or returned a sourcetable)")
    sys.exit(0)

MSM = {107:"GPS",108:"GLONASS",109:"Galileo",110:"SBAS",111:"QZSS",112:"BeiDou",113:"NavIC"}
NAMES = {"1004":"GPS L1/L2 obs (legacy)","1005":"Stationary ARP (no height)",
         "1006":"Stationary ARP + antenna height","1007":"Antenna descriptor",
         "1008":"Antenna descriptor+serial","1012":"GLONASS L1/L2 obs (legacy)",
         "1019":"GPS ephemeris","1020":"GLONASS ephemeris",
         "1033":"Receiver & antenna descriptors","1042":"BeiDou ephemeris",
         "1044":"QZSS ephemeris","1045":"Galileo F/NAV eph","1046":"Galileo I/NAV eph",
         "1230":"GLONASS code-phase biases"}

counts = Counter(); sats = {}; coords = {}; antenna = {}; receiver = {}
for (_raw, msg) in RTCMReader(io.BytesIO(data)):
    if msg is None:
        continue
    ident = msg.identity
    counts[ident] += 1
    try:
        pre = int(ident[:3])
        if pre in MSM and hasattr(msg, "DF394"):
            sats[ident] = bin(int(msg.DF394)).count("1")
    except Exception:
        pass
    if ident in ("1005", "1006"):
        try:
            X, Y, Z = float(msg.DF025), float(msg.DF026), float(msg.DF027)
            a = 6378137.0; f = 1/298.257223563; e2 = f*(2-f)
            p = math.hypot(X, Y); lon = math.atan2(Y, X); lat = math.atan2(Z, p*(1-e2)); h = 0
            for _ in range(6):
                N = a/math.sqrt(1-e2*math.sin(lat)**2); h = p/math.cos(lat)-N
                lat = math.atan2(Z, p*(1-e2*N/(N+h)))
            coords[ident] = (math.degrees(lat), math.degrees(lon), h)
        except Exception as e:
            coords[ident] = ("err", str(e), "")
    if ident in ("1007", "1008", "1033"):
        for f_, k in (("DF030","model"),):
            if hasattr(msg, f_): antenna[k] = str(getattr(msg, f_))
        for f_, k in (("DF228","model"),("DF230","firmware"),("DF232","serial")):
            if hasattr(msg, f_): receiver[k] = str(getattr(msg, f_))

print(f"Decoded {sum(counts.values())} messages, {len(counts)} distinct types.\n")
print(f"{'MsgType':<8}{'Count':>6}  {'~Hz':>5}  Description")
for ident, c in sorted(counts.items()):
    extra = NAMES.get(ident, "")
    try:
        pre = int(ident[:3])
        if pre in MSM: extra = f"{MSM[pre]} MSM observations"
    except Exception:
        pass
    s = f"  sats={sats[ident]}" if ident in sats else ""
    print(f"{ident:<8}{c:>6}  {c/secs:>5.1f}  {extra}{s}")

print("\n--- Derived data points ---")
for k, v in coords.items():
    if isinstance(v[0], float):
        print(f"Base position ({k}): lat={v[0]:.7f}  lon={v[1]:.7f}  h={v[2]:.2f} m (ellipsoidal)")
if antenna: print("Antenna:", antenna)
if receiver: print("Receiver:", receiver)
if sats:
    print("Satellites by constellation:",
          {MSM[int(k[:3])]: v for k, v in sats.items()}, f"(snapshot total ~{sum(sats.values())})")
print("Throughput: ~%d B/s (%.1f kbit/s)" % (len(data)//secs, len(data)*8/secs/1000))
