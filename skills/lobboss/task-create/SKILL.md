---
name: task-create
description: Evaluate incoming requests, propose tasks, and create task files after user confirmation
---

# Task Creation

## Phase 1 — Receive & Evaluate

When a new message arrives in the task-queue channel:

1. Evaluate whether the message is a **task request** or something else (question, greeting, status check, fleet command)
2. **Non-task messages:** Reply conversationally or route to the appropriate skill
3. **Task requests:** Continue to Phase 2

## Phase 2 — Propose

1. Draft task details from the request: title, objective, acceptance criteria, priority, tags, estimate (minutes), model, type, repo
   - **Type:** Determine the lobster type needed:
     - `research` — research, writing, documentation, analysis (default)
     - `swe` — code changes, features, bug fixes, refactoring
     - `qa` — code review, testing, verification of SWE PRs
   - **Repo:** Determine where the work happens:
     - `vault` — work lives in the vault repo (default for research tasks)
     - `lobmob` — code changes to the lobmob project itself (default for SWE tasks)
     - `owner/repo` — arbitrary GitHub repo
   - **Estimate:** If the user provides a time estimate, use it. Otherwise, generate your own based on task complexity. Use round numbers: 15, 30, 45, 60, 90, 120, 180, 240
   - **Model:** If the user specifies a model, use it. Otherwise, infer from type:
     - `swe` tasks default to `anthropic/claude-opus-4-6`
     - `research` and `qa` tasks default to `anthropic/claude-sonnet-4-5`
     - `anthropic/claude-haiku-4-5` — only for simple/mechanical tasks
     - Non-Anthropic models are also supported if appropriate
   - **requires_qa:** Set to `true` for SWE tasks that change important code. Set to `false` for minor changes.

2. Post a **Task Proposal** as a top-level message in the task-queue channel:

```
**[lobboss]** **Task Proposal**

> **Title:** <title>
> **Type:** <research|swe|qa> → **Repo:** <vault|lobmob|owner/repo>
> **Priority:** <priority>
> **Tags:** <tag1>, <tag2>
> **Estimate:** <N> min
> **Model:** <model>
> **QA Required:** <yes|no>
>
> **Objective**
> <objective text>
>
> **Acceptance Criteria**
> - <criterion 1>
> - <criterion 2>
```

3. Create a **thread** on the proposal message (thread name: `Task: <short title>`)
4. Post in the thread: `**[lobboss]** Reply **go** to create, **cancel** to discard, or describe changes.`
5. Wait for user response in the thread:
   - **Confirmation** (e.g. "go", "yes", "looks good") → Phase 3
   - **Changes** (e.g. "change priority to high") → post revised proposal, ask again
   - **Cancellation** (e.g. "cancel", "nevermind") → reply "Task cancelled." in the thread

## Phase 3 — Create

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
5. Post in the thread: `**[lobboss]** Task created: **<task-id>**`

The `lobmob-task-manager` cron will auto-assign it to an available lobster.
