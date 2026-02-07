# Discord Protocol

## Channels

| Channel | Who writes | Purpose |
|---|---|---|
| #task-queue | Humans, lobboss | Work requests and task proposals |
| #swarm-control | Lobboss, lobsters | Task assignment and coordination |
| #results | Lobsters | PR announcements with summaries |
| #swarm-logs | Lobboss | Fleet events, merge confirmations |

## Message Formats

### Task Proposal (lobboss → #task-queue)
```
**Task Proposal**

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

Reply **go** to create, **cancel** to discard, or describe changes.
```

### Task Confirmed (lobboss → #task-queue)
```
Task created: **<task-id>**
Title: <title>
I'll assign it to a lobster shortly.
```

### Task Cancelled (lobboss → #task-queue)
```
Task cancelled.
```

### Task Assignment (lobboss → #swarm-control)
```
@lobster-<id> TASK: <task-id>
Title: <title>
File: 010-tasks/active/<task-id>.md
Pull main for full details.
```

### Task Acknowledgment (lobster → #swarm-control)
```
ACK <task-id> lobster-<id>
```

### PR Announcement (lobster → #results)
```
Task Complete: <task-id>

PR: <github PR url>
Results: <github blob url to main results file>
Work log: <github blob url to lobster log>

Summary: <2-3 sentences>
Diff: +<lines> across <N> files
```

### Task Failure (lobster → #results)
```
FAIL: <task-id>

PR: <github PR url>
Reason: <what went wrong>
Partial results included in PR.
```

### PR Revision Request (lobboss → #swarm-control)
```
@lobster-<id> PR #<number> needs revision: <brief reason>.
Please fix and push to your branch.
```

### Merge Confirmation (lobboss → #swarm-logs)
```
Merged PR #<number> (<task-id>) from <lobster-id>. Branch cleaned up.
```

### Fleet Status (lobboss → #swarm-logs)
```
Fleet Status @ HH:MM
Lobsters: N active, M healthy
Tasks: X queued, Y active, Z completed today
Open PRs: N
```

### Lobster Online (lobster → #swarm-control)
```
Lobster <lobster-id> online at <wireguard_ip>.
Ready for task assignment.
```

### Lobster Idle (lobster → #swarm-control)
```
Lobster <lobster-id> idle for 30+ minutes. No pending tasks.
Available for assignment or teardown.
```
