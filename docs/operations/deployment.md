# Deployment Guide

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [gh](https://cli.github.com/) (GitHub CLI)
- [Docker](https://www.docker.com/) with buildx (for image builds)
- A DigitalOcean account with API token
- A GitHub App installation (for token broker — see [Setup Checklist](setup-checklist.md))
- A Discord bot application with token

See [[operations/setup-checklist]] for complete setup instructions.

## Step 1: Create the Vault Repo

```bash
lobmob vault-init
```

Creates the GitHub repo and seeds it with the vault structure from `vault-seed/`.

## Step 2: Deploy Infrastructure + Services

```bash
lobmob deploy
```

This runs a fully automated sequence:
1. Loads secrets from `secrets.env`
2. Runs `terraform apply` to create the DOKS cluster
3. Configures kubectl context for the new cluster
4. Creates k8s namespace, secrets, and config maps
5. Applies all k8s manifests via `kubectl apply -k k8s/overlays/prod/`

For dev environment: `lobmob --env dev deploy`

### What Gets Created

| Resource | Type | Purpose |
|---|---|---|
| DOKS cluster | Terraform | Managed Kubernetes (free control plane) |
| `lobmob` namespace | k8s | All resources live here |
| `lobmob-secrets` | k8s Secret | Discord, Anthropic, DO tokens |
| `lobwife-secrets` | k8s Secret | GitHub App PEM + credentials (broker only) |
| `lobboss-config` | k8s ConfigMap | Environment config |
| `lobwife` | k8s Deployment | Token broker + scheduler daemon |
| `lobboss` | k8s Deployment | Manager agent |
| `lobsigliere` | k8s Deployment | Ops console + task daemon |
| CronJobs (5) | k8s CronJob | Automated maintenance tasks |
| ServiceAccounts (3) | k8s SA | RBAC for lobboss, lobster, lobsigliere |

Lobster Jobs are created dynamically by lobboss when tasks are assigned.

## Step 3: Build and Push Images

Images must be built for `linux/amd64` (DOKS node architecture):

```bash
# Build base image first
docker buildx build --builder amd64-builder --platform linux/amd64 \
  -t ghcr.io/minsley/lobmob-base:latest --push \
  -f containers/base/Dockerfile .

# Then lobboss, lobster, lobsigliere (all depend on base)
docker buildx build --builder amd64-builder --platform linux/amd64 \
  --build-arg BASE_IMAGE=ghcr.io/minsley/lobmob-base:latest \
  -t ghcr.io/minsley/lobmob-lobboss:latest --push \
  -f containers/lobboss/Dockerfile .

docker buildx build --builder amd64-builder --platform linux/amd64 \
  --build-arg BASE_IMAGE=ghcr.io/minsley/lobmob-base:latest \
  -t ghcr.io/minsley/lobmob-lobster:latest --push \
  -f containers/lobster/Dockerfile .

docker buildx build --builder amd64-builder --platform linux/amd64 \
  --build-arg BASE_IMAGE=ghcr.io/minsley/lobmob-base:latest \
  -t ghcr.io/minsley/lobmob-lobwife:latest --push \
  -f containers/lobwife/Dockerfile .

docker buildx build --builder amd64-builder --platform linux/amd64 \
  --build-arg BASE_IMAGE=ghcr.io/minsley/lobmob-base:latest \
  -t ghcr.io/minsley/lobmob-lobsigliere:latest --push \
  -f containers/lobsigliere/Dockerfile .
```

After pushing, restart deployments to pick up new images.
**Important**: lobwife must be restarted first (other services depend on the token broker at startup):
```bash
kubectl -n lobmob rollout restart deployment/lobwife
kubectl -n lobmob rollout status deployment/lobwife --timeout=60s
kubectl -n lobmob rollout restart deployment/lobboss deployment/lobsigliere
```

## Step 4: Verify

```bash
lobmob status
```

Or check manually:
```bash
kubectl -n lobmob get pods                    # all pods running
kubectl -n lobmob logs deploy/lobboss         # lobboss connected to Discord
kubectl -n lobmob logs deploy/lobsigliere     # sshd + daemon running
```

Connect to the lobboss web dashboard:
```bash
lobmob connect                                # port-forward to localhost:8080
```

SSH to lobsigliere:
```bash
lobmob connect lobsigliere                    # port-forward SSH
ssh -p 2222 engineer@localhost                # then SSH in
```

## Updating Secrets

After rotating tokens or API keys:

1. Update `secrets.env`
2. Re-apply the k8s Secret:
   ```bash
   lobmob deploy   # or manually recreate the secret
   ```
3. Restart deployments to pick up new values:
   ```bash
   kubectl -n lobmob rollout restart deployment/lobboss deployment/lobsigliere
   ```

Lobsters pick up secrets at spawn time (from the k8s Secret), so existing
jobs will use old tokens until they complete.

## Applying Manifest Changes

After modifying k8s manifests:

```bash
# Validate first
kubectl apply -k k8s/overlays/prod/ --dry-run=client

# Apply
kubectl apply -k k8s/overlays/prod/
```

For dev: `kubectl apply -k k8s/overlays/dev/`

## Tearing Down

```bash
lobmob destroy
```

This destroys the DOKS cluster and all resources within it.

## Environment-Specific Deployment

| | Prod | Dev |
|---|---|---|
| Command | `lobmob deploy` | `lobmob --env dev deploy` |
| Secrets file | `secrets.env` | `secrets-dev.env` |
| Terraform vars | `infra/prod.tfvars` | `infra/dev.tfvars` |
| TF workspace | `default` | `dev` |
| kubectl context | `do-nyc3-lobmob-k8s` | `do-nyc3-lobmob-dev-k8s` |
| k8s overlay | `k8s/overlays/prod/` | `k8s/overlays/dev/` |
