# NTRIP base-station monitor

A 24×7 GitHub Actions cron that checks whether the NTRIP base station
**`LEPTON_BASE_BHATINDA`** (caster `61.247.224.198:2103`) is broadcasting, and
emails on every up→down / down→up transition.

## How the check works
`check_ntrip.sh` sends a real NTRIP v2 request for the mount point and classifies:

| Status        | Meaning |
|---------------|---------|
| `UP`          | Caster returned RTCM correction data — the base is broadcasting. |
| `DOWN`        | Caster reachable but mount not streaming (returns SOURCETABLE / 404). |
| `UNREACHABLE` | No TCP/HTTP response at all — caster down or the network/port is blocked. |
| `AUTH_ERROR`  | 401/403 — NTRIP username/password rejected. |

An active mount streams forever, so `curl` intentionally hits `--max-time`; bytes
received within that window are the "UP" signal.

## Alerting
- Email is sent **only when health flips** (UP↔not-UP) or on the first run — not every cycle.
- Sent via the Resend API, from `onboarding@resend.dev` to `deependra.yadav@leptonsoftware.com`.
- Last known status is persisted in `state.txt` (committed by the workflow) for cross-run comparison.

## Cadence caveat
The schedule is `*/5 * * * *`. GitHub's cron is ~5-minute granularity and
best-effort (runs are frequently delayed under load) — treat this as *roughly
every 5 minutes*, not a guaranteed 1-minute heartbeat.

## Secrets (repo → Settings → Secrets and variables → Actions)
| Secret | Purpose |
|--------|---------|
| `NTRIP_PASS`      | NTRIP mount-point password |
| `RESEND_API_KEY`  | Resend sending key |

Non-secret config (IP, port, mount, user, e-mail addresses) lives in the `env:`
block of `.github/workflows/monitor.yml`.

## Reachability note
If runs report `UNREACHABLE` forever, the caster likely IP-whitelists clients and
GitHub's runner IPs aren't allowed. In that case run the same `check_ntrip.sh`
from a self-hosted runner or a VPS that can reach port 2103.
