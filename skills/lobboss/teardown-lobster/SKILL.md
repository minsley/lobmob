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
- Lobster failed to respond to a health check (ping or SSH) after 3 retries
- Lobster reported a fatal error or is misbehaving
- Lobster has a stale config version (the pool manager handles this automatically)
- The pool manager destroys standby lobsters beyond POOL_STANDBY and any lobster older than 24h

## Bulk Teardown
To destroy all lobsters at once:
```bash
source /etc/lobmob/env
doctl compute droplet delete-by-tag "$LOBSTER_TAG" --force
```
