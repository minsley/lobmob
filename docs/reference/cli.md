# lobmob CLI Reference

The `lobmob` script is the primary interface for managing the swarm from
your local machine.

## Setup
```bash
chmod +x scripts/lobmob
# Optional: symlink to PATH
ln -s $(pwd)/scripts/lobmob /usr/local/bin/lobmob
```

## Commands

### Infrastructure

| Command | Description |
|---|---|
| `lobmob init` | Generate WireGuard keys, create terraform.tfvars + secrets.env, run terraform init |
| `lobmob deploy` | Terraform apply + wait for SSH + push secrets + provision manager |
| `lobmob provision-secrets` | Re-push secrets to manager (e.g. after key rotation) |
| `lobmob destroy` | Tear down ALL infrastructure (workers + manager + VPC) |

### Fleet Management

| Command | Description |
|---|---|
| `lobmob spawn [id]` | Spawn a new worker (auto or named ID) |
| `lobmob teardown <name>` | Destroy a specific worker by droplet name |
| `lobmob teardown-all` | Destroy all worker droplets |
| `lobmob status` | Show WireGuard peers, active droplets, open PRs |
| `lobmob cleanup [hours]` | Destroy workers older than N hours (default: 2) |

### Vault

| Command | Description |
|---|---|
| `lobmob vault-init` | Create the GitHub vault repo and seed it |
| `lobmob vault-sync` | Clone or pull the vault to `vault-local/` |

### SSH

| Command | Description |
|---|---|
| `lobmob ssh-manager` | SSH into the manager droplet |
| `lobmob ssh-worker <ip-or-id>` | SSH into a worker via manager ProxyJump |

### Utilities

| Command | Description |
|---|---|
| `lobmob logs` | Tail manager cloud-init logs |
| `lobmob prs` | List open PRs on the vault repo |

## Configuration Files

| File | Purpose | Gitignored? |
|---|---|---|
| `infra/terraform.tfvars` | Non-secret infra config (region, sizing, vault repo) | Yes |
| `secrets.env` | All secrets (API tokens, private keys) | Yes |

The CLI reads `secrets.env` for secret operations and Terraform state for
the manager IP. Run `lobmob init` to generate both config files.

## Dependencies

- terraform >= 1.5
- doctl
- gh (GitHub CLI)
- wg (wireguard-tools)
- ssh
- jq
