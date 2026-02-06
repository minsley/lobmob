# Deployment Guide

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5
- [doctl](https://docs.digitalocean.com/reference/doctl/how-to/install/) (DigitalOcean CLI)
- [gh](https://cli.github.com/) (GitHub CLI)
- [wg](https://www.wireguard.com/install/) (WireGuard tools — for key generation)
- A DigitalOcean account with API token
- A GitHub account with fine-grained PAT
- A Discord bot application with token

## Step 1: Initialize

```bash
cd lobmob
chmod +x scripts/lobmob
./scripts/lobmob init
```

This generates WireGuard keys and creates `infra/terraform.tfvars` from the
example. Fill in all values:

| Variable | Where to get it |
|---|---|
| `do_token` | DO Control Panel → API → Personal Access Tokens |
| `gh_token` | GitHub → Settings → Developer settings → Fine-grained PATs |
| `discord_bot_token` | Discord Developer Portal → Bot → Token |
| `anthropic_api_key` | Anthropic Console → API Keys |
| `vault_repo` | The org/repo name you'll use (created in step 2) |
| `vault_deploy_key_private` | Base64 of an SSH private key added as deploy key |

## Step 2: Create the Vault Repo

```bash
./scripts/lobmob vault-init
```

This creates the GitHub repo and seeds it with the vault structure from
`vault-seed/`.

## Step 3: Deploy the Manager

```bash
./scripts/lobmob deploy
```

Terraform creates:
- VPC in your chosen region
- Cloud firewalls for manager and workers
- Manager droplet with cloud-init bootstrap

Wait 3-5 minutes for cloud-init to complete. Check progress:
```bash
./scripts/lobmob logs
```

## Step 4: Verify

```bash
./scripts/lobmob ssh-manager
# On the manager:
wg show wg0          # WireGuard interface up
gh auth status        # GitHub authenticated
doctl account get     # DO API working
ls /opt/vault/        # Vault cloned
```

## Step 5: Configure Discord

1. Invite the bot to your Discord server
2. Create channels: `#task-queue`, `#swarm-control`, `#results`, `#swarm-logs`
3. Configure OpenClaw channel bindings in `/root/.openclaw/config.json` on the manager

## Step 6: Test a Worker

```bash
./scripts/lobmob spawn test01
./scripts/lobmob status
```

Verify the worker appears in WireGuard peers, responds to ping, and joins
Discord.

## Tearing Down

```bash
./scripts/lobmob destroy
```

This destroys all workers first, then the manager, VPC, and firewalls.
