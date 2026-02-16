---
status: active
tags: [vault, infrastructure, lobwife]
maturity: implementation
created: 2026-02-15
updated: 2026-02-16
---
# Vault Scaling & State Store

## Summary

Introduce SQLite (via lobwife API) as the source of truth for real-time machine state — task status, assignment, cost events, audit findings, job state. The Obsidian vault remains the human interface for task content (body, instructions, results, reports) and planning docs. A sync daemon on lobwife writes periodic state snapshots to vault so Obsidian stays browseable. This unblocks fast queries for web UI, Discord slash commands, cost tracking, and sequential task ID generation.

**Key separation**: DB stores task **state** (status, assignment, timing, cost, events). Vault stores task **content** (body, objectives, criteria, results). Task body is NOT stored in the DB.

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
- [x] Task body in DB? **Resolved: No. DB stores state (status, assignment, timing), vault stores content (body, results). Avoids duplicating multi-KB markdown**
- [x] API route collision with broker? **Resolved: new endpoints use `/api/v1/` prefix. Old broker routes stay in Phase 1, become deprecated aliases in Phase 2**
- [x] Broker table strategy? **Resolved: separate `broker_tasks` table in Phase 1 (tasks don't exist in DB yet). Unified into tasks table columns in Phase 2**
- [x] Dual-write during Phase 2? **Resolved: yes. Keeps Obsidian current before sync daemon. Removed in Phase 3**
- [x] task-manager.sh migration? **Resolved: rewrite in Python for Phase 2. Gets lobwife_client, proper error handling, testability**
- [x] Split lobwife-daemon.py into modules? **Resolved: yes. Extracted lobwife_db.py, lobwife_jobs.py, lobwife_broker.py, lobwife_api.py. Daemon is slim orchestrator (~100 lines)**
- [ ] status-reporter.sh: migrate to API queries in Phase 2, or defer? Lower priority (56 lines, runs every 30 min)

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
| `tasks` | vault task frontmatter | id (autoincrement), name, type, status, assignee, repos, timestamps. Body stays in vault |
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

New endpoints use `/api/v1/` prefix to avoid collision with existing broker routes at `/api/tasks/`. Existing broker routes stay unchanged in Phase 1, then become deprecated aliases in Phase 2 when broker registration is unified into the tasks table.

```
# Task CRUD (new, versioned)
POST   /api/v1/tasks                 — Create task (returns {id, task_id: "T{id}"})
GET    /api/v1/tasks                 — List tasks (?status=, ?type=, ?limit=). No body (metadata only)
GET    /api/v1/tasks/{id}            — Get task detail (metadata, no body — body lives in vault)
PATCH  /api/v1/tasks/{id}            — Update task fields (status, assigned_to, etc.)
DELETE /api/v1/tasks/{id}            — Cancel task

# Task events (new)
GET    /api/v1/tasks/{id}/events     — Task history (status changes, assignment)
POST   /api/v1/tasks/{id}/events     — Log an event

# Cost tracking (Phase 4)
POST   /api/v1/costs                 — Log cost event
GET    /api/v1/costs                 — Query costs (by task, date range, model)
GET    /api/v1/costs/summary         — Aggregated cost summary

# Audit findings (Phase 4)
POST   /api/v1/audits                — Submit audit findings
GET    /api/v1/audits                — Query findings (by type, severity, date)

# Existing broker routes (unchanged in Phase 1, deprecated in Phase 2)
POST   /api/tasks/{task_id}/register — Token broker registration
POST   /api/token                    — Token issuance
DELETE /api/tasks/{task_id}          — Token broker deregistration
GET    /api/token/audit              — Token audit log

# Existing cron/status routes (unchanged)
GET    /health, /api/status, /api/jobs, /api/jobs/{name}, etc.
```

**Broker unification (Phase 2)**: Broker registration becomes fields on the tasks table (`broker_repos`, `broker_status`, `token_count`). The old `/api/tasks/{task_id}/register` route becomes a PATCH to the task record. Token issuance (`/api/token`) looks up broker fields from the tasks table.

## Phases

### Phase 1: SQLite foundation on lobwife

- **Status**: complete (PR #11, merged 2026-02-16, E2E 10/10)
- **Goal**: Replace JSON state files with SQLite. Add task CRUD API. No consumer changes — existing vault-based flows continue working.

**1.1 — Add aiosqlite dependency**
- `containers/lobwife/requirements.txt`: add `aiosqlite>=0.20.0,<1`

**1.2 — Schema file**
- New file: `scripts/server/lobwife-schema.sql`
- Tables: `schema_version`, `tasks`, `task_events`, `job_state`, `broker_tasks`, `token_audit`
- `tasks` table stores metadata only — no body column. Fields: id (autoincrement), name, slug (old date-slug for backwards compat), type, status, priority, model, assigned_to, repos (JSON), discord_thread_id, estimate_minutes, requires_qa, workflow, timestamps (created_at, updated_at, queued_at, assigned_at, completed_at), broker fields (broker_repos, broker_status, token_count, broker_registered_at)
- Indexes on `tasks(status)`, `tasks(type)`, `task_events(task_id)`
- WAL mode enabled on DB init (`PRAGMA journal_mode=WAL`)

**1.3 — DB module in lobwife daemon**
- Add `DB_PATH = STATE_DIR / "lobmob.db"`
- `init_db()`: open connection, execute schema, enable WAL, set initial schema_version
- `migrate_json_to_db()`: one-time migration on first startup
  - Load `jobs.json` → INSERT INTO `job_state`
  - Load `tasks.json` (broker registrations) → INSERT INTO `broker_tasks`
  - Load `token-audit.json` → INSERT INTO `token_audit`
  - Rename migrated files to `.migrated`
- Hold single `aiosqlite` connection for daemon lifetime

**1.4 — Migrate JobRunner to DB**
- Replace `load_state()` / `save_state()` with DB queries
- `_ensure_state_keys()` → INSERT OR IGNORE for each job name
- `_run_job()` → UPDATE job_state at end of run
- `get_status()` / `get_job_detail()` → SELECT from job_state
- `enable()` / `disable()` → UPDATE job_state
- Remove `STATE_FILE`, `load_state()`, `save_state()`

**1.5 — Migrate TokenBroker to DB**
- Replace `self.tasks` dict and JSON persistence with `broker_tasks` table
- Keep broker as a **separate table** in Phase 1 (not yet unified with tasks table — tasks don't exist in DB yet)
- `register_task()` → INSERT INTO broker_tasks
- `deregister_task()` → UPDATE/DELETE broker_tasks
- `get_token_for_task()` → SELECT from broker_tasks
- `cleanup_expired()` → DELETE where registered_at too old
- Audit → INSERT INTO token_audit
- Remove `TASKS_FILE`, `AUDIT_FILE`, `_load_state()`, `_save_state()`, `save_audit()`

**1.6 — Task CRUD API endpoints**
- New routes under `/api/v1/`:
  - `POST /api/v1/tasks` — create task, returns `{id, task_id: "T{id}"}`
  - `GET /api/v1/tasks` — list tasks (metadata only, `?status=`, `?type=`, `?limit=`)
  - `GET /api/v1/tasks/{id}` — get task detail (metadata only)
  - `PATCH /api/v1/tasks/{id}` — update fields (status, assigned_to, etc.)
  - `DELETE /api/v1/tasks/{id}` — cancel task
  - `GET /api/v1/tasks/{id}/events` — event history
  - `POST /api/v1/tasks/{id}/events` — log event

**1.7 — Update /health**
- Add DB connectivity check (`SELECT 1 FROM schema_version`)
- Report DB file size and task count

**1.8 — Update persist_loop**
- Replace `save_state()` + `broker.save_audit()` with `PRAGMA wal_checkpoint(PASSIVE)` every 5 min
- Add periodic DB backup: SQLite `.backup` to `STATE_DIR/lobmob.db.bak` (hourly)

**1.9 — Testing checkpoint**
- Build lobwife image, deploy to dev
- Verify cron jobs still run (job_state in DB, not JSON)
- Verify token broker still works (register → get token → deregister)
- Curl test all new `/api/v1/tasks` endpoints
- Verify `/health` includes DB status
- Verify JSON → DB migration runs cleanly on first startup
- Verify old JSON files renamed to `.migrated`

### Phase 2: Migrate task lifecycle to DB

- **Status**: pending
- **Goal**: Consumers create and update task state via API. Vault still used for task content (body, results). Dual-write to vault frontmatter during this phase so Obsidian stays current until the sync daemon (Phase 3) takes over.

**2.1 — Shared lobwife API client**
- New file: `src/common/lobwife_client.py`
- Thin async HTTP client for lobwife API, shared by lobboss and lobsters
- Functions: `create_task()`, `get_task()`, `update_task()`, `list_tasks()`, `log_event()`
- Base URL from `LOBWIFE_URL` env var (already set in all containers)
- Retry with backoff on connection failures (3 attempts: 10s, 30s, 60s)

**2.2 — Migration script for existing vault tasks**
- New file: `scripts/migrate-vault-tasks.py`
- Parse all vault task files in `010-tasks/{active,completed,failed}/*.md`
- Extract frontmatter → INSERT INTO tasks table (metadata fields)
- Map old task ID (slug) to new sequential ID
- Create initial `task_events` entries (created event + current status event)
- Output mapping file `{old_slug: new_id}` for reference
- Run against dev vault first, verify, then prod

**2.3 — Update lobboss task-create skill**
- Update `skills/lobboss/task-create/SKILL.md` Phase 3 flow:
  1. `POST /api/v1/tasks` with metadata → returns `{id: 42, task_id: "T42"}`
  2. Write vault file at `010-tasks/active/T42.md` with full body (using new task_id as filename)
  3. Vault frontmatter includes DB id + human-readable fields
  4. Commit and push vault (content write — this is the only vault write at creation time)
- lobboss agent uses `lobwife_client.create_task()` via MCP tool or direct call

**2.4 — Update task_poller**
- `src/lobboss/task_poller.py` changes:
  - Query lobwife API for queued tasks (`list_tasks(status="queued")`) instead of `list_tasks(vault_path)`
  - After spawning, PATCH API (status=active, assigned_to, assigned_at)
  - Dual-write: also update vault frontmatter so Obsidian sees assignment (until Phase 3)
  - Still pull vault for task body reads (lobster needs the file)

**2.5 — Unify broker registration**
- Broker registration becomes fields on the `tasks` table: `broker_repos`, `broker_status`, `token_count`
- `_register_task_with_broker()` → `update_task(id, broker_repos=repos, broker_status="active")`
- Drop `broker_tasks` table (data migrated to tasks table columns)
- Old `/api/tasks/{task_id}/register` route → deprecated alias, looks up by slug or ID
- Token issuance (`POST /api/token`) reads broker fields from tasks table
- `git-credential-lobwife` and init container token fetch unchanged (still POST `/api/token`)

**2.6 — Rewrite task-manager in Python**
- New file: `scripts/server/lobmob-task-manager.py` (replaces `lobmob-task-manager.sh`)
- Uses `lobwife_client` for API queries and status updates
- Same three responsibilities: timeout detection, orphan recovery, investigation task creation
- State queries via API instead of vault file parsing
- Status updates via PATCH instead of vault writes
- Still creates vault files for investigation tasks (lobsigliere reads vault)
- Still queries k8s API for active jobs (kubectl or kubernetes Python client)
- Update `JOB_DEFS` in lobwife daemon to point to new Python script
- Keep old bash script as `lobmob-task-manager.sh.deprecated` for reference

**2.7 — Update lobster status reporting**
- `src/lobster/run_task.py` changes:
  - After task execution: PATCH API (status=completed or failed)
  - Log events via API (started, completed, failed, retry)
  - Still write results to vault file (content) and commit/push
  - `verify.py` — leave as-is (reads vault for content checks). Lobster writes results to vault before verify runs. Status checks can optionally also query API

**2.8 — Vault file format update**
- During Phase 2, vault task files include DB ID in frontmatter:
  ```yaml
  id: T42
  slug: task-2026-02-15-a1b2  # old format, for reference
  status: active                # dual-written from DB during Phase 2
  ```
- New tasks use `T{id}` as filename. Old tasks keep their slug filenames
- Both formats coexist during transition

**2.9 — Testing checkpoint**
- Full task lifecycle in dev: Discord create → auto-assign → lobster execute → complete
- Verify new task gets sequential ID (T1, T2, ...)
- Verify old-format tasks still readable (backwards compat)
- Verify task-manager.py detects timeouts/orphans via API
- Verify broker unification: spawn registers via tasks table, lobster gets token
- Verify vault files reflect current state (dual-write)
- Load test: create 10+ tasks, verify no git conflicts from reduced vault writes

### Phase 3: Vault sync daemon

- **Status**: pending
- **Goal**: Remove dual-writes. DB is sole state authority. Sync daemon periodically snapshots DB state into vault for Obsidian. Vault git noise drops to one commit per sync cycle.

**3.1 — Sync daemon in lobwife**
- New background task in `lobwife-daemon.py` (alongside `persist_loop`)
- Every 5 minutes: query DB for tasks updated since last sync
- For each changed task:
  - If vault file exists: update frontmatter with DB state (preserve body)
  - If no vault file: create minimal file (for tasks created via API without vault write)
- Write overview file: `010-tasks/_overview.md` with Dataview-queryable frontmatter
- Single commit + push per sync cycle
- Track `last_sync_time` to avoid redundant writes

**3.2 — Event-triggered sync**
- In addition to 5-min cycle, trigger immediate sync on significant events:
  - Task created, completed, or failed
- API handlers set a `sync_needed` flag, sync loop checks it each iteration

**3.3 — Remove dual-writes**
- `task_poller.py`: remove vault frontmatter updates after API PATCH
- `run_task.py`: keep vault writes for content (results), remove redundant status updates from frontmatter
- `task-manager.py`: remove all vault writes for status changes
- Vault writes are now limited to: task creation (body), task completion (results), sync snapshots

**3.4 — Testing checkpoint**
- Create task, verify vault file appears within sync interval
- Complete task, verify immediate sync fires
- Verify Dataview queries work against synced frontmatter
- Verify vault commit frequency dropped (count commits over a test period)
- Verify Obsidian sees accurate task state after sync

### Phase 4: Cost and audit data

- **Status**: pending
- **Goal**: Add cost and audit tracking tables, instrument API calls, enable `/costs` commands.
- Add `cost_events` and `audit_findings` tables to schema
- Indexes: `cost_events(task_id)`, `cost_events(created_at)`, `audit_findings(severity)`
- New API endpoints: `POST/GET /api/v1/costs`, `GET /api/v1/costs/summary`, `POST/GET /api/v1/audits`
- Instrument lobboss/lobster Agent SDK calls to push cost events to lobwife after each `query()`
- Audit CronJobs push findings to lobwife
- Enables [cost tracking plan](../draft/cost-tracking.md) and [maintenance automation plan](../draft/system-maintenance-automation.md) DB integration

### Phase 5: Git workflow cleanup

- **Status**: pending
- **Goal**: Harden remaining vault git operations and reduce lobster vault dependency.
- HEAD.lock auto-cleanup in `vault.py` `pull_vault()` (long-standing TODO)
- Retry-with-rebase for remaining vault git operations
- Vault writes reduced to: task creation (body), task completion (results), sync snapshots
- Evaluate whether lobsters need full vault clones. Research lobsters write reports to vault (need clone). SWE lobsters work on lobmob repo — could get task body from API, reducing vault dependency. Decision deferred until Phase 3 proves the sync daemon reliable

### Phase 6: Obsidian views

- **Status**: pending
- **Goal**: Dataview dashboards powered by sync daemon output.
- Task pipeline view (queued → active → completed, with counts)
- Cost trends (daily/weekly spend by model, by task type)
- Audit history (findings by severity, resolution status)
- Powered by DB-synced markdown files with structured frontmatter
- Skip Kanban plugin — Dataview tables are more sustainable and git-friendly

## Cross-cutting Concerns

### Graceful degradation
- If lobwife is unreachable, lobboss task_poller retries with backoff (3 attempts: 10s, 30s, 60s)
- Lobsters retry status update API calls on failure
- During extended outages, tasks queue locally; system catches up when lobwife recovers
- No fallback to vault writes — that would create split-brain state

### Rollback path
- Phase 2 dual-writes preserve vault state, so vault can serve as fallback
- DB can be rebuilt from migration script + vault content at any time
- Old JSON files kept as `.migrated` (not deleted) during Phase 1

### DB backup
- `persist_loop` runs SQLite `.backup` to `STATE_DIR/lobmob.db.bak` hourly
- Vault sync (Phase 3) serves as secondary backup of task state
- PVC snapshot via DO volume snapshots if needed

### verify.py during transition
- Lobsters write results to vault before verify runs, so vault content is current
- `verify.py` continues reading vault files for content checks (Result section, Lobster Notes)
- Status checks in verify could optionally query API, but vault frontmatter is sufficient during dual-write period

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
| 2026-02-16 | Task body NOT stored in DB | DB is state store, vault is content store. Avoids duplicating multi-KB markdown. Lobsters still clone vault for body |
| 2026-02-16 | `/api/v1/` prefix for new endpoints | Avoids collision with existing `/api/tasks/` broker routes. Clean versioning boundary |
| 2026-02-16 | Separate `broker_tasks` table in Phase 1, unify into tasks table in Phase 2 | Tasks don't exist in DB during Phase 1 (still vault-only). Separate table avoids premature coupling |
| 2026-02-16 | Rewrite task-manager.sh in Python for Phase 2 | 270-line bash script with complex logic. Python gets lobwife_client, proper error handling, testability |
| 2026-02-16 | Dual-write to vault during Phase 2 | Keeps Obsidian current before sync daemon (Phase 3). Natural rollback path. Removed in Phase 3 |
| 2026-02-16 | Shared `lobwife_client.py` for API access | Thin async HTTP client in `src/common/`, reused by lobboss, lobsters, and Python cron scripts. Retry with backoff |
| 2026-02-16 | SQLite WAL mode | Concurrent reads with single writer — matches lobwife's serialized-write pattern. Set on DB init |
| 2026-02-16 | Hourly DB backup via SQLite `.backup` | PVC loss = state loss. Backup to same PVC is first line of defense. Vault sync is secondary backup |

## Scratch

- lobwife becomes increasingly central — token broker, cron scheduler, state DB, sync daemon. Monitor for single-point-of-failure risk. Graceful degradation strategy: retry with backoff, no vault fallback (avoids split-brain)
- The vault sync daemon could also sync planning docs and roadmap state, not just task state
- Consider a read-only API on lobboss (proxying to lobwife) for the web dashboard, so the dashboard doesn't need direct lobwife access
- If lobsters only need API access for status reporting (not full vault clones), that significantly reduces git pressure and container startup time. Evaluate in Phase 5 once sync daemon is proven
- Could add WebSocket support to lobwife for real-time updates to web dashboard and Discord (push instead of poll). Stretch goal
- Task ID format `T42` is clean but may collide if we ever need multiple environments sharing a DB. Prefix with env? `T42` for prod, `D42` for dev? Or just separate DBs per environment (already the case with separate lobwife instances)
- `status-reporter.sh` also queries vault files for task counts — should be migrated to API in Phase 2 or rewritten alongside task-manager. Lower priority since it's only 56 lines and runs every 30 min
- `lobwife-daemon.py` is 669 lines. Phase 1 will roughly double this. Consider splitting into modules (`db.py`, `broker.py`, `jobs.py`, `api.py`) if it gets unwieldy
- `lobwife_client.py` could also be used by future audit CronJobs to push findings, and by Discord slash command handlers to query state

## Related

- [Roadmap](../roadmap.md)
- [Scratch Sheet](../planning-scratch-sheet.md)
- [Task Flow Improvements](../draft/task-flow-improvements.md) — Web UI task creation, sequential IDs, faster polling all depend on the DB
- [Discord UX](../draft/discord-ux.md) — Slash commands need fast state queries
- [Cost Tracking](../draft/cost-tracking.md) — Cost events table in the DB, `/costs` commands query it
- [System Maintenance Automation](../draft/system-maintenance-automation.md) — Audit findings stored in DB
