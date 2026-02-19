---
status: draft
tags: [discord, ui, lobboss]
maturity: design
created: 2026-02-15
updated: 2026-02-16
---
# Discord UX Overhaul

## Summary

Consolidate Discord to a single `#lobmob` channel with slash commands for structured actions, natural conversation for everything else, and threaded communication per task. Reduce noise, make lobboss feel like an assistant, and lay groundwork for lobsters to communicate directly with users in task threads.

## Open Questions

- [x] Channel consolidation: collapse to one channel, or keep a minimal set? **Resolved: single `#lobmob` channel, no separate alerts channel. Urgent items ping user/@channel**
- [x] Push vs. pull: what gets pushed proactively? **Resolved: tier 1 (failures, PRs needing review) push to main channel with user mention. Tier 2 (progress, completion) push to task thread. Tier 3 (fleet status, costs, logs) on request via slash commands**
- [x] Forum channel? **Resolved: no, doesn't fit the interaction model**
- [x] Trigger for conversational queries? **Resolved: bare messages (no slash command) are conversational. Slash commands for structured actions**
- [x] Thread strategy? **Resolved: one thread per task via `/task create`. Task updates stay in thread. Conversational queries in main channel get responses in main channel**
- [x] Slash command registration: discord.py app commands or bot commands? **Resolved: app commands (interactions API), guild-scoped registration for instant updates during development**
- [x] How should lobboss handle slash commands internally? **Resolved: direct handler functions for slash commands (deterministic lookups, no LLM needed), Agent SDK for conversational bare messages. Shared underlying query functions so MCP tools can call the same code**
- [x] Cost tracking: **Resolved: deferred to separate [cost tracking plan](./cost-tracking.md). Overlaps with vault scaling and database strategy**
- [x] Daily/weekly digest: **Resolved: deferred to [cost tracking plan](./cost-tracking.md)**

## Current State

### Channels
- `#task-queue` — User posts tasks, lobboss creates threads for each
- `#swarm-control` — Fleet management commands
- `#swarm-logs` — Bot status updates, lobster activity
- `#dev-task-queue` — Dev environment equivalent
- Several channels underutilized or redundant

### Interaction Model
- User posts a task description → lobboss creates a thread, proposes the task, waits for "go"
- Status updates pushed to threads as lobsters work
- Cron-driven status reports posted to `#swarm-logs` every 30min regardless of changes
- No conversational querying
- All messages come from a single anonymous "lobmob app" — no speaker attribution

### Pain Points
- Too many channels for current usage
- Status updates are noisy
- No way to ask lobboss questions outside of task creation
- Can't tell who is speaking (lobboss vs. lobster)
- No slash commands — everything is free-text message parsing

## Slash Command Structure

```
/task create <description>     — Create a task (lobboss creates thread, proposes, waits for approval)
/task status                   — Status of all active, recent completed, recent failed
/task status <task-id>         — Specific task details (e.g. /task status T42)
/task cancel <task-id>         — Cancel a task
/task cost <task-id>           — Cost info for this task

/fleet status                  — Fleet overview (pods, jobs, node status)
/fleet spawn <type>            — Manual lobster reserve spawn
/fleet kill <job-name>         — Kill a running lobster job
```

Task IDs use the sequential format from [vault scaling](../active/vault-scaling.md): `T1`, `T42`, etc. Slash command handlers query lobwife API (`GET /api/v1/tasks`) for fast state lookups — no vault file parsing needed.

Cost commands (`/costs`, `/task cost`) are deferred to the [cost tracking plan](./cost-tracking.md).

Bare messages (no slash command) are conversational — lobboss responds via Agent SDK. e.g. "What failed this week?" / "Show me the PR for the unity task" / "How's the unity task going?"

## Speaker Attribution

Currently all messages come from a single "lobmob app" bot. To distinguish lobboss from lobsters:

- **lobboss** posts as itself with its avatar (normal bot messages)
- **Lobster messages** are posted by lobboss but visually attributed via Discord embeds:
  - Embed author = lobster job name (e.g. `lobster-swe-t42`)
  - Colored sidebar by type: blue for swe, green for research, orange for qa
  - Messages go to the task's thread
- **User replies in a task thread** are routed to that task's lobster
- `/task ask <task-id> <message>` as an explicit way to message a lobster from main channel (stretch)

Future: research direct agent-to-Discord communication (each lobster posts independently rather than through lobboss relay) for reduced fragility. Separate follow-up plan.

## Phases

### Phase 1: Channel consolidation + slash commands

- **Status**: pending
- Create `#lobmob` channel (prod) and `#lobmob-dev` channel (dev)
	- Already created. `#lobmob` channel ID is 1473200779459297355. `#lobmob-dev` channel ID is 1473200751881752668.
- Implement slash command registration via discord.py app commands
- Implement core commands: `/task create`, `/task status`, `/task cancel`, `/fleet status`
- Migrate lobboss config from 3 channel IDs to 1
- Update cron scripts (status-reporter, task-manager) to post to new channel/threads
- Archive old channels (don't delete)
- Thread creation moves from "bare message in task-queue" to `/task create`
- `/task create` calls lobwife API to create task (returns sequential ID), then writes vault file for body
- `/task status` queries lobwife API (`GET /api/v1/tasks`) — requires [vault scaling](../active/vault-scaling.md) Phase 2
- Conversational queries: any non-command message in `#lobmob` gets routed to Agent SDK

### Phase 2: Noise reduction

- **Status**: pending
- Implement message tiers:
  - **Tier 1 (push to main channel)**: Task failures, PRs needing human review, system errors. Include @user or @channel mention
  - **Tier 2 (push to task thread)**: Task progress updates, completion notices
  - **Tier 3 (on request only)**: Fleet status, cost summaries, logs — served by slash commands
- Kill the periodic status-reporter dump. Replace with: post only when something changed (new failures, stale tasks)
- Aggregate similar updates — "3 tasks completed in the last hour" instead of 3 separate messages

### Phase 3: Fleet management commands

- **Status**: pending
- Implement `/fleet spawn <type>` — manual lobster reserve spawn
- Implement `/fleet kill <job-name>` — kill a running job

### Phase 4: Speaker attribution + thread improvements

- **Status**: pending
- Implement embed-based speaker attribution for lobster messages (color-coded by type, author = job name)
- Include task display name and status indicator in thread titles
- Auto-archive completed task threads after 24-48h
- Pin summary message at top of each task thread (task metadata, links, current status)

### Phase 5: Lobster-to-user communication (stretch)

- **Status**: pending
- Enable lobsters to post clarification questions and unblocking requests to their task thread during execution
- User replies in the thread are routed back to the lobster
- Requires lobster → Discord communication path (currently lobsters don't have Discord access)
- This may warrant a separate follow-up plan for direct agent-to-Discord communication

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-15 | Single `#lobmob` channel, no separate alerts | Simpler. Urgent items use @mentions to get attention |
| 2026-02-15 | Slash commands for structured actions, bare messages for conversation | Explicit intent, no ambiguity between task creation and questions |
| 2026-02-15 | No forum channels | Interaction model change too disruptive, thread-per-task already works |
| 2026-02-15 | Embed-based speaker attribution (Option A) | Single bot, visually distinct speakers. Webhooks (Option B) can be explored later for direct agent communication |
| 2026-02-15 | Dev gets separate `#dev-lobmob` channel | Clean separation, same slash commands |
| 2026-02-15 | `/task ask` and direct lobster communication deferred | Needs research into lobster → Discord path. Follow-up plan |
| 2026-02-15 | App commands (interactions API), guild-scoped | Modern Discord pattern, autocomplete support, instant registration |
| 2026-02-15 | Direct handlers for slash commands, Agent SDK for conversation | Structured lookups don't need LLM reasoning. Shared query functions for both paths |
| 2026-02-15 | Cost commands deferred to separate plan | Overlaps with vault scaling, database strategy, and data pipeline decisions |

## Scratch

- Could lobboss post a daily morning summary? "Yesterday: 5 tasks completed, 1 failed. Today: 3 queued. Budget: $X spent / $Y limit" — could be opt-in via a `/digest on` command
- Discord embeds for richer display: colored sidebar, fields for status/type/cost, thumbnail for task type icon
- Reaction-based quick actions on task thread root message: thumbs-up to approve, X to cancel
- Multi-user awareness: if multiple users interact, should lobboss track who requested what? Currently single-user assumption. Becomes important if the Discord is shared
- Consider a "do not disturb" mode where lobboss holds all non-critical messages until user returns
- For direct lobster-to-Discord: options include giving lobsters a Discord webhook URL, having them post via lobwife relay, or running a lightweight Discord client in the lobster sidecar
- Slash command discoverability: discord.py supports autocomplete for slash command arguments — could suggest task IDs, job names, etc. With sequential IDs (T1, T42), autocomplete from lobwife API becomes natural
- Thread naming: "T42 — Unity UI Overhaul" is cleaner than "task-2026-02-15-a1b2 — Unity UI Overhaul"

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [Task Flow Improvements](./task-flow-improvements.md) — Task naming, web entry, cancel/re-open actions
- [Vault Scaling](../active/vault-scaling.md) — Slash commands depend on fast API queries from lobwife DB. Task IDs, task creation flow
- [System Maintenance Automation](./system-maintenance-automation.md) — Audit findings need Discord notification strategy
