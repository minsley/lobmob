# Daily Operations

## Checking Fleet Status

```bash
./scripts/lobmob status
```

Or from any machine with SSH access:
```bash
ssh root@<lobboss-ip> lobmob-fleet-status
```

## Spawning Lobsters

```bash
./scripts/lobmob spawn              # auto-generated ID
./scripts/lobmob spawn mycustomid   # specific ID
```

The lobboss agent also spawns lobsters autonomously when tasks queue up.

## Pool Management

The lobster pool keeps pre-provisioned lobsters available for fast task startup.
Idle lobsters are powered off to standby (~1-2 min wake) instead of destroyed.

```bash
./scripts/lobmob pool                            # show pool config and state
./scripts/lobmob pool active 2 standby 3         # adjust pool sizes
./scripts/lobmob sleep-lobster lobster-a3f1      # power off a lobster to standby
./scripts/lobmob wake-lobster lobster-a3f1       # wake a standby lobster
```

The `lobmob-pool-manager` runs every 5 minutes on lobboss and automatically:
- Wakes standby lobsters or spawns new ones to maintain POOL_ACTIVE idle lobsters
- Sleeps excess idle lobsters beyond POOL_ACTIVE
- Destroys excess standby lobsters beyond POOL_STANDBY
- Destroys any lobster older than 24h

Check pool manager logs: `ssh root@<lobboss-ip> tail -f /var/log/lobmob-pool-manager.log`

## Tearing Down Lobsters

Prefer sleeping over tearing down — sleeping preserves the disk for fast wake.

```bash
./scripts/lobmob teardown lobster-a3f1          # permanently destroy a lobster
./scripts/lobmob teardown-all                     # destroy all lobsters
./scripts/lobmob cleanup                          # pool-aware cleanup (sleep idle, destroy excess)
```

## Submitting Tasks

Post in **#task-queue** on Discord. Lobboss replies with a formatted task proposal
for your confirmation. Reply **go** to approve, **cancel** to discard, or describe
changes. The task file is only created after you confirm.
Or use the test script (bypasses the confirmation flow):

```bash
tests/push-task --title "Research X" --objective "Find information about X and write it up..."
```

Or create a task file manually:

```bash
./scripts/lobmob ssh-lobboss
# Then on lobboss:
cd /opt/vault
cp .obsidian/templates/task.md 010-tasks/active/task-$(date +%Y-%m-%d)-$(openssl rand -hex 2).md
# Edit the file, then:
git add -A && git commit -m "[lobboss] Create task" && git push origin main
```

## Triggering Agents

To make lobboss assign a task:
```bash
# SSH to lobboss, then:
source /etc/lobmob/secrets.env
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY openclaw agent --agent main \
  --message "Assign task-XXXX to lobster-YYYY"
```

To make a lobster execute an assigned task:
```bash
# SSH to lobster (via ProxyJump), then:
source /etc/lobmob/secrets.env
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY openclaw agent --agent main \
  --message "Execute your assigned task task-XXXX"
```

The gateway must be running on the node for this to work. See [[operations/openclaw-setup]].

## Reviewing PRs

The lobboss does this automatically, but you can also review manually:

```bash
./scripts/lobmob prs                      # list open PRs
gh pr view <number> --repo <vault-repo>   # view a specific PR
gh pr merge <number> --repo <vault-repo>  # merge manually
```

## Syncing the Vault Locally

```bash
./scripts/lobmob vault-sync
```

Then open `vault-local/` in Obsidian.

## SSH to a Lobster

```bash
./scripts/lobmob ssh-lobster 10.0.0.3         # by WireGuard IP
./scripts/lobmob ssh-lobster lobster-a3f1      # by lobster ID (resolved via registry)
```

## Event Logging

All operational events (spawns, sleeps, wakes, destroys, convergence) are logged to `/var/log/lobmob-events.log` on each node. Every 15 minutes a cron job flushes the local log into the vault at `020-logs/`.

**Log format:**
```
2026-02-07T03:14:00+00:00 [spawn] lobster-a3f1 droplet=549933580 wg_ip=10.0.0.9
2026-02-07T03:20:00+00:00 [sleep] lobster-a3f1 droplet=549933580
2026-02-07T03:25:00+00:00 [converge] active=2 standby=1 total=3
```

**Viewing logs:**
```bash
# Local event log on lobboss
ssh root@<lobboss-ip> cat /var/log/lobmob-events.log

# Flushed logs in vault
ls vault-local/020-logs/lobboss/
ls vault-local/020-logs/lobsters/lobster-*/
```

**Manual flush:**
```bash
./scripts/lobmob flush-logs              # flush lobboss logs to vault
ssh root@<lobboss-ip> lobmob-flush-logs  # same, directly
```

Logs are also flushed automatically before sleep and destroy (best-effort for destroys).

## Monitoring

- **Discord #swarm-logs** — fleet events in real time
- **Lobboss logs**: `./scripts/lobmob logs`
- **Event log**: `ssh root@<lobboss-ip> cat /var/log/lobmob-events.log`
- **PR review log**: `ssh root@<lobboss-ip> tail -f /var/log/lobmob-pr-review.log`
- **Vault history**: `cd vault-local && git log --oneline`
