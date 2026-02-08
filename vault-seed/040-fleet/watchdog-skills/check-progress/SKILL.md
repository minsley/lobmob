---
name: check-progress
description: Check active lobsters for gateway activity and report staleness
---

# Check Progress

Run this every time you are triggered. Follow these steps exactly.

## 1. Read the Fleet Registry

```bash
cat /opt/vault/040-fleet/registry.md
```

Find all lobsters with `status` = `online`. Extract their `wg_ip` and lobster name.
If no lobsters are online, stop here — nothing to check.

## 2. Read Active Task Files

```bash
ls /opt/vault/010-tasks/active/
```

For each `.md` file, read it and check the frontmatter for:
- `status: active`
- `assigned_to` is set to a lobster name
- `discord_thread_id` is present

Build a list of (task-id, lobster-name, wg_ip, discord_thread_id) tuples.
If no active tasks with assigned lobsters, stop here.

## 3. Check Each Active Lobster

For each active lobster+task pair:

### 3a. Verify connectivity
```bash
ping -c 1 -W 3 <wg_ip>
```
If ping fails, skip SSH and flag as unreachable (see step 4).

### 3b. Check gateway log recency
```bash
ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
  root@<wg_ip> \
  "tail -1 /tmp/openclaw-gateway.log 2>/dev/null || echo NO_LOG"
```

### 3c. Parse the timestamp

The gateway log line starts with an ISO timestamp (e.g. `2026-02-07T15:30:00.000Z`).
Extract it and calculate minutes since last activity:

```bash
ssh -i /root/.ssh/lobster_admin -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
  root@<wg_ip> bash -c '
    LAST=$(tail -1 /tmp/openclaw-gateway.log 2>/dev/null)
    if [ -z "$LAST" ]; then echo STALE_999; exit; fi
    TS=$(echo "$LAST" | grep -oP "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}" | head -1)
    if [ -z "$TS" ]; then echo STALE_999; exit; fi
    LAST_EPOCH=$(date -d "$TS" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    DIFF=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
    echo MINUTES_$DIFF
  '
```

### 3d. Classify

- **Active**: `MINUTES_N` where N < 10 → lobster is working. Do nothing.
- **Stale**: `MINUTES_N` where N >= 10 → flag (see step 4)
- **Unreachable**: Ping failed or SSH failed → flag (see step 4)
- **No log**: `NO_LOG` or `STALE_999` → flag as potentially not started

## 4. Report Stale/Unreachable Lobsters

For each stale or unreachable lobster, post in **two** places:

### 4a. Task thread warning

Use the `message` tool:

For stale lobsters:
```json
{
  "action": "thread-reply",
  "channel": "discord",
  "threadId": "<discord_thread_id>",
  "text": "WATCHDOG: <lobster-name> appears stale on task <task-id> — no gateway activity for <N> minutes."
}
```

For unreachable lobsters:
```json
{
  "action": "thread-reply",
  "channel": "discord",
  "threadId": "<discord_thread_id>",
  "text": "WATCHDOG: <lobster-name> unreachable (ping failed) on task <task-id>."
}
```

### 4b. Swarm-logs alert

```json
{
  "action": "send",
  "channel": "discord",
  "to": "channel:1469216945764175946",
  "text": "WATCHDOG: <lobster-name> stale — no gateway activity for <N> min (task <task-id>)"
}
```

## 5. Done

If all lobsters are active and healthy, produce no output. Do NOT post "all clear"
messages. Silence means everything is fine.
