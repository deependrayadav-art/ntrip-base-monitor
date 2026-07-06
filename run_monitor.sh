#!/usr/bin/env bash
# Multi-mount NTRIP monitor. Probes every mount in mounts.txt, compares each
# with its last known state, and sends ONE consolidated e-mail per run listing
# only the mounts whose health flipped (UP <-> not-UP), or all mounts on the
# very first run. Per-mount state is kept in state/<mount>.
#
# Env: NTRIP_IP NTRIP_PORT NTRIP_USER NTRIP_PASS [NTRIP_TIMEOUT]
#      RESEND_API_KEY ALERT_FROM ALERT_TO
#      APPS_SCRIPT_URL APPS_SCRIPT_SECRET   (Google Sheet logging via Apps Script)
set -uo pipefail

STATE_DIR="state"
mkdir -p "$STATE_DIR"
TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"            # ISO-8601 UTC — parses cleanly in Sheets & JS
TS_IST="$(TZ='Asia/Kolkata' date '+%d %b %Y, %H:%M IST')"  # human label (Sheets won't date-parse it)
TIMEOUT="${NTRIP_TIMEOUT:-12}"
ROWS_FILE="$(mktemp)"; : > "$ROWS_FILE"

# DEGRADED thresholds: a mount can be broadcasting yet too weak for a reliable
# rover RTK fix. Flag DEGRADED when data rate or satellite count falls far below
# the healthy baseline (~800-1000 B/s, ~36-42 sats). Tuned to avoid false alarms.
DEGRADED_RATE_BPS=300     # below this sustained, epochs are dropping
DEGRADED_MIN_SATS=8       # rover needs >=5 common sats; <8 broadcast = risky

# Health tier for alerting: healthy (UP) / degraded / down (everything else).
tier() { case "$1" in UP) echo healthy ;; DEGRADED) echo degraded ;; *) echo down ;; esac; }

# Default caster — used by any mounts.txt line without an explicit override.
DEF_IP="${NTRIP_IP:?NTRIP_IP required}"; DEF_PORT="${NTRIP_PORT:?NTRIP_PORT required}"
DEF_USER="${NTRIP_USER:?NTRIP_USER required}"; DEF_PASS="${NTRIP_PASS:?NTRIP_PASS required}"

first_run=true
if ls -A "$STATE_DIR" 2>/dev/null | grep -vq '^\.gitkeep$'; then first_run=false; fi

changes=(); up=0; total=0
while IFS= read -r line; do
  clean="$(printf '%s' "$line" | sed 's/#.*//')"
  [ -z "$(printf '%s' "$clean" | xargs)" ] && continue
  # Line format: "MOUNT" (default caster) or a pipe-override:
  #   "MOUNT|IP|PORT|USER_ENV|PASS_ENV|lat,lon"  — for a different caster / VRS.
  # Empty override fields fall back to the default caster; a lat,lon in the last
  # field turns on GGA-based probing (VRS mounts).
  IFS='|' read -r f_mount f_ip f_port f_uenv f_penv f_gga <<< "$clean"
  mount="$(printf '%s' "$f_mount" | xargs)"
  [ -z "$mount" ] && continue
  total=$((total+1))
  export NTRIP_IP="$(printf '%s' "${f_ip:-$DEF_IP}" | xargs)"
  export NTRIP_PORT="$(printf '%s' "${f_port:-$DEF_PORT}" | xargs)"
  u_env="$(printf '%s' "${f_uenv:-}" | xargs)"; p_env="$(printf '%s' "${f_penv:-}" | xargs)"
  if [ -n "$u_env" ]; then export NTRIP_USER="${!u_env:-}"; else export NTRIP_USER="$DEF_USER"; fi
  if [ -n "$p_env" ]; then export NTRIP_PASS="${!p_env:-}"; else export NTRIP_PASS="$DEF_PASS"; fi
  export NTRIP_GGA="$(printf '%s' "${f_gga:-}" | xargs)"
  safe="$(echo "$mount" | tr -c 'A-Za-z0-9._-' '_')"
  sf="$STATE_DIR/$safe"
  prev="UNKNOWN"; [ -f "$sf" ] && prev="$(cut -d'|' -f1 "$sf" | tr -d '[:space:]')"

  export NTRIP_MOUNT="$mount"
  OUT="$(./check_ntrip.sh)"
  now="$(printf '%s\n' "$OUT" | sed -n 's/^STATUS=//p')"; now="${now:-DOWN}"
  detail="$(printf '%s\n' "$OUT" | sed -n 's/^DETAIL=//p')"
  # Casters often answer rapid back-to-back connects with a transient 401 or
  # drop; pause and retry once before believing a non-UP result.
  if [ "$now" = "AUTH_ERROR" ] || [ "$now" = "UNREACHABLE" ]; then
    sleep 6
    OUT="$(./check_ntrip.sh)"
    n2="$(printf '%s\n' "$OUT" | sed -n 's/^STATUS=//p')"; n2="${n2:-DOWN}"
    d2="$(printf '%s\n' "$OUT" | sed -n 's/^DETAIL=//p')"
    if [ "$n2" = "UP" ] || [ "$now" != "$n2" ]; then now="$n2"; detail="$d2 (after retry)"; fi
  fi
  sleep 4   # space out connections so the caster releases the prior session

  # --- metrics from the same probe ---
  frames="$(printf '%s\n' "$OUT" | sed -n 's/^FRAMES=//p')"; case "$frames" in ''|*[!0-9]*) frames=0 ;; esac
  bytes="$(printf '%s\n' "$OUT" | sed -n 's/^BYTES=//p')";   case "$bytes"  in ''|*[!0-9]*) bytes=0 ;; esac
  metrics="$(printf '%s\n' "$OUT" | sed -n 's/^METRICS=//p')"
  echo "$metrics" | jq -e . >/dev/null 2>&1 || metrics='{"sats_total":0,"sats_gps":0,"sats_glo":0,"sats_gal":0,"sats_bds":0,"sats_qzs":0,"lat":"","lon":"","height_m":""}'
  data_rate=$(( bytes / TIMEOUT ))
  sats_total="$(echo "$metrics" | jq -r '.sats_total // 0')"; case "$sats_total" in ''|*[!0-9]*) sats_total=0 ;; esac

  # --- DEGRADED: broadcasting, but too weak for a reliable rover fix ---
  if [ "$now" = "UP" ]; then
    if [ "$data_rate" -lt "$DEGRADED_RATE_BPS" ] || { [ "$sats_total" -gt 0 ] && [ "$sats_total" -lt "$DEGRADED_MIN_SATS" ]; }; then
      now="DEGRADED"
      detail="$detail | DEGRADED (rate=${data_rate}B/s, sats=${sats_total})"
    fi
  fi
  [ "$now" = "UP" ] && up=$((up+1))
  echo "[$mount] $prev -> $now :: $detail"

  # row for the Google Sheet (status now reflects DEGRADED)
  jq -nc --arg ts "$TS" --arg tsist "$TS_IST" --arg st "$mount" --arg status "$now" \
    --argjson bytes "$bytes" --argjson rate "$data_rate" --argjson frames "$frames" \
    --argjson metrics "$metrics" --arg detail "$detail" \
    '{ts_utc:$ts, ts_ist:$tsist, station:$st, status:$status, rtcm_bytes:$bytes,
      data_rate_bps:$rate, frames:$frames, detail:$detail} + $metrics' >> "$ROWS_FILE"

  # --- change detection by health tier (healthy / degraded / down) ---
  prevTier="$(tier "$prev")"; nowTier="$(tier "$now")"
  if [ "$prev" = "UNKNOWN" ] || [ "$prevTier" != "$nowTier" ]; then
    changes+=("$mount|$prev|$now|$detail|$nowTier")
  fi
  printf '%s|%s|%s\n' "$now" "$TS" "$detail" > "$sf"
done < mounts.txt

echo "Summary: $up/$total UP; ${#changes[@]} change(s) this run."

# --- Log every station's metrics to the Google Sheet (Apps Script web app) ---
if [ -n "${APPS_SCRIPT_URL:-}" ] && [ -n "${APPS_SCRIPT_SECRET:-}" ]; then
  ROWS_JSON="$(jq -s '.' "$ROWS_FILE")"
  PAYLOAD="$(jq -n --arg secret "$APPS_SCRIPT_SECRET" --argjson rows "$ROWS_JSON" '{secret:$secret, rows:$rows}')"
  # NOTE: no -X POST — Apps Script answers POST with a 302 whose target must be
  # fetched as GET; forcing POST through the redirect yields 405. -d defaults to
  # POST for the first hop, then curl follows the 302 as GET to read the result.
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

if $first_run; then                    subject="📡 NTRIP monitor active — $up/$total mounts UP"
elif [ "$worst" = "down" ]; then       subject="🔴 Base station DOWN —$names"
elif [ "$worst" = "degraded" ]; then   subject="🟡 Base station DEGRADED —$names"
else                                   subject="✅ Base station recovered —$names"
fi

HTML="<div style='font-family:Arial,sans-serif;font-size:14px;color:#202124'>
  <p style='font-size:16px'><b>NTRIP status change</b> &middot; $TS</p>
  <p style='color:#5f6368'><b>$up/$total</b> mounts currently UP (across all casters)</p>
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
