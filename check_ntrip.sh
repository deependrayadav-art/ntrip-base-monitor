#!/usr/bin/env bash
# NTRIP base-station up/down probe.
#
# Connects to an NTRIP caster and requests a mount point, then decides whether
# the base station is broadcasting. Always exits 0; prints two lines:
#   STATUS=<UP|DOWN|UNREACHABLE|AUTH_ERROR>
#   DETAIL=<human-readable explanation>
#
# Required env vars: NTRIP_IP NTRIP_PORT NTRIP_MOUNT NTRIP_USER NTRIP_PASS
# Optional:          NTRIP_TIMEOUT (seconds, default 10)
set -uo pipefail

IP="${NTRIP_IP:?NTRIP_IP required}"
PORT="${NTRIP_PORT:?NTRIP_PORT required}"
MOUNT="${NTRIP_MOUNT:?NTRIP_MOUNT required}"
USER_="${NTRIP_USER:?NTRIP_USER required}"
PASS="${NTRIP_PASS:?NTRIP_PASS required}"
TIMEOUT="${NTRIP_TIMEOUT:-10}"

body="$(mktemp)"; hdr="$(mktemp)"
trap 'rm -f "$body" "$hdr"' EXIT

# NTRIP v2 request. An active mount streams RTCM and never closes the socket,
# so curl is EXPECTED to hit --max-time (rc 28) on a healthy station — that is
# our "UP" signal, not an error. --http0.9 tolerates v1 casters ("ICY 200 OK").
if [ -n "${NTRIP_GGA:-}" ]; then
  # VRS mount (e.g. NetworkVRS RTCM_VRS): the caster won't broadcast until it
  # receives an NMEA GGA position, and curl can't upload a GGA while reading the
  # stream — so use the small socket client, which writes the raw stream to
  # $body and prints "HTTP=<code> BYTES=<n>". Downstream logic is unchanged.
  fres="$(python3 "$(dirname "$0")/ntrip_fetch.py" "$IP" "$PORT" "$MOUNT" "$USER_" "$PASS" "$TIMEOUT" "$NTRIP_GGA" "$body" 2>/dev/null)"
  curl_rc=$?
  http="$(printf '%s' "$fres" | sed -n 's/.*HTTP=\([0-9]\{1,\}\).*/\1/p')"; http="${http:-000}"
  size="$(printf '%s' "$fres" | sed -n 's/.*BYTES=\([0-9]\{1,\}\).*/\1/p')"; size="${size:-0}"
  : > "$hdr"
else
  out="$(curl -s --http0.9 --max-time "$TIMEOUT" \
          -H "Ntrip-Version: Ntrip/2.0" \
          -A "NTRIP base-monitor/1.0" \
          -u "$USER_:$PASS" \
          -D "$hdr" -o "$body" \
          -w '%{http_code} %{size_download}' \
          "http://$IP:$PORT/$MOUNT" 2>/dev/null)"
  curl_rc=$?
  http="${out%% *}"; size="${out##* }"
  http="${http:-000}"; size="${size:-0}"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
fi

# Count well-formed RTCM3 frames by walking the framing: 0xD3 preamble, 10-bit
# length, payload, 3-byte CRC. A real broadcast chains dozens of frames; an
# error page / SOURCETABLE blob chains ~none. This avoids false "UP" on a stray
# 0xD3 byte in non-RTCM data (e.g. an offline mount returning a short blob).
frames=0
if [ -s "$body" ]; then
  frames="$(python3 - "$body" <<'PY' 2>/dev/null || echo 0
import sys
b = open(sys.argv[1], "rb").read(); n = len(b); i = 0; f = 0
while i < n - 5:
    if b[i] == 0xD3 and (b[i+1] & 0xFC) == 0:   # preamble + 6 reserved bits zero
        L = ((b[i+1] & 0x03) << 8) | b[i+2]
        nxt = i + 3 + L + 3
        if 0 < L <= 1023 and nxt <= n:
            f += 1; i = nxt; continue
    i += 1
print(f)
PY
)"
fi
frames="${frames:-0}"; case "$frames" in ''|*[!0-9]*) frames=0 ;; esac

# If the requested mount is offline, casters answer with the SOURCETABLE listing.
is_sourcetable=0
if head -c 64 "$body" 2>/dev/null | grep -qa "SOURCETABLE" \
   || head -c 64 "$hdr" 2>/dev/null | grep -qa "SOURCETABLE"; then
  is_sourcetable=1
fi

status="DOWN"; detail=""
if [ "$frames" -ge 3 ]; then
  status="UP"; detail="streaming RTCM (${frames} frames, ${size} bytes in ${TIMEOUT}s, http=${http})"
elif [ "$http" = "401" ] || [ "$http" = "403" ]; then
  status="AUTH_ERROR"; detail="HTTP $http from caster — bad credentials OR account/connection limit"
elif [ "$is_sourcetable" = "1" ]; then
  status="DOWN"; detail="caster reachable but returned SOURCETABLE — mount '$MOUNT' is NOT broadcasting"
elif [ "$http" = "404" ]; then
  status="DOWN"; detail="HTTP 404 — mount '$MOUNT' not found on caster"
elif [ "$http" = "000" ] && [ "$size" = "0" ]; then
  status="UNREACHABLE"; detail="no TCP/HTTP response (curl rc=${curl_rc}) — caster down or network/port blocked"
else
  status="DOWN"; detail="reachable but no valid RTCM (http=${http} size=${size} frames=${frames} rc=${curl_rc})"
fi

# Decode richer metrics (satellites, base position) from the SAME captured
# stream — no extra connection. Falls back to zeros/blanks on non-RTCM data.
metrics='{"sats_total":0,"sats_gps":0,"sats_glo":0,"sats_gal":0,"sats_bds":0,"sats_qzs":0,"lat":"","lon":"","height_m":""}'
if [ "$status" = "UP" ] && [ -s "$body" ]; then
  m="$(python3 decode_metrics.py "$body" 2>/dev/null)" && [ -n "$m" ] && metrics="$m"
fi

echo "STATUS=$status"
echo "DETAIL=$detail"
echo "FRAMES=$frames"
echo "BYTES=$size"
echo "METRICS=$metrics"
