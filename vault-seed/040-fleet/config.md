---
updated:
---

# Swarm Configuration

## Scaling Rules
| Parameter | Value |
|---|---|
| Max concurrent lobsters | 10 |
| Idle timeout (minutes) | 30 |
| Stale cleanup (hours) | 2 |
| Auto-scale threshold | Queue depth > active lobsters |

## Model Routing
| Task type | Model |
|---|---|
| Default | claude-sonnet-4-5 |
| Complex reasoning | claude-opus-4-6 |
| Simple formatting | claude-haiku-4-5 |

## Droplet Sizing
| Role | Size | Monthly |
|---|---|---|
| Lobboss | s-2vcpu-4gb | $24 |
| Lobster | s-1vcpu-2gb | $12 (per-second billing) |

## Discord Channels
| Channel | Purpose |
|---|---|
| #task-queue | Task lifecycle — one parent message per task, all updates in threads |
| #swarm-control | User commands to lobboss for fleet management |
| #swarm-logs | Fleet events — spawns, merges, convergence, teardowns, status |
