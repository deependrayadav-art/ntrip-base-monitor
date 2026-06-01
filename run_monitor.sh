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
TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
TS_IST="$(TZ='Asia/Kolkata' date '+%Y-%m-%d %H:%M:%S')"
TIMEOUT="${NTRIP_TIMEOUT:-12}"
ROWS_FILE="$(mktemp)"; : > "$ROWS_FILE"

first_run=true
if ls -A "$STATE_DIR" 2>/dev/null | grep -vq '^\.gitkeep$'; then first_run=false; fi

changes=(); up=0; total=0
while IFS= read -r line; do
  mount="$(echo "$line" | sed 's/#.*//' | xargs)"
  [ -z "$mount" ] && continue
  total=$((total+1))
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
  [ "$now" = "UP" ] && up=$((up+1))
  sleep 4   # space out connections so the caster releases the prior session
  echo "[$mount] $prev -> $now :: $detail"

  # --- metrics row for the Google Sheet (from the same probe) ---
  frames="$(printf '%s\n' "$OUT" | sed -n 's/^FRAMES=//p')"; case "$frames" in ''|*[!0-9]*) frames=0 ;; esac
  bytes="$(printf '%s\n' "$OUT" | sed -n 's/^BYTES=//p')";   case "$bytes"  in ''|*[!0-9]*) bytes=0 ;; esac
  metrics="$(printf '%s\n' "$OUT" | sed -n 's/^METRICS=//p')"
  echo "$metrics" | jq -e . >/dev/null 2>&1 || metrics='{"sats_total":0,"sats_gps":0,"sats_glo":0,"sats_gal":0,"sats_bds":0,"sats_qzs":0,"lat":"","lon":"","height_m":""}'
  data_rate=$(( bytes / TIMEOUT ))
  jq -nc --arg ts "$TS" --arg tsist "$TS_IST" --arg st "$mount" --arg status "$now" \
    --argjson bytes "$bytes" --argjson rate "$data_rate" --argjson frames "$frames" \
    --argjson metrics "$metrics" --arg detail "$detail" \
    '{ts_utc:$ts, ts_ist:$tsist, station:$st, status:$status, rtcm_bytes:$bytes,
      data_rate_bps:$rate, frames:$frames, detail:$detail} + $metrics' >> "$ROWS_FILE"

  was_h=false; [ "$prev" = "UP" ] && was_h=true
  is_h=false;  [ "$now"  = "UP" ] && is_h=true
  if [ "$prev" = "UNKNOWN" ] || [ "$was_h" != "$is_h" ]; then
    changes+=("$mount|$prev|$now|$detail|$is_h")
  fi
  printf '%s|%s|%s\n' "$now" "$TS" "$detail" > "$sf"
done < mounts.txt

echo "Summary: $up/$total UP; ${#changes[@]} change(s) this run."

# --- Log every station's metrics to the Google Sheet (Apps Script web app) ---
if [ -n "${APPS_SCRIPT_URL:-}" ] && [ -n "${APPS_SCRIPT_SECRET:-}" ]; then
  ROWS_JSON="$(jq -s '.' "$ROWS_FILE")"
  PAYLOAD="$(jq -n --arg secret "$APPS_SCRIPT_SECRET" --argjson rows "$ROWS_JSON" '{secret:$secret, rows:$rows}')"
  SCODE="$(curl -s -L -m 30 -o /tmp/sheets.out -w '%{http_code}' -X POST "$APPS_SCRIPT_URL" \
    -H 'Content-Type: application/json' -d "$PAYLOAD")"
  echo "Sheet log HTTP $SCODE: $(head -c 300 /tmp/sheets.out)"
else
  echo "APPS_SCRIPT_URL/SECRET not set — skipping Google Sheet logging."
fi

[ "${#changes[@]}" -eq 0 ] && { echo "No health changes; no e-mail."; exit 0; }
[ -z "${RESEND_API_KEY:-}" ] && { echo "No RESEND_API_KEY; skipping e-mail."; exit 0; }

any_down=false; rows=""; names=""
for c in "${changes[@]}"; do
  IFS='|' read -r m p n d h <<< "$c"
  [ "$h" = "true" ] || any_down=true
  col="#188038"; [ "$h" = "true" ] || col="#d93025"
  rows="$rows<tr><td style='padding:5px 12px;border-bottom:1px solid #eee'><b>$m</b></td>"
  rows="$rows<td style='padding:5px 12px;border-bottom:1px solid #eee;color:$col'><b>$n</b></td>"
  rows="$rows<td style='padding:5px 12px;border-bottom:1px solid #eee;color:#5f6368'>was $p</td>"
  rows="$rows<td style='padding:5px 12px;border-bottom:1px solid #eee;color:#5f6368'>$d</td></tr>"
  names="$names $m"
done

if $first_run; then         subject="📡 NTRIP monitor active — $up/$total mounts UP"
elif $any_down; then        subject="🔴 Base station change —$names"
else                        subject="✅ Base station recovered —$names"
fi

HTML="<div style='font-family:Arial,sans-serif;font-size:14px;color:#202124'>
  <p style='font-size:16px'><b>NTRIP status change</b> &middot; $TS</p>
  <p style='color:#5f6368'>Caster $NTRIP_IP:$NTRIP_PORT &middot; <b>$up/$total</b> mounts currently UP</p>
  <table style='border-collapse:collapse;font-size:13px'>
    <tr style='background:#f1f3f4'><th align='left' style='padding:6px 12px'>Mount</th>
      <th align='left' style='padding:6px 12px'>Now</th>
      <th align='left' style='padding:6px 12px'>Previous</th>
      <th align='left' style='padding:6px 12px'>Detail</th></tr>
  $rows
  </table>
  <p style='color:#9aa0a6;font-size:12px'>NTRIP base-station monitor &middot; GitHub Actions &middot; alerts only on up/down change</p>
</div>"

PAYLOAD="$(jq -n --arg from "$ALERT_FROM" --arg to "$ALERT_TO" --arg s "$subject" --arg h "$HTML" \
  '{from:$from, to:[$to], subject:$s, html:$h}')"
CODE="$(curl -s -o /tmp/resend.out -w '%{http_code}' -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer $RESEND_API_KEY" -H "Content-Type: application/json" -d "$PAYLOAD")"
echo "Resend HTTP $CODE"; cat /tmp/resend.out; echo
[ "$CODE" = "200" ] || [ "$CODE" = "201" ] || { echo "::error::Resend send failed ($CODE)"; exit 1; }
