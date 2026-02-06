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

## Tearing Down Lobsters

```bash
./scripts/lobmob teardown lobster-a3f1          # specific lobster
./scripts/lobmob teardown-all                     # all lobsters
./scripts/lobmob cleanup 1                        # lobsters older than 1 hour
```

## Submitting Tasks

Post in **#task-queue** on Discord. The lobboss picks it up and handles
assignment. Or use the test script:

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

## Monitoring

- **Discord #swarm-logs** — fleet events in real time
- **Lobboss logs**: `./scripts/lobmob logs`
- **PR review log**: `ssh root@<lobboss-ip> tail -f /var/log/lobmob-pr-review.log`
- **Vault history**: `cd vault-local && git log --oneline`
