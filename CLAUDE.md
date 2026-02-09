# lobmob — Claude Code Project Guide

## What This Is
OpenClaw agent swarm management on DigitalOcean. Manager (lobboss) coordinates worker agents (lobsters) via Discord + SSH over WireGuard. Obsidian vault on GitHub for task tracking.

## Architecture Quick Reference
- **Prod**: lobboss at 138.197.55.241, WG 10.0.0.0/24, vault=lobmob-vault
- **Dev**: lobboss at 134.199.243.68, WG 10.1.0.0/24, vault=lobmob-vault-dev
- **Git-flow**: `main`=production, `develop`=integration. SWE lobsters branch from develop.
- **Three lobster types**: research (Sonnet), swe (Opus), qa (Sonnet)

## Project Structure
```
templates/cloud-init-lobboss.yaml  — Slim skeleton (~140 lines, no scripts)
scripts/server/                    — 21 standalone server scripts (deployed via SCP)
scripts/lobmob                     — Thin CLI dispatcher (115 lines)
scripts/commands/                  — 25 CLI command modules
scripts/lib/helpers.sh             — Shared CLI helpers
skills/lobboss/                    — 15 manager skills (task-create, task-assign, etc.)
skills/lobster/                    — 6 worker skills (code-task, verify-task, etc.)
openclaw/{lobboss,lobster,lobster-swe,lobster-qa}/  — Agent personas
vault-seed/                        — Vault repo initial structure + coordinator AGENTS.md
infra/                             — Terraform (prod.tfvars, dev.tfvars, workspaces)
```

## Key Commands
```bash
# Deploy / manage
lobmob deploy                         # Deploy lobboss via Terraform
lobmob --env dev deploy               # Deploy to dev environment
lobmob provision-secrets              # Re-push secrets + scripts to lobboss
lobmob spawn --type swe               # Spawn a SWE lobster
lobmob status                         # Fleet status

# Validate
cd infra && terraform validate        # Check template syntax
bash tests/<test>                     # Run smoke tests
```

## Critical Gotchas (Read Before Editing)
- `templates/cloud-init-lobboss.yaml` uses Terraform `templatefile()` — `$` must be `$$` for literal dollars, `${var}` for template vars
- Scripts in `scripts/server/` are standalone bash — NO `$$` escaping needed there
- Vault AGENTS.md at `/opt/vault/AGENTS.md` drives the system prompt, NOT `/root/.openclaw/AGENTS.md`
- GitHub App tokens expire every hour — `lobmob-refresh-gh-auth` cron handles this
- Vault clone MUST use HTTPS remote (not SSH) — App tokens only work over HTTPS
- SWE/QA lobsters need ≥2GB RAM (Opus OOMs on 1GB)
- Lobster state lifecycle: `initializing` tag → `active` tag (DO tags, checked by pool manager)
- Don't manually fix lobster mistakes — fix root causes so they behave correctly autonomously

## Git Workflow
- Always create a feature branch for changes (never commit directly to main)
- Commit at logical checkpoints, not one big commit at the end
- After approval, merge to main AND sync develop: `git checkout develop && git merge main && git push origin develop`
- Lobster code PRs target `develop`, not `main`

## Testing
- Tests are bash scripts in `tests/`
- NEVER pipe inside `check()` args — use `bash -c` to wrap
- Deploy scripts to lobboss before testing live changes

## Environment Selection
- `LOBMOB_ENV=dev lobmob <cmd>` or `lobmob --env dev <cmd>`
- Separate secrets: `secrets.env` (prod), `secrets-dev.env` (dev)
- Separate Terraform workspaces and tfvars files
