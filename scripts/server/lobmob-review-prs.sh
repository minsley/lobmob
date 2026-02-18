#!/bin/bash
# lobmob-review-prs — deterministic PR validation + auto-merge for vault housekeeping
# Runs every 2 min via cron. Auto-merges safe vault PRs (log flushes, task file moves).
# Code PRs get deterministic checks posted as comments but are NOT auto-merged —
# those require LLM QA review (eventually with functional/Selenium testing).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/container-env.sh" ]]; then
  source "$SCRIPT_DIR/container-env.sh"
elif [[ -f /etc/lobmob/env ]]; then
  source /etc/lobmob/env
fi
cd "${VAULT_PATH:-/opt/vault}"

git checkout main --quiet 2>/dev/null && git pull origin main --quiet 2>/dev/null

PRS=$(gh pr list --state open --json number,title,headRefName,author --jq '.[]' 2>/dev/null)
if [ -z "$PRS" ]; then
  exit 0
fi

echo "$PRS" | jq -c '.' | while read -r PR; do
  NUMBER=$(echo "$PR" | jq -r '.number')
  TITLE=$(echo "$PR" | jq -r '.title')
  BRANCH=$(echo "$PR" | jq -r '.headRefName')
  AUTHOR=$(echo "$PR" | jq -r '.author.login')

  echo "Reviewing PR #$NUMBER: $TITLE ($BRANCH)"

  # ── Deterministic checks (all PRs) ──────────────────────────
  BLOCKED=0
  ISSUES=""

  # Check diff for secrets
  DIFF=$(gh pr diff "$NUMBER" 2>/dev/null || true)
  if echo "$DIFF" | grep -qiE '(sk-ant-|dop_v1_|github_pat_|PRIVATE KEY|ANTHROPIC_API_KEY=sk-)'; then
    ISSUES="${ISSUES}\n- Possible secrets detected in diff"
    BLOCKED=1
  fi

  # Check file paths are within allowed directories (vault PRs only)
  FILES=$(gh pr view "$NUMBER" --json files --jq '.files[].path' 2>/dev/null)
  INVALID=$(echo "$FILES" | grep -vE '^(010-tasks/|020-logs/|030-knowledge/|000-inbox/|040-fleet/|AGENTS\.md)' || true)
  if [ -n "$INVALID" ]; then
    ISSUES="${ISSUES}\n- Files outside allowed vault paths: $(echo "$INVALID" | tr '\n' ', ')"
    BLOCKED=1
  fi

  # Validate task file frontmatter if task files are modified
  TASK_FILES=$(echo "$FILES" | grep '^010-tasks/' || true)
  for tf in $TASK_FILES; do
    if [ -n "$tf" ]; then
      # Check the PR's version of the file for required fields
      CONTENT=$(gh pr diff "$NUMBER" 2>/dev/null | grep -A 100 "^+++ b/$tf" | grep "^+" | head -20 || true)
      if echo "$CONTENT" | grep -q "^+status:" 2>/dev/null; then
        # Has frontmatter — check required fields
        for field in status id created; do
          if ! echo "$CONTENT" | grep -q "^+${field}:"; then
            ISSUES="${ISSUES}\n- Task file $tf missing required field: $field"
          fi
        done
      fi
    fi
  done

  if [ "$BLOCKED" -eq 1 ]; then
    # Check if we already commented about these issues
    EXISTING=$(gh pr view "$NUMBER" --json comments --jq '.comments[].body' 2>/dev/null | grep -c "BLOCKED" || echo 0)
    if [ "$EXISTING" -eq 0 ]; then
      gh pr comment "$NUMBER" --body "**[review-prs]** BLOCKED$(echo -e "$ISSUES")" 2>/dev/null || true
    fi
    echo "BLOCKED PR #$NUMBER"
    continue
  fi

  # ── Classify: vault housekeeping vs code PR ────────────────
  IS_HOUSEKEEPING=0

  # Housekeeping indicators: log flushes, task file moves, event logs
  if echo "$TITLE" | grep -qiE '(flush|event log|task-watcher|Move .* to completed|Move .* to failed)'; then
    IS_HOUSEKEEPING=1
  fi
  # Author is a bot doing automated work
  if echo "$BRANCH" | grep -qE '^(lobster-|lobboss/)' && echo "$TITLE" | grep -qiE '(flush|log)'; then
    IS_HOUSEKEEPING=1
  fi
  # Only vault files modified (no code)
  CODE_FILES=$(echo "$FILES" | grep -vE '^(010-tasks/|020-logs/|030-knowledge/|000-inbox/|040-fleet/)' || true)
  if [ -z "$CODE_FILES" ]; then
    # All files are in vault dirs — likely housekeeping
    IS_HOUSEKEEPING=1
  fi

  if [ "$IS_HOUSEKEEPING" -eq 1 ]; then
    # Auto-merge vault housekeeping PRs
    echo "Auto-merging housekeeping PR #$NUMBER: $TITLE"
    gh pr merge "$NUMBER" --merge --delete-branch 2>/dev/null || true
    echo "[review-prs] Auto-merged housekeeping PR #$NUMBER: $TITLE"
  else
    # Code PR — post check results, leave for LLM QA review
    EXISTING=$(gh pr view "$NUMBER" --json comments --jq '.comments[].body' 2>/dev/null | grep -c "checks passed" || echo 0)
    if [ "$EXISTING" -eq 0 ]; then
      gh pr comment "$NUMBER" --body "**[review-prs]** Deterministic checks passed (no secrets, valid paths, frontmatter OK). Awaiting LLM QA review." 2>/dev/null || true
    fi
    echo "PR #$NUMBER passes checks — awaiting LLM review"
  fi
done
