---
name: ssh-command
description: Execute a command on a lobster via SSH over the WireGuard tunnel
---

# SSH Command

Use this when Discord communication is insufficient -- for health checks, log
retrieval, emergency process management, or when a lobster is unresponsive on
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

**Read lobster logs:**
```bash
ssh root@10.0.0.3 "tail -50 /var/log/cloud-init-output.log"
```

**Check OpenClaw status:**
```bash
ssh root@10.0.0.3 "systemctl status openclaw 2>/dev/null || ps aux | grep openclaw"
```

**Read vault state on lobster:**
```bash
ssh root@10.0.0.3 "cd /opt/vault && git status && git log --oneline -5"
```

**Emergency kill a runaway process:**
```bash
ssh root@10.0.0.3 "pkill -f openclaw"
```

**Pull latest vault on lobster:**
```bash
ssh root@10.0.0.3 "cd /opt/vault && git checkout main && git pull origin main"
```

## When to Use SSH vs Discord
| Scenario | Use |
|---|---|
| Assign a task | Discord |
| Check if lobster is alive | SSH (ping first, then SSH) |
| Lobster not responding on Discord | SSH |
| Read detailed logs | SSH |
| Force-pull vault updates | SSH |
| Emergency process management | SSH |
| Normal task communication | Discord |

## Connectivity Check
Before SSH, verify WireGuard connectivity:
```bash
ping -c 1 -W 3 <wireguard_ip>
```
If ping fails, the lobster may be down or WireGuard misconfigured. Check the
droplet status via `doctl compute droplet get <name>`.
