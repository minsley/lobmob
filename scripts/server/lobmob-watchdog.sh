#!/bin/bash
# lobmob-watchdog — deterministic fleet health monitoring
# Runs every 5 min via cron. Replaces the Haiku LLM watchdog agent.
set -euo pipefail
source /etc/lobmob/env

LOG="/var/log/lobmob-watchdog.log"
NOW=$(date +%s)
STALE_THRESHOLD=600  # 10 min since last gateway log = stale

# Helper: post to Discord via gateway API
discord_post() {
  local channel="$1" msg="$2"
  local gw_token=$(jq -r '.gateway.auth.token // empty' /root/.openclaw/openclaw.json 2>/dev/null)
  if [ -n "$gw_token" ]; then
    curl -s -X POST "http://127.0.0.1:18789/api/channels/discord/send" \
      -H "Authorization: Bearer $gw_token" \
      -H "Content-Type: application/json" \
      -d "{\"channel\": \"$channel\", \"content\": \"$msg\"}" 2>/dev/null || true
  fi
}

ALERTS=""
HEALTHY=0
STALE=0
UNREACHABLE=0

# Check each WG peer
while read -r PUBKEY ALLOWED; do
  [ -n "$PUBKEY" ] || continue
  IP=$(echo "$ALLOWED" | cut -d/ -f1)

  # Ping check
  if ! ping -c 1 -W 2 "$IP" > /dev/null 2>&1; then
    UNREACHABLE=$((UNREACHABLE + 1))
    # Try to identify the lobster
    LOBSTER_ID="unknown($IP)"
    ALERTS="${ALERTS}UNREACHABLE: $LOBSTER_ID at $IP\n"
    continue
  fi

  # SSH check: get lobster ID and gateway log freshness
  RESULT=$(ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=3 -o BatchMode=yes "root@$IP" \
    'grep LOBSTER_ID /etc/lobmob/env 2>/dev/null | cut -d= -f2; stat -c %Y /var/log/openclaw-gateway.log 2>/dev/null || echo 0' 2>/dev/null || echo "")

  LOBSTER_ID=$(echo "$RESULT" | head -1)
  GW_MTIME=$(echo "$RESULT" | tail -1)
  LOBSTER_ID="${LOBSTER_ID:-unknown($IP)}"

  if [ -z "$GW_MTIME" ] || [ "$GW_MTIME" = "0" ]; then
    STALE=$((STALE + 1))
    ALERTS="${ALERTS}STALE: lobster-$LOBSTER_ID — no gateway log\n"
  elif [ $((NOW - GW_MTIME)) -gt $STALE_THRESHOLD ]; then
    STALE=$((STALE + 1))
    AGE_MIN=$(( (NOW - GW_MTIME) / 60 ))
    ALERTS="${ALERTS}STALE: lobster-$LOBSTER_ID — gateway log ${AGE_MIN}m old\n"
  else
    HEALTHY=$((HEALTHY + 1))
  fi
done < <(wg show wg0 allowed-ips 2>/dev/null)

# Log results
TOTAL=$((HEALTHY + STALE + UNREACHABLE))
echo "$(date -Iseconds) Watchdog: healthy=$HEALTHY stale=$STALE unreachable=$UNREACHABLE total=$TOTAL" >> "$LOG"

# Post alerts to #swarm-logs if any issues
if [ -n "$ALERTS" ]; then
  MSG="**[watchdog]** Fleet health check: $HEALTHY healthy, $STALE stale, $UNREACHABLE unreachable\n$(echo -e "$ALERTS")"
  discord_post "${DISCORD_CHANNEL_SWARM_LOGS:-swarm-logs}" "$MSG"
  echo "$(date -Iseconds) Alerts posted: $ALERTS" >> "$LOG"
fi
