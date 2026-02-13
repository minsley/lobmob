# Daily Operations

## Checking Fleet Status

```bash
lobmob status
```

Shows pods, jobs, open PRs, and CronJob status.

Or directly via kubectl:
```bash
kubectl -n lobmob get pods                     # lobboss + lobsigliere pods
kubectl -n lobmob get jobs                     # active/completed lobster jobs
kubectl -n lobmob get cronjobs                 # scheduled jobs
```

## Connecting to Services

```bash
lobmob connect                                 # port-forward to lobboss web dashboard
lobmob connect lobsigliere                     # port-forward SSH to lobsigliere
lobmob connect <job-name>                      # port-forward to lobster sidecar dashboard
```

SSH to lobsigliere after connecting:
```bash
ssh -p 2222 engineer@localhost
```

## Viewing Logs

```bash
lobmob logs                                    # tail lobboss logs
lobmob logs <job-name>                         # tail a specific lobster's logs
```

Or directly:
```bash
kubectl -n lobmob logs deploy/lobboss -f
kubectl -n lobmob logs deploy/lobsigliere -f
kubectl -n lobmob logs job/<job-name> -c lobster -f
```

## Submitting Tasks

Post in **#task-queue** on Discord. Lobboss replies with a task proposal and opens a
thread for discussion. Reply **go** in the thread to approve, **cancel** to discard,
or describe changes. The task file is only created after you confirm. All subsequent
updates (assignment, progress, results) appear in the same thread.

### System Tasks

For infrastructure and tooling changes, create a task with `type: system` in the vault.
Lobsigliere's background daemon picks these up automatically every 30 seconds — no
lobster spawn needed.

The daemon scans `010-tasks/active/*.md` for files with:
- `type: system`
- `status: queued`

It claims the task (sets `status: system-active`), executes via Agent SDK, and submits
a PR to `develop`.

### Manual Task Creation

From lobsigliere:
```bash
cd ~/vault
cat > 010-tasks/active/task-$(date +%Y-%m-%d)-$(openssl rand -hex 2).md << 'TASK'
---
id: task-2026-02-13-xxxx
type: swe
status: queued
created: 2026-02-13T10:00:00Z
repo: lobmob
priority: normal
---

## Objective

Description of the task...
TASK

git add -A && git commit -m "[manual] Create task" && git push origin main
```

## Reviewing PRs

Lobboss reviews PRs automatically. You can also review manually:

```bash
lobmob prs                                     # list open PRs
gh pr view <number> --repo minsley/lobmob      # view a specific PR
gh pr merge <number> --repo minsley/lobmob     # merge manually
```

## Syncing the Vault Locally

```bash
lobmob vault-sync
```

Then open `vault-local/` in Obsidian for a browsable view of tasks, logs, and knowledge.

## Flushing Logs

Logs are flushed to the vault automatically every 15 minutes by the `flush-logs` CronJob.

Manual flush:
```bash
lobmob flush-logs
```

## Restarting Services

```bash
# Restart lobboss (e.g., after config change)
kubectl -n lobmob rollout restart deployment/lobboss

# Restart lobsigliere (picks up new image + daemon code)
kubectl -n lobmob rollout restart deployment/lobsigliere

# Check rollout status
kubectl -n lobmob rollout status deployment/lobboss
```

## CronJob Management

View CronJob status and recent runs:
```bash
kubectl -n lobmob get cronjobs
kubectl -n lobmob get jobs -l app.kubernetes.io/part-of=lobmob --sort-by=.metadata.creationTimestamp
```

Manually trigger a CronJob:
```bash
kubectl -n lobmob create job --from=cronjob/task-manager task-manager-manual
```

## Monitoring

- **Discord #swarm-logs** — fleet events in real time
- **Lobboss logs**: `lobmob logs`
- **Lobsigliere logs**: `kubectl -n lobmob logs deploy/lobsigliere -f`
- **PR list**: `lobmob prs`
- **Vault history**: `cd vault-local && git log --oneline`
- **Pod resource usage**: `kubectl -n lobmob top pods`
