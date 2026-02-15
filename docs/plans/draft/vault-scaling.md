---
status: draft
tags: [vault, infrastructure]
maturity: research
created: 2026-02-15
updated: 2026-02-15
---
# Vault Scaling & Sync

## Summary

The Obsidian vault (git repo) is the central nervous system for task state, logs, reports, and agent coordination. As the system scales (more concurrent lobsters, more task types, faster iteration), the git-based approach faces real-time sync challenges, merge conflicts, and a growing tension between "human-friendly Obsidian notebook" and "machine state store." This plan explores how to evolve the vault architecture to handle increased load while preserving the Obsidian UX.

## Open Questions

- [ ] **Core question**: Should the vault remain the single source of truth for everything, or should machine state (task status, logs, metrics) move to a purpose-built store while the vault stays as the human interface?
- [ ] If splitting: what's the boundary? Task definitions and results stay in vault, but real-time status and logs go to a database?
- [ ] If keeping unified: how do we solve the concurrent-writes problem? Multiple lobsters pushing to the same repo simultaneously causes conflicts
- [ ] Git conflict resolution: who resolves? lobboss? A dedicated merge bot? File-level locking? Or restructure to avoid conflicts entirely (one file per writer)?
- [ ] Obsidian kanban: is the Kanban plugin (single-file board) good enough, or do we need Dataview-driven status views? Research showed git sync issues with Kanban boards
- [ ] Real-time sync: is "pull before every read, push after every write" fast enough? Current vault operations add seconds of latency per git cycle
- [ ] Scale target: how many concurrent vault writers do we need to support? Currently 1 (lobboss) + cron scripts. Future: 5-10 lobsters + lobboss + lobsigliere?

## Current State

### What the vault holds
- `010-tasks/` — Task definitions (frontmatter + markdown), active/completed/failed subdirs
- `020-logs/` — Session logs, Discord message logs
- `030-reports/` — Status reports, fleet reports
- `040-fleet/` — Agent configuration, AGENTS.md files
- `AGENTS.md` — Root coordinator prompt

### How it's accessed
- **lobboss**: Reads task queue, writes task files, updates status. Has a PVC mount, does git pull/push
- **lobsters**: Clone vault into container at start, read task, write results, push. Each lobster gets its own clone (no shared PVC)
- **lobwife cron scripts**: Read/write vault on PVC (task-manager, status-reporter)
- **lobsigliere**: Own PVC clone, reads investigation tasks, writes results
- **Human (Obsidian)**: Reads vault locally or via GitHub, edits task files, reviews results

### Current pain points
- Concurrent pushes occasionally fail — lobsters retry, but it adds latency
- Vault git history is noisy (many small status-update commits from cron scripts)
- No real-time sync — Obsidian sees changes only after git pull
- Vault structure is a hybrid of "things humans read" and "machine state tracking"
- `HEAD.lock` stale files from interrupted git operations (noted in MEMORY.md as a TODO)

## Approaches

### Approach A: Optimize the git workflow (incremental)

Keep vault as-is but reduce conflict surface and improve sync speed.

- **One file per writer**: Restructure so each agent writes to its own file/directory. Conflicts only happen when two writers modify the same file
- **Atomic operations**: Wrap vault git ops in a retry loop with rebase (not merge). `git pull --rebase && git push`, retry on conflict
- **Reduce commit noise**: Batch status updates (commit every N minutes, not every change). Or use a staging area that flushes periodically
- **HEAD.lock cleanup**: Auto-remove stale lock files in `pull_vault()` (MEMORY.md TODO)
- **Pros**: Minimal architecture change, preserves Obsidian UX
- **Cons**: Doesn't fundamentally solve concurrent-writes, still limited by git push/pull latency

### Approach B: Split state store (hybrid)

Move machine-to-machine state to a lightweight database. Vault stays as the human interface.

- **Vault keeps**: Task definitions, results, reports, agent prompts — things humans read/edit
- **Database gets**: Real-time task status, assignment state, log streams, metrics, token audit
- **Options**: SQLite on PVC (simplest), PostgreSQL on DO Managed DB (more capable), Redis for ephemeral state
- **Sync**: Database is authoritative for real-time state. Cron or daemon writes periodic snapshots to vault (human-readable summaries)
- **Pros**: Clean separation of concerns, real-time state queries, no git conflicts for status updates
- **Cons**: New infrastructure to manage, two sources of truth during transition, Obsidian can't query the database natively

### Approach C: Message queue / pub-sub (event-driven)

Replace direct git writes with an event system.

- **Agents publish events**: "task started", "task completed", "PR created"
- **Consumers**: Vault writer (batches events into git commits), dashboard (real-time display), Discord (notifications)
- **Options**: Redis pub/sub (already useful if adopting Approach B), NATS (lightweight), or just lobwife HTTP API as a simple event sink
- **Pros**: Decouples writers from vault, enables real-time dashboard, events are replayable
- **Cons**: Significant architecture change, new infrastructure, more complex failure modes

### Approach D: Obsidian-native improvements

Leverage Obsidian plugins to improve the vault experience without backend changes.

- **Dataview dashboards**: Task status tables, kanban-style views, audit reports — already planned in roadmap
- **Obsidian git plugin**: Auto-pull on interval, auto-push on change. Reduces manual sync friction for the human user
- **Kanban board**: Single-file board for task triage (acknowledging git sync limitations)
- **Pros**: No backend changes, improves human UX immediately
- **Cons**: Doesn't solve machine-side concurrency or scale

## Phases

### Phase 1: Quick wins (Approach A + D)

- **Status**: pending
- Add `HEAD.lock` auto-cleanup to `vault.py pull_vault()`
- Implement retry-with-rebase in vault git operations
- Add Dataview dashboards to vault (task status, recent activity)
- Restructure vault writes to reduce conflict surface (one status file per task, not a shared status doc)

### Phase 2: Evaluate split architecture (Approach B research)

- **Status**: pending
- Prototype SQLite-on-PVC for real-time state: task status, assignment map, metrics
- Benchmark: how much latency does removing git from the hot path save?
- Define the boundary: what stays in vault, what moves to DB
- Evaluate whether lobwife can host the DB (already persistent, already has API)

### Phase 3: Implement chosen approach

- **Status**: pending
- Depends on Phase 2 findings
- If split: migrate real-time state to DB, add sync daemon to write vault summaries
- If optimized git: implement batched commits, structured per-writer directories
- Either way: update all vault consumers (lobboss, lobsters, cron scripts, lobsigliere)

### Phase 4: Obsidian kanban and advanced views

- **Status**: pending
- After sync is reliable, add Kanban board for task triage
- Add Dataview-driven views for: task pipeline, lobster activity, cost tracking
- Evaluate Obsidian Projects plugin as an alternative to Kanban plugin

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-15 | Start with Approach A (optimize git) before considering split | Minimize architecture churn; current scale doesn't demand a database yet |
| 2026-02-15 | Maturity: research | Core question (split vs. unified) needs data from real usage patterns before committing |

## Scratch

- The vault git history could be cleaned up with squash commits for status-update batches (but this rewrites history — risky with multiple clones)
- Could lobwife act as a vault proxy? All writes go through lobwife API, it batches and commits. Serializes all writes, eliminates conflicts. Adds a single point of failure though
- File-level locking via git LFS lock or a custom lock file convention? Probably overkill
- If we go database route, the Obsidian Dataview plugin can't query external DBs — would need a sync layer or a custom plugin
- Consider git worktrees instead of full clones for lobsters — lighter weight, share .git objects
- The "noisy git history" problem could be solved by having a separate branch for machine state commits, periodically squashed and merged
- Redis on lobwife could serve double duty: pub/sub for events + cache for real-time state. But adds a dependency
- For Obsidian kanban: research showed the plugin is looking for new maintainers — maintenance risk. Dataview-based views might be more sustainable
- Vault-as-filesystem has one big advantage: every state change is version-controlled and auditable. A database loses that unless we add explicit audit logging
- Consider: does the vault need to be a git repo at all? Could it be a local filesystem synced via rsync/Syncthing? Git gives us versioning and remote access, but at the cost of merge complexity

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [System Maintenance Automation](./system-maintenance-automation.md) — Audit results stored in vault, affected by sync strategy
- [Task Flow Improvements](./task-flow-improvements.md) — Task naming and structure affects vault file layout
