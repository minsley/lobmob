#!/bin/bash
# lobmob-task-manager — deterministic task assignment, timeout detection, orphan recovery
# Runs every 5 min via k8s CronJob. Does NOT require LLM — pure logic.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/container-env.sh" ]]; then
  source "$SCRIPT_DIR/container-env.sh"
fi

VAULT_DIR="${VAULT_PATH:-/opt/vault}"
LOG="${LOG_DIR:-/var/log}/lobmob-task-manager.log"
NOW=$(date +%s)

LOBWIFE_URL="${LOBWIFE_URL:-http://lobwife.lobmob.svc.cluster.local:8081}"

cd "$VAULT_DIR" && git pull origin main --quiet 2>/dev/null || true

# Helper: deregister task from token broker (best-effort)
broker_deregister() {
  local task_id="$1"
  curl -sf -X DELETE "${LOBWIFE_URL}/api/tasks/${task_id}" 2>/dev/null || true
}

# Helper: post to Discord thread via Discord bot API directly
discord_post() {
  local thread_id="$1" msg="$2"
  if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
    curl -s -X POST "https://discord.com/api/v10/channels/${thread_id}/messages" \
      -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"$msg\"}" 2>/dev/null || true
  fi
}

# Helper: extract frontmatter field
fm() { grep "^$1:" "$2" 2>/dev/null | head -1 | sed "s/^$1: *//" ; }

# ── 1. Timeout Detection ────────────────────────────────────────────
for task_file in "$VAULT_DIR"/010-tasks/active/*.md; do
  [[ -f "$task_file" ]] || continue
  status=$(fm status "$task_file")
  [[ "$status" == "active" ]] || continue

  assigned_at=$(fm assigned_at "$task_file")
  estimate=$(fm estimate "$task_file")
  assigned_to=$(fm assigned_to "$task_file")
  thread_id=$(fm discord_thread_id "$task_file" | tr -d '"')
  task_id=$(basename "$task_file" .md)

  [[ -n "$assigned_at" ]] || continue

  # Parse assigned_at to epoch
  assigned_ts=$(date -d "$assigned_at" +%s 2>/dev/null || echo 0)
  elapsed_min=$(( (NOW - assigned_ts) / 60 ))

  # Determine thresholds
  if [[ -n "$estimate" ]] && [[ "$estimate" -gt 0 ]] 2>/dev/null; then
    warn_min=$((estimate + 15))
    fail_min=$((estimate * 2))
  else
    warn_min=45
    fail_min=90
  fi

  # Check for open PR (if PR exists, lobster is in review — skip timeout)
  if gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null | grep -q "$task_id"; then
    continue
  fi

  # Check for existing warning (avoid spamming)
  TASK_STATE_DIR="${TASK_STATE_DIR:-/tmp/task-state}"
  mkdir -p "$TASK_STATE_DIR" 2>/dev/null || true
  warn_state="${TASK_STATE_DIR}/${task_id}.timeout"

  if [[ "$elapsed_min" -ge "$fail_min" ]]; then
    if [[ ! -f "$warn_state" ]] || [[ "$(cat "$warn_state")" != "failed" ]]; then
      echo "failed" > "$warn_state"
      echo "$(date -Iseconds) TIMEOUT FAILURE: $task_id ($elapsed_min min, threshold $fail_min)" >> "$LOG"
      [[ -n "$thread_id" ]] && discord_post "$thread_id" \
        "**[task-manager]** Timeout failure: **$task_id** has been active for ${elapsed_min}m (limit: ${fail_min}m) with no PR. Assigned to **$assigned_to**."
    fi
  elif [[ "$elapsed_min" -ge "$warn_min" ]]; then
    if [[ ! -f "$warn_state" ]] || [[ "$(cat "$warn_state")" != "warned" ]]; then
      echo "warned" > "$warn_state"
      echo "$(date -Iseconds) TIMEOUT WARNING: $task_id ($elapsed_min min, threshold $warn_min)" >> "$LOG"
      [[ -n "$thread_id" ]] && discord_post "$thread_id" \
        "**[task-manager]** Timeout warning: **$task_id** active for ${elapsed_min}m (estimate: ${estimate:-?}m). **$assigned_to** — please post progress or submit PR."
    fi
  fi
done

# ── 2. Orphan Detection ─────────────────────────────────────────────
ACTIVE_LOBSTERS=$(kubectl get jobs -n lobmob -l app.kubernetes.io/name=lobster --field-selector=status.active=1 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)

for task_file in "$VAULT_DIR"/010-tasks/active/*.md; do
  [[ -f "$task_file" ]] || continue
  status=$(fm status "$task_file")
  [[ "$status" == "active" ]] || continue

  assigned_to=$(fm assigned_to "$task_file")
  [[ -n "$assigned_to" ]] || continue

  # Check if assigned lobster still exists (active or any state)
  if echo "$ACTIVE_LOBSTERS" | grep -q "$assigned_to"; then
    continue
  fi
  ALL_LOBSTERS=$(kubectl get jobs -n lobmob -l app.kubernetes.io/name=lobster -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)
  if echo "$ALL_LOBSTERS" | grep -q "$assigned_to"; then
    continue
  fi

  # Lobster is gone — orphaned task
  task_id=$(basename "$task_file" .md)
  thread_id=$(fm discord_thread_id "$task_file" | tr -d '"')
  assigned_at=$(fm assigned_at "$task_file")
  assigned_ts=$(date -d "$assigned_at" +%s 2>/dev/null || echo 0)
  elapsed_min=$(( (NOW - assigned_ts) / 60 ))

  # Check for open PR
  if gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null | grep -q "$task_id"; then
    echo "$(date -Iseconds) ORPHAN (has PR): $task_id — $assigned_to gone but PR exists" >> "$LOG"
    [[ -n "$thread_id" ]] && discord_post "$thread_id" \
      "**[task-manager]** Note: **$assigned_to** is offline, but a PR for **$task_id** exists. Proceeding with review."
    continue
  fi

  if [[ "$elapsed_min" -lt 30 ]]; then
    # Re-queue
    echo "$(date -Iseconds) ORPHAN RE-QUEUE: $task_id — $assigned_to gone after ${elapsed_min}m" >> "$LOG"
    broker_deregister "$task_id"
    sed -i "s/^status: active/status: queued/" "$task_file"
    sed -i "s/^assigned_to: .*/assigned_to:/" "$task_file"
    sed -i "s/^assigned_at: .*/assigned_at:/" "$task_file"
    cd "$VAULT_DIR" && git add -A && git commit -m "[task-manager] Re-queue $task_id ($assigned_to offline)" --quiet 2>/dev/null
    git push origin main --quiet 2>/dev/null || true
    [[ -n "$thread_id" ]] && discord_post "$thread_id" \
      "**[task-manager]** Re-queued **$task_id** — **$assigned_to** went offline. Will reassign."
  else
    # Mark failed
    echo "$(date -Iseconds) ORPHAN FAILED: $task_id — $assigned_to gone after ${elapsed_min}m, no PR" >> "$LOG"
    broker_deregister "$task_id"
    sed -i "s/^status: active/status: failed/" "$task_file"
    cd "$VAULT_DIR" && git add -A && git commit -m "[task-manager] Fail $task_id ($assigned_to offline, no PR)" --quiet 2>/dev/null
    git push origin main --quiet 2>/dev/null || true
    [[ -n "$thread_id" ]] && discord_post "$thread_id" \
      "**[task-manager]** Failed **$task_id** — **$assigned_to** offline for ${elapsed_min}m with no PR."
  fi
done

# ── 3. (Removed) Auto-assign now handled by lobboss task poller ────
