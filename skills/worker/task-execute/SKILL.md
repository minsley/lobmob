---
name: task-execute
description: Core workflow for receiving and executing a task assignment
---

# Task Execute

This is your main workflow when the manager assigns you a task.

## 1. Receive Assignment

You'll see a message in **#swarm-control** like:
```
@worker-<your-id> TASK: <task-id>
Title: <title>
File: 010-tasks/active/<task-id>.md
Pull main for full details.
```

## 2. Acknowledge
Post to **#swarm-control**:
```
ACK <task-id> worker-<your-id>
```

## 3. Read the Task

Use the `vault-read` skill:
```bash
cd /opt/vault && git checkout main && git pull origin main
cat 010-tasks/active/<task-id>.md
```

Read the full task file. Understand:
- The **Objective** — what needs to be done
- The **Acceptance Criteria** — how to know you're done
- Any **tags** that hint at what skills or tools are needed

## 4. Set Up Your Branch

Use the `vault-write` skill to create your branch:
```bash
git checkout -b "worker-${WORKER_ID}/task-${TASK_ID}"
```

## 5. Start Your Work Log

Create or append to `020-logs/workers/<your-id>/<date>.md`:
```markdown
## HH:MM — Task Assigned
Picked up [[010-tasks/active/<task-id>]]: <title>
```

## 6. Execute

Do the work. This varies by task — research, code, scraping, analysis, etc.
Use whatever tools OpenClaw gives you (shell, browser, file I/O).

As you work:
- Save results incrementally to the vault
- Append progress notes to your work log
- Commit periodically so work isn't lost

## 7. Finalize

When done:
1. Update the task file:
   - Set `status: completed` and `completed_at` in frontmatter
   - Fill in `## Worker Notes` with what you did
   - Fill in `## Result` with a summary and links to result files
   - Check off acceptance criteria
2. Final commit

## 8. Submit

Use the `submit-results` skill to:
1. Push your branch
2. Create a PR
3. Announce in **#results** with the PR link and summary

## 9. Handle Feedback

If the manager requests changes on your PR:
1. Read the feedback (Discord message or PR comment)
2. Make fixes on the same branch
3. Commit and push
4. Re-announce in **#results**

## Failure

If you cannot complete the task:
1. Document what went wrong in the task file and work log
2. Set `status: failed` in the frontmatter
3. Still submit a PR with partial results
4. Announce with `FAIL` prefix in **#results**
