# Discord Protocol

## Channels

| Channel | Who writes | Purpose |
|---|---|---|
| #task-queue | Humans, external systems | Post work requests |
| #swarm-control | Manager, workers | Task assignment and coordination |
| #results | Workers | PR announcements with summaries |
| #swarm-logs | Manager | Fleet events, merge confirmations |

## Message Formats

### Task Assignment (manager → #swarm-control)
```
@worker-<id> TASK: <task-id>
Title: <title>
File: 010-tasks/active/<task-id>.md
Pull main for full details.
```

### Task Acknowledgment (worker → #swarm-control)
```
ACK <task-id> worker-<id>
```

### PR Announcement (worker → #results)
```
Task Complete: <task-id>

PR: <github PR url>
Results: <github blob url to main results file>
Work log: <github blob url to worker log>

Summary: <2-3 sentences>
Diff: +<lines> across <N> files
```

### Task Failure (worker → #results)
```
FAIL: <task-id>

PR: <github PR url>
Reason: <what went wrong>
Partial results included in PR.
```

### PR Revision Request (manager → #swarm-control)
```
@worker-<id> PR #<number> needs revision: <brief reason>.
Please fix and push to your branch.
```

### Merge Confirmation (manager → #swarm-logs)
```
Merged PR #<number> (<task-id>) from <worker-id>. Branch cleaned up.
```

### Fleet Status (manager → #swarm-logs)
```
Fleet Status @ HH:MM
Workers: N active, M healthy
Tasks: X queued, Y active, Z completed today
Open PRs: N
```

### Worker Online (worker → #swarm-control)
```
Worker <worker-id> online at <wireguard_ip>.
Ready for task assignment.
```

### Worker Idle (worker → #swarm-control)
```
Worker <worker-id> idle for 30+ minutes. No pending tasks.
Available for assignment or teardown.
```
