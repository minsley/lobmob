# lobwife — lobmob Persistent Cron Service

## What This Is

You're inside **lobwife**, the persistent cron scheduler for lobmob. This pod replaces all k8s CronJobs with a single Python daemon that runs bash scripts on schedule and exposes an HTTP API for status, manual triggers, and schedule changes. State is persisted to SQLite (WAL mode) on the PVC.

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
| `lobwife_db.py` | DB init, schema, migration, connection |
| `lobwife_jobs.py` | JobRunner (cron scheduling, DB-backed state) |
| `lobwife_broker.py` | TokenBroker (GitHub credential broker, DB-backed) |
| `lobwife_api.py` | HTTP routes (jobs, broker, Task CRUD) |
| `lobwife-schema.sql` | SQLite DDL (6 tables) |

## Scheduled Jobs

| Job | Schedule | Script |
|-----|----------|--------|
| task-manager | Every 5 min | lobmob-task-manager.sh |
| review-prs | Every 2 min | lobmob-review-prs.sh |
| status-reporter | Every 30 min | lobmob-status-reporter.sh |
| flush-logs | Every 30 min | lobmob-flush-logs.sh |

## Token Broker API (port 8081)

- `POST /api/tasks/{task_id}/register` — Register a task for token access
- `POST /api/token` — Get a GitHub App installation token for a registered task
- `DELETE /api/tasks/{task_id}` — Deregister a task (revokes access)
- `GET /api/tasks` — List broker task registrations
- `GET /api/token/audit` — Token audit log

## Task CRUD API (port 8081)

- `POST /api/v1/tasks` — Create task (returns `{id, task_id: "T{id}"}`)
- `GET /api/v1/tasks` — List tasks (`?status=`, `?type=`, `?limit=`)
- `GET /api/v1/tasks/{id}` — Get task detail
- `PATCH /api/v1/tasks/{id}` — Update fields (status, assigned_to, etc.)
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

## Troubleshooting

- Check daemon: `ps aux | grep lobwife-daemon`
- Daemon logs: `tail -f ~/state/daemon.log`
- DB state: `sqlite3 ~/state/lobmob.db ".tables"` / `.schema` / `SELECT * FROM tasks;`
- Restart daemon: `sudo kill $(pgrep -f lobwife-daemon) && python3 /opt/lobmob/scripts/server/lobwife-daemon.py &`
