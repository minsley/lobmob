# Deployment Guide

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5
- [gh](https://cli.github.com/) (GitHub CLI)
- [wg](https://www.wireguard.com/install/) (WireGuard tools — for key generation)
- A DigitalOcean account with API token
- A GitHub account with fine-grained PAT
- A Discord bot application with token

See [[operations/setup-checklist]] for complete setup instructions.

## Step 1: Initialize

```bash
cd lobmob
chmod +x scripts/lobmob
./scripts/lobmob init
```

This generates WireGuard keys and creates two config files:

| File | What to fill in |
|---|---|
| `infra/terraform.tfvars` | `vault_repo` (WG public key auto-filled) |
| `secrets.env` | `DO_TOKEN`, `GH_TOKEN`, `DISCORD_BOT_TOKEN`, `ANTHROPIC_API_KEY`, `VAULT_DEPLOY_KEY_B64` (WG private key auto-filled) |

## Step 2: Create the Vault Repo

```bash
./scripts/lobmob vault-init
```

This creates the GitHub repo and seeds it with the vault structure from
`vault-seed/`.

## Step 3: Deploy the Lobboss

```bash
./scripts/lobmob deploy
```

This runs a fully automated sequence:
1. `terraform plan` → shows resources to create (VPC, firewalls, droplet)
2. Asks for confirmation
3. `terraform apply` → creates the droplet with secret-free cloud-init
4. Waits for SSH connectivity (~1-2 min)
5. Waits for cloud-init to finish (~3-5 min)
6. Pushes secrets via SSH:
   - `/etc/lobmob/secrets.env` (API tokens)
   - `/root/.ssh/vault_key` (deploy key)
   - `/etc/wireguard/wg0.conf` (WG private key)
7. Runs `lobmob-provision` on the lobboss (authenticates gh, doctl, clones vault, configures OpenClaw)

**No secrets ever appear in Terraform state or cloud-init user_data.**

## Step 4: Verify

Run the automated smoke test:
```bash
tests/smoke-lobboss
```

Or check manually:
```bash
./scripts/lobmob ssh-lobboss
# On the lobboss:
wg show wg0          # WireGuard interface up
gh auth status        # GitHub authenticated
doctl account get     # DO API working
ls /opt/vault/        # Vault cloned
cat /etc/lobmob/.awaiting-secrets  # Should not exist (file removed after provisioning)
```

## Step 5: Configure OpenClaw + Discord

1. Invite the bot to your Discord server (if not done during setup)
2. Create channels: `#task-queue`, `#swarm-control`, `#results`, `#swarm-logs`
3. Set up OpenClaw on the lobboss — see [[operations/openclaw-setup]] for the full procedure

## Step 6: Test a Lobster

```bash
./scripts/lobmob spawn test01
./scripts/lobmob status
```

The spawn process:
1. Lobboss creates a droplet with secret-free cloud-init (WireGuard + packages)
2. Waits for WireGuard connectivity over the mesh
3. Waits for cloud-init to complete
4. SSHes into the lobster over WireGuard to push secrets
5. Authenticates gh, clones vault, configures OpenClaw

Verify with the smoke test:
```bash
tests/smoke-lobster 10.0.0.3
```

Then set up OpenClaw on the lobster — see [[operations/openclaw-setup]].

For full end-to-end testing, see [[operations/testing]].

## Re-Provisioning Secrets

After rotating tokens or API keys, update `secrets.env` and re-push:

```bash
./scripts/lobmob provision-secrets
```

This SSHes into the lobboss and re-runs the full provision flow. Lobsters will
need to be respawned to pick up new secrets.

## Tearing Down

```bash
./scripts/lobmob destroy
```

This destroys all lobsters first, then the lobboss, VPC, and firewalls.
