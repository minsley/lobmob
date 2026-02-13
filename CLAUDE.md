# lobmob — Claude Code Project Guide

## What This Is
Agent swarm management on DigitalOcean Kubernetes (DOKS). Manager (lobboss) coordinates worker agents (lobsters) via Discord + Agent SDK. Obsidian vault on GitHub for task tracking.

## Architecture Quick Reference
- **Prod DOKS**: `lobmob-k8s` cluster, context `do-nyc3-lobmob-k8s`, vault=lobmob-vault
- **Dev DOKS**: `lobmob-dev-k8s` cluster, context `do-nyc3-lobmob-dev-k8s`, vault=lobmob-vault-dev
- **Git-flow**: `main`=production, `develop`=integration. SWE lobsters branch from develop.
- **Three lobster types**: research (Sonnet), swe (Opus), qa (Sonnet)
- **lobboss**: k8s Deployment, discord.py + Agent SDK (long-running, session rotation every 2-4h)
- **lobsters**: k8s Jobs, Agent SDK `query()` (ephemeral, one task per container)
- **Images**: GHCR — lobmob-base, lobmob-lobboss, lobmob-lobster (all amd64)

## Project Structure
```
src/lobboss/                       — Bot + agent (Python, discord.py + Agent SDK)
src/lobster/                       — Ephemeral task worker (Python, Agent SDK)
src/common/                        — Shared modules (vault, logging, health)
containers/{base,lobboss,lobster}/ — Dockerfiles
k8s/base/                          — Kubernetes manifests (Kustomize base)
k8s/overlays/{dev,prod}/           — Environment-specific overlays
scripts/lobmob                     — CLI dispatcher
scripts/commands/                  — CLI command modules
scripts/server/                    — Server-side scripts (cron, web dashboard)
scripts/lib/helpers.sh             — Shared CLI helpers
skills/lobboss/                    — Manager skills (task lifecycle, discord, review)
skills/lobster/                    — Worker skills (code-task, verify-task, etc.)
vault-seed/                        — Vault repo initial structure
infra/                             — Terraform (DOKS clusters, prod.tfvars, dev.tfvars)
```

## Key Commands
```bash
# Deploy / manage
lobmob deploy                         # Deploy via Terraform + kubectl
lobmob --env dev deploy               # Deploy to dev environment
lobmob status                         # Fleet status (pods, jobs, PRs)
lobmob connect                        # Port-forward to lobboss web dashboard
lobmob connect <job-name>             # Port-forward to lobster sidecar
lobmob logs                           # Tail lobboss pod logs
lobmob logs <job-name>                # Tail lobster pod logs

# Build images (from Mac, amd64 for DOKS)
docker buildx build --builder amd64-builder --platform linux/amd64 \
  --build-arg BASE_IMAGE=ghcr.io/minsley/lobmob-base:latest \
  -t ghcr.io/minsley/lobmob-lobboss:latest --push \
  -f containers/lobboss/Dockerfile .

# Apply k8s manifests directly
kubectl apply -k k8s/overlays/dev/
kubectl apply -k k8s/overlays/prod/

# Validate
kubectl apply -k k8s/overlays/dev/ --dry-run=client
cd infra && terraform validate
```

## Critical Gotchas (Read Before Editing)
- Cross-arch builds: Mac builds ARM images. DOKS nodes are amd64. Always use `--platform linux/amd64`
- Dockerfile FROM arg: Use `ARG BASE_IMAGE` + `FROM ${BASE_IMAGE}` so buildx resolves GHCR base
- PVC lost+found: New PVCs have `lost+found` dir. Clean before git clone
- GHCR pull secrets: `imagePullSecrets` needed in deployment AND cronjob pod specs
- GitHub App tokens expire hourly — `gh-token-refresh` CronJob handles this
- Vault clone MUST use HTTPS remote (not SSH) — App tokens only work over HTTPS
- ConfigMap keys are case-sensitive — match exactly
- Don't manually fix lobster mistakes — fix root causes so they behave correctly autonomously

## Git Workflow
- Always create a feature branch for changes (never commit directly to main)
- Commit at logical checkpoints, not one big commit at the end
- After approval, merge to main AND sync develop: `git checkout develop && git merge main && git push origin develop`
- Lobster code PRs target `develop`, not `main`

## Testing
- Tests are bash scripts in `tests/`
- NEVER pipe inside `check()` args — use `bash -c` to wrap
- Build and deploy to dev before testing live changes

## Environment Selection
- `LOBMOB_ENV=dev lobmob <cmd>` or `lobmob --env dev <cmd>`
- Separate secrets: `secrets.env` (prod), `secrets-dev.env` (dev)
- Separate Terraform workspaces and tfvars files

## Session Self-Maintenance

These are instructions for Claude to follow to keep sessions productive.

### At Session Start
- Read MEMORY.md (auto-loaded) and check for stale items
- If MEMORY.md has items marked "TODO" that are now done, update them
- Check the plan file (`.claude/plans/`) for current phase — don't re-plan completed work
- **Version check**: Run `claude --version` and compare with `memory/claude-code-version.md`. If the version changed:
  1. Run `npm view @anthropic-ai/claude-code version` to confirm we're on latest
  2. Check the changelog: `WebFetch https://github.com/anthropics/claude-code/releases` for new features
  3. Update `memory/claude-code-version.md` with the new version, date, and any notable changes
  4. If new features are relevant (new hook types, memory changes, agent capabilities), suggest updates to CLAUDE.md or hooks

### Before Context Gets Large
- If you've made 5+ commits, suggest a checkpoint: commit, push, and offer to start a fresh session
- When approaching complex multi-file changes, use plan mode first
- Use subagents for research to keep the main context focused on implementation

### After Completing Major Work
- Update MEMORY.md with new gotchas, decisions, or architectural changes discovered
- If a plan file phase is complete, update it (mark done, note any deviations)
- Suggest merging and syncing develop if on a feature branch

### Memory Hygiene
- MEMORY.md must stay under 200 lines (only first 200 are loaded)
- Move resolved "Known Issues / TODO" items out when fixed
- Keep gotchas that save time; remove ones that are no longer relevant
- If a gotcha has been codified in a script or config, it can be shortened to a reference

### Context Optimization
- For large refactors, commit after each logical phase and offer to continue in a fresh session
- When context is compacted, re-read CLAUDE.md and critical files rather than relying on compressed history
- Use `terraform validate` after any template changes as a quick sanity check
