# Git Workflow — PR-Based Task Delivery

## Principle

Lobsters never push to `main`. All results are delivered as pull requests that
the lobboss reviews and merges.

## Branch Naming

```
lobster-{id}/task-{task-id}
```

One branch per task. Examples:
- `lobster-swe-001-salty-squidward/task-2026-02-05-a1b2`
- `lobster-research-002-bubbly-nemo/task-2026-02-05-c3d4`

## Flow

```
1. Lobboss creates task file on main
2. Lobster pulls main, creates task branch
3. Lobster does work, commits results to branch
4. Lobster pushes branch, opens PR
5. Lobster announces PR in the task's thread with summary + links
6. Lobboss reviews PR (automated checks + semantic review)
7. Lobboss merges or requests changes (feedback in task thread)
8. If changes requested: lobster fixes, pushes (PR auto-updates), posts update in thread
9. On merge: lobboss confirms in the task's thread + event to #swarm-logs
```

## What the Lobboss Pushes to Main
- Task file creation (`010-tasks/active/`)
- Task assignment updates (frontmatter changes)
- Fleet registry updates (`040-fleet/registry.md`)
- Post-merge task moves (`active/` → `completed/` or `failed/`)
- Daily lobboss logs (`020-logs/lobboss/`)

## What Lobsters Put in PRs
- Updated task file (status: completed, lobster notes, results)
- Result files (`030-knowledge/topics/`, `030-knowledge/assets/`)
- Lobster daily log (`020-logs/lobsters/<id>/`)
- Raw findings if applicable (`000-inbox/`)

## PR Body Structure

```markdown
## Task
- **ID**: task-2026-02-05-a1b2
- **Lobster**: lobster-swe-001-salty-squidward
- **Completed**: 2026-02-05T15:30:00Z

## Results Summary
<what was accomplished>

## Files Changed
<list with descriptions>

## Linked Vault Pages
<[[wikilinks]] to key pages>

## Acceptance Criteria
- [x] Criterion met
- [x] Another criterion
```

## Discord Announcement (posted to task's thread in #task-queue)

```
Task Complete: task-2026-02-05-a1b2

PR: https://github.com/org/lobmob-vault/pull/17
Results: <blob URL to main results file on branch>
Work log: <blob URL to lobster log on branch>

Summary: <2-3 sentences>
Diff: +142 lines across 4 files
```

## Lobboss Review Checks
1. Automated (`lobmob-review-prs` script):
   - No secrets in diff
   - Files within allowed paths
   - No merge conflicts
2. Semantic (lobboss agent):
   - Results address task acceptance criteria
   - Work log documents the process
   - Obsidian wikilinks connect to existing pages
   - Quality bar met (not stubs)
