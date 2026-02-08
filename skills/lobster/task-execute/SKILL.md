---
name: task-execute
description: Core workflow for receiving and executing a task assignment
---

# Task Execute

This is your main workflow when the lobboss assigns you a task.

## 1. Receive Assignment

You'll see a message in a **task thread** under #task-queue like:
```
Assigned to **lobster-<your-id>**.
@lobster-<your-id> — pull main and read `010-tasks/active/<task-id>.md` for details.
```

## 2. Acknowledge

Read the task file to get the `discord_thread_id` from the frontmatter.
Post your ACK in the **task's thread**:
```
ACK <task-id> lobster-<your-id>
```

## Progress Posting

As you work through this task, post brief milestone updates in the **task's thread**
(using the `discord_thread_id` from the task file frontmatter). Use the `message` tool:

```json
{
  "action": "thread-reply",
  "channel": "discord",
  "threadId": "<discord_thread_id from task frontmatter>",
  "text": "PROGRESS <task-id>: <milestone message>"
}
```

Post at these milestones (one message each, keep it to one line):

| When | Message |
|---|---|
| After reading and understanding the task (step 3) | `PROGRESS <task-id>: Task understood. Starting work.` |
| When beginning research or information gathering | `PROGRESS <task-id>: Researching — <what you're looking into>` |
| When actively building, writing, or executing | `PROGRESS <task-id>: Working — <brief description>` |
| When finalizing results (step 7) | `PROGRESS <task-id>: Finalizing results and preparing PR.` |

Do NOT post more than one message per phase. These are heartbeat-level updates,
not detailed reports. Save detail for the PR summary and work log.

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
git checkout -b "lobster-${LOBSTER_ID}/task-${TASK_ID}"
```

## 5. Start Your Work Log

Create or append to `020-logs/lobsters/<your-id>/<date>.md`:
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
   - Fill in `## Lobster Notes` with what you did
   - Fill in `## Result` with a summary and links to result files
   - Check off acceptance criteria
2. Final commit

## 8. Submit

Use the `submit-results` skill to:
1. Push your branch
2. Create a PR
3. Announce in the **task's thread** with the PR link and summary

## 9. Handle Feedback

If the lobboss requests changes on your PR:
1. Read the feedback in the task's thread or PR comment
2. Make fixes on the same branch
3. Commit and push
4. Post an update in the **task's thread**

## Failure

If you cannot complete the task:
1. Document what went wrong in the task file and work log
2. Set `status: failed` in the frontmatter
3. Still submit a PR with partial results
4. Announce with `FAIL` prefix in the **task's thread**
