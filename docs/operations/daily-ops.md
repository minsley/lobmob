# Daily Operations

## Checking Fleet Status

```bash
./scripts/lobmob status
```

Or from any machine with SSH access:
```bash
ssh root@<manager-ip> lobmob-fleet-status
```

## Spawning Workers

```bash
./scripts/lobmob spawn              # auto-generated ID
./scripts/lobmob spawn mycustomid   # specific ID
```

The manager agent also spawns workers autonomously when tasks queue up.

## Tearing Down Workers

```bash
./scripts/lobmob teardown lobmob-worker-a3f1    # specific worker
./scripts/lobmob teardown-all                     # all workers
./scripts/lobmob cleanup 1                        # workers older than 1 hour
```

## Submitting Tasks

Post in **#task-queue** on Discord. The manager picks it up and handles
assignment. Or create a task file directly:

```bash
./scripts/lobmob ssh-manager
# Then on manager:
cd /opt/vault
cp .obsidian/templates/task.md 010-tasks/active/task-$(date +%Y-%m-%d)-$(openssl rand -hex 2).md
# Edit the file, then:
git add -A && git commit -m "[manager] Create task" && git push origin main
```

## Reviewing PRs

The manager does this automatically, but you can also review manually:

```bash
./scripts/lobmob prs                      # list open PRs
gh pr view <number> --repo <vault-repo>   # view a specific PR
gh pr merge <number> --repo <vault-repo>  # merge manually
```

## Syncing the Vault Locally

```bash
./scripts/lobmob vault-sync
```

Then open `vault-local/` in Obsidian.

## SSH to a Worker

```bash
./scripts/lobmob ssh-worker 10.0.0.3       # by WireGuard IP
./scripts/lobmob ssh-worker worker-a3f1     # by worker ID (resolved via registry)
```

## Monitoring

- **Discord #swarm-logs** — fleet events in real time
- **Manager logs**: `./scripts/lobmob logs`
- **PR review log**: `ssh root@<manager-ip> tail -f /var/log/lobmob-pr-review.log`
- **Vault history**: `cd vault-local && git log --oneline`
