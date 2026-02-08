---
name: submit-results
description: Package completed task results into a PR and announce on Discord
---

# Submit Results

When you have completed a task, use this skill to deliver your results.

## Prerequisites
- All result files written to the appropriate location
- Task file frontmatter updated with `status: completed` and `completed_at`
- Work log entry appended to `020-logs/lobsters/<your-lobster-id>/<date>.md`

## Multi-Repo Tasks (SWE/QA)

If the task has `repo:` set to something other than `vault` (e.g. `lobmob`), you'll have **two PRs**:
1. **Code PR** — your actual code changes, pushed to the target repo's `develop` branch (see the `code-task` or `verify-task` skill)
2. **Vault PR** — task file update with results and code PR link, pushed to vault `main`

Create the Code PR first (via the code-task skill), then follow the steps below for the Vault PR. Reference the Code PR URL in the vault task file's Result section.

## Vault-Only Tasks (Research)

For standard research/writing tasks where `repo: vault`, follow all steps below as normal — there's only one PR.

## Steps

### 1. Create a task branch
```bash
cd /opt/vault
git checkout main && git pull origin main
git checkout -b "lobster-${LOBSTER_ID}/task-${TASK_ID}"
```

### 2. Write your deliverables

Place files according to the vault structure:
- **Task file update**: `010-tasks/active/<task-id>.md` — update frontmatter, fill in Lobster Notes and Result sections
- **Results**: `030-knowledge/topics/<descriptive-name>.md`
- **Assets**: `030-knowledge/assets/<topic>/` for images, screenshots, data files
- **Work log**: `020-logs/lobsters/<your-id>/<date>.md`

Use Obsidian `[[wikilinks]]` to connect your results to existing vault pages.

### 3. Commit
```bash
git add -A
git commit -m "[lobster-${LOBSTER_ID}] Complete task-${TASK_ID}: <short title>"
```

### 4. Push your branch
```bash
git push origin "lobster-${LOBSTER_ID}/task-${TASK_ID}"
```

### 5. Create the PR
```bash
PR_URL=$(gh pr create \
  --title "Task ${TASK_ID}: <title>" \
  --body "$(cat <<'PRBODY'
## Task
- **ID**: ${TASK_ID}
- **Lobster**: lobster-${LOBSTER_ID}
- **Completed**: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Results Summary
<2-3 sentences describing what you found/built/accomplished>

## Files Changed
<list each file with a one-line description>

## Linked Vault Pages
<list [[wikilinks]] to key pages this PR adds or updates>

## Acceptance Criteria
<copy from task file, check off completed items>
PRBODY
)" \
  --base main \
  --head "lobster-${LOBSTER_ID}/task-${TASK_ID}" 2>&1 | tail -1)

PR_NUMBER=$(echo "$PR_URL" | grep -oP '\d+$')
```

### 6. Wait for review

The task-watcher cron will detect your task status change and post to Discord
automatically. You don't need to announce in Discord.

The lobboss will review your PR. If changes are requested:
1. Read the PR comment or Discord message
2. Make the changes in `/opt/vault/`
3. Commit and push to the same branch (the PR updates automatically)
4. Only post to Discord if you need to ask a clarifying question

## If something goes wrong

If you cannot complete the task:
1. Still create the PR with whatever partial results you have
2. Set `status: failed` in the task frontmatter
3. Document what went wrong in the Lobster Notes section
4. The task-watcher will detect the failure and post to Discord
