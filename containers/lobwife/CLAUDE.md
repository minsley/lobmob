# lobwife — lobmob Persistent Cron Service

## What This Is

You're inside **lobwife**, the persistent cron scheduler for lobmob. This pod replaces all k8s CronJobs with a single Python daemon that runs scripts on schedule and exposes an HTTP API for status, manual triggers, and schedule changes. State is persisted to SQLite (WAL mode) on the PVC.

## Environment

- **Home**: `/home/lobwife` (persistent 1Gi PVC)
- **lobmob repo**: `~/lobmob` (on develop branch)
- **Vault**: `~/vault` (task files, used by cron scripts)
- **Database**: `~/state/lobmob.db` (SQLite, WAL mode — task state, job state, broker, audit)
- **Daemon**: `lobwife-daemon.py` running in background (APScheduler + aiohttp + aiosqlite)
- **Web UI**: `lobwife-web.js` on port 8080 (proxies to daemon API on port 8081)
- **gh CLI**: Authenticated with GitHub App token

## Daemon Modules

| Module | Purpose |
|--------|---------|
| `lobwife-daemon.py` | Main entry point, init + orchestration |
| `lobwife_db.py` | DB init, schema (v2), migration, connection |
| `lobwife_jobs.py` | JobRunner (cron scheduling, DB-backed state, .py + .sh support) |
| `lobwife_broker.py` | TokenBroker (unified: checks tasks table first, falls back to broker_tasks) |
| `lobwife_api.py` | HTTP routes (jobs, broker compat shims, Task CRUD, broker registration) |
| `lobwife_sync.py` | VaultSyncDaemon (periodic DB→vault sync, event-triggered) |
| `lobwife-schema.sql` | SQLite DDL (6 tables, schema v2 with broker columns on tasks) |

## Scheduled Jobs

| Job | Schedule | Script |
|-----|----------|--------|
| task-manager | Every 5 min | lobmob-task-manager.py |
| review-prs | Every 2 min | lobmob-review-prs.sh |
| status-reporter | Every 30 min | lobmob-status-reporter.py |
| flush-logs | Every 30 min | lobmob-flush-logs.sh |

## Token Broker

Broker registration is now unified into the `tasks` table (Phase 2). The old broker routes are compat shims that look up tasks by slug, name, or T-format ID, falling back to the `broker_tasks` table for legacy entries.

### Broker API (port 8081)

- `POST /api/v1/tasks/{id}/register` — Register broker on tasks table (new, preferred)
- `POST /api/tasks/{task_id}/register` — Compat shim (looks up task, sets broker fields)
- `POST /api/token` — Get token (checks tasks table first, falls back to broker_tasks)
- `DELETE /api/tasks/{task_id}` — Deregister (still uses broker_tasks)
- `GET /api/tasks` — List broker_tasks entries (legacy)
- `GET /api/token/audit` — Token audit log

## Task CRUD API (port 8081)

- `POST /api/v1/tasks` — Create task (returns `{id, task_id: "T{id}"}`)
- `GET /api/v1/tasks` — List tasks (`?status=`, `?type=`, `?limit=`)
- `GET /api/v1/tasks/{id}` — Get task detail (includes broker fields)
- `PATCH /api/v1/tasks/{id}` — Update fields (status, assigned_to, broker_repos, etc.)
- `DELETE /api/v1/tasks/{id}` — Cancel task (soft delete)
- `GET /api/v1/tasks/{id}/events` — Event history
- `POST /api/v1/tasks/{id}/events` — Log event

## Job Management API (port 8081)

- `GET /api/status` — All jobs status + broker summary
- `GET /api/jobs` — List configured jobs
- `GET /api/jobs/{name}` — Job details + recent output
- `POST /api/jobs/{name}/trigger` — Manual trigger
- `POST /api/jobs/{name}/enable` — Enable job
- `POST /api/jobs/{name}/disable` — Disable job
- `GET /health` — Health check (includes DB status)

## Schema (v2)

The `tasks` table now includes broker fields: `broker_repos`, `broker_status`, `token_count`, `broker_registered_at`. This allows broker registration to work directly through the tasks table instead of requiring a separate `broker_tasks` entry.

## Vault Sync Daemon

The sync daemon runs as a background asyncio task inside the lobwife daemon. It replaces the Phase 2 dual-writes: DB is the sole state authority, and the sync daemon periodically snapshots DB task state into vault frontmatter for Obsidian browsing.

- **Interval**: 5 minutes (configurable via `VAULT_SYNC_INTERVAL` env var)
- **Event-triggered**: Immediate sync on task creation, completion, failure, cancellation
- **Overview file**: `010-tasks/_overview.md` with status counts and recent tasks table
- **API**: `GET /api/v1/sync` (status), `POST /api/v1/sync/trigger` (manual trigger)

## Troubleshooting

- Check daemon: `ps aux | grep lobwife-daemon`
- Daemon logs: `tail -f ~/state/daemon.log`
- DB state: `sqlite3 ~/state/lobmob.db ".tables"` / `.schema` / `SELECT * FROM tasks;`
- Check schema version: `sqlite3 ~/state/lobmob.db "SELECT * FROM schema_version;"`
- Restart daemon: `sudo kill $(pgrep -f lobwife-daemon) && python3 /opt/lobmob/scripts/server/lobwife-daemon.py &`
