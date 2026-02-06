# lobmob

OpenClaw agent swarm management system for DigitalOcean.

## Quick Links
- [[architecture/overview]] — System architecture and component diagram
- [[architecture/git-workflow]] — PR-based task delivery workflow
- [[operations/setup-checklist]] — Pre-deployment setup (GitHub, DO, Discord)
- [[operations/deployment]] — How to deploy the swarm
- [[operations/daily-ops]] — Day-to-day fleet operations
- [[reference/discord-protocol]] — Message formats and channel usage
- [[reference/vault-structure]] — Obsidian vault layout and conventions
- [[reference/cli]] — lobmob CLI reference

## Components
| Component | Location | Purpose |
|---|---|---|
| Terraform infra | `infra/` | VPC, firewall, manager droplet |
| Cloud-init templates | `templates/` | Droplet bootstrapping |
| OpenClaw skills | `skills/` | Agent capabilities |
| Agent personas | `openclaw/` | AGENTS.md definitions |
| Vault seed | `vault-seed/` | Initial Obsidian vault structure |
| CLI | `scripts/lobmob` | Deployment and management commands |
| Docs (this vault) | `docs/` | Project documentation |
