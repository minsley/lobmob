# lobmob vault

Shared Obsidian vault for the lobmob OpenClaw agent swarm.

## Structure

| Directory | Purpose |
|---|---|
| `000-inbox/` | Raw dumps, unsorted findings |
| `010-tasks/` | Task tracking (active, completed, failed) |
| `020-logs/` | Daily logs for lobboss and each lobster |
| `030-knowledge/` | Research results, documentation, assets |
| `040-fleet/` | Fleet registry, swarm configuration, shared skills |

## Usage

- **Humans**: Clone and open in Obsidian for browsing
- **Lobboss**: Pushes directly to main (task creation, PR merges, fleet registry)
- **Lobsters**: Push to task branches, submit PRs for review
