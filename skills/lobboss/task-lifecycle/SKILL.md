---
name: task-lifecycle
description: Create, assign, and track tasks through the vault and Discord
---

# Task Lifecycle

You manage all tasks through markdown files in the vault repo at `/opt/vault/`.
All Discord communication for a task happens in a single thread under **#task-queue**.
Read the `discord-messaging` skill for posting patterns.

## Creating a Task

### Phase 1 — Receive & Evaluate

When a new message arrives in **#task-queue**:

1. Evaluate whether the message is a **task request** or something else (question, greeting, status check, fleet command)
2. **Non-task messages:** Reply conversationally or route to the appropriate skill
3. **Task requests:** Continue to Phase 2

### Phase 2 — Propose

1. Draft task details from the request: title, objective, acceptance criteria, priority, tags
2. Post a **Task Proposal** as a top-level message in **#task-queue**:

```
**Task Proposal**

> **Title:** <title>
> **Priority:** <priority>
> **Tags:** <tag1>, <tag2>
>
> **Objective**
> <objective text>
>
> **Acceptance Criteria**
> - <criterion 1>
> - <criterion 2>
```

3. Create a **thread** on the proposal message (thread name: `Task: <short title>`)
4. Post in the thread: `Reply **go** to create, **cancel** to discard, or describe changes.`
5. Wait for user response in the thread:
   - **Confirmation** (e.g. "go", "yes", "looks good", "create it") → Phase 3
   - **Changes** (e.g. "change priority to high") → post revised proposal in the thread, ask again
   - **Cancellation** (e.g. "cancel", "nevermind") → reply "Task cancelled." in the thread

### Phase 3 — Create

1. Generate a task ID: `task-YYYY-MM-DD-<4hex>` (e.g. `task-2026-02-05-a1b2`)
2. Save the thread ID from Phase 2
3. Create the task file at `010-tasks/active/<task-id>.md`:

```markdown
---
id: <task-id>
status: queued
created: <ISO timestamp>
assigned_to:
assigned_at:
completed_at:
priority: <priority>
tags: [<tags>]
discord_thread_id: <thread-id>
---

# <Task title>

## Objective
<Objective from the confirmed proposal>

## Acceptance Criteria
- [ ] <Criterion 1>
- [ ] <Criterion 2>

## Lobster Notes
_To be filled by assigned lobster_

## Result
_Pending_
```

4. Commit and push to main:
   ```bash
   cd /opt/vault
   git add "010-tasks/active/<task-id>.md"
   git commit -m "[lobboss] Create task <task-id>"
   git push origin main
   ```
5. Post in the thread:
   ```
   Task created: **<task-id>**
   I'll assign it to a lobster shortly.
   ```

## Assigning a Task

1. Choose a lobster — prefer idle lobsters, or spawn a new one if needed
2. Update the task frontmatter:
   ```yaml
   status: active
   assigned_to: lobster-<id>
   assigned_at: <ISO timestamp>
   ```
3. Commit and push to main
4. Post in the **task's thread** (read `discord_thread_id` from the task file):
   ```
   Assigned to **lobster-<id>**.
   @lobster-<id> — pull main and read `010-tasks/active/<task-id>.md` for details.
   ```

## Completing a Task (via PR)

You do NOT move the task file yourself. The lobster will:
1. Update the task file with results
2. Open a PR from their branch
3. Announce the PR in the **task's thread**

Your job after the PR is merged (via the `review-prs` skill):
1. Verify the task file has `status: completed` and `completed_at` set
2. Move it to `010-tasks/completed/` if the lobster didn't:
   ```bash
   git mv "010-tasks/active/<task-id>.md" "010-tasks/completed/<task-id>.md"
   ```
3. Commit and push
4. Post in the **task's thread**: `Task complete. PR merged.`

## Failing a Task

If a lobster reports failure or times out:
1. Update the task frontmatter: `status: failed`
2. Add failure notes under `## Lobster Notes`
3. Move to `010-tasks/failed/`
4. Close any orphaned PR for that task:
   ```bash
   gh pr close <number> --comment "Task failed/timed out"
   ```
5. Post in the **task's thread**: `Task failed. <brief reason>`
6. Decide whether to re-queue (create a new task referencing the failed one)
