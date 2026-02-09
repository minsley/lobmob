---
name: task-qa-create
description: Auto-create QA verification tasks when SWE lobsters open PRs
---

# Auto-Creating QA Verification Tasks

When a SWE lobster completes a task and opens a PR:

1. Read the original SWE task file. Check the `requires_qa` field.
2. If `requires_qa: true`:
   a. Create a new QA task file at `010-tasks/active/<qa-task-id>.md`:
      ```yaml
      type: qa
      repo: <same repo as the SWE task>
      related_task: <swe-task-id>
      pr_number: <the PR number>
      model: anthropic/claude-sonnet-4-5
      requires_qa: false
      ```
      Title: `Verify: <original task title>`
      Objective: `Review and test PR #<number> from <swe-lobster-id>.`
      Acceptance criteria: Code review completed, tests pass, no security issues, verification report posted.
   b. Commit and push the QA task file
   c. The `lobmob-task-manager` cron will auto-assign it to a QA lobster

3. If `requires_qa: false`: Skip QA, proceed directly with your own review via `review-prs`.

## QA-Gated Merge

**Important:** Do NOT merge the SWE PR until QA completes (if requires_qa is true).
- QA reports PASS → merge the SWE PR to `develop`
- QA reports FAIL → request changes from the SWE lobster
- QA reports BLOCK → do not merge, escalate to user
