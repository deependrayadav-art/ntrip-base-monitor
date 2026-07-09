#!/usr/bin/env bash
# NTRIP monitor.
#   1) Probes every physical-base mount in mounts.txt against the default caster.
#   2) Probes the NetworkVRS RTCM_VRS caster once per credential, but ONLY for
#      accounts currently AVAILABLE in the pool (IN_USE = a surveyor is on it,
#      healthy by definition; DISABLED = intentionally off) — so a probe never
#      collides with a live rover. Availability comes from the CORS Credentials
#      sheet (read=CORS Credentials), refreshed every ~2 min.
# One consolidated e-mail per run lists mounts whose health tier flipped.
# Per-mount/-account state in state/<safe-name>; every row is logged to the
# Base Station Logs Google Sheet (Apps Script) for the dashboard.
#
# Env: NTRIP_IP NTRIP_PORT NTRIP_USER NTRIP_PASS [NTRIP_TIMEOUT]
#      NETWORKVRS_ACCOUNTS ("user:pass;user:pass;...")  CORS_CREDS_URL CORS_CREDS_SECRET
#      RESEND_API_KEY ALERT_FROM ALERT_TO  APPS_SCRIPT_URL APPS_SCRIPT_SECRET
set -uo pipefail

STATE_DIR="state"; mkdir -p "$STATE_DIR"
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
TS_IST="$(TZ='Asia/Kolkata' date '+%d %b %Y, %H:%M IST')"
TIMEOUT="${NTRIP_TIMEOUT:-12}"
ROWS_FILE="$(mktemp)"; : > "$ROWS_FILE"
ZERO_METRICS='{"sats_total":0,"sats_gps":0,"sats_glo":0,"sats_gal":0,"sats_bds":0,"sats_qzs":0,"lat":"","lon":"","height_m":""}'

DEGRADED_RATE_BPS=300
DEGRADED_MIN_SATS=8
tier() { case "$1" in UP) echo healthy ;; DEGRADED) echo degraded ;; *) echo down ;; esac; }

DEF_IP="${NTRIP_IP:?NTRIP_IP required}"; DEF_PORT="${NTRIP_PORT:?NTRIP_PORT required}"
DEF_USER="${NTRIP_USER:?NTRIP_USER required}"; DEF_PASS="${NTRIP_PASS:?NTRIP_PASS required}"

first_run=true
if ls -A "$STATE_DIR" 2>/dev/null | grep -vq '^\.gitkeep$'; then first_run=false; fi

changes=(); up=0; total=0

# Append one row to the Google-Sheet payload.
emit_row() { # station status detail bytes rate frames metricsJson
  jq -nc --arg ts "$TS" --arg tsist "$TS_IST" --arg st "$1" --arg status "$2" \
    --argjson bytes "$4" --argjson rate "$5" --argjson frames "$6" \
    --argjson metrics "$7" --arg detail "$3" \
    '{ts_utc:$ts, ts_ist:$tsist, station:$st, status:$status, rtcm_bytes:$bytes,
      data_rate_bps:$rate, frames:$frames, detail:$detail} + $metrics' >> "$ROWS_FILE"
}

# Probe the mount with the currently-exported NTRIP_* env; record a row, state,
# and a change for the alert e-mail. $station is the label (state key + sheet).
probe_record() { # mount station
  local mount="$1" station="$2"
  local to="${NTRIP_TIMEOUT:-$TIMEOUT}"
  total=$((total+1))
  local safe sf prev OUT now detail
  safe="$(echo "$station" | tr -c 'A-Za-z0-9._-' '_')"; sf="$STATE_DIR/$safe"
  prev="UNKNOWN"; [ -f "$sf" ] && prev="$(cut -d'|' -f1 "$sf" | tr -d '[:space:]')"
  export NTRIP_MOUNT="$mount"
  OUT="$(./check_ntrip.sh)"
  now="$(printf '%s\n' "$OUT" | sed -n 's/^STATUS=//p')"; now="${now:-DOWN}"
  detail="$(printf '%s\n' "$OUT" | sed -n 's/^DETAIL=//p')"
  if [ "$now" = "AUTH_ERROR" ] || [ "$now" = "UNREACHABLE" ]; then
    sleep 6
    OUT="$(./check_ntrip.sh)"
    local n2 d2
    n2="$(printf '%s\n' "$OUT" | sed -n 's/^STATUS=//p')"; n2="${n2:-DOWN}"
    d2="$(printf '%s\n' "$OUT" | sed -n 's/^DETAIL=//p')"
    if [ "$n2" = "UP" ] || [ "$now" != "$n2" ]; then now="$n2"; detail="$d2 (after retry)"; fi
  fi
  sleep 4
  local frames bytes metrics data_rate sats_total
  frames="$(printf '%s\n' "$OUT" | sed -n 's/^FRAMES=//p')"; case "$frames" in ''|*[!0-9]*) frames=0 ;; esac
  bytes="$(printf '%s\n' "$OUT" | sed -n 's/^BYTES=//p')";   case "$bytes"  in ''|*[!0-9]*) bytes=0 ;; esac
  metrics="$(printf '%s\n' "$OUT" | sed -n 's/^METRICS=//p')"
  echo "$metrics" | jq -e . >/dev/null 2>&1 || metrics="$ZERO_METRICS"
  data_rate=$(( bytes / to ))
  sats_total="$(echo "$metrics" | jq -r '.sats_total // 0')"; case "$sats_total" in ''|*[!0-9]*) sats_total=0 ;; esac
  if [ "$now" = "UP" ]; then
    if [ "$data_rate" -lt "$DEGRADED_RATE_BPS" ] || { [ "$sats_total" -gt 0 ] && [ "$sats_total" -lt "$DEGRADED_MIN_SATS" ]; }; then
      now="DEGRADED"; detail="$detail | DEGRADED (rate=${data_rate}B/s, sats=${sats_total})"
    fi
  fi
  [ "$now" = "UP" ] && up=$((up+1))
  echo "[$station] $prev -> $now :: $detail"
  emit_row "$station" "$now" "$detail" "$bytes" "$data_rate" "$frames" "$metrics"
  local prevTier nowTier
  prevTier="$(tier "$prev")"; nowTier="$(tier "$now")"
  if [ "$prev" = "UNKNOWN" ] || [ "$prevTier" != "$nowTier" ]; then
    changes+=("$station|$prev|$now|$detail|$nowTier")
  fi
  printf '%s|%s|%s\n' "$now" "$TS" "$detail" > "$sf"
}

# ---- 1) Physical-base mounts (default caster) ---- (skipped when targeting one account)
if [ -z "${ONLY_ACCOUNT:-}" ]; then
while IFS= read -r line; do
  clean="$(printf '%s' "$line" | sed 's/#.*//')"
  [ -z "$(printf '%s' "$clean" | xargs)" ] && continue
  # "MOUNT" or override "MOUNT|IP|PORT|USER_ENV|PASS_ENV|lat,lon".
  IFS='|' read -r f_mount f_ip f_port f_uenv f_penv f_gga <<< "$clean"
  mount="$(printf '%s' "$f_mount" | xargs)"; [ -z "$mount" ] && continue
  export NTRIP_IP="$(printf '%s' "${f_ip:-$DEF_IP}" | xargs)"
  export NTRIP_PORT="$(printf '%s' "${f_port:-$DEF_PORT}" | xargs)"
  u_env="$(printf '%s' "${f_uenv:-}" | xargs)"; p_env="$(printf '%s' "${f_penv:-}" | xargs)"
  if [ -n "$u_env" ]; then export NTRIP_USER="${!u_env:-}"; else export NTRIP_USER="$DEF_USER"; fi
  if [ -n "$p_env" ]; then export NTRIP_PASS="${!p_env:-}"; else export NTRIP_PASS="$DEF_PASS"; fi
  export NTRIP_GGA="$(printf '%s' "${f_gga:-}" | xargs)"
  export NTRIP_TIMEOUT="$TIMEOUT"
  probe_record "$mount" "$mount"
done < mounts.txt
fi

# ---- 2) NetworkVRS RTCM_VRS: probe only AVAILABLE accounts ----
if [ -n "${NETWORKVRS_ACCOUNTS:-}" ]; then
  VRS_IP="103.205.244.106"; VRS_PORT="2101"; VRS_MOUNT="RTCM_VRS"; VRS_GGA="30.2407,74.9528"
  CJSON=""
  if [ -n "${CORS_CREDS_URL:-}" ] && [ -n "${CORS_CREDS_SECRET:-}" ]; then
    CJSON="$(curl -s -L -m 30 "${CORS_CREDS_URL}?read=CORS%20Credentials&secret=${CORS_CREDS_SECRET}")"
  fi
  IFS=';' read -ra ACCTS <<< "$NETWORKVRS_ACCOUNTS"
  for acct in "${ACCTS[@]}"; do
    user="${acct%%:*}"; pass="${acct#*:}"
    [ -z "$user" ] && continue
    [ -n "${ONLY_ACCOUNT:-}" ] && [ "$user" != "$ONLY_ACCOUNT" ] && continue
    # current pool status for this username (UNKNOWN if sheet unavailable)
    st="UNKNOWN"
    if [ -n "$CJSON" ]; then
      st="$(printf '%s' "$CJSON" | jq -r --arg u "$user" '
        (.header|index("username")) as $ui | (.header|index("status")) as $si |
        ([.rows[]? | select(.[$ui]==$u) | .[$si]] | first) // "UNKNOWN"' 2>/dev/null)"
      st="${st:-UNKNOWN}"
    fi
    station="RTCM_VRS:$user"
    if [ "$st" = "AVAILABLE" ] || [ "$st" = "DISABLED" ] || { [ -n "${ONLY_ACCOUNT:-}" ] && [ "$st" != "IN_USE" ]; }; then
      # Safe to probe: AVAILABLE (free) or DISABLED (pool never hands it out), so
      # no live rover to collide with. Probing a DISABLED account also reveals
      # whether it's still valid upstream (auth) vs truly revoked.
      export NTRIP_IP="$VRS_IP" NTRIP_PORT="$VRS_PORT" NTRIP_GGA="$VRS_GGA"
      export NTRIP_USER="$user" NTRIP_PASS="$pass" NTRIP_TIMEOUT="6"
      probe_record "$VRS_MOUNT" "$station"
    else
      # IN_USE (a live rover is on it) or UNKNOWN status — do NOT probe (would
      # collide / status uncertain). Log the pool status for the dashboard only.
      echo "[$station] (not probed) pool status=$st"
      emit_row "$station" "$st" "not probed — pool status $st" 0 0 0 "$ZERO_METRICS"
    fi
  done
fi

echo "Summary: $up/$total probed UP; ${#changes[@]} change(s) this run."

# --- Log every row to the Base Station Logs Google Sheet ---
if [ -n "${APPS_SCRIPT_URL:-}" ] && [ -n "${APPS_SCRIPT_SECRET:-}" ]; then
  ROWS_JSON="$(jq -s '.' "$ROWS_FILE")"
  PAYLOAD="$(jq -n --arg secret "$APPS_SCRIPT_SECRET" --argjson rows "$ROWS_JSON" '{secret:$secret, rows:$rows}')"
  SCODE="$(curl -s -L -m 30 -o /tmp/sheets.out -w '%{http_code}' "$APPS_SCRIPT_URL" \
    -H 'Content-Type: application/json' -d "$PAYLOAD")"
  echo "Sheet log HTTP $SCODE: $(head -c 300 /tmp/sheets.out)"
else
  echo "APPS_SCRIPT_URL/SECRET not set — skipping Google Sheet logging."
fi

[ "${#changes[@]}" -eq 0 ] && { echo "No health changes; no e-mail."; exit 0; }
[ -z "${RESEND_API_KEY:-}" ] && { echo "No RESEND_API_KEY; skipping e-mail."; exit 0; }

worst="healthy"; rows=""; names=""
for c in "${changes[@]}"; do
  IFS='|' read -r m p n d t <<< "$c"
  case "$t" in
    down)     col="#d93025"; worst="down" ;;
    degraded) col="#d97706"; [ "$worst" != "down" ] && worst="degraded" ;;
    *)        col="#188038" ;;
  esac
  rows="$rows<tr><td style='padding:5px 12px;border-bottom:1px solid #eee'><b>$m</b></td>"
  rows="$rows<td style='padding:5px 12px;border-bottom:1px solid #eee;color:$col'><b>$n</b></td>"
  rows="$rows<td style='padding:5px 12px;border-bottom:1px solid #eee;color:#5f6368'>was $p</td>"
  rows="$rows<td style='padding:5px 12px;border-bottom:1px solid #eee;color:#5f6368'>$d</td></tr>"
  names="$names $m"
done

if $first_run; then                    subject="📡 NTRIP monitor active — $up/$total UP"
elif [ "$worst" = "down" ]; then       subject="🔴 Base station DOWN —$names"
elif [ "$worst" = "degraded" ]; then   subject="🟡 Base station DEGRADED —$names"
else                                   subject="✅ Base station recovered —$names"
fi

HTML="<div style='font-family:Arial,sans-serif;font-size:14px;color:#202124'>
  <p style='font-size:16px'><b>NTRIP status change</b> &middot; $TS</p>
  <p style='color:#5f6368'><b>$up/$total</b> probed mounts/accounts currently UP</p>
  <table style='border-collapse:collapse;font-size:13px'>
    <tr style='background:#f1f3f4'><th align='left' style='padding:6px 12px'>Mount</th>
      <th align='left' style='padding:6px 12px'>Now</th>
      <th align='left' style='padding:6px 12px'>Previous</th>
      <th align='left' style='padding:6px 12px'>Detail</th></tr>
  $rows
  </table>
  <p style='color:#9aa0a6;font-size:12px'>NTRIP base-station monitor &middot; GitHub Actions &middot; alerts on up / degraded / down change. DEGRADED = broadcasting but &lt;${DEGRADED_RATE_BPS} B/s or &lt;${DEGRADED_MIN_SATS} sats (rover fix at risk)</p>
</div>"

PAYLOAD="$(jq -n --arg from "$ALERT_FROM" --arg to "$ALERT_TO" --arg s "$subject" --arg h "$HTML" \
  '{from:$from, to:[$to], subject:$s, html:$h}')"
CODE="$(curl -s -o /tmp/resend.out -w '%{http_code}' -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer $RESEND_API_KEY" -H "Content-Type: application/json" -d "$PAYLOAD")"
echo "Resend HTTP $CODE"; cat /tmp/resend.out; echo
[ "$CODE" = "200" ] || [ "$CODE" = "201" ] || { echo "::error::Resend send failed ($CODE)"; exit 1; }
