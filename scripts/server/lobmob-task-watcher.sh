#!/bin/bash
set -euo pipefail
VAULT_DIR="/opt/vault"
STATE_DIR="/var/lib/lobmob/task-state"
LOG="/var/log/lobmob-task-watcher.log"
mkdir -p "$STATE_DIR"

# Skip if vault not provisioned yet
if [ ! -d "$VAULT_DIR/.git" ]; then
  exit 0
fi

# Pull latest vault
cd "$VAULT_DIR" && git pull origin main --quiet 2>/dev/null || true

# Check each active task file for status changes
for task_file in "$VAULT_DIR"/010-tasks/active/*.md; do
  [ -f "$task_file" ] || continue
  task_id=$(basename "$task_file" .md)
  state_file="$STATE_DIR/${task_id}.state"

  # Extract key frontmatter fields
  status=$(grep "^status:" "$task_file" | head -1 | awk '{print $2}')
  assigned=$(grep "^assigned_to:" "$task_file" | head -1 | sed 's/assigned_to: *//')
  thread_id=$(grep "^discord_thread_id:" "$task_file" | head -1 | awk '{print $2}')

  # Build current state string
  current="status=$status assigned=$assigned"

  # Compare with last known state
  previous=""
  if [ -f "$state_file" ]; then
    previous=$(cat "$state_file")
  fi

  if [ "$current" != "$previous" ]; then
    echo "$current" > "$state_file"

    # Skip if no thread_id (can't post to Discord without it)
    if [ -z "$thread_id" ]; then continue; fi

    # Determine what changed and compose message
    msg=""
    prev_status=$(echo "$previous" | grep -o 'status=[^ ]*' | cut -d= -f2)
    prev_assigned=$(echo "$previous" | grep -o 'assigned=[^ ]*' | cut -d= -f2)

    if [ "$status" = "active" ] && [ "$prev_status" != "active" ] && [ -n "$assigned" ]; then
msg="Task **$task_id** assigned to **$assigned**"
    elif [ "$status" = "completed" ] && [ "$prev_status" != "completed" ]; then
msg="Task **$task_id** completed by **$assigned**"
    elif [ "$status" = "failed" ] && [ "$prev_status" != "failed" ]; then
msg="Task **$task_id** failed (assigned to **$assigned**)"
    elif [ "$status" = "queued" ] && [ "$prev_status" = "active" ]; then
msg="Task **$task_id** re-queued"
    fi

    if [ -n "$msg" ]; then
echo "$(date -Iseconds) $msg" >> "$LOG"
# Post to Discord thread via OpenClaw gateway API
GW_TOKEN=$(jq -r '.gateway.auth.token // empty' /root/.openclaw/openclaw.json 2>/dev/null)
if [ -n "$GW_TOKEN" ]; then
  curl -s -X POST "http://127.0.0.1:18789/api/channels/discord/send" \
    -H "Authorization: Bearer $GW_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"threadId\": \"$thread_id\", \"content\": \"$msg\"}" 2>/dev/null || true
fi
    fi
  fi
done

# Also check for completed/failed tasks that should be moved
for task_file in "$VAULT_DIR"/010-tasks/active/*.md; do
  [ -f "$task_file" ] || continue
  status=$(grep "^status:" "$task_file" | head -1 | awk '{print $2}')
  if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
    task_id=$(basename "$task_file" .md)
    dest="$VAULT_DIR/010-tasks/$status/$task_id.md"
    if [ ! -f "$dest" ]; then
      mv "$task_file" "$dest"
      cd "$VAULT_DIR" && git add -A && git commit -m "[task-watcher] Move $task_id to $status" --quiet 2>/dev/null
      git push origin main --quiet 2>/dev/null || true
      rm -f "$STATE_DIR/${task_id}.state"
      echo "$(date -Iseconds) Moved $task_id to $status" >> "$LOG"
    fi
  fi
done
