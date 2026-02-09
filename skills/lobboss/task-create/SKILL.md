---
name: task-create
description: Evaluate incoming requests, propose tasks, and create task files after user confirmation
---

# Task Creation

## Phase 1 — Receive & Evaluate

When a new message arrives in the task-queue channel:

1. Evaluate whether the message is a **task request** or something else (question, greeting, status check, fleet command)
2. **Non-task messages:** Reply conversationally in a thread on their message
3. **Task requests:** Continue to Phase 2

## Phase 2 — Propose

**IMPORTANT: Reply in a thread on the user's original message.** Do NOT post a top-level message. The thread keeps all task discussion contained and avoids message splitting issues.

1. Draft task details from the request: title, objective, acceptance criteria, priority, tags, estimate (minutes), model, type, repo
   - **Type:** `research` (default), `swe` (code changes), `qa` (verification)
   - **Repo:** `vault` (default for research), `lobmob` (default for swe)
   - **Estimate:** Round minutes: 15, 30, 45, 60, 90, 120, 180, 240
   - **Model:** `swe` → `anthropic/claude-opus-4-6`, others → `anthropic/claude-sonnet-4-5`
   - **requires_qa:** `true` for important SWE changes, `false` for minor

2. Reply **in a thread on the user's message** with a compact proposal:

```
**[lobboss] Task Proposal**
**Title:** <title>
**Type:** <type> | **Repo:** <repo> | **Est:** <N>min | **QA:** <yes/no>

**Objective:** <1-2 sentence objective>

**Criteria:**
- <criterion 1>
- <criterion 2>

Reply **go** to create, **cancel** to discard, or describe changes.
```

Keep the proposal SHORT — under 500 characters if possible to avoid Discord message splitting.

3. Wait for user response **in the same thread**:
   - **Confirmation** (e.g. "go", "yes", "looks good") → Phase 3
   - **Changes** (e.g. "change priority to high") → post revised proposal in thread, ask again
   - **Cancellation** (e.g. "cancel", "nevermind") → reply "Task cancelled." in thread

## Phase 3 — Create

1. Generate a task ID: `task-YYYY-MM-DD-<4hex>` (e.g. `task-2026-02-05-a1b2`)
2. Save the thread ID (this is the thread on the user's message)
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
estimate: <minutes>
model: <model>
type: <research|swe|qa>
repo: <vault|lobmob|owner/repo>
requires_qa: <true|false>
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

4. Commit and push to main
5. Reply in the thread: `**[lobboss]** Task created: **<task-id>**. The task-manager will assign it shortly.`

The `lobmob-task-manager` cron (every 5 min) handles auto-assignment to an available lobster.
