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
│  CronJobs: task-manager, status-reporter, review-prs,        │
│            gh-token-refresh, flush-logs                       │
│                                                               │
│  ┌────────────────────────────────────────────────────┐      │
│  │  k8s Secrets (lobmob-secrets) + ConfigMap          │      │
│  └────────────────────────────────────────────────────┘      │
└──────────────────────┬────────────────────────────────────────┘
                       │     ┌──────────┐
                       └────►│  GitHub  │◄── lobmob-vault (tasks, logs)
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
- Spawns lobsters as k8s Jobs via the Kubernetes API
- Reviews and merges lobster PRs
- Pushes directly to vault `main` for task creation and fleet updates

### Lobsters (k8s Jobs)
- **Ephemeral** — created on demand, auto-cleaned after completion
- One k8s Job per task, with TTL-based cleanup (1h after completion)
- Agent SDK `query()` for one-shot task execution
- Init container clones the vault; main container runs the agent
- Native sidecar container serves web dashboard on port 8080
- Types: research (Sonnet), swe (Opus), qa (Sonnet), image-gen (Sonnet+Gemini)
- SWE lobsters branch from `develop`, submit PRs to `develop`
- Safety hooks enforce tool restrictions per type (e.g., QA can't push)

### Lobsigliere (Deployment)
- **Persistent** operations pod with SSH access, kubectl, terraform, gh CLI, Claude Code
- Background daemon polls vault every 30s for `type: system` tasks
- Scans `010-tasks/active/*.md` for files with `type: system` + `status: queued`
- Executes system tasks via Agent SDK, creates branches and PRs to develop
- Persistent 10Gi PVC at `/home/engineer` for workspace and vault clone
- Claude Code CLI configured with CLAUDE.md and dark mode

### CronJobs
| CronJob | Schedule | Purpose |
|---|---|---|
| `task-manager` | Every 5m | Assign queued tasks to idle lobsters, detect timeouts |
| `status-reporter` | Every 15m | Post fleet status to #swarm-logs |
| `review-prs` | Every 10m | Trigger deterministic PR checks |
| `gh-token-refresh` | Every 45m | Rotate GitHub App installation token |
| `flush-logs` | Every 15m | Flush event logs to vault |

### Discord Server
- **#task-queue** — task lifecycle; one parent message per task with a thread for all updates
- **#swarm-control** — user commands to lobboss for fleet management
- **#swarm-logs** — fleet events: spawns, completions, status reports

### GitHub Vault Repo
- Obsidian vault with [[reference/vault-structure|structured directories]]
- Lobboss writes to `main` (task files, fleet registry, merged PRs)
- Lobsters write to task branches, submit PRs
- Lobsigliere writes to `main` for task status updates
- Browsable locally in Obsidian by humans

## Container Images

All images built for `linux/amd64` (DOKS node architecture), pushed to GHCR.

| Image | Base | Purpose |
|---|---|---|
| `lobmob-base` | `python:3.12-slim` | Python + Node.js 22 + Claude Code CLI + pip deps |
| `lobmob-lobboss` | `lobmob-base` | discord.py bot, MCP tools, skills, web dashboard |
| `lobmob-lobster` | `lobmob-base` | Agent SDK runner, skills, web sidecar |
| `lobmob-lobsigliere` | `lobmob-base` | SSH server, terraform, kubectl, gh CLI, daemon |

## Networking

All inter-component communication uses k8s pod networking within the `lobmob` namespace:
- **ClusterIP Services** for lobboss (port 8080) and lobsigliere (port 22)
- **Port-forwarding** from local machine for dashboard access and SSH
- No ingress, no public endpoints — access via `kubectl port-forward` or `lobmob connect`

## Security

| Layer | Mechanism |
|---|---|
| Secrets | k8s Secrets (`lobmob-secrets`), injected via `envFrom` |
| Auth tokens | GitHub App (hourly rotation via CronJob) |
| Network | No public endpoints; k8s RBAC per ServiceAccount |
| RBAC | Separate SAs: lobboss (job create), lobster (job read), lobsigliere (full namespace) |
| Agent safety | Tool permission hooks per lobster type (blocked commands, domain allowlists) |
| Images | Private GHCR registry, `imagePullSecrets` on all pod specs |
| Vault | No secrets in repo; Git LFS for large assets |
