---
name: task-fail
description: Handle task failure — mark failed, close PRs, decide on re-creation
---

# Task Failure

When a lobster reports failure or the task-manager cron detects a timeout/orphan:

1. Update the task frontmatter: `status: failed`
2. Add failure notes under `## Lobster Notes` if not already documented
3. The `lobmob-task-watcher` cron will move it to `010-tasks/failed/` and post to Discord
4. Close any orphaned PR for that task:
   ```bash
   gh pr close <number> --comment "Task failed/timed out"
   ```

## Re-Creation Decision

After a failure, decide whether to re-create the task:
- **Transient failure** (lobster crashed, network issue): Create a new task referencing the failed one
- **Inherent difficulty** (task is too complex, unclear requirements): Discuss with the user first
- **Repeated failures**: Investigate root cause before re-queuing

If re-creating, include a note in the new task: `Previous attempt: <failed-task-id> — <reason for failure>`
