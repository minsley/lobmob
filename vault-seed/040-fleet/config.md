---
updated:
---

# Swarm Configuration

## Scaling Rules
| Parameter | Value |
|---|---|
| Max concurrent lobsters | 10 |
| Job timeout (hours) | 2 |
| Job TTL after completion (hours) | 1 |
| Auto-scale threshold | Queue depth > active lobsters |

## Model Routing
| Task type | Model |
|---|---|
| research | claude-sonnet-4-5 |
| swe | claude-opus-4-6 |
| qa | claude-sonnet-4-5 |
| image-gen | claude-sonnet-4-5 |

## Infrastructure
| Component | Runtime |
|---|---|
| lobboss | k8s Deployment (DOKS) |
| lobsters | k8s Jobs (ephemeral) |
| lobwife | k8s Deployment (cron + broker) |
| lobsigliere | k8s Deployment (system tasks) |
| Images | GHCR (amd64) |

## Discord Channels
| Channel | Purpose |
|---|---|
| #task-queue | Task lifecycle — one parent message per task, all updates in threads |
| #swarm-control | User commands to lobboss for fleet management |
| #swarm-logs | Fleet events — spawns, merges, completions, status |
