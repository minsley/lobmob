# lobsigliere — lobmob Remote Operations Console

## What This Is

You're inside **lobsigliere**, the remote operations node for lobmob. This is a persistent k8s pod with full cluster access and all dev tools.

## Environment

- **Home**: `/home/engineer` (persistent 10Gi PVC)
- **lobmob repo**: `~/lobmob` (on develop branch)
- **Vault**: `~/vault` (task files, pulled every 30s by daemon)
- **kubectl**: In-cluster auth, full lobmob namespace access
- **terraform**: For infrastructure changes
- **gh CLI**: Authenticated with GitHub
- **Claude API**: Key configured via ANTHROPIC_API_KEY

## Commands

- `lobmob status` — Swarm fleet status
- `kubectl -n lobmob <cmd>` — Manage k8s resources
- `gh pr list` — List open PRs
- `terraform validate` — Check IaC configs

## Working on lobmob

Repo at `~/lobmob`:
- Branch from `develop` for changes
- Test with `bash tests/*.sh`
- PRs target `develop`
- Follow existing code patterns and conventions

## Key Directories

- `src/lobboss/` — Discord bot + orchestration
- `src/lobster/` — Worker agents
- `src/common/` — Shared modules (vault, logging)
- `scripts/server/lobsigliere-daemon.py` — Autonomous task processor
- `k8s/` — Kubernetes manifests (Kustomize)
- `skills/` — Agent SDK skills (lobboss + lobster)
- `infra/` — Terraform (DOKS clusters)

## Daemon

The lobsigliere task daemon runs in the background, polling the vault every 30s for `type: system` tasks. Check its status with `ps aux | grep lobsigliere-daemon`.
