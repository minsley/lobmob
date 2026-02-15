# Testing

Test scripts live in `tests/` and verify deployments and the task lifecycle.

## Quick Reference

| Script | What it tests | Duration |
|---|---|---|
| `tests/push-task` | Push a task to the vault | ~5s |
| `tests/await-task-pickup <id> [<id>...]` | Lobboss assigns queued tasks, k8s Job created | up to 10m |
| `tests/await-task-completion <id>` | Full lifecycle: PR opened, merged, task completed | up to 15m |
| `tests/e2e-task` | Full E2E: push → pickup → execution → PR → completion | configurable (default 10m) |
| `tests/event-logging` | Event log+flush functions, vault export, event types | ~30s |

All scripts exit 0 on success, 1 on failure. Use `LOBMOB_ENV=dev` to target the dev cluster.

## Task Lifecycle Tests

### Push a Task

```bash
tests/push-task                                                   # default haiku task (research)
tests/push-task --title "My task" --objective "Do X"              # custom
tests/push-task --type swe --title "Fix bug" --objective "..."    # specify lobster type
LOBMOB_ENV=dev tests/push-task                                    # push to dev vault
```

Clones/pulls `vault-local/`, creates a task file in `010-tasks/active/` with `type:` in frontmatter, commits, and pushes to main. Prints the task ID.

### Await Task Pickup

```bash
tests/await-task-pickup task-2026-02-06-d67f
tests/await-task-pickup --timeout 5 task-1 task-2    # multiple tasks, 5m timeout
LOBMOB_ENV=dev tests/await-task-pickup task-2026-02-14-abcd
```

Polls the vault for each task to transition from `status: queued` to `status: active` with an `assigned_to` value. Verifies the assigned lobster k8s Job exists and checks pod phase via kubectl.

### Await Task Completion

```bash
tests/await-task-completion task-2026-02-06-d67f
tests/await-task-completion --timeout 20 task-2026-02-06-d67f
```

Polls for three stages:
1. **PR opened** — lobster pushes a branch and creates a pull request
2. **PR merged** — lobboss reviews and merges the PR
3. **Task completed** — task file in the vault has `status: completed`

## Running the Full E2E Flow

### Automated (recommended)

```bash
# Run the entire lifecycle in one command
LOBMOB_ENV=dev tests/e2e-task

# Custom task with longer timeout
LOBMOB_ENV=dev tests/e2e-task --type swe --title "Fix the bug" --objective "..." --timeout 20

# Default haiku smoke test against prod
tests/e2e-task
```

The `e2e-task` script runs all 6 stages automatically: push task → await pickup → watch k8s Job → wait for PR merge → verify task completion. It evaluates results (frontmatter fields, Result/Notes sections filled in, output file for the default haiku task) and reports per-stage timing.

### Manual (step by step)

```bash
# 1. Check fleet status
lobmob --env dev status

# 2. Push a test task
LOBMOB_ENV=dev tests/push-task --title "Write a haiku" --objective "Write a haiku about the sea..."

# 3. Wait for lobboss to assign and spawn a lobster
LOBMOB_ENV=dev tests/await-task-pickup task-YYYY-MM-DD-XXXX

# 4. Wait for full completion (PR + merge + vault update)
LOBMOB_ENV=dev tests/await-task-completion task-YYYY-MM-DD-XXXX

# 5. Check lobster logs if needed
lobmob --env dev logs <job-name>
```

The task poller in lobboss automatically picks up queued tasks and spawns lobster Jobs. No manual triggering needed.

## Event Logging

```bash
tests/event-logging              # full test (writes a test event, flushes to vault)
tests/event-logging --no-flush   # skip vault write (infrastructure + static checks only)
```

Checks: lobmob-log and lobmob-flush-logs scripts exist, cron active, log format correct, vault export works, all 8 event types ([spawn], [destroy], [sleep], [wake], [converge], [cleanup], [boot], [ready]) wired into scripts, pre-sleep/pre-destroy flush wired in, lobster-side logging in spawn userdata.
