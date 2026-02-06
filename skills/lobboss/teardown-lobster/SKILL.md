---
name: teardown-lobster
description: Destroy a lobster droplet and remove it from the WireGuard mesh
---

# Teardown Lobster

Use this skill to decommission a lobster that has finished its tasks or is misbehaving.

## Steps

1. Run the teardown script:
   ```bash
   lobmob-teardown-lobster <lobster-name>
   ```
   where `<lobster-name>` is the droplet name like `lobmob-lobster-a3f1`.

2. The script will:
   - Remove the lobster's WireGuard peer from the lobboss
   - Destroy the DigitalOcean droplet

3. Update the fleet registry:
   - Remove or mark the lobster entry as `offline` in `/opt/vault/040-fleet/registry.md`
   - Commit and push to main

4. Announce in **#swarm-logs**:
   ```
   Lobster <lobster-id> decommissioned. Droplet destroyed.
   ```

## When to Teardown
- Lobster has been idle for more than 30 minutes with no pending tasks
- Lobster failed to respond to a health check (ping or SSH) after 3 retries
- Lobster reported a fatal error
- The automatic cleanup cron handles lobsters older than 2 hours, but you can teardown earlier

## Bulk Teardown
To destroy all lobsters at once:
```bash
source /etc/lobmob/env
doctl compute droplet delete-by-tag "$LOBSTER_TAG" --force
```
