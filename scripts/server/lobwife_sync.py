"""lobwife_sync — Vault sync daemon.

Periodically snapshots DB task state into vault files for Obsidian browsing.
DB is the sole source of truth for task state; vault gets periodic updates.

Runs as a background asyncio task inside lobwife-daemon.py alongside persist_loop.
"""

import asyncio
import json
import logging
import os
import re
from datetime import datetime, timezone
from pathlib import Path

import yaml

from lobwife_db import get_db

log = logging.getLogger("lobwife.sync")

VAULT_PATH = os.environ.get("VAULT_PATH", "/home/lobwife/vault")
TASKS_DIR = "010-tasks"
OVERVIEW_FILE = f"{TASKS_DIR}/_overview.md"
SYNC_INTERVAL = int(os.environ.get("VAULT_SYNC_INTERVAL", "300"))  # 5 min default

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)

# Status -> subdirectory mapping for vault task files
STATUS_DIR_MAP = {
    "queued": "active",
    "active": "active",
    "blocked": "active",
    "completed": "completed",
    "failed": "failed",
    "cancelled": "failed",
}


# ── Git helpers ──────────────────────────────────────────────────────

async def _git(*args: str) -> str:
    """Run a git command in the vault directory. Returns stdout."""
    cmd = ["git", "-C", VAULT_PATH, *args]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
    if proc.returncode != 0:
        err = stderr.decode().strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {err}")
    return stdout.decode().strip()


async def _pull_vault() -> None:
    """Pull latest vault changes."""
    try:
        await _git("pull", "--rebase", "origin", "main")
    except RuntimeError:
        try:
            await _git("rebase", "--abort")
        except RuntimeError:
            pass
        await _git("pull", "origin", "main")


async def _commit_and_push(message: str, files: list[str]) -> bool:
    """Stage files, commit, and push. Returns True if a commit was made."""
    if not files:
        return False

    for f in files:
        await _git("add", f)

    # Check if there's anything to commit
    try:
        await _git("diff", "--cached", "--quiet")
        # No changes staged
        return False
    except RuntimeError:
        pass  # Changes exist — proceed

    await _git("commit", "-m", message)
    try:
        await _git("push", "origin", "main")
    except RuntimeError:
        # Conflict — pull and retry
        log.warning("Sync push conflict, pulling and retrying")
        await _pull_vault()
        await _git("push", "origin", "main")

    return True


# ── Frontmatter helpers ──────────────────────────────────────────────

def _parse_frontmatter(content: str) -> tuple[dict, str]:
    """Parse YAML frontmatter from markdown. Returns (metadata, body)."""
    match = FRONTMATTER_RE.match(content)
    if match:
        metadata = yaml.safe_load(match.group(1)) or {}
        body = content[match.end():]
        return metadata, body
    return {}, content


def _serialize_task_file(metadata: dict, body: str) -> str:
    """Serialize metadata + body into a frontmatter markdown file."""
    fm = yaml.dump(metadata, default_flow_style=False, sort_keys=False).strip()
    return f"---\n{fm}\n---\n\n{body}\n"


def _find_task_file(task_id: str) -> Path | None:
    """Find existing vault file for a task across all subdirs."""
    for subdir in ("active", "completed", "failed"):
        path = Path(VAULT_PATH) / TASKS_DIR / subdir / f"{task_id}.md"
        if path.exists():
            return path
    return None


# ── DB -> Frontmatter field mapping ─────────────────────────────────

# Fields synced from DB to vault frontmatter
SYNC_FIELDS = {
    "status", "type", "priority", "model", "assigned_to",
    "assigned_at", "completed_at", "estimate_minutes", "requires_qa",
    "workflow", "discord_thread_id",
}


def _db_row_to_frontmatter(row: dict) -> dict:
    """Convert a DB task row to vault frontmatter fields."""
    fm = {
        "id": f"T{row['id']}",
        "name": row.get("name", ""),
        "type": row.get("type", "swe"),
        "status": row.get("status", "queued"),
        "created": row.get("created_at", ""),
        "priority": row.get("priority", "normal"),
    }
    # Optional fields — only include if set
    for field in ("assigned_to", "assigned_at", "completed_at", "model",
                  "estimate_minutes", "workflow", "discord_thread_id"):
        val = row.get(field)
        if val is not None:
            fm[field] = val

    if row.get("requires_qa"):
        fm["requires_qa"] = True

    if row.get("slug"):
        fm["slug"] = row["slug"]

    if row.get("repos"):
        repos = row["repos"]
        if isinstance(repos, str):
            try:
                repos = json.loads(repos)
            except (json.JSONDecodeError, TypeError):
                pass
        fm["repos"] = repos

    return fm


# ── Sync logic ───────────────────────────────────────────────────────

async def _query_updated_tasks(since: str | None) -> list[dict]:
    """Query DB for tasks updated since a given timestamp (or all if None)."""
    db = await get_db()
    if since:
        query = """SELECT * FROM tasks WHERE updated_at > ? ORDER BY id"""
        async with db.execute(query, (since,)) as cur:
            rows = await cur.fetchall()
    else:
        query = """SELECT * FROM tasks ORDER BY id"""
        async with db.execute(query) as cur:
            rows = await cur.fetchall()
    return [dict(r) for r in rows]


async def _sync_task_file(row: dict) -> str | None:
    """Sync a single task's DB state to its vault file.

    Returns the relative file path if changed, None if unchanged.
    """
    task_id = f"T{row['id']}"
    status = row.get("status", "queued")
    target_subdir = STATUS_DIR_MAP.get(status, "active")
    target_path = Path(VAULT_PATH) / TASKS_DIR / target_subdir / f"{task_id}.md"

    # Find existing file (may be in a different subdir)
    existing = _find_task_file(task_id)

    # Also check by slug for migrated tasks
    slug = row.get("slug")
    if not existing and slug:
        existing = _find_task_file(slug)

    new_fm = _db_row_to_frontmatter(row)

    if existing:
        content = existing.read_text()
        old_fm, body = _parse_frontmatter(content)

        # Merge: DB fields override, but preserve any vault-only fields
        merged = dict(old_fm)
        for key, val in new_fm.items():
            merged[key] = val

        # Check if anything actually changed
        if merged == old_fm and existing == target_path:
            return None

        # Move file if status changed subdirectory
        if existing != target_path:
            target_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                await _git("mv", str(existing), str(target_path))
            except RuntimeError:
                # git mv can fail if file is untracked; fall back to rename
                existing.rename(target_path)

        target_path.write_text(_serialize_task_file(merged, body.strip()))
    else:
        # No vault file exists — create a minimal one
        target_path.parent.mkdir(parents=True, exist_ok=True)
        body = f"# {row.get('name', task_id)}\n\n_Task created via API. Content pending._"
        target_path.write_text(_serialize_task_file(new_fm, body))

    return str(target_path.relative_to(VAULT_PATH))


async def _write_overview() -> str:
    """Write a task overview file with Dataview-queryable frontmatter.

    Returns the relative file path.
    """
    db = await get_db()

    # Count by status
    async with db.execute(
        "SELECT status, COUNT(*) as cnt FROM tasks GROUP BY status"
    ) as cur:
        status_counts = {r["status"]: r["cnt"] for r in await cur.fetchall()}

    # Recent tasks (last 20)
    async with db.execute(
        "SELECT id, name, type, status, assigned_to, created_at, completed_at "
        "FROM tasks ORDER BY id DESC LIMIT 20"
    ) as cur:
        recent = [dict(r) for r in await cur.fetchall()]

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    overview_fm = {
        "synced_at": now,
        "total_tasks": sum(status_counts.values()),
        "queued": status_counts.get("queued", 0),
        "active": status_counts.get("active", 0),
        "completed": status_counts.get("completed", 0),
        "failed": status_counts.get("failed", 0),
        "cancelled": status_counts.get("cancelled", 0),
        "blocked": status_counts.get("blocked", 0),
    }

    # Build task table
    lines = ["# Task Overview", "", "_Auto-generated by vault sync daemon. Do not edit._", ""]
    lines.append(f"**Last synced:** {now}")
    lines.append("")

    # Summary
    lines.append("## Summary")
    lines.append("")
    for status, count in sorted(status_counts.items()):
        lines.append(f"- **{status}**: {count}")
    lines.append("")

    # Recent tasks table
    lines.append("## Recent Tasks")
    lines.append("")
    lines.append("| ID | Name | Type | Status | Assigned To | Created |")
    lines.append("|-----|------|------|--------|-------------|---------|")
    for t in recent:
        tid = f"T{t['id']}"
        name = (t.get("name") or "")[:40]
        ttype = t.get("type", "")
        status = t.get("status", "")
        assigned = t.get("assigned_to") or ""
        created = (t.get("created_at") or "")[:10]
        lines.append(f"| [{tid}]({tid}.md) | {name} | {ttype} | {status} | {assigned} | {created} |")
    lines.append("")

    body = "\n".join(lines)
    overview_path = Path(VAULT_PATH) / OVERVIEW_FILE
    overview_path.parent.mkdir(parents=True, exist_ok=True)
    overview_path.write_text(_serialize_task_file(overview_fm, body))

    return OVERVIEW_FILE


async def run_sync_cycle(last_sync: str | None) -> str:
    """Run a single sync cycle. Returns the new last_sync timestamp."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Pull latest vault state
    try:
        await _pull_vault()
    except RuntimeError as e:
        log.warning("Vault pull failed, skipping sync cycle: %s", e)
        return last_sync  # Don't advance timestamp on failure

    # Query tasks updated since last sync
    tasks = await _query_updated_tasks(last_sync)
    if not tasks and last_sync:
        log.debug("No tasks updated since last sync")
        return now

    # Sync each changed task
    changed_files = []
    for task in tasks:
        try:
            rel_path = await _sync_task_file(task)
            if rel_path:
                changed_files.append(rel_path)
        except Exception as e:
            log.warning("Failed to sync task T%s: %s", task.get("id"), e)

    # Write overview file
    try:
        overview_path = await _write_overview()
        changed_files.append(overview_path)
    except Exception as e:
        log.warning("Failed to write overview: %s", e)

    # Commit and push all changes in one go
    if changed_files:
        try:
            committed = await _commit_and_push(
                f"[sync] Update {len(changed_files)} vault file(s)",
                changed_files,
            )
            if committed:
                log.info("Vault sync: committed %d file(s)", len(changed_files))
            else:
                log.debug("Vault sync: no changes to commit")
        except RuntimeError as e:
            log.warning("Vault sync commit/push failed: %s", e)

    return now


# ── Sync daemon loop ─────────────────────────────────────────────────

class VaultSyncDaemon:
    """Background task that syncs DB state to vault on a schedule.

    Supports event-triggered sync: call request_sync() to trigger
    an immediate sync on the next loop iteration.
    """

    def __init__(self, broker=None):
        self._last_sync: str | None = None
        self._sync_needed = asyncio.Event()
        self._running = False
        self._broker = broker

    def request_sync(self):
        """Signal that an immediate sync is needed (called from API handlers)."""
        self._sync_needed.set()

    async def run(self):
        """Main loop: sync every SYNC_INTERVAL seconds, or immediately on event."""
        self._running = True
        log.info("Vault sync daemon started (interval=%ds, vault=%s)", SYNC_INTERVAL, VAULT_PATH)

        # Check vault is a git repo
        if not Path(VAULT_PATH).joinpath(".git").is_dir():
            log.error("Vault path %s is not a git repo — sync daemon disabled", VAULT_PATH)
            return

        # Ensure git identity is configured for commits
        try:
            await _git("config", "user.email", "lobwife@lobmob.local")
            await _git("config", "user.name", "lobwife sync")
        except RuntimeError:
            pass

        # Refresh vault remote URL with a fresh token before first sync
        await self._refresh_vault_credentials()

        # Initial sync on startup (full scan)
        try:
            self._last_sync = await run_sync_cycle(None)
            log.info("Initial vault sync complete")
        except Exception:
            log.exception("Initial vault sync failed")

        while self._running:
            try:
                # Wait for either: interval elapsed or event triggered
                try:
                    await asyncio.wait_for(
                        self._sync_needed.wait(),
                        timeout=SYNC_INTERVAL,
                    )
                    # Event triggered — clear it
                    self._sync_needed.clear()
                    log.info("Event-triggered vault sync")
                except asyncio.TimeoutError:
                    # Normal interval sync
                    pass

                await self._refresh_vault_credentials()
                self._last_sync = await run_sync_cycle(self._last_sync)

            except Exception:
                log.exception("Vault sync cycle failed")
                # Don't spin on repeated failures
                await asyncio.sleep(60)

    async def _refresh_vault_credentials(self):
        """Update vault remote URL with a fresh GitHub App token from the broker."""
        if not self._broker:
            return
        try:
            token_data = await self._broker.create_service_token("lobwife-sync")
            token = token_data["token"]
            vault_repo = os.environ.get("VAULT_REPO", "")
            if not vault_repo:
                # Detect repo from current remote URL
                current = await _git("remote", "get-url", "origin")
                # Extract org/repo from URL
                if "github.com" in current:
                    parts = current.rstrip("/").rstrip(".git").split("github.com/")[-1]
                    vault_repo = parts
            if vault_repo:
                new_url = f"https://x-access-token:{token}@github.com/{vault_repo}.git"
                await _git("remote", "set-url", "origin", new_url)
                log.debug("Vault credentials refreshed")
        except Exception as e:
            log.warning("Failed to refresh vault credentials: %s", e)

    def stop(self):
        self._running = False
        self._sync_needed.set()  # Unblock the wait
