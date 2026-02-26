# Testing

Test scripts live in `tests/` and verify deployments and the task lifecycle.

## Quick Reference

| Script | What it tests | Duration | Requires cluster? |
|---|---|---|---|
| `tests/episode-loop` | Multi-turn episode loop (7 scenarios: pass, fail-retry, max turns, SDK error, inject) | ~2s | No (mocked) |
| `tests/ipc-server` | LobsterIPC server (health, inject, SSE headers) | ~3s | No (local Python) |
| `tests/push-task` | Push a task to the vault | ~5s | Yes |
| `tests/await-task-pickup <id> [<id>...]` | Lobboss assigns queued tasks, k8s Job created | up to 10m | Yes |
| `tests/await-task-completion <id>` | Full lifecycle: PR opened, merged, task completed | up to 15m | Yes |
| `tests/e2e-task` | Full E2E: push → pickup → execution → PR → completion | configurable (default 10m) | Yes |
| `tests/event-logging` | Event log+flush functions, vault export, event types | ~30s | Yes |

All scripts exit 0 on success, 1 on failure. Use `LOBMOB_ENV=dev` to target the dev cluster.

## Unit Tests (no cluster needed)

```bash
python3 tests/episode-loop   # multi-turn episode loop (mocks Agent SDK)
tests/ipc-server              # IPC server smoke test (starts local Python process)
```

These run locally without a k8s cluster. `episode-loop` mocks `claude_agent_sdk` in `sys.modules` since the real SDK is only in containers.

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

## Local Testing (k3d)

For fast iteration without cloud costs:

```bash
# Set up local cluster
lobmob --env local cluster-create
lobmob --env local build all
lobmob --env local apply
lobmob --env local status

# Create a test task via the lobwife API
kubectl --context k3d-lobmob-local -n lobmob port-forward svc/lobwife 8081:8081 &
curl -X POST http://localhost:8081/api/v1/tasks \
  -H 'Content-Type: application/json' \
  -d '{"name": "Test task description", "type": "swe", "status": "queued"}'

# Watch the lobster run
lobmob --env local status              # see the job appear
lobmob --env local logs <job-name>     # tail lobster logs
lobmob --env local attach <job-name>   # live event stream + inject
```

The task poller picks up queued tasks within 60s and spawns a lobster Job. The multi-turn episode loop runs up to 5 episodes with verification between each.

## Event Logging

```bash
tests/event-logging              # full test (writes a test event, flushes to vault)
tests/event-logging --no-flush   # skip vault write (infrastructure + static checks only)
```

Checks: lobmob-log and lobmob-flush-logs scripts exist, cron active, log format correct, vault export works, all 8 event types ([spawn], [destroy], [sleep], [wake], [converge], [cleanup], [boot], [ready]) wired into scripts, pre-sleep/pre-destroy flush wired in, lobster-side logging in spawn userdata.
