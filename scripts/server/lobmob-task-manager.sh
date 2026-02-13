#!/bin/bash
# lobmob-task-manager — deterministic task assignment, timeout detection, orphan recovery
# Runs every 5 min via cron. Does NOT require LLM — pure logic.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/container-env.sh" ]]; then
  source "$SCRIPT_DIR/container-env.sh"
else
  source /etc/lobmob/env
  source /etc/lobmob/secrets.env 2>/dev/null || true
fi

VAULT_DIR="${VAULT_PATH:-/opt/vault}"
LOG="${LOG_DIR:-/var/log}/lobmob-task-manager.log"
NOW=$(date +%s)

cd "$VAULT_DIR" && git pull origin main --quiet 2>/dev/null || true

# Helper: post to Discord thread via Discord bot API directly
discord_post() {
  local thread_id="$1" msg="$2"
  if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
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
  [ -f "$task_file" ] || continue
  status=$(fm status "$task_file")
  [ "$status" = "active" ] || continue

  assigned_at=$(fm assigned_at "$task_file")
  estimate=$(fm estimate "$task_file")
  assigned_to=$(fm assigned_to "$task_file")
  thread_id=$(fm discord_thread_id "$task_file" | tr -d '"')
  task_id=$(basename "$task_file" .md)

  [ -n "$assigned_at" ] || continue

  # Parse assigned_at to epoch
  assigned_ts=$(date -d "$assigned_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$assigned_at" +%s 2>/dev/null || echo 0)
  elapsed_min=$(( (NOW - assigned_ts) / 60 ))

  # Determine thresholds
  if [ -n "$estimate" ] && [ "$estimate" -gt 0 ] 2>/dev/null; then
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
  TASK_STATE_DIR="${TASK_STATE_DIR:-/var/lib/lobmob/task-state}"
  mkdir -p "$TASK_STATE_DIR" 2>/dev/null || true
  warn_state="${TASK_STATE_DIR}/${task_id}.timeout"

  if [ "$elapsed_min" -ge "$fail_min" ]; then
    if [ ! -f "$warn_state" ] || [ "$(cat "$warn_state")" != "failed" ]; then
      echo "failed" > "$warn_state"
      echo "$(date -Iseconds) TIMEOUT FAILURE: $task_id ($elapsed_min min, threshold $fail_min)" >> "$LOG"
      [ -n "$thread_id" ] && discord_post "$thread_id" \
        "**[task-manager]** Timeout failure: **$task_id** has been active for ${elapsed_min}m (limit: ${fail_min}m) with no PR. Assigned to **$assigned_to**."
    fi
  elif [ "$elapsed_min" -ge "$warn_min" ]; then
    if [ ! -f "$warn_state" ] || [ "$(cat "$warn_state")" != "warned" ]; then
      echo "warned" > "$warn_state"
      echo "$(date -Iseconds) TIMEOUT WARNING: $task_id ($elapsed_min min, threshold $warn_min)" >> "$LOG"
      [ -n "$thread_id" ] && discord_post "$thread_id" \
        "**[task-manager]** Timeout warning: **$task_id** active for ${elapsed_min}m (estimate: ${estimate:-?}m). **$assigned_to** — please post progress or submit PR."
    fi
  fi
done

# ── 2. Orphan Detection ─────────────────────────────────────────────
if [[ "${LOBMOB_RUNTIME:-droplet}" == "k8s" ]]; then
  ACTIVE_LOBSTERS=$(kubectl get jobs -n lobmob -l app.kubernetes.io/name=lobster --field-selector=status.active=1 -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)
else
  ACTIVE_LOBSTERS=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}-active" --format Name --no-header 2>/dev/null || true)
fi

for task_file in "$VAULT_DIR"/010-tasks/active/*.md; do
  [ -f "$task_file" ] || continue
  status=$(fm status "$task_file")
  [ "$status" = "active" ] || continue

  assigned_to=$(fm assigned_to "$task_file")
  [ -n "$assigned_to" ] || continue

  # Check if assigned lobster still exists
  if echo "$ACTIVE_LOBSTERS" | grep -q "$assigned_to"; then
    continue
  fi

  # Also check standby (powered off on Droplet, or completed/pending in k8s)
  if [[ "${LOBMOB_RUNTIME:-droplet}" == "k8s" ]]; then
    STANDBY_LOBSTERS=$(kubectl get jobs -n lobmob -l app.kubernetes.io/name=lobster -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' || true)
  else
    STANDBY_LOBSTERS=$(doctl compute droplet list --tag-name "${LOBSTER_TAG}" --format Name,Status --no-header 2>/dev/null | awk '$2=="off"{print $1}' || true)
  fi
  if echo "$STANDBY_LOBSTERS" | grep -q "$assigned_to"; then
    continue
  fi

  # Lobster is gone — orphaned task
  task_id=$(basename "$task_file" .md)
  thread_id=$(fm discord_thread_id "$task_file" | tr -d '"')
  assigned_at=$(fm assigned_at "$task_file")
  assigned_ts=$(date -d "$assigned_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$assigned_at" +%s 2>/dev/null || echo 0)
  elapsed_min=$(( (NOW - assigned_ts) / 60 ))

  # Check for open PR
  if gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null | grep -q "$task_id"; then
    echo "$(date -Iseconds) ORPHAN (has PR): $task_id — $assigned_to gone but PR exists" >> "$LOG"
    [ -n "$thread_id" ] && discord_post "$thread_id" \
      "**[task-manager]** Note: **$assigned_to** is offline, but a PR for **$task_id** exists. Proceeding with review."
    continue
  fi

  if [ "$elapsed_min" -lt 30 ]; then
    # Re-queue
    echo "$(date -Iseconds) ORPHAN RE-QUEUE: $task_id — $assigned_to gone after ${elapsed_min}m" >> "$LOG"
    sed -i "s/^status: active/status: queued/" "$task_file"
    sed -i "s/^assigned_to: .*/assigned_to:/" "$task_file"
    sed -i "s/^assigned_at: .*/assigned_at:/" "$task_file"
    cd "$VAULT_DIR" && git add -A && git commit -m "[task-manager] Re-queue $task_id ($assigned_to offline)" --quiet 2>/dev/null
    git push origin main --quiet 2>/dev/null || true
    [ -n "$thread_id" ] && discord_post "$thread_id" \
      "**[task-manager]** Re-queued **$task_id** — **$assigned_to** went offline. Will reassign."
  else
    # Mark failed
    echo "$(date -Iseconds) ORPHAN FAILED: $task_id — $assigned_to gone after ${elapsed_min}m, no PR" >> "$LOG"
    sed -i "s/^status: active/status: failed/" "$task_file"
    cd "$VAULT_DIR" && git add -A && git commit -m "[task-manager] Fail $task_id ($assigned_to offline, no PR)" --quiet 2>/dev/null
    git push origin main --quiet 2>/dev/null || true
    [ -n "$thread_id" ] && discord_post "$thread_id" \
      "**[task-manager]** Failed **$task_id** — **$assigned_to** offline for ${elapsed_min}m with no PR."
  fi
done

# ── 3. Auto-Assign Queued Tasks ─────────────────────────────────────
for task_file in "$VAULT_DIR"/010-tasks/active/*.md; do
  [ -f "$task_file" ] || continue
  status=$(fm status "$task_file")
  [ "$status" = "queued" ] || continue

  task_id=$(basename "$task_file" .md)
  task_type=$(fm type "$task_file")
  task_type="${task_type:-research}"
  thread_id=$(fm discord_thread_id "$task_file" | tr -d '"')

  # Find an idle lobster of the correct type
  IDLE_LOBSTER=""
  if [[ "${LOBMOB_RUNTIME:-droplet}" == "k8s" ]]; then
    # In k8s, lobboss spawns new Jobs on demand — no need to find an idle lobster.
    # Mark as "k8s-spawn" to signal the trigger section below.
    IDLE_LOBSTER="k8s-spawn"
  else
    for lobster in $(doctl compute droplet list --tag-name "${LOBSTER_TAG}-type-${task_type}" --format Name,Status --no-header 2>/dev/null | awk '$2=="active"{print $1}'); do
      lobster_short=$(echo "$lobster" | sed 's/^lobster-//')
      if ! grep -rl "$lobster_short" "$VAULT_DIR"/010-tasks/active/ 2>/dev/null | head -1 | grep -q .; then
        IDLE_LOBSTER="$lobster"
        break
      fi
    done
  fi

  if [ -z "$IDLE_LOBSTER" ]; then
    # No idle lobster of the right type — skip (pool manager will spawn if needed)
    continue
  fi

  # Assign
  echo "$(date -Iseconds) AUTO-ASSIGN: $task_id -> $IDLE_LOBSTER" >> "$LOG"
  ASSIGN_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sed -i "s/^status: queued/status: active/" "$task_file"
  sed -i "s/^assigned_to:.*/assigned_to: $IDLE_LOBSTER/" "$task_file"
  sed -i "s/^assigned_at:.*/assigned_at: $ASSIGN_TIME/" "$task_file"

  cd "$VAULT_DIR" && git add -A && git commit -m "[task-manager] Assign $task_id to $IDLE_LOBSTER" --quiet 2>/dev/null
  git push origin main --quiet 2>/dev/null || true

  # Trigger the lobster agent
  if [[ "${LOBMOB_RUNTIME:-droplet}" == "k8s" ]]; then
    # In k8s, the lobboss agent's spawn_lobster MCP tool creates Jobs.
    # The task-manager just marks the task — lobboss picks it up and spawns.
    echo "$(date -Iseconds) Task $task_id queued for k8s Job spawn by lobboss" >> "$LOG"
  else
    # Legacy: trigger via SSH over WireGuard
    LOBSTER_WG_IP=""
    for peer_ip in $(wg show wg0 allowed-ips 2>/dev/null | awk '{print $2}' | cut -d/ -f1); do
      rid=$(ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=2 -o BatchMode=yes \
        "root@$peer_ip" "grep LOBSTER_ID /etc/lobmob/env 2>/dev/null | cut -d= -f2" 2>/dev/null || true)
      if [ -n "$rid" ] && echo "$IDLE_LOBSTER" | grep -q "$rid"; then
        LOBSTER_WG_IP="$peer_ip"
        break
      fi
    done

    if [ -n "$LOBSTER_WG_IP" ]; then
      ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o BatchMode=yes "root@$LOBSTER_WG_IP" \
        "source /root/.openclaw/.env; nohup openclaw agent --agent main --message 'You have been assigned $task_id. Read /opt/vault/010-tasks/active/${task_id}.md and execute it.' > /tmp/openclaw-task.log 2>&1 &" 2>/dev/null || true
      echo "$(date -Iseconds) Triggered agent on $IDLE_LOBSTER ($LOBSTER_WG_IP)" >> "$LOG"
    fi
  fi

  [ -n "$thread_id" ] && discord_post "$thread_id" \
    "**[task-manager]** Assigned **$task_id** to **$IDLE_LOBSTER**"
done
