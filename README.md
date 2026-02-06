# lobmob

OpenClaw agent swarm management system for DigitalOcean. A persistent manager agent (lobboss) coordinates ephemeral worker agents (lobsters) to execute tasks. Communication flows through Discord and SSH over WireGuard. A shared Obsidian vault on GitHub provides persistent storage.

```
┌──────────────────────────────────────────────────────────────┐
│                      DISCORD SERVER                          │
│  #task-queue   #swarm-control   #results   #swarm-logs       │
└──────┬───────────────────────────────────────┬───────────────┘
       │                                       │
       ▼                                       ▼
┌────────────────────┐              ┌────────────────────────┐
│  LOBBOSS DROPLET   │    SSH/WG    │  LOBSTER DROPLET (N)   │
│                    │◄────────────►│                        │
│  OpenClaw Gateway  │              │  OpenClaw Gateway      │
│  Lobboss Agent     │              │  Lobster Agent         │
│  WireGuard Hub     │              │  WireGuard Peer        │
│  PR Reviewer       │              │  Task Executor         │
│                    │              │                        │
│  /opt/vault (main) │              │  /opt/vault (branch)   │
└───────────────┬────┘              └──────────────┬─────────┘
                │     ┌──────────┐                 │
                └────►│  GitHub  │◄────────────────┘
                      │  Vault   │       (PRs)
                      │  Repo    │
                      └──────────┘
```

## How It Works

1. Tasks are submitted via Discord or pushed directly to the vault repo
2. Lobboss assigns tasks to lobsters and spawns new droplets as needed
3. Lobsters execute tasks, write results to the vault, and open pull requests
4. Lobboss reviews and merges PRs, then posts summaries to Discord

All inter-node traffic flows over an encrypted WireGuard mesh. Secrets are never stored in Terraform state or cloud-init user-data — they're pushed via SSH after boot.

## Project Structure

| Directory | Purpose |
|---|---|
| `infra/` | Terraform — VPC, firewall, lobboss droplet |
| `templates/` | Cloud-init YAML for droplet bootstrapping |
| `scripts/lobmob` | CLI for deployment and fleet management |
| `skills/` | OpenClaw skill definitions (manager + worker) |
| `openclaw/` | Agent persona definitions (AGENTS.md) |
| `vault-seed/` | Initial Obsidian vault structure for the shared repo |
| `tests/` | Smoke tests and end-to-end lifecycle tests |
| `docs/` | Project documentation (Obsidian vault) |

## Quick Start

```bash
# 1. Setup
chmod +x scripts/lobmob
./scripts/lobmob init          # generates WG keys, creates config files
# Fill in secrets.env and infra/terraform.tfvars

# 2. Create the vault repo
./scripts/lobmob vault-init

# 3. Deploy lobboss
./scripts/lobmob deploy

# 4. Verify
tests/smoke-lobboss

# 5. Spawn a lobster
./scripts/lobmob spawn

# 6. Submit a task
tests/push-task --title "Research topic X" --objective "..."
```

See `docs/operations/setup-checklist.md` for full prerequisites and `docs/operations/deployment.md` for the deployment guide.

## Prerequisites

- Terraform >= 1.5
- GitHub CLI (`gh`)
- WireGuard tools (`wg`)
- DigitalOcean account + API token
- GitHub account + fine-grained PAT
- Discord bot application + token
- Anthropic API key

## Tests

| Script | What it tests |
|---|---|
| `tests/smoke-lobboss` | Lobboss health (14 checks) |
| `tests/smoke-lobster <ip>` | Lobster health (12 checks) |
| `tests/push-task` | Push a task to the vault |
| `tests/await-task-pickup` | Verify lobboss assigns queued tasks |
| `tests/await-task-completion` | Full lifecycle: execute, PR, review, merge |

## Documentation

Full docs are in `docs/` (openable as an Obsidian vault):

- [Architecture overview](docs/architecture/overview.md)
- [Setup checklist](docs/operations/setup-checklist.md)
- [Deployment guide](docs/operations/deployment.md)
- [Daily operations](docs/operations/daily-ops.md)
- [Testing](docs/operations/testing.md)
- [OpenClaw setup](docs/operations/openclaw-setup.md)
- [CLI reference](docs/reference/cli.md)
