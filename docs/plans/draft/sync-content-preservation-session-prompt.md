# Session Prompt: Fix Sync Content Preservation

## Context

Read `docs/plans/draft/sync-content-preservation.md` for full background. The vault sync daemon (`scripts/server/lobwife_sync.py`) races with lobster PR merges, overwriting Result/Notes sections with template placeholders.

## What to implement

**Approach A from the plan: make the sync daemon frontmatter-only.**

### Changes to `scripts/server/lobwife_sync.py`

In `_sync_task_file()` (line ~187):

1. **When file exists** (line 207-229): Only update frontmatter, preserve the entire body unchanged. Currently it already does this (line 209 reads body, line 229 writes it back), BUT the issue is that the file may not exist on main yet (it's on the lobster's branch). So the "existing file" path works correctly — the problem is the "new file" path.

2. **When file doesn't exist** (line 230-234): Create with a proper template body that includes all expected sections. Currently creates a minimal stub: `"_Task created via API. Content pending._"`. Change to:

```python
body = (
    f"# {row.get('name', task_id)}\n\n"
    "## Objective\n\n"
    f"{row.get('description') or '_Task created via API._'}\n\n"
    "## Acceptance Criteria\n\n"
    "- [ ] Task completed as described\n\n"
    "## Lobster Notes\n\n"
    "_To be filled by assigned lobster_\n\n"
    "## Result\n\n"
    "_Pending_"
)
```

3. **Critical fix**: When the sync daemon moves a file between directories (line 220-228, e.g., `active/` → `completed/`), it currently reads the existing file body and preserves it. BUT if the file at the source path was created by the sync daemon itself (with template body), and the lobster's content is on a branch waiting to be merged, the sync daemon perpetuates the template body.

   The fix: after moving a completed task file, check if the body still has `_Pending_` in the Result section. If so, and if a merged PR exists for this task, pull the body content from the merged PR's version of the file. This is a lightweight version of Approach C — only done once at completion time, not every sync cycle.

   Alternatively (simpler): just don't regenerate files where the body hasn't changed from the template. Let the PR merge bring in the real content. The sync daemon only needs to ensure the file is in the right directory with correct frontmatter.

### Testing

1. Run `tests/lobwife-db` to verify existing tests pass
2. On DOKS dev: `LOBMOB_ENV=dev tests/e2e-task --timeout 15` — target 10/10 (Result and Notes checks should pass)
3. On prod: run another e2e after deploying fix

### Key files

- `scripts/server/lobwife_sync.py` — main change (lines 187-236)
- `src/lobster/verify.py` — verify checks (read-only, no changes needed)
- `vault-seed/.obsidian/templates/task.md` — reference template for section structure
- `tests/e2e-task` — lines 436-459 check Result/Notes sections
- `containers/lobwife/Dockerfile` — rebuild after changes
- `containers/lobwife/entrypoint.sh` — no changes needed

### Build & deploy

```bash
lobmob build lobwife
LOBMOB_ENV=dev lobmob restart lobwife
LOBMOB_ENV=dev tests/e2e-task --timeout 15
# If 10/10, deploy to prod:
LOBMOB_ENV=prod lobmob restart lobwife
LOBMOB_ENV=prod tests/e2e-task --timeout 15
```

### Gotchas

- The sync daemon runs as an asyncio task inside `lobwife-daemon.py`, not as a standalone script
- VAULT_REPO must be in the daemon's env (passed through `su -` in entrypoint — already fixed in `2617568`)
- The vault PVC is owned by `lobwife` user but sync daemon may run git ops as a different user — `safe.directory` is already configured
- `_serialize_task_file()` handles YAML frontmatter serialization — don't reinvent
- `_parse_frontmatter()` splits content into (dict, str) — body includes everything after the closing `---`
