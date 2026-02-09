---
name: task-lifecycle
description: Index for task management sub-skills — creation, assignment, monitoring, recovery, completion
---

# Task Lifecycle

You manage tasks through markdown files in the vault at `/opt/vault/010-tasks/`.

This is a routing index. For each workflow, read the corresponding sub-skill:

| Workflow | Skill | When |
|---|---|---|
| **Create a task** | `task-create` | New request in task-queue channel |
| **Assign a task** | `task-assign` | Manual assignment override (routine assignment is automated by `lobmob-task-manager` cron) |
| **Monitor tasks** | `task-monitor` | Check for stalled/timed-out tasks (routine detection is automated) |
| **Recover orphans** | `task-recover` | Handle tasks assigned to missing lobsters (routine recovery is automated) |
| **Complete a task** | `task-complete` | After PR is merged (routine file moves are automated by `lobmob-task-watcher` cron) |
| **Fail a task** | `task-fail` | Lobster reports failure or timeout exceeded |
| **Create QA task** | `task-qa-create` | SWE lobster opens a PR on a `requires_qa: true` task |

## What's Automated vs. What Needs You

**Automated by cron (no LLM needed):**
- Task assignment to idle lobsters (`lobmob-task-manager`, every 5 min)
- Timeout detection and warnings (`lobmob-task-manager`, every 5 min)
- Orphan detection and recovery (`lobmob-task-manager`, every 5 min)
- Task file moves (active → completed/failed) (`lobmob-task-watcher`, every 2 min)
- Discord status posting (`lobmob-task-watcher`, every 2 min)
- PR deterministic checks and vault PR auto-merge (`lobmob-review-prs`, every 2 min)

**Requires you (LLM judgment):**
- Evaluating new task requests (understanding user intent)
- Drafting task proposals (decomposing requests into structured tasks)
- Handling user feedback on proposals (revisions, clarifications)
- Creating QA verification tasks for code PRs
- Semantic code review and merge decisions for code PRs
- Deciding whether to re-create failed tasks
