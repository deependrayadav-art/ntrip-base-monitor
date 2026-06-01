#!/usr/bin/env python3
"""Decode a captured RTCM sample file and emit compact JSON metrics on stdout.
Usage: decode_metrics.py <stream-file>  -> {"sats_total":..,"lat":..,...}
Safe on non-RTCM / empty data (returns zeros / blanks). Requires pyrtcm."""
import sys, math, io, json, time

out = {"sats_total": 0, "sats_gps": 0, "sats_glo": 0, "sats_gal": 0,
       "sats_bds": 0, "sats_qzs": 0, "lat": "", "lon": "", "height_m": "",
       "correction_latency_sec": ""}
try:
    from pyrtcm import RTCMReader
    data = open(sys.argv[1], "rb").read()
    MSM = {107: "sats_gps", 108: "sats_glo", 109: "sats_gal", 111: "sats_qzs", 112: "sats_bds"}
    gps_tow_ms = None   # latest GPS MSM epoch time (ms into the GPS week)
    for _raw, m in RTCMReader(io.BytesIO(data)):
        if m is None:
            continue
        ident = m.identity
        try:
            pre = int(ident[:3])
            if pre in MSM and hasattr(m, "DF394"):
                out[MSM[pre]] = bin(int(m.DF394)).count("1")
            if pre == 107 and hasattr(m, "DF004"):     # GPS MSM epoch (TOW, ms)
                t = int(m.DF004)
                if gps_tow_ms is None or t > gps_tow_ms:
                    gps_tow_ms = t
        except Exception:
            pass
        if ident in ("1005", "1006") and out["lat"] == "":
            try:
                X, Y, Z = float(m.DF025), float(m.DF026), float(m.DF027)
                a = 6378137.0; f = 1 / 298.257223563; e2 = f * (2 - f)
                p = math.hypot(X, Y); lon = math.atan2(Y, X); lat = math.atan2(Z, p * (1 - e2)); h = 0
                for _ in range(6):
                    N = a / math.sqrt(1 - e2 * math.sin(lat) ** 2); h = p / math.cos(lat) - N
                    lat = math.atan2(Z, p * (1 - e2 * N / (N + h)))
                out["lat"] = round(math.degrees(lat), 7)
                out["lon"] = round(math.degrees(lon), 7)
                out["height_m"] = round(h, 2)
            except Exception:
                pass
    out["sats_total"] = sum(out[k] for k in ("sats_gps", "sats_glo", "sats_gal", "sats_bds", "sats_qzs"))

    # Caster-side correction latency: how old the freshest GPS epoch is vs now.
    # GPS epoch = 1980-01-06 UTC (unix 315964800); GPS is ahead of UTC by 18
    # leap seconds (constant since 2017). TOW = seconds into the GPS week.
    if gps_tow_ms is not None:
        gps_now_tow = ((time.time() - 315964800) + 18) % 604800
        lat_s = gps_now_tow - gps_tow_ms / 1000.0
        if lat_s < -302400:   lat_s += 604800     # week wrap
        elif lat_s > 302400:  lat_s -= 604800
        out["correction_latency_sec"] = round(max(0.0, lat_s), 1)
except Exception:
    pass
print(json.dumps(out))
