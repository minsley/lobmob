#!/bin/bash
set -euo pipefail
source /etc/lobmob/env
cd /opt/vault

git checkout main && git pull origin main

PRS=$(gh pr list --state open --json number,title,headRefName --jq '.[]' 2>/dev/null)
if [ -z "$PRS" ]; then
  exit 0
fi

echo "$PRS" | jq -c '.' | while read -r PR; do
  NUMBER=$(echo "$PR" | jq -r '.number')
  TITLE=$(echo "$PR" | jq -r '.title')
  BRANCH=$(echo "$PR" | jq -r '.headRefName')

  echo "Reviewing PR #$NUMBER: $TITLE ($BRANCH)"

  # Check diff for secrets
  DIFF=$(gh pr diff "$NUMBER" 2>/dev/null || true)
  if echo "$DIFF" | grep -qiE '(sk-ant-|dop_v1_|github_pat_|PRIVATE KEY)'; then
    gh pr comment "$NUMBER" --body "Possible secrets detected in diff. Please remove and force-push."
    echo "BLOCKED PR #$NUMBER -- secrets detected"
    continue
  fi

  # Check file paths are within allowed directories
  FILES=$(gh pr view "$NUMBER" --json files --jq '.files[].path')
  INVALID=$(echo "$FILES" | grep -vE '^(010-tasks/|020-logs/|030-knowledge/|000-inbox/)' || true)
  if [ -n "$INVALID" ]; then
    gh pr comment "$NUMBER" --body "Files outside allowed paths: $INVALID"
    echo "BLOCKED PR #$NUMBER -- invalid paths"
    continue
  fi

  echo "PR #$NUMBER passes checks -- ready for lobboss agent review"
done
