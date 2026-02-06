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
| `lobmob init` | Generate WireGuard keys, create terraform.tfvars, run terraform init |
| `lobmob deploy` | Plan and apply Terraform to create the manager droplet |
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

## Environment

The CLI reads configuration from `infra/terraform.tfvars` and Terraform
state. Ensure you've run `lobmob init` and `lobmob deploy` first.

## Dependencies

- terraform >= 1.5
- doctl
- gh (GitHub CLI)
- wg (wireguard-tools)
- ssh
- jq
