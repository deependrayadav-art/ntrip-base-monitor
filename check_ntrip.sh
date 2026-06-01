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

# RTCM3 frames begin with the 0xD3 preamble; its presence in the first KB means
# real correction data is flowing => the base is broadcasting.
has_rtcm=0
if [ -s "$body" ] && head -c 2048 "$body" | LC_ALL=C grep -qa $'\xd3'; then
  has_rtcm=1
fi
# If the requested mount is offline, casters answer with the SOURCETABLE listing.
is_sourcetable=0
if head -c 64 "$body" 2>/dev/null | grep -qa "SOURCETABLE" \
   || head -c 64 "$hdr" 2>/dev/null | grep -qa "SOURCETABLE"; then
  is_sourcetable=1
fi

status="DOWN"; detail=""
if [ "$http" = "401" ] || [ "$http" = "403" ]; then
  status="AUTH_ERROR"; detail="HTTP $http from caster — check NTRIP username/password"
elif [ "$is_sourcetable" = "1" ]; then
  status="DOWN"; detail="caster reachable but returned SOURCETABLE — mount '$MOUNT' is NOT broadcasting"
elif [ "$has_rtcm" = "1" ] || { [ "$http" = "200" ] && [ "$size" -gt 50 ]; }; then
  status="UP"; detail="streaming RTCM (${size} bytes in ${TIMEOUT}s, http=${http})"
elif [ "$http" = "404" ]; then
  status="DOWN"; detail="HTTP 404 — mount '$MOUNT' not found on caster"
elif [ "$http" = "000" ] && [ "$size" = "0" ]; then
  status="UNREACHABLE"; detail="no TCP/HTTP response (curl rc=${curl_rc}) — caster down or network/port blocked"
else
  status="DOWN"; detail="unexpected response (http=${http} size=${size} rc=${curl_rc}, no RTCM)"
fi

echo "STATUS=$status"
echo "DETAIL=$detail"
