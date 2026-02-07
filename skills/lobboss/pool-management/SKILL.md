---
name: pool-management
description: Manage the warm pool of lobster droplets (active, idle, standby)
---

# Pool Management

The lobster pool keeps pre-provisioned lobsters available so tasks can start
quickly instead of waiting 5-8 minutes for a fresh spawn.

## Pool States

| State | DO Status | Meaning |
|---|---|---|
| **active-busy** | active | Running, assigned to a task |
| **active-idle** | active | Running, no task, ready for instant assignment |
| **standby** | off | Powered off, disk preserved, ~1-2 min to wake |

## Pool Config

Set in `/etc/lobmob/env`:
- `POOL_ACTIVE` — number of idle lobsters to keep running (default: 1)
- `POOL_STANDBY` — number of powered-off lobsters to keep on hand (default: 2)

Adjust via the local CLI: `lobmob pool active 2 standby 3`

## How It Works

The `lobmob-pool-manager` runs every 5 minutes via cron and reconciles:

1. If active-idle < POOL_ACTIVE → wake a standby or spawn a new lobster
2. If active-idle > POOL_ACTIVE → sleep excess idle lobsters
3. If standby > POOL_STANDBY → destroy oldest excess
4. If pool is underfilled → spawn new lobsters to fill
5. Any lobster older than 24h is destroyed regardless of state

## Config Versioning

Each lobster stores a config version hash at `/etc/lobmob/config-version`
(the md5sum of the spawn script at the time it was created). When waking a
standby lobster, the pool manager checks this version. If it doesn't match
the current spawn script, the stale lobster is destroyed and a fresh one
is spawned instead.

## When to Manually Adjust the Pool

- **Before a burst of tasks**: increase POOL_ACTIVE so lobsters are ready
- **During quiet periods**: set POOL_ACTIVE=0 POOL_STANDBY=1 to save costs
- **After changing the spawn script**: stale standby lobsters will be
  automatically replaced on next pool-manager run

## Tools

- `lobmob-pool-manager` — run the reconciliation loop manually
- `lobmob-sleep-lobster <name>` — power off a specific lobster
- `lobmob-wake-lobster <name>` — power on a specific standby lobster
- `lobmob-cleanup` — pool-aware cleanup (sleep excess idle, destroy excess standby)
- `lobmob-fleet-status` — shows pool state and config
