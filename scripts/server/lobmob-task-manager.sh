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
VAULT_REPO="${VAULT_REPO:-}"

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

# Helper: attempt to create a fallback PR from an existing branch (Layer 2)
# Returns 0 if PR was created, 1 otherwise
try_fallback_pr() {
  local task_id="$1"
  [[ -n "$VAULT_REPO" ]] || return 1

  # Look for a branch matching this task (paginate to catch all)
  local branch
  branch=$(gh api "repos/${VAULT_REPO}/branches" --paginate --jq '.[].name' 2>/dev/null \
    | grep -F "$task_id" | head -1 || true)
  [[ -n "$branch" ]] || return 1

  # Check if PR already exists for this branch
  local existing_pr
  existing_pr=$(gh pr list --repo "$VAULT_REPO" --head "$branch" --state all --json number --jq 'length' 2>/dev/null || echo 0)
  if [[ "$existing_pr" -gt 0 ]]; then
    echo "$(date -Iseconds) FALLBACK: PR already exists for branch $branch ($task_id)" >> "$LOG"
    return 0
  fi

  # URL-encode the branch name for the compare API (handles slashes)
  local encoded_branch
  encoded_branch=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$branch', safe=''))" 2>/dev/null || echo "$branch")

  # Check if branch has commits ahead of main
  local ahead
  ahead=$(gh api "repos/${VAULT_REPO}/compare/main...${encoded_branch}" --jq '.ahead_by' 2>/dev/null || echo 0)
  [[ "$ahead" -gt 0 ]] || return 1

  # Create the fallback PR
  gh pr create --repo "$VAULT_REPO" --head "$branch" --base main \
    --title "Task ${task_id} (auto-submitted by task-manager)" \
    --body "[task-manager] Lobster completed work on branch but didn't create a PR. ${ahead} commit(s) ahead of main." \
    2>/dev/null || return 1

  echo "$(date -Iseconds) FALLBACK PR created for $task_id from branch $branch ($ahead commits)" >> "$LOG"
  return 0
}

# Helper: create investigation task for lobsigliere (Layer 3)
create_investigation_task() {
  local task_id="$1" task_type="$2" assigned_to="$3" failure_reason="$4"

  # Rate limit: use state file to track whether investigation was already created
  TASK_STATE_DIR="${TASK_STATE_DIR:-/tmp/task-state}"
  mkdir -p "$TASK_STATE_DIR" 2>/dev/null || true
  local inv_state="${TASK_STATE_DIR}/${task_id}.investigation"
  if [[ -f "$inv_state" ]]; then
    echo "$(date -Iseconds) SKIP investigation: already created for $task_id" >> "$LOG"
    return
  fi

  local inv_id="task-$(date +%Y-%m-%d)-inv-$(openssl rand -hex 4)"
  local inv_file="$VAULT_DIR/010-tasks/active/${inv_id}.md"
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cat > "$inv_file" <<INVEOF
---
id: ${inv_id}
type: system
status: queued
created: ${now_iso}
priority: high
tags: [investigation, reliability]
---

# Investigate failed task: ${task_id}

## Objective

Task **${task_id}** (type: ${task_type}) was assigned to **${assigned_to}** and failed.
Failure reason: ${failure_reason}

Investigate why the lobster failed to complete all workflow steps and submit a PR
to the lobmob repo that fixes the root cause.

## Investigation Steps

1. Read the failed task file at 010-tasks/active/${task_id}.md (or failed/)
2. Check if the lobster's vault branch exists and has commits
3. Read the lobster's work log at 020-logs/lobsters/${assigned_to}/
4. Examine the relevant lobster prompt (src/lobster/prompts/${task_type}.md)
5. Check verify.py criteria — which checks failed?
6. Identify the root cause and implement a fix

## Scope

- Fix prompts, verify.py, hooks.py, or run_task.py as needed
- Do NOT fix the original task — fix why the lobster couldn't complete it
- Target: lobsters should reliably complete all workflow steps autonomously
INVEOF

  if cd "$VAULT_DIR" && git add "$inv_file" && \
    git commit -m "[task-manager] Create investigation task $inv_id for failed $task_id" --quiet 2>/dev/null; then
    git push origin main --quiet 2>/dev/null || {
      echo "$(date -Iseconds) WARN: Failed to push investigation task $inv_id" >> "$LOG"
    }
    echo "$inv_id" > "$inv_state"
    echo "$(date -Iseconds) INVESTIGATION TASK created: $inv_id for failed $task_id" >> "$LOG"
  else
    echo "$(date -Iseconds) WARN: Failed to commit investigation task $inv_id" >> "$LOG"
    rm -f "$inv_file"
  fi
}

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

  # Layer 2: Try to create a fallback PR from the lobster's branch
  if try_fallback_pr "$task_id"; then
    echo "$(date -Iseconds) ORPHAN (fallback PR): $task_id — created PR from $assigned_to branch" >> "$LOG"
    [[ -n "$thread_id" ]] && discord_post "$thread_id" \
      "**[task-manager]** **$assigned_to** is offline, but found work for **$task_id**. Created fallback PR."
    continue
  fi

  task_type=$(fm type "$task_file")

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

    # Layer 3: Create investigation task for lobsigliere
    create_investigation_task "$task_id" "${task_type:-unknown}" "$assigned_to" "Orphan: lobster offline ${elapsed_min}m, no PR, no fallback branch"
  fi
done

# ── 3. (Removed) Auto-assign now handled by lobboss task poller ────
