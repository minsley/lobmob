# lobwife — lobmob Persistent Cron Service

## What This Is

You're inside **lobwife**, the persistent cron scheduler for lobmob. This pod replaces all k8s CronJobs with a single Python daemon that runs bash scripts on schedule and exposes an HTTP API for status, manual triggers, and schedule changes.

## Environment

- **Home**: `/home/lobwife` (persistent 1Gi PVC)
- **lobmob repo**: `~/lobmob` (on develop branch)
- **Vault**: `~/vault` (task files, used by cron scripts)
- **Daemon**: `lobwife-daemon.py` running in background (APScheduler + aiohttp)
- **Web UI**: `lobwife-web.js` on port 8080 (proxies to daemon API on port 8081)
- **gh CLI**: Authenticated with GitHub App token

## Scheduled Jobs

| Job | Schedule | Script |
|-----|----------|--------|
| task-manager | Every 5 min | lobmob-task-manager.sh |
| review-prs | Every 2 min | lobmob-review-prs.sh |
| status-reporter | Every 30 min | lobmob-status-reporter.sh |
| flush-logs | Every 30 min | lobmob-flush-logs.sh |

## Token Broker API (port 8081)

- `POST /api/broker/register` — Register a task for token access
- `POST /api/token` — Get a GitHub App installation token for a registered task
- `POST /api/broker/deregister` — Deregister a task (revokes access)
- `GET /api/broker/status` — Broker status (registered tasks, token cache)

## HTTP API (port 8081)

- `GET /api/status` — All jobs status
- `GET /api/jobs` — List configured jobs
- `GET /api/jobs/{name}` — Job details + recent output
- `POST /api/jobs/{name}/trigger` — Manual trigger
- `POST /api/jobs/{name}/enable` — Enable job
- `POST /api/jobs/{name}/disable` — Disable job
- `GET /health` — Health check

## Troubleshooting

- Check daemon: `ps aux | grep lobwife-daemon`
- Daemon logs: `tail -f ~/state/daemon.log`
- Job state: `cat ~/state/jobs.json`
- Restart daemon: `sudo kill $(pgrep -f lobwife-daemon) && python3 /opt/lobmob/scripts/server/lobwife-daemon.py &`
