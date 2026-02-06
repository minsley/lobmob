# Architecture Overview

## System Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                      DISCORD SERVER                          │
│  #task-queue   #swarm-control   #results   #swarm-logs       │
└──────┬───────────────────────────────────────┬───────────────┘
       │                                       │
       ▼                                       ▼
┌────────────────────┐              ┌────────────────────────┐
│  MANAGER DROPLET   │    SSH/WG    │  WORKER DROPLET (N)    │
│                    │◄────────────►│                        │
│  OpenClaw Gateway  │              │  OpenClaw Gateway      │
│  Manager Agent     │              │  Worker Agent          │
│  WireGuard Hub     │              │  WireGuard Peer        │
│  PR Reviewer       │              │  Task Executor         │
│                    │              │                        │
│  /opt/vault (main) │              │  /opt/vault (branch)   │
└───────────────┬────┘              └──────────────┬─────────┘
                │     ┌──────────┐                 │
                └────►│  GitHub  │◄────────────────┘
                      │  Repo    │       (PRs)
                      │          │
                      │ lobmob-  │  ◄── Browsable locally
                      │ vault/   │      in Obsidian
                      └──────────┘
```

## Components

### Manager Droplet
- **Persistent** — runs 24/7
- s-2vcpu-4gb ($24/mo)
- Runs OpenClaw with the [[../reference/manager-persona|manager persona]]
- WireGuard hub at 10.0.0.1
- Holds all secrets (DO token, Discord bot token, API keys)
- Spawns/destroys workers via `doctl`
- Reviews and merges worker PRs
- Pushes directly to `main` for task creation and fleet registry updates

### Worker Droplets
- **Ephemeral** — created on demand, self-destructs when idle
- s-1vcpu-2gb ($12/mo, per-second billing)
- Bootstrapped via cloud-init with OpenClaw, WireGuard, git, gh CLI
- Connects to manager via WireGuard mesh
- Listens on Discord for task assignments
- Delivers results as [[architecture/git-workflow|pull requests]]

### Discord Server
- **#task-queue** — humans/external systems post work requests
- **#swarm-control** — manager assigns tasks, requests PR revisions
- **#results** — workers announce completed PRs with summaries and links
- **#swarm-logs** — manager posts merge events, fleet status, errors

### GitHub Vault Repo
- Obsidian vault with [[reference/vault-structure|structured directories]]
- Manager writes to `main` (task files, fleet registry, merged PRs)
- Workers write to task branches, submit PRs
- Browsable locally in Obsidian by humans

### WireGuard Mesh
- Hub-and-spoke: manager is hub, workers are spokes
- 10.0.0.0/24 subnet
- All SSH traffic between nodes flows over encrypted WireGuard tunnels
- Workers have no public SSH exposure — only WireGuard UDP 51820

## Security Layers
| Layer | Mechanism |
|---|---|
| Secret delivery | SSH-push only — zero secrets in cloud-init user_data or Terraform state |
| Network | DO Cloud Firewall (SSH only from manager, WG UDP 51820) |
| Transport | WireGuard encryption on all inter-node traffic |
| SSH | Ed25519 keys, password auth disabled |
| Secrets at rest | `/etc/lobmob/secrets.env` mode 0600; OpenClaw config mode 0600 |
| Workers | Secrets pushed via SSH over WireGuard after boot; ephemeral; auto-destroyed after 2 hours |
| Vault | No secrets in repo; Git LFS for large assets |

## Secret Flow
```
Local machine                    Manager                      Worker
secrets.env ──── SSH ────► /etc/lobmob/secrets.env
                           /root/.ssh/vault_key
                           /etc/wireguard/wg0.conf
                                    │
                                    │ SSH over WireGuard
                                    ▼
                           /etc/lobmob/secrets.env ────► Worker secrets
                           (GH_TOKEN, ANTHROPIC,         (subset only —
                            DISCORD only)                 no DO_TOKEN)
```
Secrets never appear in:
- Terraform state files
- Cloud-init user_data (readable via DO metadata endpoint at 169.254.169.254)
- Git history
- Discord messages
