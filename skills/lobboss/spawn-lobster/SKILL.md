---
name: spawn-lobster
description: Provision a new lobster droplet and add it to the WireGuard mesh
---

# Spawn Lobster

Use this skill when you need to create a new lobster to handle tasks.

## Before Spawning — Check the Pool First

Before creating a brand-new lobster, check if a standby lobster is available:
```bash
lobmob-fleet-status   # check Pool State section
```

If there are standby lobsters, **wake one instead of spawning**:
```bash
lobmob-wake-lobster <lobster-name>
```
Waking takes ~1-2 minutes vs 5-8 minutes for a fresh spawn.

The `lobmob-pool-manager` handles this automatically, but when you need a
lobster urgently, you can wake one manually.

See the **pool-management** skill for full details.

## Steps (Fresh Spawn)

1. Decide on a lobster ID (short hex string, e.g. `a3f1`) or accept the auto-generated one
2. Run the spawn script:
   ```bash
   lobmob-spawn-lobster <lobster-id>
   ```
3. The script will:
   - Generate a WireGuard keypair for the lobster
   - Create a DigitalOcean droplet with cloud-init that installs OpenClaw, WireGuard, git, and gh CLI
   - Add the lobster as a WireGuard peer on this lobboss
   - Return JSON with the lobster's droplet ID, public IP, and WireGuard IP

4. Wait 2-3 minutes for cloud-init to complete on the lobster
5. Verify connectivity:
   ```bash
   ping -c 3 <wireguard_ip>
   ssh root@<wireguard_ip> "echo ok"
   ```

6. Update the fleet registry:
   - Edit `/opt/vault/040-fleet/registry.md` to add the new lobster entry
   - Commit and push to main

7. Announce in **#swarm-control**:
   ```
   Lobster <lobster-id> online at <wireguard_ip> (droplet <droplet_id>).
   Ready for task assignment.
   ```

## When to Spawn
- Queue depth in #task-queue exceeds current lobster count
- A task is tagged `high` or `critical` priority and no idle lobsters exist
- Current lobsters are all busy (in_progress tasks)

## Limits
- Maximum 10 concurrent lobsters (cost safety)
- Check `lobmob-fleet-status` before spawning to avoid duplicates
