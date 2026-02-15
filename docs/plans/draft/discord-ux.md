---
status: draft
tags: [discord, ui, lobboss]
maturity: design
created: 2026-02-15
updated: 2026-02-15
---
# Discord UX Overhaul

## Summary

Rethink how lobboss uses Discord to reduce noise, improve usability, and make the bot feel more like an assistant than a log stream. Currently the bot is spammy, we have more channels than we use, and the interaction model is mostly push (bot broadcasts) rather than pull (user asks).

## Open Questions

- [ ] Channel consolidation: collapse to one channel, or keep a minimal set (e.g. one for tasks, one for alerts)? Single channel with threads might be cleanest
- [ ] What should be pushed proactively vs. only shown on request? Candidates for push: task completion, failures, PRs needing review. Candidates for pull: status queries, logs, cost reports
- [ ] Thread strategy: one thread per task (current) works well — should we also use threads for status conversations, reviews, daily summaries?
- [ ] Should lobboss support conversational queries? e.g. "what's the status of the unity task?" / "how much have we spent today?" / "show me failed tasks this week"
- [ ] Notification preferences: should users be able to configure what gets pushed? Per-user or per-channel?
- [ ] Should completed task threads be auto-archived after a time window?
- [ ] Forum channel vs. regular channel? Forum channels give better thread organization and per-thread tags

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
- Cron-driven status reports posted to `#swarm-logs`
- No conversational querying — can't ask "what's running?" in Discord

### Pain Points
- Too many channels for the current usage level
- Status updates are noisy — every cron run generates output
- No way to ask lobboss questions outside of task creation
- Thread naming doesn't clearly indicate task status at a glance

## Phases

### Phase 1: Channel consolidation

- **Status**: pending
- Audit current channel usage — which channels get messages, which are dead
- Propose a minimal channel set. Candidate: single `#lobmob` channel with threads, or `#tasks` + `#alerts`
- If using forum channel: define tag categories (task type, status, priority)
- Migrate bot configuration to target new channel(s)
- Archive unused channels (don't delete — preserve history)

### Phase 2: Noise reduction

- **Status**: pending
- Classify all bot messages into tiers:
  - **Tier 1 (always push)**: Task failures, PRs needing human review, system errors
  - **Tier 2 (push to thread)**: Task progress updates, completion notices
  - **Tier 3 (on request only)**: Status reports, cost summaries, fleet status, logs
- Update status-reporter to only post when there's something meaningful (not every 30min regardless)
- Aggregate similar updates — "3 tasks completed in the last hour" instead of 3 separate messages
- Add quiet hours or batching: accumulate non-urgent updates, post a digest

### Phase 3: Conversational queries

- **Status**: pending
- Enable lobboss to respond to natural language queries in Discord:
  - "status" / "what's running?" → current fleet status
  - "show me task X" → task details, assigned lobster, PR links
  - "costs today" → token usage and cost summary
  - "failed tasks this week" → filtered task list
- This leverages the existing Agent SDK integration — lobboss already understands natural language, just needs the right MCP tools exposed for querying
- Define a trigger pattern: direct mention (`@lobboss status`), or any message in the control channel, or prefix (`!status`)

### Phase 4: Thread improvements

- **Status**: pending
- Include task display name and status emoji in thread titles (e.g. "Unity UI Overhaul [in-progress]")
- Auto-archive completed task threads after 24-48h
- Pin summary message at top of each task thread (task metadata, links, current status)
- Add reaction-based quick actions: thumbs-up to approve, X to cancel

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|

## Scratch

- Could lobboss post a daily morning summary? "Yesterday: 5 tasks completed, 1 failed. Today: 3 queued. Budget: $X spent / $Y limit"
- Discord forum channels support tags per thread — could tag by task type (swe/research/qa) and status. Would need discord.py forum channel support
- Consider a "do not disturb" mode where lobboss holds all non-critical messages until user returns
- Slash commands (`/status`, `/spawn`, `/costs`) might be cleaner than natural language parsing for structured queries — but less flexible
- Could use Discord embeds for richer task status display (colored sidebar, fields, thumbnails)
- Multi-user awareness: if multiple users interact, should lobboss track who requested what? Currently single-user assumption

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [Task Flow Improvements](./task-flow-improvements.md) — Task naming affects Discord thread names
