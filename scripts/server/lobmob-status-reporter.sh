#!/bin/bash
# lobmob-status-reporter — periodic fleet summary posted to #swarm-logs
# Runs every 30 min via k8s CronJob. Pure templated output, no LLM needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/container-env.sh" ]]; then
  source "$SCRIPT_DIR/container-env.sh"
fi

LOG="${LOG_DIR:-/var/log}/lobmob-status-reporter.log"
VAULT_DIR="${VAULT_PATH:-/opt/vault}"

# Helper: post to Discord channel via bot API
discord_post_channel() {
  local channel_name="$1" msg="$2"
  echo "$(date -Iseconds) [status-report] $msg" >> "$LOG"
}

# Pull vault for task counts
cd "$VAULT_DIR" && git pull origin main --quiet 2>/dev/null || true

# Worker counts
ACTIVE=$(kubectl get pods -n lobmob -l app.kubernetes.io/name=lobster --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
PENDING=$(kubectl get pods -n lobmob -l app.kubernetes.io/name=lobster --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$((ACTIVE + PENDING))

# Worker counts by type
TYPE_RESEARCH=$(kubectl get jobs -n lobmob -l lobmob.io/lobster-type=research --no-headers 2>/dev/null | wc -l | tr -d ' ')
TYPE_SWE=$(kubectl get jobs -n lobmob -l lobmob.io/lobster-type=swe --no-headers 2>/dev/null | wc -l | tr -d ' ')
TYPE_QA=$(kubectl get jobs -n lobmob -l lobmob.io/lobster-type=qa --no-headers 2>/dev/null | wc -l | tr -d ' ')

# Task counts
TASKS_QUEUED=$(ls "$VAULT_DIR"/010-tasks/active/*.md 2>/dev/null | xargs grep -l "^status: queued" 2>/dev/null | wc -l | tr -d ' ')
TASKS_ACTIVE=$(ls "$VAULT_DIR"/010-tasks/active/*.md 2>/dev/null | xargs grep -l "^status: active" 2>/dev/null | wc -l | tr -d ' ')
TASKS_COMPLETED=$(ls "$VAULT_DIR"/010-tasks/completed/*.md 2>/dev/null | wc -l | tr -d ' ')
TASKS_FAILED=$(ls "$VAULT_DIR"/010-tasks/failed/*.md 2>/dev/null | wc -l | tr -d ' ')

# Open PRs
VAULT_PRS=$(gh pr list --state open --json number --jq 'length' 2>/dev/null || echo 0)

# Cost estimate (node-based)
NODE_COUNT=$(kubectl get nodes -l lobmob.io/role=lobster --no-headers 2>/dev/null | wc -l | tr -d ' ')
MONTHLY_COST=$(( NODE_COUNT * 24 + 24 ))  # lobster nodes + lobboss node
HOURLY_COST=$(awk "BEGIN {printf \"%.2f\", $MONTHLY_COST / 730}" 2>/dev/null || echo "?")

# Format summary
MSG="**[status-report]** Fleet Summary — $(date -u +%H:%M) UTC
**Lobsters:** $TOTAL total ($ACTIVE running, $PENDING pending)
**Types:** research=$TYPE_RESEARCH, swe=$TYPE_SWE, qa=$TYPE_QA
**Tasks:** $TASKS_QUEUED queued, $TASKS_ACTIVE active, $TASKS_COMPLETED completed, $TASKS_FAILED failed
**PRs:** $VAULT_PRS open
**Cost:** ~\$$HOURLY_COST/hr (\$$MONTHLY_COST/mo est.)"

discord_post_channel "${DISCORD_CHANNEL_SWARM_LOGS:-swarm-logs}" "$MSG"
echo "$(date -Iseconds) Status report posted" >> "$LOG"
