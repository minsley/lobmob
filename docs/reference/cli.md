# lobmob CLI Reference

The `lobmob` script is the primary interface for managing the swarm from
your local machine.

## Setup
```bash
chmod +x scripts/lobmob
# Symlink to PATH
ln -s $(pwd)/scripts/lobmob /usr/local/bin/lobmob
```

## Environment Selection

```bash
lobmob <command>                   # uses prod environment (default)
lobmob --env dev <command>         # uses dev environment
LOBMOB_ENV=dev lobmob <command>    # alternative env selection
```

## Commands

### Infrastructure

| Command | Description |
|---|---|
| `lobmob deploy` | Terraform apply + kubectl apply (creates cluster + deploys services) |
| `lobmob destroy` | Tear down DOKS cluster and all resources |

### Fleet Management

| Command | Description |
|---|---|
| `lobmob status` | Show pods, jobs, CronJobs, and open PRs |
| `lobmob connect` | Port-forward to lobboss web dashboard (localhost:8080) |
| `lobmob connect lobsigliere` | Port-forward SSH to lobsigliere (localhost:2222) |
| `lobmob connect <job-name>` | Port-forward to a lobster's web sidecar |
| `lobmob logs` | Tail lobboss pod logs |
| `lobmob logs <job-name>` | Tail a specific lobster's logs |
| `lobmob flush-logs` | Flush event logs to vault |
| `lobmob prs` | List open PRs on the vault repo |

### Vault

| Command | Description |
|---|---|
| `lobmob vault-init` | Create the GitHub vault repo and seed it |
| `lobmob vault-sync` | Clone or pull the vault to `vault-local/` |

## Configuration Files

| File | Purpose | Gitignored? |
|---|---|---|
| `secrets.env` | Prod secrets (API tokens, keys) | Yes |
| `secrets-dev.env` | Dev secrets | Yes |
| `infra/prod.tfvars` | Prod Terraform config | Yes |
| `infra/dev.tfvars` | Dev Terraform config | Yes |

## Dependencies

- terraform >= 1.5
- kubectl
- gh (GitHub CLI)
- docker with buildx
- jq
