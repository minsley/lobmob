# Testing

Test scripts live in `tests/` and verify deployments and the task lifecycle.

## Quick Reference

| Script | What it tests | Duration |
|---|---|---|
| `tests/smoke-lobboss` | Lobboss health (14 checks) | ~10s |
| `tests/smoke-lobster <ip>` | Lobster health (12 checks) | ~15s |
| `tests/push-task` | Push a task to the vault | ~5s |
| `tests/await-task-pickup <id> [<id>...]` | Lobboss assigns queued tasks | up to 10m |
| `tests/await-task-completion <id>` | Full lifecycle: PR opened, merged, task completed | up to 15m |
| `tests/event-logging` | Event log+flush functions, vault export, event types | ~30s |

All scripts exit 0 on success, 1 on failure.

## Smoke Tests

### Lobboss

```bash
tests/smoke-lobboss
```

Checks: SSH reachable, cloud-init complete, WireGuard up, tools installed (gh, doctl, node, openclaw), secrets provisioned, vault cloned, git identity, OpenClaw config, crons.

### Lobster

```bash
tests/smoke-lobster 10.0.0.3           # by WireGuard IP
tests/smoke-lobster lobster-swift-coral  # by lobster name (resolved via fleet registry)
```

Checks: WireGuard ping (from lobboss), SSH (via ProxyJump), WireGuard interface, tools (gh, node, openclaw), secrets, vault, OpenClaw config, AGENTS.md, git identity.

## Task Lifecycle Tests

### Push a Task

```bash
tests/push-task                                         # default haiku task
tests/push-task --title "My task" --objective "Do X"    # custom
```

Clones/pulls `vault-local/`, creates a task file in `010-tasks/active/`, commits, and pushes to main. Prints the task ID.

### Await Task Pickup

```bash
tests/await-task-pickup task-2026-02-06-d67f
tests/await-task-pickup --timeout 5 task-1 task-2    # multiple tasks, 5m timeout
```

Polls the vault for each task to transition from `status: queued` to `status: active` with an `assigned_to` value. Verifies assigned lobsters exist in the fleet.

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

```bash
# 1. Verify lobboss is healthy
tests/smoke-lobboss

# 2. Spawn a lobster and verify
lobmob spawn test01
tests/smoke-lobster test01

# 3. Set up OpenClaw on the lobster (see [[operations/openclaw-setup]])
#    Then push a task
tests/push-task --title "Write a haiku" --objective "Write a haiku about the sea..."

# 4. Trigger lobboss to assign the task (or wait for it to notice)
# 5. Trigger lobster agent to execute (or wait for Discord message)
# 6. Verify completion
tests/await-task-completion task-YYYY-MM-DD-XXXX
```

Note: Steps 4 and 5 currently require manually triggering the agents via `openclaw agent --message "..."` on each node. See [[operations/openclaw-setup]] for details.

## Event Logging

```bash
tests/event-logging              # full test (writes a test event, flushes to vault)
tests/event-logging --no-flush   # skip vault write (infrastructure + static checks only)
```

Checks: lobmob-log and lobmob-flush-logs scripts exist, cron active, log format correct, vault export works, all 8 event types ([spawn], [destroy], [sleep], [wake], [converge], [cleanup], [boot], [ready]) wired into scripts, pre-sleep/pre-destroy flush wired in, lobster-side logging in spawn userdata.
