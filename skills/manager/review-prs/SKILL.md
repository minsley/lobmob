---
name: review-prs
description: Review open PRs from workers and merge or request changes
---

# Review PRs

Periodically check for open PRs from workers and review them. The automated
`lobmob-review-prs` script handles basic validation (secrets, file paths).
You handle the semantic review.

## Review Cycle

Run this every time you see a worker announce a PR in **#results**, or
proactively every few minutes.

### Step 1 — List open PRs
```bash
cd /opt/vault
gh pr list --state open --json number,title,headRefName,author,createdAt
```

### Step 2 — Review each PR

For each open PR:

1. **Read the PR body** for the structured summary:
   ```bash
   gh pr view <number> --json body,title,files
   ```

2. **Read the diff**:
   ```bash
   gh pr diff <number>
   ```

3. **Validate**:
   - Task file exists in `010-tasks/` with correct frontmatter (status: completed, completed_at set)
   - Work log entry present in `020-logs/workers/<worker-id>/`
   - Results placed in appropriate location under `030-knowledge/`
   - No secrets, API keys, or credentials in the diff
   - No files outside allowed paths (`000-inbox/`, `010-tasks/`, `020-logs/workers/`, `030-knowledge/`)
   - Content is relevant and addresses the task's acceptance criteria
   - No merge conflicts

4. **Check quality**:
   - Are the results substantive or just stubs?
   - Are Obsidian wikilinks `[[like this]]` used to connect related pages?
   - Are images in `030-knowledge/assets/` and referenced properly?

### Step 3 — Merge or request changes

**If the PR passes review:**
```bash
gh pr merge <number> --merge --delete-branch
```

Then:
- Post to **#swarm-logs**: `Merged PR #<number> (<task-id>) from <worker-id>. Branch cleaned up.`
- Pull main: `git pull origin main`
- Verify task file is in `010-tasks/completed/`. Move it there if the worker left it in `active/`.

**If the PR needs changes:**
```bash
gh pr comment <number> --body "<specific feedback>"
```

Then post to **#swarm-control**:
```
@worker-<id> PR #<number> needs revision: <brief reason>.
Please fix and push to your branch.
```

The worker will fix, push (PR updates automatically), and re-announce in #results.

### Step 4 — Log the review cycle
Append to today's manager log (`020-logs/manager/YYYY-MM-DD.md`):
```
## HH:MM — PR Review Cycle
- PR #<number>: merged / requested changes / blocked
```
Commit and push to main.
