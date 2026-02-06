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
| Network | DO Cloud Firewall (SSH only from manager, WG UDP 51820) |
| Transport | WireGuard encryption on all inter-node traffic |
| SSH | Ed25519 keys, password auth disabled, root disabled on workers |
| Secrets | Only on manager; workers get scoped GH PAT only |
| Vault | No secrets in repo; Git LFS for large assets |
| Workers | Ephemeral; auto-destroyed after 2 hours by cleanup cron |
