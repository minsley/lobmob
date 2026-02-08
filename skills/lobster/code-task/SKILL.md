---
name: code-task
description: Execute a software engineering task — clone target repo, implement changes, run tests, submit PR to develop
---

# Code Task

Use this skill when you've been assigned a task with `type: swe`. You'll implement code changes in a target repo using git-flow patterns.

## 1. Receive and Read

1. You'll be notified of your assignment in the task's Discord thread.
2. Pull the vault: `cd /opt/vault && git pull origin main --rebase`
3. Read the task file at `010-tasks/active/<task-id>.md`
4. Note the `repo:` field — this is where your code changes go (e.g. `lobmob` → `/opt/lobmob`)
5. Note the acceptance criteria — these define when you're done.

## 2. Acknowledge

Post in the task's Discord thread (use `discord_thread_id` from frontmatter):
```
ACK <task-id> <your-lobster-id> — starting code task
```

## 3. Set Up Working Branch

```bash
cd /opt/lobmob   # or the target repo directory
git fetch origin
git checkout develop
git pull origin develop
git checkout -b feature/task-<task-id>
```

**Rules:**
- Always branch from `develop`, never `main`
- Use `feature/task-<id>` for features, `fix/task-<id>` for bugfixes
- One branch per task

## 4. Understand the Codebase

Before making changes:
1. Read relevant existing code to understand patterns and conventions
2. Check for a MEMORY.md, CLAUDE.md, or similar project guidance
3. Look at recent commits for style conventions: `git log --oneline -20`
4. Identify which files need modification

## 5. Implement

- Make focused, incremental changes
- Commit frequently with descriptive messages referencing the task:
  ```bash
  git commit -m "task-<id>: Add --version flag to CLI"
  ```
- Follow existing code style and patterns
- Don't introduce unnecessary dependencies
- Don't make changes outside the task scope

## 6. Test

Before committing final changes, always run tests:

```bash
cd /opt/lobmob

# Run the project test suite
for test in tests/*; do
  echo "=== $test ==="
  bash "$test" 2>&1
done

# Lint any shell scripts you modified
shellcheck scripts/lobmob 2>&1 || true
shellcheck scripts/connect-*.sh 2>&1 || true
```

If tests fail:
- Fix the issue and re-test
- If the failure is pre-existing (not caused by your changes), note it in your PR

## 7. Push and Create PR

```bash
cd /opt/lobmob
git push origin feature/task-<task-id>
gh pr create \
  --title "Task <task-id>: <concise title>" \
  --body "## Summary
<what changed and why>

## Changes
<list of key changes>

## Test Results
<test output summary>

## Task
Implements task-<task-id> in the vault." \
  --base develop
```

Note the PR number from the output.

## 8. Update Vault Task File

```bash
cd /opt/vault
git pull origin main --rebase
```

Update `010-tasks/active/<task-id>.md`:
- Set `status: completed`
- Set `completed_at: <now>`
- Fill in the **Result** section with PR URL and summary
- Fill in **Lobster Notes** with implementation details

Commit and push via your vault task branch:
```bash
git checkout -b lobster-<id>/task-<task-id>
git add 010-tasks/
git commit -m "[lobster-<id>] Complete task-<task-id>: <title>"
git push origin lobster-<id>/task-<task-id>
gh pr create --title "Task <task-id>: <title>" --body "<summary>" --base main
```

## 9. Wait for Review

Status updates to Discord are handled automatically by the task-watcher
when it detects your task file changes. You don't need to post to Discord.

If lobboss or a QA lobster requests changes (via PR comment or Discord thread):
1. Read the feedback
2. Make fixes on your feature branch
3. Push — the PR updates automatically
4. Only post to Discord if you need to ask a clarifying question
