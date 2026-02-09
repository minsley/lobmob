#!/bin/bash
# lobmob-watchdog — deterministic fleet health monitoring
# Runs every 5 min via cron. Replaces the Haiku LLM watchdog agent.
set -euo pipefail
source /etc/lobmob/env

LOG="/var/log/lobmob-watchdog.log"
NOW=$(date +%s)
STALE_THRESHOLD=600  # 10 min since last gateway log = stale

# Helper: post to Discord channel via bot API
# Requires DISCORD_CHANNEL_ID_<NAME> in env, or falls back to channel name lookup
discord_post_channel() {
  local channel_name="$1" msg="$2"
  source /etc/lobmob/secrets.env 2>/dev/null || true
  [ -n "${DISCORD_BOT_TOKEN:-}" ] || return 0
  # Look up channel ID from openclaw config (cached guild channels)
  local channel_id=$(jq -r ".channels.discord.guilds[].channels | to_entries[] | select(.key == \"$channel_name\") | .key" /root/.openclaw/openclaw.json 2>/dev/null || true)
  # For now, log to file instead of Discord if we can't resolve the channel ID
  if [ -z "$channel_id" ]; then
    echo "$(date -Iseconds) [discord-post] Could not resolve channel: $channel_name — $msg" >> /var/log/lobmob-watchdog.log
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
  discord_post_channel "${DISCORD_CHANNEL_SWARM_LOGS:-swarm-logs}" "$MSG"
  echo "$(date -Iseconds) Alerts posted: $ALERTS" >> "$LOG"
fi
