---
name: fleet-status
description: Check the health and status of the entire swarm
---

# Fleet Status

Run this periodically or when asked about the state of the swarm.

## Quick Status
```bash
lobmob-fleet-status
```

This shows WireGuard peers, active worker droplets, and open PRs.

## Detailed Health Check

### 1. List all workers
```bash
source /etc/lobmob/env
doctl compute droplet list --tag-name "$WORKER_TAG" --format ID,Name,PublicIPv4,Status,Memory,VCPUs,Created --no-header
```

### 2. Ping all WireGuard peers
```bash
for ip in $(wg show wg0 allowed-ips | awk '{print $2}' | cut -d/ -f1); do
  echo -n "$ip: "
  ping -c 1 -W 2 "$ip" > /dev/null 2>&1 && echo "UP" || echo "DOWN"
done
```

### 3. Check task pipeline
```bash
cd /opt/vault
echo "Queued:    $(ls 010-tasks/active/*.md 2>/dev/null | grep -c 'status: queued' || echo 0)"
echo "Active:    $(ls 010-tasks/active/*.md 2>/dev/null | grep -c 'status: active' || echo 0)"
echo "Completed: $(ls 010-tasks/completed/*.md 2>/dev/null | wc -l)"
echo "Failed:    $(ls 010-tasks/failed/*.md 2>/dev/null | wc -l)"
```

### 4. Open PRs
```bash
gh pr list --state open --json number,title,headRefName,createdAt
```

### 5. Cost estimate
Count active worker-hours and estimate current burn rate based on droplet sizes.

## Report to Discord

After gathering status, post a summary to **#swarm-logs**:
```
Fleet Status @ HH:MM
Workers: N active, M healthy
Tasks: X queued, Y active, Z completed today
Open PRs: N
Est. cost today: $X.XX
```

## Update Registry

Keep `/opt/vault/040-fleet/registry.md` in sync with actual state:
- Add new workers when spawned
- Mark unreachable workers
- Remove destroyed workers
Commit and push after changes.
