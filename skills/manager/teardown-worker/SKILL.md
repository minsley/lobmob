---
name: teardown-worker
description: Destroy a worker droplet and remove it from the WireGuard mesh
---

# Teardown Worker

Use this skill to decommission a worker that has finished its tasks or is misbehaving.

## Steps

1. Run the teardown script:
   ```bash
   lobmob-teardown-worker <worker-name>
   ```
   where `<worker-name>` is the droplet name like `lobmob-worker-a3f1`.

2. The script will:
   - Remove the worker's WireGuard peer from the manager
   - Destroy the DigitalOcean droplet

3. Update the fleet registry:
   - Remove or mark the worker entry as `offline` in `/opt/vault/040-fleet/registry.md`
   - Commit and push to main

4. Announce in **#swarm-logs**:
   ```
   Worker <worker-id> decommissioned. Droplet destroyed.
   ```

## When to Teardown
- Worker has been idle for more than 30 minutes with no pending tasks
- Worker failed to respond to a health check (ping or SSH) after 3 retries
- Worker reported a fatal error
- The automatic cleanup cron handles workers older than 2 hours, but you can teardown earlier

## Bulk Teardown
To destroy all workers at once:
```bash
source /etc/lobmob/env
doctl compute droplet delete-by-tag "$WORKER_TAG" --force
```
