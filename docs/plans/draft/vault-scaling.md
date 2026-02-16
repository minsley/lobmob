---
status: draft
tags: [vault, infrastructure, lobwife]
maturity: design
created: 2026-02-15
updated: 2026-02-15
---
# Vault Scaling & State Store

## Summary

Introduce SQLite (via lobwife API) as the source of truth for real-time machine state — task status, assignment, cost events, audit findings, job state. The Obsidian vault remains the human interface for task definitions, results, reports, and planning docs. A sync daemon on lobwife writes periodic snapshots to vault so Obsidian stays browseable. This unblocks fast queries for web UI, Discord slash commands, cost tracking, and sequential task ID generation.

## Open Questions

- [x] **Core question**: unified vault or split state store? **Resolved: split. SQLite for real-time machine state, vault for human-readable content**
- [x] Database choice? **Resolved: SQLite on lobwife PVC, accessed via lobwife HTTP API. Migrate to PostgreSQL if/when SQLite limits are hit**
- [x] Concurrent writes? **Resolved: all writes go through lobwife API, serialized to SQLite. No concurrent-write problem**
- [x] Git conflict resolution? **Resolved: vault becomes mostly-read for machines. Sync daemon writes, no concurrent pushes to shared files**
- [x] Obsidian kanban? **Resolved: skip Kanban plugin. Use Dataview tables querying vault frontmatter (synced from DB)**
- [x] Real-time sync? **Resolved: real-time state lives in DB, queried via API. Vault gets periodic snapshots for Obsidian browsing**
- [x] Scale target? **Resolved: lobwife API serializes all writes. No limit on concurrent readers. Scales well past 10 lobsters**
- [x] Task ID generation? **Resolved: SQLite autoincrement gives sequential IDs (T1, T2, ...). Date and slug become metadata fields**
- [x] Vault sync frequency: **Resolved: every 5 minutes + on significant state changes (completion, failure). Configurable**
- [x] Vault sync format: **Resolved: one file per task (current pattern) plus an overview file with Dataview frontmatter**
- [x] Migration path: **Resolved: one-time Python script to parse existing vault task frontmatter and insert into DB. Old files stay as human-readable copies**
- [x] API authentication: **Resolved: cluster-internal networking sufficient for now. Add token auth when WAN access is introduced**
- [x] Schema versioning: **Resolved: simple `schema_version` table + Python migration scripts. No alembic needed at this scale**

## Architecture

```
                         ┌─────────────────┐
                         │   Obsidian       │
                         │   (human reads)  │
                         └────────▲─────────┘
                                  │ git pull
                         ┌────────┴─────────┐
                         │   Vault (git)    │
                         │   Human content  │
                         │   + DB snapshots │
                         └────────▲─────────┘
                                  │ periodic sync
┌──────────┐  HTTP   ┌───────────┴──────────┐   HTTP   ┌──────────┐
│ lobboss  │────────▶│      lobwife          │◀────────│ lobsters │
│          │         │                       │         │          │
│          │         │  SQLite DB (PVC)      │         │          │
│          │         │  ├─ tasks             │         │          │
│          │         │  ├─ task_events       │         │          │
│          │         │  ├─ cost_events       │         │          │
│          │         │  ├─ audit_findings    │         │          │
│          │         │  ├─ job_state         │         │          │
│          │         │  └─ broker_tasks      │         │          │
│          │         │                       │         │          │
│          │         │  Token broker (existing)        │          │
│          │         │  Cron scheduler (existing)      │          │
│          │         └───────────────────────┘         └──────────┘
                              ▲
                              │ HTTP
                     ┌────────┴────────┐
                     │  audit CronJobs │
                     │  Discord cmds   │
                     │  web dashboard  │
                     └─────────────────┘
```

## What Lives Where

### Database (SQLite via lobwife API) — source of truth for real-time state

| Table | Replaces | Purpose |
|-------|----------|---------|
| `tasks` | vault task frontmatter | id (autoincrement), name, type, status, assignee, repos, description, created_at, updated_at, completed_at |
| `task_events` | (new) | Status changes, assignment, completion — full audit trail |
| `cost_events` | (new) | Per-API-call token usage and cost. Feeds `/costs` commands |
| `audit_findings` | (new) | Audit results with severity, resolution tracking |
| `job_state` | jobs.json | k8s job tracking. Replaces lobwife's current JSON file |
| `broker_tasks` | tasks.json | Token broker registrations. Replaces lobwife's current JSON file |

### Vault (git) — human interface, Obsidian-browseable

| Content | Access pattern |
|---------|---------------|
| Task definitions (full markdown with context, instructions) | Written once at creation, read by lobsters |
| Task results and reports (PR links, output, notes) | Written by lobsters at completion |
| Audit report summaries (synced from DB) | Written by sync daemon |
| Agent prompts, skills, config | Read on startup |
| Planning docs, roadmap, scratch sheets | Human read/write |
| DB snapshots (task status overviews, cost summaries) | Written by sync daemon, read by Obsidian/Dataview |

### Task ID Migration

Current: `2026-02-15-unity-ui` (date-slug, used as filename and k8s label)
New: `T42` (sequential autoincrement from SQLite)

- Date and slug become metadata fields in the DB (`created_at`, `name`)
- Vault task files named by new ID: `010-tasks/active/T42.md`
- K8s job names: `lobster-swe-t42` (shorter, cleaner)
- Discord threads: "T42 — Unity UI Overhaul"
- Backwards-compatible: old-format task files can coexist during migration

## lobwife API Extensions

New endpoints alongside existing token broker and cron API:

```
# Task CRUD
POST   /api/tasks                    — Create task (returns new ID)
GET    /api/tasks                    — List tasks (filterable by status, type, date range)
GET    /api/tasks/{id}               — Get task details
PATCH  /api/tasks/{id}               — Update task (status, name, assignee, etc.)
DELETE /api/tasks/{id}               — Cancel/delete task

# Task events
GET    /api/tasks/{id}/events        — Task history (status changes, assignment)
POST   /api/tasks/{id}/events        — Log an event

# Cost tracking
POST   /api/costs                    — Log cost event
GET    /api/costs                    — Query costs (by task, date range, model)
GET    /api/costs/summary            — Aggregated cost summary

# Audit findings
POST   /api/audits                   — Submit audit findings
GET    /api/audits                   — Query findings (by type, severity, date)

# Existing (unchanged)
POST   /api/tasks/{id}/register      — Token broker registration
POST   /api/token                    — Token issuance
DELETE /api/tasks/{id}               — Token broker deregistration
GET    /api/token/audit              — Token audit log
```

Note: the token broker `POST/DELETE /api/tasks/{id}` endpoints overlap with the new task CRUD. These should be unified — broker registration becomes a field/event on the task, not a separate resource.

## Phases

### Phase 1: SQLite foundation on lobwife

- **Status**: pending
- Add SQLite to lobwife daemon (replace jobs.json and tasks.json with DB tables)
- Define schema: tasks, task_events, job_state, broker_tasks
- Migrate token broker and job runner state from JSON files to SQLite
- Add basic task CRUD API endpoints
- Sequential task ID generation via autoincrement
- No vault changes yet — just the DB layer

### Phase 2: Migrate task lifecycle to DB

- **Status**: pending
- Update lobboss to create tasks via lobwife API instead of writing vault files directly
- Update lobsters to report status via lobwife API
- Update task-manager cron to read/write task state via API
- Vault task files become the "human-readable copy" synced from DB
- Write migration script for existing vault tasks → DB import

### Phase 3: Vault sync daemon

- **Status**: pending
- Periodic sync from DB to vault: task status overviews, active task list, recent completions
- Configurable frequency (default: every 5 minutes, or on significant state change)
- Sync writes Dataview-queryable markdown files to vault
- Obsidian sees current state without manual git pull of machine-generated commits
- Reduce vault git noise — one sync commit per cycle instead of per-status-change

### Phase 4: Cost and audit data

- **Status**: pending
- Add cost_events and audit_findings tables
- Instrument lobboss/lobster Agent SDK calls to push cost events to lobwife
- Audit CronJobs push findings to lobwife
- Enables `/costs` Discord commands and web dashboard cost views
- Ties into [cost tracking plan](./cost-tracking.md)

### Phase 5: Git workflow cleanup

- **Status**: pending
- HEAD.lock auto-cleanup in vault.py (long-standing TODO)
- Retry-with-rebase for remaining vault git operations
- Reduce vault writes to: task definitions (at creation), results (at completion), sync snapshots
- Evaluate whether lobsters still need full vault clones or can work with API + targeted file access

### Phase 6: Obsidian views

- **Status**: pending
- Dataview dashboards in vault: task pipeline, cost trends, audit history
- Powered by DB-synced markdown files with structured frontmatter
- Skip Kanban plugin — Dataview tables are more sustainable and git-friendly

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-15 | Split state store: SQLite for machine state, vault for human content | Git is a poor fit for high-frequency machine state. DB unblocks web UI, Discord commands, cost tracking, and sequential IDs |
| 2026-02-15 | SQLite on lobwife PVC, not managed PostgreSQL | Simplest path. No new infrastructure. lobwife already has PVC and API. Migrate to PostgreSQL later if needed |
| 2026-02-15 | All writes through lobwife API | Serializes writes, eliminates concurrent-write conflicts, provides a clean API for all consumers |
| 2026-02-15 | Sequential task IDs (T1, T2, ...) via autoincrement | Solves distributed counter problem. Shorter, cleaner than date-slug format |
| 2026-02-15 | Skip Kanban plugin | Git sync issues, uncertain maintenance. Dataview tables are more sustainable |
| 2026-02-15 | Vault becomes human interface, not machine coordination layer | Clean separation of concerns. Machines talk to API, humans browse Obsidian |
| 2026-02-15 | Vault sync every 5min + on significant events | Keeps Obsidian current without noisy commits. Configurable |
| 2026-02-15 | One file per task in vault (with overview file) | Better git diffs, Obsidian browsing. Overview has Dataview frontmatter |
| 2026-02-15 | One-time migration script for existing tasks | Parse frontmatter, insert into DB. Old files stay as-is |
| 2026-02-15 | Cluster-internal networking, no API auth for now | lobwife only reachable via ClusterIP. Add token auth with WAN access |
| 2026-02-15 | Simple schema_version table + migration scripts | No heavy tooling needed at this scale |

## Scratch

- lobwife becomes increasingly central — token broker, cron scheduler, state DB, sync daemon. Monitor for single-point-of-failure risk. Consider: what happens if lobwife is down? lobboss and lobsters should degrade gracefully (queue writes, retry)
- Schema versioning: could use a simple `schema_version` table and migration scripts. Or use a lightweight migration tool (alembic for Python, but may be overkill)
- The vault sync daemon could also sync planning docs and roadmap state, not just task state
- Consider a read-only API on lobboss (proxying to lobwife) for the web dashboard, so the dashboard doesn't need direct lobwife access
- SQLite WAL mode enables concurrent reads with a single writer — good fit for lobwife's serialized-write pattern
- If lobsters only need API access for status reporting (not full vault clones), that significantly reduces git pressure and container startup time
- The token broker `tasks` and the new task CRUD `tasks` should be unified into one table. Broker registration becomes "this task has repo access" rather than a separate resource
- Could add WebSocket support to lobwife for real-time updates to web dashboard and Discord (push instead of poll). Stretch goal
- Task ID format `T42` is clean but may collide if we ever need multiple environments sharing a DB. Prefix with env? `T42` for prod, `D42` for dev? Or just separate DBs per environment (already the case with separate lobwife instances)

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [Task Flow Improvements](./task-flow-improvements.md) — Web UI task creation, sequential IDs, faster polling all depend on the DB
- [Discord UX](./discord-ux.md) — Slash commands need fast state queries
- [Cost Tracking](./cost-tracking.md) — Cost events table in the DB, `/costs` commands query it
- [System Maintenance Automation](./system-maintenance-automation.md) — Audit findings stored in DB
