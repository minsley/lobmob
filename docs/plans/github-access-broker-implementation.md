# GitHub Access Broker — Implementation Plan

> Step-by-step execution plan for Claude Code.
> Architecture: [agent-cluster-github-access-broker.md](./agent-cluster-github-access-broker.md)

## Branch

`feature/github-access-broker` from `develop`. PR targets `develop`.

## Phases

### Phase 1: Token Broker on lobwife

**Goal**: Add credential broker endpoints to the existing lobwife daemon. No changes to lobsters or lobboss yet — old and new paths coexist.

#### 1.1 Add `PyJWT` + `cryptography` to lobwife dependencies

**File**: `containers/lobwife/requirements.txt`

Add:
```
PyJWT>=2.8.0,<3
cryptography>=42.0.0,<44
```

These are needed for RS256 JWT generation (GitHub App auth). The existing `lobmob-gh-token.sh` does this with `openssl` CLI — we're porting to Python so the broker can generate JWTs in-process.

#### 1.2 Create `TokenBroker` class

**File**: `scripts/server/lobwife-daemon.py`

Add a new class alongside the existing `JobRunner`:

```python
class TokenBroker:
    """GitHub token broker — generates repo-scoped installation tokens."""

    def __init__(self):
        self.app_id = os.environ.get("GH_APP_ID", "")
        self.install_id = os.environ.get("GH_APP_INSTALL_ID", "")
        self.pem_key = self._load_pem()
        self.tasks = {}      # task_id → {repos, lobster_type, registered_at, status}
        self.audit_log = []   # [{timestamp, task_id, repos, action}, ...]
        self._load_tasks()

    def _load_pem(self) -> str | None:
        """Load PEM from GH_APP_PEM (base64) or GH_APP_PEM_PATH (file)."""

    def _generate_jwt(self) -> str:
        """Create GitHub App JWT signed with PEM (10-min lifetime)."""
        # Use PyJWT: jwt.encode(payload, pem_key, algorithm="RS256")

    async def create_scoped_token(self, repos: list[str]) -> dict:
        """POST /app/installations/{id}/access_tokens with repo scope."""
        # Use aiohttp.ClientSession to call GitHub API
        # Body: {"repositories": [repo_name_only], "permissions": {...}}
        # Return: {"token": "ghs_...", "expires_at": "ISO8601"}

    def register_task(self, task_id, repos, lobster_type):
        """Register a task's repo access. Called by lobboss at spawn."""

    def deregister_task(self, task_id):
        """Remove task registration. Called on job completion."""

    async def get_token_for_task(self, task_id) -> dict:
        """Validate task is active, return scoped token."""

    def _audit(self, action, task_id, repos):
        """Append to audit log, trim to last 500 entries."""

    def _load_tasks(self):
        """Load from ~/state/tasks.json on startup."""

    def _save_tasks(self):
        """Persist to ~/state/tasks.json."""

    def cleanup_expired(self, max_age_hours=24):
        """Remove task registrations older than max_age. Called periodically."""
```

Important details:
- PEM loading: try `GH_APP_PEM` env var (base64-decode), fall back to `GH_APP_PEM_PATH` file, fall back to None (broker disabled).
- If PEM is not configured, broker endpoints return 503 with a clear message. This keeps lobwife functional for cron-only deployments.
- `create_scoped_token` must strip the `owner/` prefix from repo names — GitHub's API wants just the repo name, not the full `owner/repo` path.
- Audit log capped at 500 entries in memory, persisted to `~/state/token-audit.json`.

#### 1.3 Add broker HTTP routes

**File**: `scripts/server/lobwife-daemon.py` — in `build_app()` function

Add these routes to the existing aiohttp app:

```python
# Task registration (called by lobboss)
app.router.add_post("/api/tasks/{task_id}/register", handle_register_task)
app.router.add_delete("/api/tasks/{task_id}", handle_deregister_task)
app.router.add_get("/api/tasks", handle_list_tasks)

# Token issuance (called by lobster credential helper)
app.router.add_post("/api/token", handle_get_token)

# Audit
app.router.add_get("/api/token/audit", handle_token_audit)
```

Handler implementations:
- `handle_register_task`: Parse JSON body `{repos, lobster_type}`, call `broker.register_task()`, return 200.
- `handle_get_token`: Parse JSON body `{task_id}`, call `broker.get_token_for_task()`, return token or 403/404.
- `handle_deregister_task`: Call `broker.deregister_task()`, return 200.
- `handle_list_tasks`: Return `broker.tasks` as JSON.
- `handle_token_audit`: Return `broker.audit_log`, optionally filtered by `?task_id=`.

#### 1.4 Wire broker into daemon lifecycle

**File**: `scripts/server/lobwife-daemon.py` — in `main()` function

- Instantiate `TokenBroker` alongside `JobRunner`
- Pass broker to `build_app()` so routes can access it
- Add `broker.cleanup_expired()` call to the existing 5-minute persist loop
- Add `broker._save_tasks()` to shutdown handler

#### 1.5 Add broker status to web dashboard

**File**: `scripts/server/lobwife-web.js`

Add a "Token Broker" section to the dashboard:
- Card showing: broker status (enabled/disabled), active task count, tokens issued (from audit log length)
- Table: registered tasks (task_id, repos, lobster_type, registered_at)
- Link to `/api/token/audit` for full audit log

#### 1.6 Build and deploy to dev

```bash
lobmob build lobwife
LOBMOB_ENV=dev lobmob deploy   # or kubectl apply -k k8s/overlays/dev/
```

#### 1.7 Verify broker endpoints

Add broker checks to `scripts/commands/verify.sh`:
- `GET /api/tasks` returns 200
- `POST /api/tasks/test-task/register` with `{"repos": ["minsley/lobmob-vault-dev"], "lobster_type": "test"}` returns 200
- `POST /api/token` with `{"task_id": "test-task"}` returns a token (if GH_APP_PEM is configured)
- `DELETE /api/tasks/test-task` returns 200
- `GET /api/token/audit` shows the issuance

**Commit checkpoint**: "Add token broker to lobwife daemon"

---

### Phase 2: Git Credential Helper

**Goal**: Create the lobster-side credential helper and install it in the image.

#### 2.1 Create credential helper script

**File**: `scripts/git-credential-lobwife`

Bash script implementing git credential helper protocol. On `get`:
1. Read `TASK_ID` and `LOBWIFE_URL` from environment
2. `curl -sf POST $LOBWIFE_URL/api/token` with `{"task_id": "$TASK_ID"}`
3. Parse JSON response (use `python3 -c` for JSON extraction — no extra deps)
4. Output git credential format: protocol, host, username=x-access-token, password=$TOKEN

On `store`/`erase`: no-op.

Error handling: if curl fails or LOBWIFE_URL is not set, exit 1 (git falls back to other credential helpers or prompts).

#### 2.2 Add to lobster Dockerfile

**File**: `containers/lobster/Dockerfile`

```dockerfile
# Git credential helper for lobwife token broker
COPY scripts/git-credential-lobwife /usr/local/bin/git-credential-lobwife
RUN chmod +x /usr/local/bin/git-credential-lobwife
```

#### 2.3 Add to lobwife Dockerfile (for SSH sessions)

**File**: `containers/lobwife/Dockerfile`

Same COPY + chmod. Useful for SSH sessions where the operator wants to use the broker for git.

#### 2.4 Add to lobsigliere Dockerfile (for ops console)

**File**: `containers/lobsigliere/Dockerfile`

Same COPY + chmod.

**Commit checkpoint**: "Add git-credential-lobwife to container images"

---

### Phase 3: Wire Lobboss to Broker

**Goal**: lobboss registers tasks with lobwife at spawn time. Lobsters use credential helper instead of PEM injection.

#### 3.1 Add task registration to `spawn_lobster()`

**File**: `src/lobboss/mcp_tools.py`

Before creating the k8s Job:

```python
# Determine repos for this task
repos = [vault_repo]  # from VAULT_REPO env/config
task_file = read_task(task_id)
if task_file and task_file.metadata.get("repos"):
    repos.extend(task_file.metadata["repos"])

# Register with lobwife broker
lobwife_url = os.environ.get("LOBWIFE_URL", "http://lobwife.lobmob.svc.cluster.local:8081")
async with aiohttp.ClientSession() as session:
    await session.post(
        f"{lobwife_url}/api/tasks/{task_id}/register",
        json={"repos": repos, "lobster_type": lobster_type}
    )
```

Note: Registration failure should log a warning but not block job creation (graceful degradation — lobster can still work if broker is down, using fallback PEM if available).

#### 3.2 Replace PEM injection with LOBWIFE_URL

**File**: `src/lobboss/mcp_tools.py`

In the lobster Job container env vars:

**Remove**:
```python
client.V1EnvVar(name="GH_TOKEN", value_from=...)  # GH_APP_PRIVATE_KEY
```

**Add**:
```python
client.V1EnvVar(name="LOBWIFE_URL",
    value="http://lobwife.lobmob.svc.cluster.local:8081")
```

`TASK_ID` is already injected. `ANTHROPIC_API_KEY` stays as-is (still from k8s secret).

#### 3.3 Update init container (vault-clone)

**File**: `src/lobboss/mcp_tools.py`

The init container currently runs:
```bash
git clone "https://x-access-token:${GH_TOKEN}@github.com/${VAULT_REPO}.git" /opt/vault
```

Replace with a script that fetches a token from lobwife first:
```bash
TOKEN=$(curl -sf -X POST "http://lobwife.lobmob.svc.cluster.local:8081/api/token" \
  -H "Content-Type: application/json" \
  -d "{\"task_id\": \"${TASK_ID}\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
git clone "https://x-access-token:${TOKEN}@github.com/${VAULT_REPO}.git" /opt/vault
```

The init container needs: `TASK_ID` and network access to lobwife's ClusterIP service. No PEM key needed.

#### 3.4 Configure git credential helper in lobster startup

**File**: `src/lobster/run_task.py` or the lobster Dockerfile

Add to the container's git config (in Dockerfile or entrypoint):
```bash
git config --global credential.helper lobwife
```

This ensures all git operations (clone, push, fetch) by the Agent SDK Bash tool use the credential helper automatically.

#### 3.5 Add task deregistration

**File**: `src/lobboss/mcp_tools.py` or `scripts/server/lobmob-task-manager.sh`

When task-manager detects a completed/failed job, deregister:
```bash
curl -sf -X DELETE "http://lobwife.lobmob.svc.cluster.local:8081/api/tasks/${TASK_ID}"
```

Or add to lobboss's job completion handler if one exists.

#### 3.6 Add LOBWIFE_URL to lobboss deployment env

**File**: `k8s/base/lobboss-deployment.yaml` (or via ConfigMap)

```yaml
- name: LOBWIFE_URL
  value: "http://lobwife.lobmob.svc.cluster.local:8081"
```

**Commit checkpoint**: "Wire lobboss to lobwife token broker"

---

### Phase 4: Migrate PEM Key to lobwife-only Secret

**Goal**: Remove PEM from the shared `lobmob-secrets`. Only lobwife holds it.

#### 4.1 Create `lobwife-secrets` k8s Secret

Separate secret containing only the GitHub App credentials:
- `GH_APP_ID`
- `GH_APP_INSTALL_ID`
- `GH_APP_PEM` (base64-encoded PEM)

#### 4.2 Update lobwife deployment to use `lobwife-secrets`

**File**: `k8s/base/lobwife-deployment.yaml`

Add:
```yaml
envFrom:
  - secretRef:
      name: lobwife-secrets
      optional: true
  - secretRef:
      name: lobmob-secrets
  - configMapRef:
      name: lobboss-config
```

#### 4.3 Remove GH_APP_PRIVATE_KEY from `lobmob-secrets`

After verifying all services use the broker:
- Remove from `secrets.env` template
- Remove from k8s secret creation
- Update `secrets.env.example`

#### 4.4 Update `lobmob-gh-token.sh` to use broker

The cron job currently generates tokens via JWT+PEM. Update it to call the broker API instead, or disable it entirely (broker handles on-demand generation).

**Commit checkpoint**: "Isolate PEM key to lobwife-only secret"

---

### Phase 5: Setup Wizard

**Goal**: `lobmob setup` and `lobmob setup github` CLI commands.

#### 5.1 Create `setup-github.sh`

**File**: `scripts/commands/setup-github.sh`

Implements the GitHub App manifest flow:

1. Parse args: `--name` (default: "lobmob-fleet"), `--org` (optional, for org-level apps)
2. Start a background Python HTTP server for the callback:
   ```python
   # Inline Python script started via subprocess
   # Listens on localhost:3456
   # Single route: GET /callback?code=XXX
   # Writes code to a temp file and exits
   ```
3. Build manifest JSON (permissions, redirect_url, name)
4. Open browser: `open "https://github.com/settings/apps/new?manifest=$ENCODED_MANIFEST"`
   - If `--org` provided: `https://github.com/organizations/$ORG/settings/apps/new?...`
5. Wait for callback (poll temp file for code, timeout after 5 minutes)
6. Exchange code via `curl POST /app-manifests/$CODE/conversions`
7. Parse response: app_id, pem, client_id, client_secret, slug
8. Write to secrets file:
   ```bash
   GH_APP_ID=12345
   GH_APP_INSTALL_ID=   # filled after installation step
   GH_APP_PEM=$(echo "$PEM" | base64)
   ```
9. Prompt to install app on repos, open installation page
10. Poll `GET /app/installations` (with JWT auth) until installation_id appears
11. Write `GH_APP_INSTALL_ID` to secrets file

#### 5.2 Create `setup.sh`

**File**: `scripts/commands/setup.sh`

Interactive multi-stage bootstrap:

```bash
# Stage 1: Prerequisites
log "Checking prerequisites..."
check_command terraform
check_command kubectl
check_command docker
check_command gh
check_command jq

# Stage 2: DigitalOcean
if prompt_yn "Configure DigitalOcean?"; then
  read -rp "DO API token: " DO_TOKEN
  # Validate: curl -sf -H "Authorization: Bearer $DO_TOKEN" https://api.digitalocean.com/v2/account
fi

# Stage 3: GitHub App
if prompt_yn "Create GitHub App?"; then
  source "$SCRIPT_DIR/commands/setup-github.sh"
fi

# Stage 4: Discord
if prompt_yn "Configure Discord bot?"; then
  read -rp "Discord bot token: " DISCORD_BOT_TOKEN
  read -rp "Task queue channel ID: " TASK_QUEUE_CHANNEL_ID
  # ...
fi

# Stage 5: Anthropic
if prompt_yn "Configure Anthropic API?"; then
  read -rp "Anthropic API key: " ANTHROPIC_API_KEY
fi

# Stage 6: Write secrets.env
write_secrets_file

# Stage 7: Optionally create k8s secrets
if prompt_yn "Push secrets to cluster now?"; then
  create_k8s_secrets
fi
```

#### 5.3 Create `setup-rotate-pem.sh`

**File**: `scripts/commands/setup-rotate-pem.sh`

Emergency PEM rotation command for when a key is revoked/regenerated on GitHub:

```
lobmob setup rotate-pem <path-to-pem>
lobmob setup rotate-pem --from-stdin < new-key.pem
lobmob --env dev setup rotate-pem <path-to-pem>
```

Implementation:

```bash
PEM_SOURCE="${1:-}"

# Read PEM from file or stdin
if [[ "$PEM_SOURCE" == "--from-stdin" ]]; then
    PEM_RAW=$(cat)
elif [[ -n "$PEM_SOURCE" && -f "$PEM_SOURCE" ]]; then
    PEM_RAW=$(cat "$PEM_SOURCE")
else
    err "Usage: lobmob setup rotate-pem <pem-file>"
    err "       lobmob setup rotate-pem --from-stdin < key.pem"
    exit 1
fi

# Validate PEM format
if [[ "$PEM_RAW" != *"BEGIN RSA PRIVATE KEY"* && "$PEM_RAW" != *"BEGIN PRIVATE KEY"* ]]; then
    err "File does not appear to be a PEM private key"
    exit 1
fi

PEM_B64=$(echo "$PEM_RAW" | base64)

# 1. Update secrets file
log "Updating $SECRETS_FILE..."
# Replace GH_APP_PEM line (or append if missing)
if grep -q "^GH_APP_PEM=" "$SECRETS_FILE"; then
    portable_sed_i "s|^GH_APP_PEM=.*|GH_APP_PEM=${PEM_B64}|" "$SECRETS_FILE"
else
    echo "GH_APP_PEM=${PEM_B64}" >> "$SECRETS_FILE"
fi

# 2. Update k8s secret
log "Updating k8s secret..."
kubectl --context "$KUBE_CONTEXT" -n lobmob create secret generic lobwife-secrets \
    --from-literal="GH_APP_PEM=${PEM_B64}" \
    --from-literal="GH_APP_ID=${GH_APP_ID}" \
    --from-literal="GH_APP_INSTALL_ID=${GH_APP_INSTALL_ID}" \
    --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart lobwife
log "Restarting lobwife..."
kubectl --context "$KUBE_CONTEXT" -n lobmob rollout restart deployment/lobwife
kubectl --context "$KUBE_CONTEXT" -n lobmob rollout status deployment/lobwife --timeout=120s

# 4. Verify
log "Verifying broker health..."
sleep 5
kubectl --context "$KUBE_CONTEXT" -n lobmob port-forward svc/lobwife 18080:8080 &>/dev/null &
PF_PID=$!
sleep 3
HEALTH=$(curl -sf http://localhost:18080/health 2>/dev/null || true)
kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null || true

if [[ "$HEALTH" == *'"ok"'* ]]; then
    log "PEM rotation complete. Lobwife is healthy."
    log "Note: existing installation tokens remain valid up to 1 hour."
else
    err "Lobwife health check failed after rotation. Check pod logs."
    exit 1
fi
```

Key details:
- Reads `GH_APP_ID` and `GH_APP_INSTALL_ID` from existing secrets file (they don't change during PEM rotation)
- Uses `kubectl create secret --dry-run=client -o yaml | kubectl apply -f -` to upsert the secret
- During migration (before Phase 4 is complete), also update `lobmob-secrets` if that's where the PEM lives
- Restarts lobwife and waits for rollout to complete before verifying
- Environment-aware: `--env dev` targets the dev cluster/secrets

#### 5.4 Register commands in CLI dispatcher

**File**: `scripts/lobmob`

Add `setup`, `setup-github`, and `setup-rotate-pem` commands to the case statement and usage text. The `setup` subcommands use a nested dispatch pattern:

```bash
setup)
    SETUP_CMD="${1:-}"
    shift || true
    case "$SETUP_CMD" in
        ""|wizard)    source "$SCRIPT_DIR/commands/setup.sh" ;;
        github)       source "$SCRIPT_DIR/commands/setup-github.sh" ;;
        rotate-pem)   source "$SCRIPT_DIR/commands/setup-rotate-pem.sh" ;;
        *)            err "Unknown setup command: $SETUP_CMD"; exit 1 ;;
    esac
    ;;
```

**Commit checkpoint**: "Add lobmob setup and lobmob setup github commands"

---

### Phase 6: Testing & Verification

#### 6.1 Update `lobmob verify lobwife` for broker checks

Add to `scripts/commands/verify.sh`:
- Broker health (is PEM loaded?)
- Task registration round-trip
- Token generation (if PEM configured)
- Audit log

#### 6.2 End-to-end test on dev

1. `lobmob setup github` — create App (or use existing)
2. Install App on vault-dev + a test project repo
3. Deploy lobwife with PEM key
4. Manually register a task: `curl -X POST .../api/tasks/test-123/register -d '{"repos": ["minsley/lobmob-vault-dev"]}'`
5. Manually request token: `curl -X POST .../api/token -d '{"task_id": "test-123"}'`
6. Use token to clone repo: `git clone https://x-access-token:TOKEN@github.com/minsley/lobmob-vault-dev.git`
7. Post a task in Discord #task-queue → verify lobboss registers with lobwife → lobster uses credential helper
8. For long-task test: set a lobster's task timeout to 2h, verify token refreshes work

#### 6.3 Verify old path still works (backward compatibility)

During Phase 1-2, the old PEM injection path must continue working. Verify by deploying with both paths available and confirming lobsters that don't have `LOBWIFE_URL` fall back to the old `GH_TOKEN` env var.

---

## File Summary

### New files

| File | Description |
|------|-------------|
| `scripts/git-credential-lobwife` | Git credential helper (bash) |
| `scripts/commands/setup.sh` | Interactive bootstrap wizard |
| `scripts/commands/setup-github.sh` | GitHub App manifest flow |
| `scripts/commands/setup-rotate-pem.sh` | Emergency PEM key rotation |

### Modified files

| File | Changes |
|------|---------|
| `scripts/server/lobwife-daemon.py` | Add TokenBroker class + HTTP routes |
| `scripts/server/lobwife-web.js` | Add broker status to dashboard |
| `scripts/commands/verify.sh` | Add broker verification checks |
| `scripts/lobmob` | Register setup, setup-github, setup-rotate-pem commands |
| `src/lobboss/mcp_tools.py` | Task registration + replace PEM with LOBWIFE_URL |
| `src/lobster/run_task.py` | Configure git credential helper |
| `containers/lobwife/requirements.txt` | Add PyJWT, cryptography |
| `containers/lobwife/Dockerfile` | Add git-credential-lobwife |
| `containers/lobster/Dockerfile` | Add git-credential-lobwife |
| `containers/lobsigliere/Dockerfile` | Add git-credential-lobwife |
| `k8s/base/lobboss-deployment.yaml` | Add LOBWIFE_URL env var |
| `k8s/base/lobwife-deployment.yaml` | Add lobwife-secrets ref |
| `secrets.env.example` | Update for new secret structure |

### Commit sequence

1. "Add token broker to lobwife daemon" (Phase 1)
2. "Add git-credential-lobwife to container images" (Phase 2)
3. "Wire lobboss to lobwife token broker" (Phase 3)
4. "Isolate PEM key to lobwife-only secret" (Phase 4)
5. "Add lobmob setup and lobmob setup github commands" (Phase 5)
6. "Add broker verification and end-to-end tests" (Phase 6)

## Dependencies

- `PyJWT` and `cryptography` Python packages (for RS256 JWT generation)
- No new infrastructure — all changes are to existing services
- GitHub App must be installed on target repos (setup wizard handles this)
- lobwife must be reachable from lobster pods via ClusterIP service (already is — port 8081)
