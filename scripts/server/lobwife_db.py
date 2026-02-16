"""lobwife_db — SQLite database module for lobwife daemon.

Manages the aiosqlite connection, schema initialization, and one-time
migration from JSON state files to SQLite.
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Optional

import aiosqlite

log = logging.getLogger("lobwife")

STATE_DIR = Path(
    os.environ.get("LOBWIFE_STATE_DIR")
    or os.path.join(os.environ.get("HOME", "/home/lobwife"), "state")
)
DB_PATH = STATE_DIR / "lobmob.db"
SCHEMA_PATH = Path(__file__).parent / "lobwife-schema.sql"

CURRENT_SCHEMA_VERSION = 1

# Module-level connection
_db: Optional[aiosqlite.Connection] = None


async def get_db() -> aiosqlite.Connection:
    if _db is None:
        raise RuntimeError("Database not initialized — call init_db() first")
    return _db


async def init_db() -> aiosqlite.Connection:
    global _db
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    _db = await aiosqlite.connect(str(DB_PATH))
    _db.row_factory = aiosqlite.Row

    # Enable WAL mode + foreign keys
    await _db.execute("PRAGMA journal_mode=WAL")
    await _db.execute("PRAGMA foreign_keys=ON")

    # Apply schema
    schema_sql = SCHEMA_PATH.read_text()
    await _db.executescript(schema_sql)

    # Set schema version if not present
    async with _db.execute("SELECT COUNT(*) FROM schema_version") as cur:
        row = await cur.fetchone()
        if row[0] == 0:
            await _db.execute(
                "INSERT INTO schema_version (version) VALUES (?)",
                (CURRENT_SCHEMA_VERSION,),
            )
            await _db.commit()

    # Run one-time migration from JSON files
    await migrate_json_to_db(_db)

    log.info("Database initialized: %s", DB_PATH)
    return _db


async def close_db():
    global _db
    if _db is not None:
        await _db.close()
        _db = None
        log.info("Database connection closed")


async def migrate_json_to_db(db: aiosqlite.Connection):
    """One-time migration from JSON state files to SQLite.

    Idempotent: uses INSERT OR IGNORE. Renames .json to .json.migrated
    after successful import.
    """
    jobs_file = STATE_DIR / "jobs.json"
    tasks_file = STATE_DIR / "tasks.json"
    audit_file = STATE_DIR / "token-audit.json"

    migrated_any = False

    # --- jobs.json -> job_state ---
    if jobs_file.exists():
        try:
            data = json.loads(jobs_file.read_text())
            for name, state in data.items():
                await db.execute(
                    """INSERT OR IGNORE INTO job_state
                       (name, last_run, last_status, last_duration, last_output,
                        run_count, fail_count, enabled)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        name,
                        state.get("last_run"),
                        state.get("last_status"),
                        state.get("last_duration"),
                        state.get("last_output"),
                        state.get("run_count", 0),
                        state.get("fail_count", 0),
                        1 if state.get("enabled", True) else 0,
                    ),
                )
            await db.commit()
            jobs_file.rename(jobs_file.with_suffix(".json.migrated"))
            log.info("Migrated jobs.json -> job_state (%d jobs)", len(data))
            migrated_any = True
        except Exception as e:
            log.warning("Failed to migrate jobs.json: %s", e)

    # --- tasks.json (broker registrations) -> broker_tasks ---
    if tasks_file.exists():
        try:
            data = json.loads(tasks_file.read_text())
            for task_id, task in data.items():
                repos = task.get("repos", [])
                await db.execute(
                    """INSERT OR IGNORE INTO broker_tasks
                       (task_id, repos, lobster_type, registered_at, status, token_count)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (
                        task_id,
                        json.dumps(repos),
                        task.get("lobster_type", "unknown"),
                        task.get("registered_at"),
                        task.get("status", "active"),
                        task.get("token_count", 0),
                    ),
                )
            await db.commit()
            tasks_file.rename(tasks_file.with_suffix(".json.migrated"))
            log.info("Migrated tasks.json -> broker_tasks (%d tasks)", len(data))
            migrated_any = True
        except Exception as e:
            log.warning("Failed to migrate tasks.json: %s", e)

    # --- token-audit.json -> token_audit ---
    if audit_file.exists():
        try:
            data = json.loads(audit_file.read_text())
            for entry in data:
                repos = entry.get("repos", [])
                await db.execute(
                    """INSERT OR IGNORE INTO token_audit
                       (task_id, repos, action, created_at)
                       VALUES (?, ?, ?, ?)""",
                    (
                        entry.get("task_id", ""),
                        json.dumps(repos),
                        entry.get("action", ""),
                        entry.get("timestamp"),
                    ),
                )
            await db.commit()
            audit_file.rename(audit_file.with_suffix(".json.migrated"))
            log.info("Migrated token-audit.json -> token_audit (%d entries)", len(data))
            migrated_any = True
        except Exception as e:
            log.warning("Failed to migrate token-audit.json: %s", e)

    if not migrated_any:
        log.debug("No JSON files to migrate")
