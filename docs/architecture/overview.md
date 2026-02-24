# Architecture Overview

## System Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                      DISCORD SERVER                          │
│  #task-queue        #swarm-control        #swarm-logs        │
│  (threads per task)                                          │
└──────┬───────────────────────────────────────┬───────────────┘
       │                                       │
       ▼                                       ▼
┌─────────────────── DOKS CLUSTER (lobmob namespace) ──────────┐
│                                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │  LOBBOSS     │  │  LOBSTER (N) │  │  LOBSIGLIERE     │   │
│  │  Deployment  │  │  k8s Jobs    │  │  Deployment      │   │
│  │              │  │              │  │                   │   │
│  │  discord.py  │  │  Agent SDK   │  │  SSH server       │   │
│  │  Agent SDK   │  │  query()     │  │  task daemon      │   │
│  │  MCP tools   │  │  (ephemeral) │  │  kubectl/tf/gh   │   │
│  │  web dash    │  │  web sidecar │  │  Claude Code CLI  │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────┘   │
│         │                  │                                  │
│         │    HTTP API      │                                  │
│         ▼                  ▼                                  │
│  ┌─────────────────────────────────────────────────────┐     │
│  │  LOBWIFE (Deployment)                                │     │
│  │                                                      │     │
│  │  SQLite DB ── task state, events, jobs, broker       │     │
│  │  REST API ── /api/v1/ task CRUD + events             │     │
│  │  Token broker ── GitHub App token generation         │     │
│  │  Sync daemon ── DB → vault (5min + event-triggered)  │     │
│  │  APScheduler ── cron jobs (task-manager, review-prs) │     │
│  └──────────────────────┬──────────────────────────────┘     │
│                          │                                    │
│  ┌───────────────────────┴────────────────────────────┐      │
│  │  k8s Secrets (lobmob-secrets) + ConfigMaps          │      │
│  └────────────────────────────────────────────────────┘      │
└──────────────────────┬────────────────────────────────────────┘
                       │     ┌──────────┐
                       └────►│  GitHub  │◄── lobmob-vault (synced from DB)
                             │          │◄── lobmob (code PRs)
                             └──────────┘
```

## Components

### Lobboss (Deployment)
- **Persistent** — runs 24/7 as a k8s Deployment (1 replica)
- Python: discord.py bot + Claude Agent SDK for multi-turn conversations
- Custom MCP tools: `discord_post`, `spawn_lobster`, `lobster_status`
- Web dashboard on port 8080 (Node.js subprocess)
- Holds session state for Discord conversations
- Task poller queries lobwife API for queued tasks, spawns lobsters as k8s Jobs
- Reports task state changes (assignment, completion) back to lobwife API
- Reviews and merges lobster PRs

### Lobsters (k8s Jobs)
- **Ephemeral** — created on demand, auto-cleaned after completion
- One k8s Job per task, with TTL-based cleanup (1h after completion)
- Agent SDK `query()` for one-shot task execution
- Init container clones the vault; main container runs the agent
- Native sidecar container serves web dashboard on port 8080
- Types: research (Sonnet), swe (Opus), qa (Sonnet), image-gen (Sonnet+Gemini)
- SWE lobsters branch from `develop`, submit PRs to `develop`
- Safety hooks enforce tool restrictions per type (e.g., QA can't push)

### Lobwife (Deployment)
- **Persistent** — central state store and service hub, runs 24/7 as a k8s Deployment (1 replica)
- **SQLite database** on PVC — source of truth for task state, events, job tracking, broker registrations
- **REST API** (`/api/v1/`) — task CRUD, events, service tokens. All state writes go through this API
- **Token broker** — generates ephemeral GitHub App installation tokens on demand. All containers use the `gh-lobwife` wrapper to fetch tokens transparently
- **Vault sync daemon** — mirrors DB task state to the Obsidian vault every 5 minutes + on significant state changes (assignment, completion). Single commit per sync cycle
- **APScheduler** — runs cron jobs as subprocess tasks (see below)
- **Web dashboard** on port 8080 (Node.js subprocess)
- PVC stores the SQLite DB (`lobmob.db`) and a vault clone for sync pushes

### Lobsigliere (Deployment)
- **Persistent** operations pod with SSH access, kubectl, terraform, gh CLI, Claude Code
- Background daemon polls lobwife API for `type: system` tasks
- Executes system tasks via Agent SDK, creates branches and PRs to develop
- Persistent 10Gi PVC at `/home/engineer` for workspace and vault clone
- Claude Code CLI configured with CLAUDE.md and dark mode

### Scheduled Jobs (APScheduler on lobwife)
| Job | Schedule | Purpose |
|---|---|---|
| `task-manager` | Every 5m | Detect timed-out jobs, create fallback PRs from orphaned branches, spawn investigation tasks |
| `review-prs` | Every 2m | Auto-merge approved PRs on the vault repo |
| `status-reporter` | Every 30m | Post fleet status to #swarm-logs |
| `flush-logs` | Every 30m | Flush event logs to vault |

### Discord Server
- **#task-queue** — task lifecycle; one parent message per task with a thread for all updates
- **#swarm-control** — user commands to lobboss for fleet management
- **#swarm-logs** — fleet events: spawns, completions, status reports

### GitHub Vault Repo
- Obsidian vault with [[reference/vault-structure|structured directories]]
- **Sync daemon** writes to `main` — periodic snapshots of DB task state into vault markdown files
- **Lobsters** write to task branches (results, output files), submit PRs to `main`
- **Humans** browse in Obsidian — task state is kept current by the sync daemon
- DB is the source of truth for task state; vault is the human-readable mirror

## Container Images

All images built for `linux/amd64` (DOKS node architecture), pushed to GHCR.

| Image | Base | Purpose |
|---|---|---|
| `lobmob-base` | `python:3.12-slim` | Python + Node.js 22 + Claude Code CLI + pip deps |
| `lobmob-lobboss` | `lobmob-base` | discord.py bot, MCP tools, skills, web dashboard |
| `lobmob-lobster` | `lobmob-base` | Agent SDK runner, skills, web sidecar |
| `lobmob-lobwife` | `lobmob-base` | State store, API, token broker, sync daemon, scheduler |
| `lobmob-lobsigliere` | `lobmob-base` | SSH server, terraform, kubectl, gh CLI, daemon |

## Networking

All inter-component communication uses k8s pod networking within the `lobmob` namespace:
- **ClusterIP Services** for lobwife (port 8081 API), lobboss (port 8080 dashboard), and lobsigliere (port 22 SSH)
- All task state operations route through the lobwife API (cluster-internal only)
- **Port-forwarding** from local machine for dashboard access and SSH
- No ingress, no public endpoints — access via `kubectl port-forward` or `lobmob connect`

## Security

| Layer | Mechanism |
|---|---|
| Secrets | k8s Secrets (`lobmob-secrets`), injected via `envFrom` |
| Auth tokens | GitHub App (on-demand tokens via lobwife broker) |
| Network | No public endpoints; k8s RBAC per ServiceAccount |
| RBAC | Separate SAs: lobboss (job create), lobster (job read), lobsigliere (full namespace) |
| Agent safety | Tool permission hooks per lobster type (blocked commands, domain allowlists) |
| Images | Private GHCR registry, `imagePullSecrets` on all pod specs |
| Vault | No secrets in repo; Git LFS for large assets |
