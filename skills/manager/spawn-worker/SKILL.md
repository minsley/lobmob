---
name: spawn-worker
description: Provision a new worker droplet and add it to the WireGuard mesh
---

# Spawn Worker

Use this skill when you need to create a new worker to handle tasks.

## Steps

1. Decide on a worker ID (short hex string, e.g. `a3f1`) or accept the auto-generated one
2. Run the spawn script:
   ```bash
   lobmob-spawn-worker <worker-id>
   ```
3. The script will:
   - Generate a WireGuard keypair for the worker
   - Create a DigitalOcean droplet with cloud-init that installs OpenClaw, WireGuard, git, and gh CLI
   - Add the worker as a WireGuard peer on this manager
   - Return JSON with the worker's droplet ID, public IP, and WireGuard IP

4. Wait 2-3 minutes for cloud-init to complete on the worker
5. Verify connectivity:
   ```bash
   ping -c 3 <wireguard_ip>
   ssh root@<wireguard_ip> "echo ok"
   ```

6. Update the fleet registry:
   - Edit `/opt/vault/040-fleet/registry.md` to add the new worker entry
   - Commit and push to main

7. Announce in **#swarm-control**:
   ```
   Worker <worker-id> online at <wireguard_ip> (droplet <droplet_id>).
   Ready for task assignment.
   ```

## When to Spawn
- Queue depth in #task-queue exceeds current worker count
- A task is tagged `high` or `critical` priority and no idle workers exist
- Current workers are all busy (in_progress tasks)

## Limits
- Maximum 10 concurrent workers (cost safety)
- Check `lobmob-fleet-status` before spawning to avoid duplicates
