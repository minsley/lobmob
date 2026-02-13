#!/bin/bash
set -euo pipefail

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/container-env.sh" ]]; then
  source "$SCRIPT_DIR/container-env.sh"
elif [[ -f /etc/lobmob/env ]]; then
  source /etc/lobmob/env
fi

LOG_FILE="${LOG_DIR:-/var/log}/lobmob-events.log"
VAULT_DIR="${VAULT_PATH:-/opt/vault}"
LOCK_FILE="/tmp/lobmob-flush.lock"

# Nothing to flush
if [ ! -s "$LOG_FILE" ]; then
  exit 0
fi

exec 200>"$LOCK_FILE"
flock -n 200 || { echo "Another flush is running"; exit 0; }

if [ -n "${LOBSTER_ID:-}" ]; then
  LOG_SUBDIR="020-logs/lobsters/lobster-$LOBSTER_ID"
  COMMIT_PREFIX="[lobster-$LOBSTER_ID]"
else
  LOG_SUBDIR="020-logs/lobboss"
  COMMIT_PREFIX="[lobboss]"
fi

TODAY=$(date +%Y-%m-%d)
TARGET_FILE="$VAULT_DIR/$LOG_SUBDIR/events-$TODAY.log"

cd "$VAULT_DIR"
git pull origin main --quiet 2>/dev/null || true

mkdir -p "$VAULT_DIR/$LOG_SUBDIR"
cat "$LOG_FILE" >> "$TARGET_FILE"

git add "$LOG_SUBDIR/"
if git diff --cached --quiet; then
  exit 0
fi

git commit -m "$COMMIT_PREFIX Flush event log" --quiet
git push origin main --quiet

# Truncate local log on success
: > "$LOG_FILE"
