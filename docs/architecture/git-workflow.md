# Git Workflow — PR-Based Task Delivery

## Principle

Workers never push to `main`. All results are delivered as pull requests that
the manager reviews and merges.

## Branch Naming

```
worker-{id}/task-{task-id}
```

One branch per task. Examples:
- `worker-a3f1/task-2026-02-05-a1b2`
- `worker-07cc/task-2026-02-05-c3d4`

## Flow

```
1. Manager creates task file on main
2. Worker pulls main, creates task branch
3. Worker does work, commits results to branch
4. Worker pushes branch, opens PR
5. Worker announces PR in #results with summary + links
6. Manager reviews PR (automated checks + semantic review)
7. Manager merges or requests changes
8. If changes requested: worker fixes, pushes (PR auto-updates), re-announces
9. On merge: manager confirms in #swarm-logs, cleans up branch
```

## What the Manager Pushes to Main
- Task file creation (`010-tasks/active/`)
- Task assignment updates (frontmatter changes)
- Fleet registry updates (`040-fleet/registry.md`)
- Post-merge task moves (`active/` → `completed/` or `failed/`)
- Daily manager logs (`020-logs/manager/`)

## What Workers Put in PRs
- Updated task file (status: completed, worker notes, results)
- Result files (`030-knowledge/topics/`, `030-knowledge/assets/`)
- Worker daily log (`020-logs/workers/<id>/`)
- Raw findings if applicable (`000-inbox/`)

## PR Body Structure

```markdown
## Task
- **ID**: task-2026-02-05-a1b2
- **Worker**: worker-a3f1
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

## Discord Announcement (posted to #results)

```
Task Complete: task-2026-02-05-a1b2

PR: https://github.com/org/lobmob-vault/pull/17
Results: <blob URL to main results file on branch>
Work log: <blob URL to worker log on branch>

Summary: <2-3 sentences>
Diff: +142 lines across 4 files
```

## Manager Review Checks
1. Automated (`lobmob-review-prs` script):
   - No secrets in diff
   - Files within allowed paths
   - No merge conflicts
2. Semantic (manager agent):
   - Results address task acceptance criteria
   - Work log documents the process
   - Obsidian wikilinks connect to existing pages
   - Quality bar met (not stubs)
