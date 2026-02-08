---
name: teardown-lobster
description: Destroy a lobster droplet and remove it from the WireGuard mesh
---

# Teardown Lobster

Use this skill to decommission a lobster that has finished its tasks or is misbehaving.

## Prefer Sleeping Over Destroying

If the lobster is healthy but just idle, **sleep it** instead of tearing it down:
```bash
lobmob-sleep-lobster <lobster-name>
```

Sleeping powers off the droplet but preserves its disk. It can be woken in ~1-2
minutes, much faster than a fresh spawn (5-8 min). The pool manager handles
this automatically — only use teardown for permanent removal.

**When to teardown (destroy permanently):**
- Lobster is misbehaving or unresponsive after retries
- Lobster has a stale config version
- You need to free up the droplet slot (max 10 limit)
- Lobster is older than the 24h hard ceiling

## Steps

1. **Check for assigned tasks** before destroying anything:
   ```bash
   cd /opt/vault && git pull origin main
   grep -rl "assigned_to: <lobster-name>" 010-tasks/active/ 2>/dev/null
   ```
   For each task assigned to this lobster:
   - Check for an open PR: `gh pr list --state open --json number,headRefName | grep "<task-id>"`
   - **If a PR exists:** Leave the task alone — the PR can still be reviewed and merged
   - **If no PR and active < 30 min:** Re-queue the task (see "Re-queue a Task" below)
   - **If no PR and active >= 30 min:** Fail the task (see task-lifecycle skill "Failing a Task")

2. Run the teardown script:
   ```bash
   lobmob-teardown-lobster <lobster-name>
   ```
   where `<lobster-name>` is the droplet name like `lobster-swe-001-salty-squidward`.

3. The script will:
   - Remove the lobster's WireGuard peer from the lobboss
   - Destroy the DigitalOcean droplet

4. Update the fleet registry:
   - Remove or mark the lobster entry as `offline` in `/opt/vault/040-fleet/registry.md`
   - Commit and push to main

5. Announce in **#swarm-logs**:
   ```
   **[lobboss]** Lobster <lobster-id> decommissioned. Droplet destroyed.
   ```

## When to Teardown
- Lobster failed to respond to a health check (ping or SSH) after 3 retries
- Lobster reported a fatal error or is misbehaving
- Lobster has a stale config version (the pool manager handles this automatically)
- The pool manager destroys standby lobsters beyond POOL_STANDBY and any lobster older than 24h

## Re-queue a Task

When a task needs to be re-assigned because its lobster was torn down:

1. Update the task frontmatter:
   ```yaml
   status: queued
   assigned_to:
   assigned_at:
   ```
2. Add a note under `## Lobster Notes`: `Re-queued: <lobster-name> was torn down before completion.`
3. Commit and push to main
4. Post in the **task's thread** (using `discord_thread_id`):
   ```
   **[lobboss]** Task <task-id> re-queued — <lobster-name> was torn down. Will reassign to another lobster.
   ```
5. Assign the task to another lobster (follow the task-lifecycle skill "Assigning a Task")

## Bulk Teardown
To destroy all lobsters at once:
```bash
source /etc/lobmob/env
doctl compute droplet delete-by-tag "$LOBSTER_TAG" --force
```
