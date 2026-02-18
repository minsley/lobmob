# Setup Checklist

Everything you need to configure before running `lobmob deploy`.

## Secret Management

Two layers of secrets:

| Location | Contains | Committed to git? |
|---|---|---|
| `secrets.env` (prod) / `secrets-dev.env` (dev) | API tokens, keys | No (gitignored) |
| k8s Secret `lobmob-secrets` | Same tokens, deployed to cluster | Created by `lobmob deploy` |
| `infra/prod.tfvars` / `infra/dev.tfvars` | Non-secret infra config | No (gitignored) |

The `lobmob deploy` command creates the DOKS cluster via Terraform, then creates
k8s Secrets and applies manifests via kubectl.

---

## DigitalOcean

### Account & API
- [ ] Create a DigitalOcean account (or use existing)
- [ ] Generate a **Personal Access Token** with full read/write scope
  - Control Panel -> API -> Tokens -> Generate New Token
  - Save as `DO_TOKEN` in `secrets.env`
  - Also export as `DIGITALOCEAN_TOKEN` for Terraform

---

## GitHub

### Vault Repository
- [ ] Decide on a repo name for the shared vault (e.g. `yourorg/lobmob-vault`)
  - The `lobmob vault-init` command creates this for you
  - Dev environment uses a separate repo (e.g. `lobmob-vault-dev`)

### GitHub App (required)
- [ ] Create a GitHub App (Settings -> Developer settings -> GitHub Apps)
  - **Permissions**: Contents (R/W), Pull requests (R/W), Metadata (R)
  - **Repository access**: All repositories the App is installed on (vault, vault-dev, lobmob)
  - **Webhook**: Uncheck "Active" (not needed)
- [ ] Install the App on your account/org
- [ ] Download the private key PEM file
  - Base64-encode: `base64 -w0 < your-app.pem`
  - Save as `GH_APP_PEM_B64` in `secrets.env`
- [ ] Note the App ID and Installation ID
  - Save as `GH_APP_ID` and `GH_APP_INSTALL_ID` in `secrets.env`

The lobwife token broker generates ephemeral tokens on-demand. All containers use the `gh-lobwife` wrapper for automatic token refresh. See [Token Management](token-management.md) for details.

---

## Discord

### Bot Application
- [ ] Create a Discord Application
  - Discord Developer Portal -> New Application -> name it `lobmob`
- [ ] Create a Bot user (Application -> Bot -> Add Bot)
- [ ] Copy the bot token -> save as `DISCORD_BOT_TOKEN` in `secrets.env`
- [ ] Enable required intents:
  - Bot -> Privileged Gateway Intents:
    - **Message Content Intent** — ON
    - **Server Members Intent** — ON (optional)

### Server Setup
- [ ] Create a Discord server (or use existing)
- [ ] Create three text channels:
  - `#task-queue` — task lifecycle (threads per task)
  - `#swarm-control` — user commands to lobboss
  - `#swarm-logs` — fleet events (post-only)
- [ ] Invite the bot to the server:
  - Developer Portal -> OAuth2 -> URL Generator
  - Scopes: `bot`
  - Bot Permissions: `Send Messages`, `Read Message History`, `Embed Links`, `Attach Files`, `Use Slash Commands`
- [ ] Note the channel IDs (right-click -> Copy Channel ID with Developer Mode on)

---

## Anthropic

### API Key
- [ ] Generate an API key from the Anthropic Console
  - console.anthropic.com -> API Keys -> Create Key
  - Save as `ANTHROPIC_API_KEY` in `secrets.env`
- [ ] Ensure your account has sufficient credits/billing set up

---

## Local Tools

### Required
- [ ] **Terraform** >= 1.5
  ```bash
  brew install terraform
  ```
- [ ] **kubectl**
  ```bash
  brew install kubectl
  ```
- [ ] **GitHub CLI** (`gh`)
  ```bash
  brew install gh && gh auth login
  ```
- [ ] **Docker** with buildx support (for building container images)
  ```bash
  # Colima or Docker Desktop
  brew install colima docker docker-buildx
  colima start
  # Create an amd64 builder (DOKS nodes are amd64, Mac is ARM)
  docker buildx create --name amd64-builder --use
  ```

### Recommended
- [ ] **doctl** (for direct DO API access if needed)
  ```bash
  brew install doctl && doctl auth init
  ```
- [ ] **Obsidian** (for browsing the vault locally)
- [ ] **jq** (used by some scripts)
  ```bash
  brew install jq
  ```

---

## Configuration Files

Create from examples:

```bash
cp secrets.env.example secrets.env
cp infra/prod.tfvars.example infra/prod.tfvars
# For dev environment:
cp secrets.env.example secrets-dev.env
cp infra/dev.tfvars.example infra/dev.tfvars
```

### secrets.env

```bash
DO_TOKEN=dop_v1_...
DIGITALOCEAN_TOKEN=dop_v1_...   # same as DO_TOKEN, used by Terraform
GH_APP_ID=123456
GH_APP_INSTALL_ID=789012
GH_APP_PEM_B64=base64...        # base64-encoded PEM (lobwife broker uses this)
DISCORD_BOT_TOKEN=MTIz...
ANTHROPIC_API_KEY=sk-ant-...
```

### terraform.tfvars

```hcl
region     = "nyc3"
cluster_name = "lobmob-k8s"
```

---

## Pre-Flight Verification

Before deploying, verify:

- [ ] `secrets.env` has all required values filled
- [ ] `infra/prod.tfvars` is configured
- [ ] `gh auth status` succeeds
- [ ] Discord bot is in the server and channels exist
- [ ] Vault repo exists on GitHub (run `lobmob vault-init` if not)
- [ ] Docker buildx works: `docker buildx ls` shows an amd64-capable builder
- [ ] kubectl context exists: `kubectl config get-contexts`

Then: `lobmob deploy`
