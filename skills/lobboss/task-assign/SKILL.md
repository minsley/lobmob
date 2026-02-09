---
name: task-assign
description: Select a lobster for a task and configure it for assignment
---

# Task Assignment

**Note:** Routine assignment is now handled by the `lobmob-task-manager` cron.
This skill is for manual assignment when the cron can't resolve (e.g., ambiguous
type matching, model conflicts, or when you need to override the automatic choice).

## Choosing a Lobster

Read the task's `type` field. **Only consider lobsters of the matching type.** Check lobster types by querying DO tags (`lobmob-type-<type>`).

Priority order:

1. **Active-idle lobster** — running, no current task, correct type. Immediate.
   - If multiple are idle, prefer one already configured with the task's model.

2. **Active-busy lobster** — running, correct type, already on a task. Only if:
   - The lobster's current model matches the new task's model.
   - The lobster's current task has an `estimate` of **30 min or less**.

3. **Standby lobster** — powered off, correct type. Run `lobmob-wake-lobster <name>` (~1-2 min).

4. **Spawn a new lobster** — takes 5-8 minutes. Run `lobmob-spawn-lobster <name> '' <type>`.
   - Only if no idle or standby lobsters of the correct type exist.
   - Respect `MAX_LOBSTERS` limit.

## Configuring the Model

If the task has a `model` set that differs from the chosen lobster's current model:
```bash
ssh -i /root/.ssh/lobster_admin root@<wg_ip> \
  "jq '.agents.defaults.model.primary = \"<model>\"' /root/.openclaw/openclaw.json > /tmp/oc.tmp && mv /tmp/oc.tmp /root/.openclaw/openclaw.json"
```

## Recording the Assignment

1. Update the task frontmatter: `status: active`, `assigned_to: lobster-<id>`, `assigned_at: <ISO timestamp>`
2. Commit and push to main
3. The `lobmob-task-watcher` cron will post the assignment to Discord automatically
