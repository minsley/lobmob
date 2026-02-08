# Infrastructure Isolation, OAuth Token Automation, and Web UI

Tracking doc for the multi-phase project to isolate lobmob in DigitalOcean, automate token renewal, and build a management web UI.

## Status: In Progress

## Why

- Lobmob resources share a DO account with no organizational boundary
- Lobboss IP changes on recreate, breaking WireGuard configs for all lobsters
- API tokens (DO, GitHub) are long-lived PATs with no automatic renewal
- No monitoring alerts for resource exhaustion

## Tasks

### Phase 1: Terraform Infrastructure
- [ ] Add `digitalocean_project` + resource assignments to `infra/main.tf`
- [ ] Add `digitalocean_reserved_ip` + assignment to `infra/main.tf`
- [ ] Add monitoring alerts (CPU/memory/disk) for lobboss and lobster tag
- [ ] Add port 8080 firewall rule for web UI
- [ ] Add `alert_email` variable to `infra/variables.tf`
- [ ] Update spawn script to assign lobsters to project via doctl

### Phase 2: GitHub App Authentication
- [ ] Write `lobmob-gh-token` script (JWT + PEM -> installation token)
- [ ] Integrate into `lobmob-provision` (lobboss uses App token for gh auth)
- [ ] Integrate into `lobmob-spawn-lobster` (lobsters get fresh App token)
- [ ] Add PEM push to `cmd_provision_secrets_to()` in `scripts/lobmob`
- [ ] Update bootstrap wizard with GitHub App option
- [ ] Backward-compatible: fall back to PAT if App not configured

### Phase 3: DO OAuth + Web UI
- [ ] Write `lobmob-web` Node.js server (single file, no deps)
- [ ] Implement OAuth routes: authorize redirect, callback, token storage
- [ ] Write `lobmob-refresh-do-token` cron script
- [ ] Add `lobmob-web.service` systemd unit
- [ ] Update bootstrap wizard with DO OAuth option
- [ ] Add web.env provisioning to `scripts/lobmob`

### Phase 4: Integration and Testing
- [ ] Update `tests/smoke-lobboss` (openclaw.json check, reserved IP, gh-token, web service)
- [ ] Update `tests/smoke-lobster` (gh auth verification)
- [ ] Write `docs/operations/token-management.md`
- [ ] Write `docs/operations/web-ui.md`

### Deployment
- [ ] `terraform apply` (creates reserved IP, project, monitoring, firewall rule)
- [ ] `lobmob provision-secrets` to push updated scripts
- [ ] Run smoke tests
- [ ] Manual: create GitHub App, install on vault repo, download PEM
- [ ] Manual: create DO OAuth App with callback URL
- [ ] Test OAuth flow via browser

## Key Files

| File | Role |
|---|---|
| `infra/main.tf` | Terraform resources |
| `infra/variables.tf` | Terraform variables |
| `templates/cloud-init-lobboss.yaml` | All scripts deployed to lobboss |
| `scripts/lobmob` | CLI (bootstrap, deploy, provision) |
| `tests/smoke-lobboss` | Lobboss health checks |
| `tests/smoke-lobster` | Lobster health checks |

## Design Decisions

- **GitHub App** uses JWT-based server-to-server auth (no web server needed for token renewal)
- **DO OAuth** uses browser redirect flow through lobboss web UI on port 8080
- **Web UI** starts with HTTP (no domain needed); document HTTPS upgrade path for later
- **Reserved IP** used for stable WG endpoint (WireGuard resolves hostnames only at startup)
- **All OAuth changes are backward-compatible** with existing PAT tokens
- **Web server is a single Node.js file** using only built-in `http` module (no npm deps)
