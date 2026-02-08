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
     - Non-Anthropic models (e.g. `openai/o3`, `google/gemini-2.5-pro`) are also supported if appropriate
   - **requires_qa:** Set to `true` for SWE tasks that change important code. Set to `false` for minor changes.
2. Post a **Task Proposal** as a top-level message in **#task-queue**:

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
   - **Confirmation** (e.g. "go", "yes", "looks good", "create it") → Phase 3
   - **Changes** (e.g. "change priority to high") → post revised proposal in the thread, ask again
   - **Cancellation** (e.g. "cancel", "nevermind") → reply "**[lobboss]** Task cancelled." in the thread

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

4. Commit and push to main:
   ```bash
   cd /opt/vault
   git add "010-tasks/active/<task-id>.md"
   git commit -m "[lobboss] Create task <task-id>"
   git push origin main
   ```
5. Post in the thread:
   ```
   **[lobboss]** Task created: **<task-id>**
   I'll assign it to a lobster shortly.
   ```

## Assigning a Task

### Choosing a Lobster

Read the task's `type` field. **Only consider lobsters of the matching type.** Check lobster types by reading their `/etc/lobmob/env` via SSH or by querying DO tags (`lobmob-type-<type>`).

Pick the best available lobster of the correct type using this priority order:

1. **Active-idle lobster** — running, no current task, correct type. Immediate assignment.
   - If multiple are idle, prefer one already configured with the task's model.

2. **Active-busy lobster** — running, correct type, already on a task. May accept a second task if ALL:
   - The lobster's current model matches the new task's model (no model switch mid-task).
   - The lobster's current task has an `estimate` of **30 min or less**, OR you judge based on progress posts that the remaining work is under ~2 minutes.
   - If neither condition is met, skip it.

3. **Standby lobster** — powered off, correct type. Run `lobmob-wake-lobster <name>` (~1-2 min).
   - Prefer one last configured with the task's model.

4. **Spawn a new lobster** — takes 5-8 minutes. Run `lobmob-spawn-lobster <name> '' <type>`.
   - Only if no idle or standby lobsters of the correct type exist.
   - Respect `MAX_LOBSTERS` — if at the limit, the task must wait.

### Configuring the Model

If the task has a `model` set and it differs from the chosen lobster's current model, update the lobster's OpenClaw config before assignment:
```bash
ssh -i /root/.ssh/lobster_admin root@<wg_ip> \
  "jq '.agents.defaults.model.primary = \"<model>\"' /root/.openclaw/openclaw.json > /tmp/oc.tmp && mv /tmp/oc.tmp /root/.openclaw/openclaw.json"
```

### Recording the Assignment

1. Update the task frontmatter:
   ```yaml
   status: active
   assigned_to: lobster-<id>
   assigned_at: <ISO timestamp>
   ```
2. Commit and push to main
3. Post in the **task's thread** (read `discord_thread_id` from the task file):
   ```
   **[lobboss]** Assigned to **lobster-<id>** (type: <type>, model: <model>, repo: <repo>).
   @lobster-<id> — pull main and read `010-tasks/active/<task-id>.md` for details.
   ```

## Monitoring Active Tasks

When you check on tasks (periodically or when prompted), look for stalled tasks:

### Timeout Detection

For each task in `010-tasks/active/` with `status: active`:

1. Read `assigned_at` and `estimate` from the frontmatter
2. Calculate elapsed time since assignment
3. Determine timeout thresholds:
   - If `estimate` is set: **warning** at `estimate + 15` min, **failure** at `estimate * 2` min
   - If `estimate` is empty: **warning** at 45 min, **failure** at 90 min (defaults)
4. Check for an open PR:
   ```bash
   gh pr list --state open --json number,title,headRefName | grep "<task-id>"
   ```
   If a PR exists, the lobster is in submit/review phase — do not flag as timed out.

5. **Warning (elapsed > warning threshold, no PR, no recent PROGRESS post)**:
   Post in the **task's thread**:
   ```
   **[lobboss]** Timeout warning: Task <task-id> has been active for <N> minutes with no recent progress from <lobster-id>.
   @<lobster-id> — please post a status update or submit your PR.
   ```
   Post to **#swarm-logs** (channel `1469216945764175946`):
   ```
   **[lobboss]** Timeout warning: <task-id> assigned to <lobster-id> for <N> min, no progress.
   ```

6. **Failure (elapsed > failure threshold, no PR)**:
   SSH to the lobster to check if it's still working:
   ```bash
   ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
     root@<wg_ip> "tail -1 /tmp/openclaw-gateway.log 2>/dev/null || echo NO_LOG"
   ```
   If the lobster appears dead, consider failing the task (follow "Failing a Task" below).

## Recovering Orphaned Tasks

When checking active tasks, also look for tasks assigned to lobsters that no longer
exist or are offline. Cross-reference `assigned_to` against the fleet registry at
`/opt/vault/040-fleet/registry.md`.

### Detection

```bash
cd /opt/vault && git pull origin main
```

For each task in `010-tasks/active/` with `status: active` and `assigned_to` set:
1. Look up the lobster in `040-fleet/registry.md`
2. If the lobster is `offline`, `destroyed`, or missing from the registry entirely → orphaned

### Decision Logic

For each orphaned task:

1. **Check for an open PR:**
   ```bash
   gh pr list --state open --json number,title,headRefName | grep "<task-id>"
   ```
   If a PR exists → leave the task as-is. The PR can still be reviewed and merged
   even though the lobster is gone. Post a note in the task thread:
   ```
   **[lobboss]** Note: <lobster-id> is offline, but PR #<number> is open. Proceeding with review.
   ```

2. **No PR, assigned < 30 min ago** → re-queue:
   - Update frontmatter: `status: queued`, clear `assigned_to` and `assigned_at`
   - Add a note: `Re-queued: <lobster-id> went offline before completion.`
   - Commit and push
   - Post in task thread: `**[lobboss]** Task <task-id> re-queued — <lobster-id> is offline. Will reassign.`
   - Assign to another lobster

3. **No PR, assigned >= 30 min ago** → fail and re-create:
   - Check if the lobster's branch exists: `git ls-remote origin "lobster-*/task-<task-id>"`
   - If partial work exists on the branch, note it
   - Follow "Failing a Task" below with reason: `<lobster-id> went offline after <N> min, no PR submitted`
   - Create a **new** task referencing the failed one (include a note about partial work if any)

### When to Run This

- When the watchdog posts a `WATCHDOG:` alert about an unreachable or stale lobster
- When you notice orphaned tasks during normal task management
- After any bulk teardown event

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
4. Post in the **task's thread**: `**[lobboss]** Task complete. PR merged.`

## Auto-Creating QA Verification Tasks

When a SWE lobster opens a PR and announces it in the task thread:

1. Read the original SWE task file. Check the `requires_qa` field.
2. If `requires_qa: true` (or the task involves important code changes):
   a. Create a new QA task using the standard task creation flow (Phase 3), with:
      ```yaml
      type: qa
      repo: <same repo as the SWE task>
      related_task: <swe-task-id>
      pr_number: <the PR number from the SWE lobster's announcement>
      model: anthropic/claude-sonnet-4-5
      ```
      Title: `Verify: <original task title>`
      Objective: `Review and test PR #<number> from <swe-lobster-id>.`
      Acceptance criteria: Code review completed, tests pass, no security issues, verification report posted.
   b. Assign the QA task to a QA lobster (follow "Choosing a Lobster" with type=qa).
   c. Post in the **original SWE task's thread**:
      ```
      **[lobboss]** QA verification task created: <qa-task-id>
      Assigning to a QA lobster for review before merge.
      ```
3. If `requires_qa: false` — skip QA, proceed directly with your own review via the `review-prs` skill.

**Important:** Do NOT merge the SWE PR until QA completes (if requires_qa is true). Wait for the QA lobster's verification report. If QA reports PASS → merge. If QA reports FAIL → request changes from the SWE lobster.

## Failing a Task

If a lobster reports failure or times out:
1. Update the task frontmatter: `status: failed`
2. Add failure notes under `## Lobster Notes`
3. Move to `010-tasks/failed/`
4. Close any orphaned PR for that task:
   ```bash
   gh pr close <number> --comment "Task failed/timed out"
   ```
5. Post in the **task's thread**: `**[lobboss]** Task failed. <brief reason>`
6. Decide whether to re-queue (create a new task referencing the failed one)
