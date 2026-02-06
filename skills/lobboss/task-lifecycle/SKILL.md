---
name: task-lifecycle
description: Create, assign, and track tasks through the vault and Discord
---

# Task Lifecycle

You manage all tasks through markdown files in the vault repo at `/opt/vault/`.

## Creating a Task

When a new request arrives in **#task-queue**:

1. Generate a task ID: `task-YYYY-MM-DD-<4hex>` (e.g. `task-2026-02-05-a1b2`)
2. Create the task file at `010-tasks/active/<task-id>.md`:

```markdown
---
id: <task-id>
status: queued
created: <ISO timestamp>
assigned_to:
assigned_at:
completed_at:
priority: normal
tags: []
---

# <Task title>

## Objective
<What needs to be done, extracted from the #task-queue message>

## Acceptance Criteria
- [ ] <Criterion 1>
- [ ] <Criterion 2>

## Lobster Notes
_To be filled by assigned lobster_

## Result
_Pending_
```

3. Commit and push to main:
   ```bash
   cd /opt/vault
   git add "010-tasks/active/<task-id>.md"
   git commit -m "[lobboss] Create task <task-id>"
   git push origin main
   ```

## Assigning a Task

1. Choose a lobster -- prefer idle lobsters, or spawn a new one if needed
2. Update the task frontmatter:
   ```yaml
   status: active
   assigned_to: lobster-<id>
   assigned_at: <ISO timestamp>
   ```
3. Commit and push to main
4. Post in **#swarm-control**:
   ```
   @lobster-<id> TASK: <task-id>
   Title: <title>
   File: 010-tasks/active/<task-id>.md
   Pull main for full details.
   ```

## Completing a Task (via PR)

You do NOT move the task file yourself. The lobster will:
1. Update the task file with results
2. Open a PR from their branch
3. Announce in **#results** with the PR link

Your job after the PR is merged (via the `review-prs` skill):
1. Verify the task file has `status: completed` and `completed_at` set
2. Move it to `010-tasks/completed/` if the lobster didn't:
   ```bash
   git mv "010-tasks/active/<task-id>.md" "010-tasks/completed/<task-id>.md"
   ```
3. Commit and push

## Failing a Task

If a lobster reports failure or times out:
1. Update the task frontmatter: `status: failed`
2. Add failure notes under `## Lobster Notes`
3. Move to `010-tasks/failed/`
4. Close any orphaned PR for that task:
   ```bash
   gh pr close <number> --comment "Task failed/timed out"
   ```
5. Decide whether to re-queue (create a new task referencing the failed one)
