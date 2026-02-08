# Discord Protocol

## Channels

| Channel | Who writes | Purpose |
|---|---|---|
| #task-queue | Humans, lobboss, lobsters | Task lifecycle — one parent message per task, all updates in threads |
| #swarm-control | Humans, lobboss | User commands for fleet management (spawn, converge, pool config, wake/sleep) |
| #swarm-logs | Lobboss, watchdog | Fleet events — spawns, merges, convergence, teardowns, fleet status |

## Agent Name Prefix

All bot messages start with the agent name in bold brackets so humans can tell
who posted (the Discord bot username is shared across all agents):

| Agent | Prefix |
|---|---|
| lobboss | `**[lobboss]**` |
| lobster | `**[lobster-<id>]**` |
| watchdog | `**[watchdog]**` |

## Thread-Based Task Lifecycle

Each task gets a single parent message in **#task-queue** with a thread underneath.
All task communication (proposals, confirmation, assignment, ACK, progress, results,
PR review) happens in that thread. The `discord_thread_id` is stored in the task
file frontmatter so any agent can post to it.

### Flow

1. User posts request in #task-queue
2. Lobboss posts **Task Proposal** as a top-level message
3. Lobboss creates a thread on the proposal (named `Task: <title>`)
4. User confirms/changes/cancels in the thread
5. On confirmation: task file created with `discord_thread_id`, confirmation posted in thread
6. Assignment posted in thread
7. Lobster ACKs in thread
8. Progress updates posted in thread by lobster
9. Results/PR announced in thread
10. PR review feedback in thread
11. Merge confirmation in thread + event to #swarm-logs

## Message Formats

### Task Proposal (lobboss → #task-queue, top-level)
```
**[lobboss]** **Task Proposal**

> **Title:** <title>
> **Priority:** <priority>
> **Tags:** <tag1>, <tag2>
>
> **Objective**
> <objective text>
>
> **Acceptance Criteria**
> - <criterion 1>
> - <criterion 2>
```

### Thread: Confirmation Prompt (lobboss → task thread)
```
**[lobboss]** Reply **go** to create, **cancel** to discard, or describe changes.
```

### Thread: Task Created (lobboss → task thread)
```
**[lobboss]** Task created: **<task-id>**
I'll assign it to a lobster shortly.
```

### Thread: Task Cancelled (lobboss → task thread)
```
**[lobboss]** Task cancelled.
```

### Thread: Assignment (lobboss → task thread)
```
**[lobboss]** Assigned to **lobster-<id>**.
@lobster-<id> — pull main and read `010-tasks/active/<task-id>.md` for details.
```

### Thread: ACK (lobster → task thread)
```
**[lobster-<id>]** ACK <task-id>
```

### Thread: Progress Update (lobster → task thread)
```
**[lobster-<id>]** PROGRESS <task-id>: <brief milestone message>
```

### Thread: Watchdog Alert (watchdog → task thread + #swarm-logs)
```
**[watchdog]** <lobster-id> appears stale on task <task-id> — no gateway activity for <N> minutes.
```

### Thread: Timeout Warning (lobboss → task thread + #swarm-logs)
```
**[lobboss]** Timeout warning: Task <task-id> has been active for <N> minutes with no recent progress from <lobster-id>.
```

### Thread: Task Re-queued (lobboss → task thread)
```
**[lobboss]** Task <task-id> re-queued — <lobster-id> is offline. Will reassign.
```

### Thread: PR Announcement (lobster → task thread)
```
**[lobster-<id>]** Task Complete: <task-id>

PR: <github PR url>
Results: <github blob url to main results file>
Work log: <github blob url to lobster log>

Summary: <2-3 sentences>
Diff: +<lines> across <N> files
```

### Thread: Task Failure (lobster → task thread)
```
**[lobster-<id>]** FAIL: <task-id>
PR: <github PR url>
Reason: <what went wrong>
Partial results included in PR.
```

### Thread: PR Revision Request (lobboss → task thread)
```
**[lobboss]** @lobster-<id> PR #<number> needs revision: <brief reason>.
Please fix and push to your branch.
```

### Thread: Task Complete (lobboss → task thread)
```
**[lobboss]** Task complete. PR merged.
```

### Merge Event (lobboss → #swarm-logs)
```
**[lobboss]** Merged PR #<number> (<task-id>) from <lobster-id>. Branch cleaned up.
```

### Fleet Status (lobboss → #swarm-logs)
```
**[lobboss]** Fleet Status @ HH:MM
Lobsters: N active, M healthy
Tasks: X queued, Y active, Z completed today
Open PRs: N
```

### Lobster Online (lobboss → #swarm-logs)
```
**[lobboss]** Lobster <lobster-id> online at <wireguard_ip>.
Ready for task assignment.
```

### Lobster Idle (lobster → #swarm-control)
```
**[lobster-<id>]** Idle for 30+ minutes. No pending tasks.
Available for assignment or teardown.
```

### Lobster Decommissioned (lobboss → #swarm-logs)
```
**[lobboss]** Lobster <lobster-id> decommissioned. Droplet destroyed.
```
