---
status: draft
tags: [lobwife, vault, sync, lobster]
maturity: design
created: 2026-02-26
updated: 2026-02-26
---
# Vault Sync: Content Preservation

## Summary

The vault sync daemon races with lobster PR merges, causing lobster-written content (Result/Notes sections) to be overwritten with template placeholders. When a lobster completes a task, it writes rich content to a vault branch and creates a PR. Meanwhile, the sync daemon sees the task as `completed` in DB and regenerates the file on main with DB-only metadata — losing the lobster's body content. This causes e2e test failures (Result/Notes checks) and degrades the vault's value as a human-readable record.

## Problem Details

**Observed on prod (v0.6.0, T8):** e2e 7/10 — Result and Notes sections showed template placeholders despite the lobster having written full content on its branch.

**Root cause — race between two writers:**

1. **Lobster** writes Result/Notes to task file on a vault branch, pushes, creates PR
2. **Sync daemon** (runs every 5min + on status change events) sees `status: completed` in DB, generates/updates `T{id}.md` in `completed/` on main
3. Sync daemon's version has only DB metadata + template body (`_Pending_`, `_To be filled by assigned lobster_`)
4. When the lobster's PR eventually merges, one of two things happens:
   - Merge conflict (sync daemon already wrote the file at the target path) — gh merge fails
   - PR merges first but next sync cycle overwrites body with DB-generated version

**Why it worked on dev but not always on prod:** Timing. If review-prs merges the PR before the sync daemon's next cycle AND the sync daemon's `_sync_task_file` finds the existing file with lobster content, the body is preserved (line 209: it reads existing body). But if the sync daemon runs first (creating the file from scratch with template body, line 233), the lobster's content is never merged into main.

**Key code paths:**
- `lobwife_sync.py:187-236` — `_sync_task_file()`: preserves body if file exists, creates stub if not
- `lobwife_sync.py:233` — New file body: `"_Task created via API. Content pending._"` (no sections)
- `verify.py:22-23` — Regex checks for non-empty `## Result` and `## Lobster Notes`
- `verify.py:82-86` — Returns missing steps if sections empty
- `agent.py` — Continue loop sends missing steps as next episode prompt (max 5 episodes)

## Open Questions

- [ ] Should the sync daemon skip writing body content entirely and only manage frontmatter + file location (move between active/completed/failed)?
- [ ] Should lobsters write Result/Notes to the DB via the API instead of (or in addition to) the vault file?
- [ ] Should the sync daemon detect an open/merged PR for the task and pull content from the branch before writing?

## Approaches

### A: Sync daemon becomes frontmatter-only (recommended)

Sync daemon only updates frontmatter fields and moves files between directories. Never touches body content. If the file doesn't exist yet, creates it with proper template sections (## Objective, ## Result, ## Lobster Notes, ## Acceptance Criteria) but leaves them as placeholders.

**Pros:** Simple, eliminates the race entirely, preserves all lobster content
**Cons:** If a task is created via API and never assigned, the vault file has placeholder body until someone edits it
**Effort:** Small — modify `_sync_task_file()` to only write frontmatter, preserve full body

### B: Lobsters write Result/Notes to DB via API

Add `result` and `notes` text columns to the `tasks` table. Lobsters call `PATCH /api/v1/tasks/{id}` with result/notes content. Sync daemon renders these into the vault file sections.

**Pros:** DB becomes complete source of truth for everything, sync daemon can always regenerate correct content
**Cons:** Larger change, requires lobster prompt updates, API changes, schema migration. Result content can be large (multi-paragraph with code blocks)
**Effort:** Medium — schema migration, API endpoint, prompt updates, sync rendering

### C: Sync daemon checks for PR content before writing

Before creating/updating a file, the sync daemon checks if a PR exists for this task. If so, it fetches the file content from the PR branch and uses that as the body.

**Pros:** Content always preserved, no lobster changes needed
**Cons:** Complex (GitHub API calls per task per sync cycle), fragile (branch may be deleted), slow
**Effort:** Medium-high — API calls, error handling, branch discovery

### D: Sync daemon defers to lobster's PR (do-not-touch window)

When a task transitions to `completed`, the sync daemon waits N minutes (or until the PR is merged) before writing the vault file. Lobster's PR merge provides the authoritative content.

**Pros:** Leverages existing PR flow
**Cons:** Vault lags behind DB for completed tasks, complex timing logic, PR may never merge
**Effort:** Medium

## Recommended: Approach A (frontmatter-only sync)

Simplest fix with the cleanest separation:
- **DB** owns metadata (status, assigned_to, timestamps, etc.)
- **Vault** owns content (objective, result, notes, acceptance criteria)
- **Sync daemon** bridges them: DB metadata → vault frontmatter, vault body untouched

### Phase 1: Fix sync daemon body handling

- **Status**: pending
- Modify `_sync_task_file()`:
  - When file exists: update frontmatter only, preserve entire body unchanged
  - When file doesn't exist: create with proper template sections (matching `vault-seed` template)
- Update the new-file template to include `## Objective`, `## Acceptance Criteria`, `## Lobster Notes`, `## Result` sections
- Add the task `name` as the `# Title` heading
- Test: create task via API → verify vault file has proper sections → lobster fills in → verify content preserved after sync

### Phase 2: Add result/notes to DB (optional, for Approach B later)

- **Status**: pending
- Add `result_text` and `notes_text` columns to `tasks` table (schema v3)
- PATCH endpoint accepts these fields
- Sync daemon renders them into vault body if present (fallback to existing body if not)
- This gives the best of both worlds: DB has content for API consumers, vault has content for humans

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-26 | Approach A (frontmatter-only sync) as immediate fix | Eliminates the race condition with minimal code change. Approach B can layer on top later |

## Scratch

- T7 on prod had full content (PR merged before sync daemon ran)
- T8 on prod lost content (sync daemon wrote template body before PR merged)
- Dev e2e 10/10 because review-prs was running frequently and merging before sync
- verify.py checks pass inside the lobster (content is on branch) but e2e checks fail after sync overwrites main
- The sync daemon's `_parse_frontmatter` / body split already works correctly — the issue is only with NEW file creation (line 233) and the timing of when the existing file appears on main

## Related

- [Roadmap](../roadmap.md)
- [Vault Scaling](../active/vault-scaling.md) — Phase 3 introduced the sync daemon
- [Lobster Reliability](../completed/lobster-reliability.md) — verify.py checks
- [Multi-turn Lobster](../completed/multi-turn-lobster.md) — episode loop uses verify results
