---
name: task-complete
description: Handle task completion after PR merge
---

# Task Completion

**Note:** Routine task file moving (active → completed/failed) is handled by the `lobmob-task-watcher` cron every 2 minutes. This skill documents the full completion flow.

## Automatic (cron-handled)

When a lobster sets `status: completed` in the task file and pushes:
1. `lobmob-task-watcher` detects the status change
2. Posts completion notice to the task's Discord thread
3. Moves the file from `010-tasks/active/` to `010-tasks/completed/`
4. Commits and pushes

## Your Role

After the PR is merged (via the `review-prs` flow):
1. Verify the task file has `status: completed` and `completed_at` set
2. If the lobster forgot to set these, update them manually
3. The cron handles the rest

## QA-Gated Tasks

If the completed task has `requires_qa: true`, do NOT merge the code PR until QA completes. The `task-qa-create` skill handles creating the QA verification task.
