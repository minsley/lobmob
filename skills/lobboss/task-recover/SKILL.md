---
name: task-recover
description: Detect and recover orphaned tasks assigned to offline lobsters
---

# Orphan Task Recovery

**Note:** Routine orphan detection is now handled by the `lobmob-task-manager` cron every 5 minutes. This skill documents the logic and handles edge cases the cron can't resolve.

## Detection

An orphaned task is one where `status: active` and `assigned_to` references a lobster that no longer exists (not in active or standby droplet list).

## Automatic Recovery (cron)

The `lobmob-task-manager` cron applies this decision table:
- **Has open PR** → leave as-is, note in thread that lobster is offline
- **No PR, assigned < 30 min ago** → re-queue (clear assigned_to/assigned_at)
- **No PR, assigned >= 30 min ago** → mark as failed

## Manual Intervention

For edge cases the cron can't handle:
1. **Partial work on a branch**: Check if the lobster pushed any commits:
   ```bash
   git ls-remote origin "lobster-*/task-<task-id>"
   ```
   If partial work exists, decide whether to create a new task that builds on it.

2. **Ambiguous lobster state**: The lobster might be transitioning (waking, rebooting). Check DO API:
   ```bash
   doctl compute droplet list --format Name,Status,Created | grep <lobster-name>
   ```

3. **Repeated failures**: If a task keeps getting orphaned, investigate the root cause (lobster OOM, network issues, etc.) rather than just re-queuing.
