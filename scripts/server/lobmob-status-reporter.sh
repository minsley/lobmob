#!/bin/bash
# lobmob-status-reporter — periodic fleet summary posted to #swarm-logs
# Runs every 30 min via cron. Pure templated output, no LLM needed.
set -euo pipefail
source /etc/lobmob/env
source /etc/lobmob/secrets.env 2>/dev/null || true

LOG="/var/log/lobmob-status-reporter.log"

# Helper: post to Discord via gateway API
discord_post() {
  local channel="$1" msg="$2"
  local gw_token=$(jq -r '.gateway.auth.token // empty' /root/.openclaw/openclaw.json 2>/dev/null)
  if [ -n "$gw_token" ]; then
    curl -s -X POST "http://127.0.0.1:18789/api/channels/discord/send" \
      -H "Authorization: Bearer $gw_token" \
      -H "Content-Type: application/json" \
      -d "{\"channel\": \"$channel\", \"content\": $(echo "$msg" | jq -Rs .)}" 2>/dev/null || true
  fi
}

# Pull vault for task counts
cd /opt/vault && git pull origin main --quiet 2>/dev/null || true

# Droplet counts by state
INITIALIZING=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-initializing" --format ID --no-header 2>/dev/null | wc -l | tr -d ' ')
ACTIVE=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-active" --format ID --no-header 2>/dev/null | wc -l | tr -d ' ')
STANDBY=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}" --format Status --no-header 2>/dev/null | grep -c "off" || echo 0)
TOTAL=$((INITIALIZING + ACTIVE + STANDBY))

# Droplet counts by type
TYPE_RESEARCH=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-type-research" --format ID --no-header 2>/dev/null | wc -l | tr -d ' ')
TYPE_SWE=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-type-swe" --format ID --no-header 2>/dev/null | wc -l | tr -d ' ')
TYPE_QA=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-type-qa" --format ID --no-header 2>/dev/null | wc -l | tr -d ' ')

# Task counts
TASKS_QUEUED=$(ls /opt/vault/010-tasks/active/*.md 2>/dev/null | xargs grep -l "^status: queued" 2>/dev/null | wc -l | tr -d ' ')
TASKS_ACTIVE=$(ls /opt/vault/010-tasks/active/*.md 2>/dev/null | xargs grep -l "^status: active" 2>/dev/null | wc -l | tr -d ' ')
TASKS_COMPLETED=$(ls /opt/vault/010-tasks/completed/*.md 2>/dev/null | wc -l | tr -d ' ')
TASKS_FAILED=$(ls /opt/vault/010-tasks/failed/*.md 2>/dev/null | wc -l | tr -d ' ')

# Open PRs
VAULT_PRS=$(gh pr list --state open --json number --jq 'length' 2>/dev/null || echo 0)

# Cost estimate (rough: active=$12/mo each, lobboss=$24/mo)
MONTHLY_COST=$(( (ACTIVE + INITIALIZING) * 12 + 24 ))
HOURLY_COST=$(echo "scale=2; $MONTHLY_COST / 730" | bc 2>/dev/null || echo "?")

# Format summary
MSG="**[status-report]** Fleet Summary — $(date -u +%H:%M) UTC
**Lobsters:** $TOTAL total ($ACTIVE active, $INITIALIZING initializing, $STANDBY standby)
**Types:** research=$TYPE_RESEARCH, swe=$TYPE_SWE, qa=$TYPE_QA
**Tasks:** $TASKS_QUEUED queued, $TASKS_ACTIVE active, $TASKS_COMPLETED completed, $TASKS_FAILED failed
**PRs:** $VAULT_PRS open
**Cost:** ~\$$HOURLY_COST/hr (\$$MONTHLY_COST/mo est.)"

discord_post "${DISCORD_CHANNEL_SWARM_LOGS:-swarm-logs}" "$MSG"
echo "$(date -Iseconds) Status report posted" >> "$LOG"
