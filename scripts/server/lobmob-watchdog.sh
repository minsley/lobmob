#!/bin/bash
# lobmob-watchdog — deterministic fleet health monitoring
# Runs every 5 min via cron. Replaces the Haiku LLM watchdog agent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/container-env.sh" ]]; then
  source "$SCRIPT_DIR/container-env.sh"
else
  source /etc/lobmob/env
  source /etc/lobmob/secrets.env 2>/dev/null || true
fi

LOG="${LOG_DIR:-/var/log}/lobmob-watchdog.log"
NOW=$(date +%s)
STALE_THRESHOLD=600  # 10 min since last gateway log = stale

# Helper: post to Discord channel via bot API
discord_post_channel() {
  local channel_name="$1" msg="$2"
  [[ -n "${DISCORD_BOT_TOKEN:-}" ]] || return 0
  echo "$(date -Iseconds) [discord-post] $channel_name — $msg" >> "$LOG"
}

ALERTS=""
HEALTHY=0
STALE=0
UNREACHABLE=0

if [[ "${LOBMOB_RUNTIME:-droplet}" == "k8s" ]]; then
  # k8s mode: check lobster pod health via kubectl
  while IFS=$'\t' read -r POD_NAME STATUS AGE; do
    [[ -n "$POD_NAME" ]] || continue
    case "$STATUS" in
      Running) HEALTHY=$((HEALTHY + 1)) ;;
      Succeeded) HEALTHY=$((HEALTHY + 1)) ;;
      Failed)
        STALE=$((STALE + 1))
        ALERTS="${ALERTS}FAILED: $POD_NAME (age: $AGE)\n"
        ;;
      Pending)
        # Check if pending too long (> 10 min)
        STALE=$((STALE + 1))
        ALERTS="${ALERTS}PENDING: $POD_NAME (age: $AGE)\n"
        ;;
      *)
        UNREACHABLE=$((UNREACHABLE + 1))
        ALERTS="${ALERTS}UNKNOWN: $POD_NAME status=$STATUS\n"
        ;;
    esac
  done < <(kubectl get pods -n lobmob -l app.kubernetes.io/name=lobster -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp --no-headers 2>/dev/null || true)
else
  # Legacy: check each WG peer
  while read -r PUBKEY ALLOWED; do
    [[ -n "$PUBKEY" ]] || continue
    IP=$(echo "$ALLOWED" | cut -d/ -f1)

    if ! ping -c 1 -W 2 "$IP" > /dev/null 2>&1; then
      UNREACHABLE=$((UNREACHABLE + 1))
      LOBSTER_ID="unknown($IP)"
      ALERTS="${ALERTS}UNREACHABLE: $LOBSTER_ID at $IP\n"
      continue
    fi

    RESULT=$(ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=3 -o BatchMode=yes "root@$IP" \
      'grep LOBSTER_ID /etc/lobmob/env 2>/dev/null | cut -d= -f2; stat -c %Y /var/log/openclaw-gateway.log 2>/dev/null || echo 0' 2>/dev/null || echo "")

    LOBSTER_ID=$(echo "$RESULT" | head -1)
    GW_MTIME=$(echo "$RESULT" | tail -1)
    LOBSTER_ID="${LOBSTER_ID:-unknown($IP)}"

    if [[ -z "$GW_MTIME" ]] || [[ "$GW_MTIME" == "0" ]]; then
      STALE=$((STALE + 1))
      ALERTS="${ALERTS}STALE: lobster-$LOBSTER_ID — no gateway log\n"
    elif [[ $((NOW - GW_MTIME)) -gt $STALE_THRESHOLD ]]; then
      STALE=$((STALE + 1))
      AGE_MIN=$(( (NOW - GW_MTIME) / 60 ))
      ALERTS="${ALERTS}STALE: lobster-$LOBSTER_ID — gateway log ${AGE_MIN}m old\n"
    else
      HEALTHY=$((HEALTHY + 1))
    fi
  done < <(wg show wg0 allowed-ips 2>/dev/null)
fi

# Log results
TOTAL=$((HEALTHY + STALE + UNREACHABLE))
echo "$(date -Iseconds) Watchdog: healthy=$HEALTHY stale=$STALE unreachable=$UNREACHABLE total=$TOTAL" >> "$LOG"

# Post alerts to #swarm-logs if any issues
if [ -n "$ALERTS" ]; then
  MSG="**[watchdog]** Fleet health check: $HEALTHY healthy, $STALE stale, $UNREACHABLE unreachable\n$(echo -e "$ALERTS")"
  discord_post_channel "${DISCORD_CHANNEL_SWARM_LOGS:-swarm-logs}" "$MSG"
  echo "$(date -Iseconds) Alerts posted: $ALERTS" >> "$LOG"
fi
