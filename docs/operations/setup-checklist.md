# Setup Checklist

Everything you need to configure before running `lobmob deploy`.

## Important: Secret Management

Secrets are **never stored in Terraform state or cloud-init user_data**.
Two config files are used:

| File | Contains | Committed to git? |
|---|---|---|
| `infra/terraform.tfvars` | Non-secret infra config (region, sizing, vault repo, WG public key) | No (gitignored) |
| `secrets.env` | All secrets (API tokens, private keys) | No (gitignored) |

The `lobmob deploy` command creates infrastructure via Terraform (secret-free),
then pushes secrets to the manager via SSH. Workers receive secrets from the
manager via SSH over WireGuard — never via cloud-init.

---

## DigitalOcean

### Account & API
- [ ] Create a DigitalOcean account (or use existing)
- [ ] Generate a **Personal Access Token** with full read/write scope
  - Control Panel → API → Tokens → Generate New Token
  - Save as `DO_TOKEN` in `secrets.env`

### SSH Key
- [ ] Generate an Ed25519 keypair (if you don't have one):
  ```bash
  ssh-keygen -t ed25519 -C "lobmob" -f ~/.ssh/id_ed25519
  ```
- [ ] Note the path to the public key — goes in `ssh_pub_key_path` in `terraform.tfvars`
  - Terraform uploads this key to DO and injects it into all droplets
  - You do NOT need to manually add it in the DO control panel

### Region Selection
- [ ] Choose a region for your swarm (e.g. `nyc3`, `sfo3`, `ams3`, `fra1`)
  - Pick one close to you for lower SSH latency
  - All droplets (manager + workers) will be in this region
  - Set as `region` in `terraform.tfvars`

---

## GitHub

### Vault Repository
- [ ] Decide on a repo name for the shared vault (e.g. `yourorg/lobmob-vault`)
  - The `lobmob vault-init` command creates this for you — just have the name ready
  - Set as `vault_repo` in `terraform.tfvars`

### Fine-Grained Personal Access Token
- [ ] Create a fine-grained PAT scoped to the vault repo
  - GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens
  - **Resource owner**: your user or org
  - **Repository access**: Only select repositories → select the vault repo
  - **Permissions needed**:
    - **Contents**: Read and write (push branches, read files)
    - **Pull requests**: Read and write (create PRs, read/post comments)
    - **Metadata**: Read (required by default)
  - Save as `GH_TOKEN` in `secrets.env`

### Deploy Key (for server-side git over SSH)
- [ ] Generate a dedicated deploy keypair:
  ```bash
  ssh-keygen -t ed25519 -C "lobmob-deploy" -f ~/.ssh/lobmob_deploy -N ""
  ```
- [ ] Add the **public** key as a deploy key on the vault repo:
  - Vault repo → Settings → Deploy keys → Add deploy key
  - Title: `lobmob-swarm`
  - Check "Allow write access"
  - Paste contents of `~/.ssh/lobmob_deploy.pub`
- [ ] Base64-encode the **private** key and save in `secrets.env`:
  ```bash
  base64 < ~/.ssh/lobmob_deploy
  # Copy output into VAULT_DEPLOY_KEY_B64 in secrets.env
  ```

---

## Discord

### Bot Application
- [ ] Create a Discord Application
  - Discord Developer Portal → New Application → name it `lobmob`
- [ ] Create a Bot user
  - Application → Bot → Add Bot
- [ ] Copy the bot token
  - Bot → Reset Token → Copy
  - Save as `DISCORD_BOT_TOKEN` in `secrets.env`
- [ ] Enable required intents:
  - Bot → Privileged Gateway Intents:
    - **Message Content Intent** — ON (needed to read task messages)
    - **Server Members Intent** — ON (optional, for @mentions)

### Server Setup
- [ ] Create a Discord server (or use existing)
- [ ] Create four text channels:
  - `#task-queue` — where humans post work requests
  - `#swarm-control` — manager-worker coordination
  - `#results` — workers post PR announcements
  - `#swarm-logs` — manager posts fleet events
- [ ] Invite the bot to the server:
  - Developer Portal → OAuth2 → URL Generator
  - Scopes: `bot`
  - Bot Permissions: `Send Messages`, `Read Message History`, `Embed Links`, `Attach Files`, `Use Slash Commands`
  - Copy the generated URL, open in browser, select your server
- [ ] Note the channel IDs (needed for OpenClaw config post-deploy):
  - Enable Developer Mode: User Settings → Advanced → Developer Mode
  - Right-click each channel → Copy Channel ID

---

## Anthropic

### API Key
- [ ] Generate an API key from the Anthropic Console
  - console.anthropic.com → API Keys → Create Key
  - Save as `ANTHROPIC_API_KEY` in `secrets.env`
- [ ] Ensure your account has sufficient credits/billing set up

---

## Local Tools

### Required
- [ ] **Terraform** >= 1.5
  ```bash
  brew install terraform    # macOS
  ```
- [ ] **GitHub CLI** (`gh`)
  ```bash
  brew install gh           # macOS
  gh auth login
  ```
- [ ] **WireGuard tools** (for key generation during `lobmob init`)
  ```bash
  brew install wireguard-tools   # macOS
  ```

### Recommended
- [ ] **doctl** (for direct DO API access if needed)
  ```bash
  brew install doctl
  doctl auth init
  ```
- [ ] **Obsidian** (for browsing the vault locally)
  - Download from obsidian.md
  - After `lobmob vault-sync`, open `vault-local/` as a vault
- [ ] **jq** (used by some scripts)
  ```bash
  brew install jq
  ```

---

## Running `lobmob init`

Once all the above are ready:

```bash
cd lobmob
chmod +x scripts/lobmob
./scripts/lobmob init
```

This will:
1. Generate WireGuard manager keypair
2. Create `infra/terraform.tfvars` with the WG public key (fill in `vault_repo`)
3. Create `secrets.env` with the WG private key (fill in all tokens)
4. Run `terraform init`

---

## Pre-Flight Verification

Before deploying, verify:

- [ ] `infra/terraform.tfvars` has `vault_repo` and `wg_manager_public_key` set
- [ ] `secrets.env` has all 6 values filled (no placeholders)
- [ ] `gh auth status` succeeds
- [ ] Discord bot is in the server and channels exist
- [ ] Vault repo exists on GitHub (run `lobmob vault-init` if not)
- [ ] Deploy key is added to the vault repo with write access

Then: `./scripts/lobmob deploy`

The deploy command will:
1. Run `terraform plan` and ask for confirmation
2. Create the droplet (secret-free cloud-init)
3. Wait for SSH connectivity
4. Wait for cloud-init to complete
5. Push secrets via SSH
6. Run the provision script on the manager
