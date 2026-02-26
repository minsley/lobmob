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
lobmob <command>                     # uses prod environment (default)
lobmob --env dev <command>           # uses dev environment (staging)
lobmob --env local <command>         # uses local k3d cluster
LOBMOB_ENV=dev lobmob <command>      # alternative env selection
```

## Commands

### Infrastructure

| Command | Description |
|---|---|
| `lobmob deploy` | Terraform apply + kubectl apply (creates cluster + deploys services) |
| `lobmob destroy` | Tear down DOKS cluster and all resources |
| `lobmob apply` | Apply k8s manifests + push secrets (no terraform) |
| `lobmob build <target>` | Build container image (`base\|lobboss\|lobwife\|lobsigliere\|lobster\|all`) |

### Local Development (k3d)

| Command | Description |
|---|---|
| `lobmob --env local cluster-create` | Create k3d cluster with labeled nodes (auto-installs Docker, Colima, k3d) |
| `lobmob --env local cluster-delete` | Delete local k3d cluster |
| `lobmob --env local build all` | Native docker build + k3d image import (`:local` tag) |
| `lobmob --env local apply` | Apply local overlay + push secrets |

### Fleet Management

| Command | Description |
|---|---|
| `lobmob status` | Show pods, jobs, and open PRs |
| `lobmob connect` | Port-forward to lobboss web dashboard (localhost:8080) |
| `lobmob connect lobsigliere` | Port-forward SSH to lobsigliere (localhost:2222) |
| `lobmob connect <job-name>` | Port-forward to a lobster's web sidecar |
| `lobmob attach <job-name>` | Live attach to a running lobster: SSE event stream + inject prompt |
| `lobmob logs` | Tail lobboss pod logs |
| `lobmob logs <job-name>` | Tail a specific lobster's logs |
| `lobmob restart` | Rollout restart deployments |
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
| `secrets-local.env` | Local secrets (copy from dev) | Yes (`secrets-*.env` glob) |
| `infra/prod.tfvars` | Prod Terraform config | Yes |
| `infra/dev.tfvars` | Dev Terraform config | Yes |

## Dependencies

- terraform >= 1.5
- kubectl
- gh (GitHub CLI)
- docker with buildx
- jq
