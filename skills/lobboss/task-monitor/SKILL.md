---
name: task-monitor
description: Timeout detection and stall alerts for active tasks
---

# Task Monitoring

**Note:** Routine timeout detection is now handled by the `lobmob-task-manager` cron every 5 minutes. This skill documents the logic for reference and for manual intervention.

## Timeout Thresholds

For each active task:
- If `estimate` is set: **warning** at `estimate + 15` min, **failure** at `estimate * 2` min
- If `estimate` is empty: **warning** at 45 min, **failure** at 90 min

## Exceptions

Do NOT flag as timed out if:
- An open PR exists for the task (lobster is in review phase)
- The lobster has posted a recent progress update

## Manual Intervention

If the cron has posted a failure alert and the lobster appears unresponsive:
1. SSH to the lobster to check if it's still working:
   ```bash
   ssh -i /root/.ssh/lobster_admin root@<wg_ip> "ps aux | grep openclaw; tail -5 /var/log/openclaw-gateway.log"
   ```
2. If the lobster is dead, the task-manager cron will detect it as an orphan and handle recovery
3. If the lobster is alive but stuck, consider killing the agent and re-triggering
