---
status: completed
tags: [lobster, reliability]
maturity: implementation
created: 2026-02-14
updated: 2026-02-14
---
# Lobster Agent Reliability — Verify-and-Retry Loop

**Status**: Implemented (2026-02-14)
**Branch**: `feature/e2e-task-test`

## Problem

Lobster agents sometimes complete core work but skip final steps (pushing commits, creating PRs, updating task files). The single `query()` architecture has no recovery path — if the agent decides it's "done" early, everything is lost when the container exits.

## Solution: Three-layer defense

### Layer 1: Post-agent verification in `run_task.py`

After `query()` returns, `verify.py` checks completion criteria. If steps are missing, `run_retry()` re-invokes the agent with a focused prompt.

- **verify.py**: Checks task file frontmatter (status, completed_at), Result/Notes sections, vault PR, code PR (SWE only)
- **retry prompt**: Tells agent exactly which steps are missing, instructs it to complete only those
- **Budget**: Max 2 retries, each with `max_turns=15`, `$2.00` budget
- **Skip**: No retry if original run returned `is_error=True`

### Layer 2: Fallback PR creation in `task-manager.sh`

When orphan detection finds a gone lobster with no PR, check if a branch with commits exists and create the PR automatically.

- Uses GitHub API to find branches matching the task ID
- Checks `ahead_by` to confirm commits exist
- Creates PR via `gh pr create`

### Layer 3: Investigation tasks for lobsigliere

When task-manager marks a task as failed, it creates a `type: system` investigation task. Lobsigliere picks this up and submits a lobmob code fix PR.

- Rate-limited: max 1 investigation per failed task
- No recursive investigations
- Scope: fix prompts, verify.py, hooks.py, run_task.py — not the original task

## Files Changed

| File | Action | Purpose |
|------|--------|---------|
| `src/lobster/verify.py` | New | Completion criteria checker |
| `src/lobster/prompts/retry.md` | New | Focused retry system prompt |
| `src/lobster/agent.py` | Modified | Added `run_retry()` function |
| `src/lobster/run_task.py` | Modified | Verify-retry loop after main query |
| `scripts/server/lobmob-task-manager.sh` | Modified | Fallback PR + investigation tasks |

## Design Decisions

- **Why not fresh context per retry?** Lobsters run in containers with persistent disk. Verify-retry is lighter — only re-invokes for missing steps, agent reads previous work from `/opt/vault`.
- **Why 2 retries max?** If the agent can't complete final steps in 2 focused attempts, something is structurally wrong. Better to fail fast.
- **Why three layers?** Layer 1 handles the common case (forgot a step). Layer 2 handles rare case (retries fail but work exists). Layer 3 turns persistent failures into self-healing.
