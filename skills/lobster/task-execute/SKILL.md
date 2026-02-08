---
name: task-execute
description: Core workflow for receiving and executing a task assignment
---

# Task Execute

This is your main workflow when the lobboss assigns you a task.

## 1. Receive Assignment

You'll be notified of your assignment. Pull the vault and read your task file.

## 2. Read the Task

```bash
cd /opt/vault && git checkout main && git pull origin main
cat 010-tasks/active/<task-id>.md
```

Understand:
- The **Objective** — what needs to be done
- The **Acceptance Criteria** — how to know you're done
- Any **tags** that hint at what skills or tools are needed

## 3. Set Up Your Branch

```bash
git checkout -b "lobster-${LOBSTER_ID}/task-${TASK_ID}"
```

## 4. Start Your Work Log

Create or append to `020-logs/lobsters/<your-id>/<date>.md`:
```markdown
## HH:MM — Task Assigned
Picked up [[010-tasks/active/<task-id>]]: <title>
```

## 5. Execute

Do the work. This varies by task — research, code, scraping, analysis, etc.
Use whatever tools OpenClaw gives you (shell, browser, file I/O).

As you work:
- Save results incrementally to the vault
- Append progress notes to your work log
- Commit periodically so work isn't lost

## 6. Finalize

When done:
1. Update the task file:
   - Set `status: completed` and `completed_at` in frontmatter
   - Fill in `## Lobster Notes` with what you did
   - Fill in `## Result` with a summary and links to result files
   - Check off acceptance criteria
2. Final commit

## 7. Submit

Use the `submit-results` skill to:
1. Push your branch
2. Create a PR

Status updates to Discord are handled automatically by the task-watcher
when it detects your task file changes. You don't need to post to Discord.

## 8. Handle Feedback

If the lobboss requests changes on your PR (you'll see this in the task's
Discord thread or as a PR comment):
1. Read the feedback
2. Make fixes on the same branch
3. Commit and push
4. Post a reply in the **task's Discord thread** only if you need clarification

## Failure

If you cannot complete the task:
1. Document what went wrong in the task file and work log
2. Set `status: failed` in the frontmatter
3. Still submit a PR with partial results
