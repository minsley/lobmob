# lobmob

Agent swarm management on DigitalOcean Kubernetes (DOKS) with local k3d development.

## Quick Links
- [Architecture overview](architecture/overview.md) — System architecture and component diagram
- [Git workflow](architecture/git-workflow.md) — PR-based task delivery workflow
- [Setup checklist](operations/setup-checklist.md) — Pre-deployment setup (GitHub, DO, Discord)
- [Deployment guide](operations/deployment.md) — Cloud and local deployment
- [Daily operations](operations/daily-ops.md) — Day-to-day fleet operations
- [Testing](operations/testing.md) — Test scripts, unit tests, and local testing
- [CLI reference](reference/cli.md) — lobmob CLI commands
- [Vault structure](reference/vault-structure.md) — Obsidian vault layout and conventions
- [Token management](operations/token-management.md) — GitHub App tokens, broker
- [Web UI](operations/web-ui.md) — Web dashboards and lobster IPC
- [Discord protocol](reference/discord-protocol.md) — Message formats and channel usage

## Components
| Component | Location | Purpose |
|---|---|---|
| lobboss | `src/lobboss/` | Manager agent — Discord bot + task poller + MCP tools |
| lobster | `src/lobster/` | Worker agent — multi-turn episode loop + IPC server |
| lobwife | `scripts/server/` | State store — SQLite + REST API + token broker + sync daemon |
| lobsigliere | `containers/lobsigliere/` | Ops console — SSH + system task daemon |
| Shared code | `src/common/` | Vault ops, models, lobwife API client |
| Kubernetes | `k8s/` | Base manifests + overlays (prod, dev, local) |
| Terraform | `infra/` | DOKS cluster provisioning |
| Skills | `skills/` | Agent SDK skill definitions |
| CLI | `scripts/lobmob` | Deployment and fleet management |
| Docs (this vault) | `docs/` | Project documentation |
