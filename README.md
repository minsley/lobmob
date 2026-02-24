<!-- lobmob — Agent swarm on DigitalOcean Kubernetes -->
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

# lobmob

Agent swarm management on DigitalOcean Kubernetes (DOKS). A persistent manager agent (lobboss) coordinates ephemeral worker agents (lobsters) to execute tasks via Claude Agent SDK. A central state store (lobwife) tracks all task state in SQLite, with a sync daemon that mirrors state to an Obsidian vault on GitHub for human browsing.

```
┌──────────────────────────────────────────────────────────────┐
│                      DISCORD SERVER                          │
│  #task-queue        #swarm-control        #swarm-logs        │
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
│  │           k8s Secrets + ConfigMaps                  │      │
│  └────────────────────────────────────────────────────┘      │
└──────────────────────┬────────────────────────────────────────┘
                       │     ┌──────────┐
                       └────►│  GitHub  │◄── Vault repo (synced from DB)
                             │          │◄── lobmob repo (code PRs)
                             └──────────┘
```

## How It Works

1. Tasks are created via Discord or the lobwife API, stored in SQLite as the source of truth
2. Lobboss polls the API for queued tasks and spawns lobsters as ephemeral k8s Jobs
3. Lobsters execute tasks via Agent SDK, report status back to the API, and open PRs
4. Lobboss reviews PRs semantically, merges or requests changes
5. The sync daemon on lobwife mirrors task state to the Obsidian vault for human browsing
6. System tasks (`type: system`) are auto-processed by lobsigliere's background daemon

All inter-service traffic stays within the k8s cluster. Secrets are managed via k8s Secrets. GitHub auth uses ephemeral App tokens via the lobwife broker.

## Project Structure

| Directory | Purpose |
|---|---|
| `src/lobboss/` | Manager agent — discord.py + Agent SDK |
| `src/lobster/` | Worker agent — ephemeral Agent SDK task runner |
| `src/common/` | Shared modules (vault operations, logging, health) |
| `containers/` | Dockerfiles (base, lobboss, lobster, lobwife, lobsigliere) |
| `k8s/base/` | Kubernetes manifests (Kustomize base) |
| `k8s/overlays/` | Environment-specific overlays (dev, prod) |
| `scripts/lobmob` | CLI dispatcher for deployment and fleet management |
| `scripts/commands/` | CLI command modules (deploy, status, connect, etc.) |
| `scripts/server/` | Server-side scripts (cron jobs, web dashboard, daemon) |
| `skills/` | Agent SDK skill definitions (lobboss + lobster) |
| `infra/` | Terraform (DOKS cluster provisioning) |
| `vault-seed/` | Initial Obsidian vault structure |
| `tests/` | Smoke tests and lifecycle tests |
| `docs/` | Project documentation |

## Quick Start

```bash
git clone https://github.com/minsley/lobmob.git
cd lobmob

# Set up secrets
cp secrets.env.example secrets.env   # fill in all tokens
cp infra/prod.tfvars.example infra/prod.tfvars

# Deploy
lobmob deploy                        # terraform + kubectl apply
lobmob status                        # verify fleet
```

See `docs/operations/setup-checklist.md` for full prerequisites and `docs/operations/deployment.md` for the deployment guide.

## Prerequisites

- Terraform >= 1.5
- kubectl
- GitHub CLI (`gh`)
- Docker with buildx (for image builds)
- DigitalOcean account + API token
- GitHub account + App installation (for token broker — see [Token Management](docs/operations/token-management.md))
- Discord bot application + token
- Anthropic API key

## Lobster Types

| Type | Use For | Model |
|---|---|---|
| `research` | Research, writing, documentation, analysis | Sonnet |
| `swe` | Code changes, features, bug fixes | Opus |
| `qa` | Code review, testing, verification | Sonnet |
| `image-gen` | Image generation tasks | Sonnet + Gemini |
| `system` | Infrastructure, CI/CD, tooling (auto-processed by lobsigliere) | Opus |

## Environments

| | Prod | Dev |
|---|---|---|
| DOKS cluster | `lobmob-k8s` | `lobmob-dev-k8s` |
| kubectl context | `do-nyc3-lobmob-k8s` | `do-nyc3-lobmob-dev-k8s` |
| Vault repo | `lobmob-vault` | `lobmob-vault-dev` |
| CLI usage | `lobmob <cmd>` | `lobmob --env dev <cmd>` |

## Documentation

Full docs are in `docs/` (openable as an Obsidian vault):

- [Architecture overview](docs/architecture/overview.md)
- [Setup checklist](docs/operations/setup-checklist.md)
- [Deployment guide](docs/operations/deployment.md)
- [Daily operations](docs/operations/daily-ops.md)
- [Testing](docs/operations/testing.md)
- [CLI reference](docs/reference/cli.md)
- [Vault structure](docs/reference/vault-structure.md)
- [Token management](docs/operations/token-management.md)

## Contributing

Contributions are welcome! Open an issue or submit a pull request. Please keep PRs focused — one feature or fix per PR.

## License

[MIT](LICENSE)
