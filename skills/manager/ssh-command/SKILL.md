---
name: ssh-command
description: Execute a command on a worker via SSH over the WireGuard tunnel
---

# SSH Command

Use this when Discord communication is insufficient — for health checks, log
retrieval, emergency process management, or when a worker is unresponsive on
Discord.

## Usage

```bash
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new root@<wireguard_ip> "<command>"
```

## Examples

**Health check:**
```bash
ssh root@10.0.0.3 "uptime && docker ps && wg show wg0"
```

**Read worker logs:**
```bash
ssh root@10.0.0.3 "tail -50 /var/log/cloud-init-output.log"
```

**Check OpenClaw status:**
```bash
ssh root@10.0.0.3 "systemctl status openclaw 2>/dev/null || ps aux | grep openclaw"
```

**Read vault state on worker:**
```bash
ssh root@10.0.0.3 "cd /opt/vault && git status && git log --oneline -5"
```

**Emergency kill a runaway process:**
```bash
ssh root@10.0.0.3 "pkill -f openclaw"
```

**Pull latest vault on worker:**
```bash
ssh root@10.0.0.3 "cd /opt/vault && git checkout main && git pull origin main"
```

## When to Use SSH vs Discord
| Scenario | Use |
|---|---|
| Assign a task | Discord |
| Check if worker is alive | SSH (ping first, then SSH) |
| Worker not responding on Discord | SSH |
| Read detailed logs | SSH |
| Force-pull vault updates | SSH |
| Emergency process management | SSH |
| Normal task communication | Discord |

## Connectivity Check
Before SSH, verify WireGuard connectivity:
```bash
ping -c 1 -W 3 <wireguard_ip>
```
If ping fails, the worker may be down or WireGuard misconfigured. Check the
droplet status via `doctl compute droplet get <name>`.
