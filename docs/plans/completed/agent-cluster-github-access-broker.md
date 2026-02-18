---
status: completed
tags: [infrastructure, security, lobwife]
maturity: implementation
created: 2026-02-14
updated: 2026-02-14
---
# GitHub Access Broker & Setup Wizard

> Centralized GitHub credential management for the lobmob agent cluster.
> Replaces per-pod PEM injection with a token broker on lobwife + automated setup.

## Problem

1. **PEM key sprayed everywhere**: The GitHub App private key is injected into every lobster pod via `lobmob-secrets`. Any pod compromise exposes the full key.
2. **No repo scoping**: Every lobster gets the same unscoped installation token. A research lobster has the same GitHub access as an SWE lobster.
3. **No mid-task refresh**: Tokens expire hourly. Long SWE tasks (multi-hour Unity builds, large refactors) will fail mid-push.
4. **Manual setup**: Creating the GitHub App is a 6-step manual checklist. Barrier to adoption and open-source onboarding.
5. **Multi-repo tasks not supported**: SWE lobsters will need access to project repos (Unity, Android, etc.) alongside the vault. Current init container only clones the vault.

## Architecture

```
                    ┌──────────────┐
                    │  GitHub API  │
                    └──────┬───────┘
                           │
            ┌──────────────▼──────────────┐
            │         lobwife             │
            │  (existing persistent pod)  │
            │                             │
            │  Cron scheduler (existing)  │
            │  + Token broker (new)       │
            │  + gh-token-refresh (JWT)   │
            │                             │
            │  PEM key stays HERE only    │
            └──────┬──────────────┬───────┘
                   │              │
        ┌──────────▼───┐   ┌─────▼──────────┐
        │   lobboss    │   │    lobster      │
        │              │   │                 │
        │ registers    │   │ requests token  │
        │ task repos   │   │ via credential  │
        │ at spawn     │   │ helper (HTTP)   │
        └──────────────┘   └────────┬────────┘
                                    │
                           ┌────────▼────────┐
                           │  Git Repos      │
                           │  (vault + proj) │
                           └─────────────────┘
```

### Token Flow

1. **lobboss** spawns a lobster Job and calls lobwife `POST /api/tasks/{id}/register` with the repo list (vault + project repos)
2. **lobster** pod starts with `LOBWIFE_URL` and `TASK_ID` env vars (no PEM, no GH_TOKEN)
3. **git credential helper** in lobster image calls lobwife `POST /api/token` on every git operation
4. **lobwife** validates the task is registered, generates a repo-scoped installation token via GitHub API, returns it
5. For long tasks, the credential helper transparently fetches a fresh token on each git operation — no background daemon needed
6. **lobwife** logs every token issuance for audit

### What changes vs. current system

| Component | Before | After |
|-----------|--------|-------|
| PEM key location | `lobmob-secrets` (all pods) | `lobwife-secrets` (lobwife only) |
| Lobster gets | Raw PEM key via env var | `LOBWIFE_URL` + `TASK_ID` only |
| Token generation | `gh-token-refresh` cron (unscoped) | On-demand, repo-scoped per task |
| Token refresh | None (tasks must finish within 1hr) | Transparent via git credential helper |
| Vault clone | Init container with baked-in token | Init container calls lobwife for token |
| Project repo clone | Not supported | Agent SDK Bash tool clones via credential helper |
| Setup | Manual 6-step checklist | `lobmob setup github` CLI wizard |

---

## 1. Setup Wizard: `lobmob setup`

### Overview

Interactive CLI command that bootstraps a new lobmob deployment. GitHub App creation is one stage; the full setup covers all prerequisites.

### `lobmob setup` stages

```
lobmob setup
  1. Prerequisites check (terraform, kubectl, docker buildx, gh CLI)
  2. DigitalOcean — prompt for API token, validate
  3. GitHub App — manifest API flow (see below)
  4. Discord — prompt for bot token, channel IDs
  5. Anthropic — prompt for API key
  6. Write secrets.env (and secrets-dev.env if dev)
  7. Optionally create k8s secrets from the file
```

Each stage is idempotent and can be skipped if already configured. `lobmob setup github` runs only the GitHub stage.

### `lobmob setup github` flow

Uses the GitHub App manifest API for one-click App creation:

```
1. CLI starts a temporary local HTTP server on localhost:3456
2. Builds manifest JSON with:
   - name: "lobmob-fleet" (or user-provided name via --name flag)
   - permissions: contents:write, pull_requests:write, metadata:read, issues:write
   - No webhook (not needed — we poll, not push)
   - redirect_url: http://localhost:3456/callback
3. Opens browser to: https://github.com/settings/apps/new?manifest={base64}
   (or https://github.com/organizations/{org}/settings/apps/new?manifest={base64})
4. User clicks "Create GitHub App" on GitHub
5. GitHub redirects to localhost:3456/callback?code=XXX
6. CLI exchanges code for credentials via POST /app-manifests/{code}/conversions
7. CLI receives: app_id, client_id, client_secret, pem, webhook_secret
8. CLI prompts: "Install this app to your repositories now? [Y/n]"
   - Opens: https://github.com/apps/{slug}/installations/new
   - User selects repos (vault + project repos)
   - CLI polls for installation_id via GET /app/installations
9. CLI writes to secrets.env:
   - GH_APP_ID=...
   - GH_APP_INSTALL_ID=...
   - GH_APP_PEM=<base64-encoded PEM>
10. CLI shuts down temp server
```

### Implementation notes

- **Bash script** (`scripts/commands/setup.sh` + `scripts/commands/setup-github.sh`), not Python — consistent with CLI patterns
- Temp HTTP server: `python3 -m http.server` won't work (need routing). Use a small inline Python snippet for the callback server, invoked from bash.
- The manifest API requires a browser redirect — no way to avoid user interaction
- For orgs: detect from user input whether to use `/settings/apps/new` or `/organizations/{org}/settings/apps/new`
- Store PEM as base64 in secrets.env (same as current `GH_APP_PEM` pattern)

---

## 2. Token Broker: lobwife endpoints

### New endpoints on existing lobwife daemon

Added to `scripts/server/lobwife-daemon.py` alongside the existing cron scheduler API. All endpoints served by the same aiohttp server on port 8081 (proxied through lobwife-web.js on 8080).

### API

```
POST /api/tasks/{task_id}/register
  Body: {"repos": ["owner/repo-a", "owner/repo-b"], "lobster_type": "swe"}
  Called by: lobboss (at job spawn time)
  Response: {"status": "registered"}
  Stores: task_id → {repos, lobster_type, registered_at, status: "active"}

POST /api/token
  Body: {"task_id": "xxx"}
  Called by: lobster (via git credential helper)
  Response: {"token": "ghs_...", "expires_at": "ISO8601"}
  Validates: task is registered and active
  Generates: repo-scoped installation token via GitHub API

DELETE /api/tasks/{task_id}
  Called by: lobboss (when job completes/fails) or lobwife cleanup cron
  Response: {"status": "removed"}
  Clears: task registration (prevents further token requests)

GET /api/tasks
  Returns: all registered tasks with status, repos, token count
  Used by: web dashboard, debugging

GET /api/token/audit
  Query: ?task_id=xxx (optional)
  Returns: token issuance log (last 200 entries)
```

### Token generation

Reuses the existing JWT generation logic from `lobmob-gh-token.sh`, ported to Python:

```python
# In lobwife-daemon.py — new TokenBroker class

class TokenBroker:
    def __init__(self):
        self.app_id = os.environ.get("GH_APP_ID")
        self.install_id = os.environ.get("GH_APP_INSTALL_ID")
        self.pem_key = self._load_pem()  # from GH_APP_PEM env (base64) or file
        self.tasks = {}     # task_id → {repos, lobster_type, registered_at, status}
        self.audit_log = [] # {timestamp, task_id, repos, action}

    def _generate_jwt(self) -> str:
        """Generate GitHub App JWT (10-min lifetime)."""
        # Same logic as lobmob-gh-token.sh but in Python
        # iat, exp, iss → RS256 sign with PEM

    async def create_scoped_token(self, repos: list[str]) -> dict:
        """Generate installation token scoped to specific repos."""
        # POST /app/installations/{id}/access_tokens
        # Body: {"repositories": ["repo-name"], "permissions": {...}}

    async def get_token_for_task(self, task_id: str) -> dict:
        """Validate task and return scoped token."""
        task = self.tasks.get(task_id)
        if not task or task["status"] != "active":
            raise ValueError(f"Task {task_id} not registered or inactive")
        token_data = await self.create_scoped_token(task["repos"])
        self._audit("token_issued", task_id, task["repos"])
        return token_data
```

### State persistence

Task registrations stored in `~/state/tasks.json` alongside existing `~/state/jobs.json`. Loaded on startup, saved after mutations. Tasks auto-expire after 24 hours (configurable) via a cleanup check in the existing periodic persist loop.

### gh-token-refresh replacement

Once the broker is operational, `gh-token-refresh` cron job becomes unnecessary — tokens are generated on demand. The cron job definition stays in lobwife's `JOB_DEFS` but can be disabled. Other services (lobboss, lobsigliere) that need GitHub tokens can call lobwife's broker API too.

---

## 3. Git Credential Helper: lobster-side

### Shell script in lobster image

```bash
#!/bin/bash
# /usr/local/bin/git-credential-lobwife
# Git credential helper that fetches tokens from lobwife broker.
# Configured via: git config --global credential.helper lobwife

case "${1:-}" in
  get)
    TASK_ID="${TASK_ID:-}"
    LOBWIFE_URL="${LOBWIFE_URL:-}"
    if [[ -z "$TASK_ID" || -z "$LOBWIFE_URL" ]]; then exit 1; fi

    RESPONSE=$(curl -sf -X POST "$LOBWIFE_URL/api/token" \
      -H "Content-Type: application/json" \
      -d "{\"task_id\": \"$TASK_ID\"}" 2>/dev/null)

    if [[ $? -ne 0 || -z "$RESPONSE" ]]; then exit 1; fi

    TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null)
    if [[ -z "$TOKEN" ]]; then exit 1; fi

    echo "protocol=https"
    echo "host=github.com"
    echo "username=x-access-token"
    echo "password=$TOKEN"
    ;;
  store|erase)
    # No-op — tokens are ephemeral
    ;;
esac
```

### Why a shell script, not Python

- No `requests` dependency needed (uses `curl` + `python3 -c` for JSON parsing)
- Faster startup than a Python script (git calls the helper on every operation)
- Bash is already in the lobster image
- Matches the git credential helper protocol exactly

### Installation

Added to lobster Dockerfile:
```dockerfile
COPY scripts/git-credential-lobwife /usr/local/bin/git-credential-lobwife
RUN chmod +x /usr/local/bin/git-credential-lobwife
```

Configured in lobster entrypoint or init container:
```bash
git config --global credential.helper lobwife
```

---

## 4. Changes to Lobster Job Spawning

### lobboss `spawn_lobster()` changes

In `src/lobboss/mcp_tools.py`:

1. **Register task with lobwife** before creating the k8s Job:
   ```python
   # Determine repos for this task
   repos = [vault_repo]  # Always include vault
   if task.get("repos"):
       repos.extend(task["repos"])  # Project repos from task definition

   # Register with lobwife broker
   await register_task_with_lobwife(task_id, repos, lobster_type)
   ```

2. **Replace GH_APP_PRIVATE_KEY env var** with:
   ```python
   client.V1EnvVar(name="LOBWIFE_URL",
       value="http://lobwife.lobmob.svc.cluster.local:8081")
   client.V1EnvVar(name="TASK_ID", value=task_id)
   ```

3. **Update init container** (vault-clone):
   - Instead of using `GH_TOKEN` from secret, call lobwife for a token
   - Or: use the git credential helper (requires git config in init container)
   - Simplest: small curl script that fetches token from lobwife, clones vault

4. **Deregister task** when job completes (via task-manager or lobboss callback):
   ```python
   await deregister_task_with_lobwife(task_id)
   ```

### Task definition changes

Task files in vault gain an optional `repos` field in frontmatter:
```yaml
---
id: 2026-02-15-unity-ui
type: swe
status: queued
repos:
  - minsley/unity-project
  - minsley/shared-assets
---
Implement the new inventory UI...
```

The vault repo is always included implicitly. `repos` lists additional project repos the lobster needs access to.

---

## 5. Security Model

### Key isolation

| Secret | Accessible by |
|--------|---------------|
| GitHub App PEM | lobwife only |
| ANTHROPIC_API_KEY | lobboss, lobsters (via k8s secret) |
| DISCORD_BOT_TOKEN | lobboss only |
| Installation tokens | Individual lobster (via credential helper, scoped to task repos) |

### Token properties

- **Lifetime**: 1 hour (GitHub enforced maximum)
- **Scope**: Only repos registered for that task
- **Permissions**: contents:write, pull_requests:write, metadata:read
- **Refresh**: Transparent — each git operation triggers a credential helper call. If the cached token is still valid, GitHub returns the same one. If expired, lobwife generates a new one.
- **Revocation**: Automatic — task deregistration prevents new tokens. Existing tokens expire within 1 hour.

### Audit trail

Every token issuance logged with timestamp, task_id, repos, and action. Visible in lobwife web dashboard and via API. Persisted to PVC state file.

### PEM key rotation: `lobmob setup rotate-pem`

If the PEM key is compromised or the GitHub App's private key is regenerated in GitHub settings, the operator needs to push the new key to the cluster and restart lobwife. This is a single CLI command:

```
lobmob setup rotate-pem <path-to-new-pem-file>
lobmob setup rotate-pem --from-stdin < new-key.pem
```

Flow:
1. Read new PEM from file path or stdin
2. Validate it looks like an RSA private key (starts with `-----BEGIN RSA PRIVATE KEY-----`)
3. Base64-encode and update `GH_APP_PEM` in `secrets.env` (or `secrets-dev.env` if `--env dev`)
4. Update the `lobwife-secrets` k8s Secret (or `lobmob-secrets` during migration) with the new value
5. Restart lobwife deployment to pick up the new key: `kubectl rollout restart deployment/lobwife`
6. Verify: call lobwife's `/health` endpoint and confirm broker reports PEM loaded
7. All in-flight installation tokens remain valid until their natural expiry (up to 1 hour) — no disruption to running lobsters

The old PEM is immediately invalidated on GitHub's side when a new key is generated, so any tokens lobwife generates with the old key after GitHub's revocation will fail. The restart ensures lobwife picks up the new key promptly.

### What lobsters CANNOT do

- Access repos not registered for their task
- Generate tokens for other tasks
- Read the GitHub App PEM key
- Access the k8s Secrets API (RBAC restricts to pod/log read only)

---

## 6. Migration Path

### Phase 1: Add broker to lobwife (additive, no breaking changes)

- Add TokenBroker class and API endpoints to lobwife daemon
- Add git credential helper to lobster image
- Add task registration call to lobboss spawn_lobster()
- Both old (PEM injection) and new (broker) paths work simultaneously

### Phase 2: Switch lobsters to broker (cutover)

- Remove GH_APP_PRIVATE_KEY from lobster env vars in spawn_lobster()
- Update init container to use credential helper for vault clone
- Verify long-running tasks refresh tokens correctly

### Phase 3: Remove PEM from shared secret (cleanup)

- Move PEM to lobwife-only secret (`lobwife-secrets`)
- Remove `GH_APP_PRIVATE_KEY` from `lobmob-secrets`
- lobboss and lobsigliere use lobwife broker for their own GitHub access

### Phase 4: Setup wizard (independent, can be done anytime)

- Implement `lobmob setup` and `lobmob setup github`
- Update documentation to reference wizard instead of manual checklist

---

## 7. Troubleshooting

**Token request returns 404 from lobwife:**
- Task not registered. Check lobboss logs for registration call.
- Task expired (>24h). Re-register or extend timeout.

**Git clone fails with "Repository not found":**
- Repo not in task's registered repo list. Check vault task frontmatter `repos` field.
- GitHub App not installed on that repo. Run `lobmob setup github` and add repo.

**Git push fails after long task:**
- Credential helper should auto-refresh. Check lobwife connectivity from pod:
  `curl -sf http://lobwife.lobmob.svc.cluster.local:8081/health`
- Check lobwife logs for token generation errors.

**lobwife can't generate tokens (JWT errors):**
- PEM key not loaded. Check `GH_APP_PEM` env var in lobwife deployment.
- App ID or Installation ID wrong. Verify in GitHub App settings.
- Clock skew. JWT uses `iat`/`exp` — k8s nodes must have synced clocks.

---

## Appendix: GitHub App Permissions

### Required (all lobster types)

```json
{
  "contents": "write",
  "pull_requests": "write",
  "metadata": "read"
}
```

### Optional (enable as needed)

```json
{
  "issues": "write",
  "workflows": "write",
  "actions": "read"
}
```

### Read-only (research lobsters)

Future: broker could issue read-only tokens for research tasks by passing reduced permissions to the installation token API. Not implemented in v1 — all tokens get write access.
