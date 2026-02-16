"""lobwife_broker — GitHub credential broker with SQLite-backed state.

Extracted from lobwife-daemon.py. Replaces in-memory dicts and JSON
persistence with broker_tasks and token_audit tables.
"""

import base64
import json
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path

from aiohttp import ClientSession

from lobwife_db import get_db

try:
    import jwt as pyjwt
except ImportError:
    pyjwt = None

log = logging.getLogger("lobwife")

TASK_MAX_AGE_HOURS = 24
AUDIT_MAX_ENTRIES = 500


class TokenBroker:
    """GitHub credential broker — generates repo-scoped installation tokens."""

    def __init__(self):
        self.app_id = os.environ.get("GH_APP_ID", "")
        self.install_id = os.environ.get("GH_APP_INSTALL_ID", "")
        self.pem_key = self._load_pem()
        if self.pem_key:
            log.info("Token broker enabled (app_id=%s)", self.app_id)
        else:
            log.warning("Token broker disabled — no PEM key configured")

    @property
    def enabled(self) -> bool:
        return bool(self.pem_key and self.app_id and self.install_id)

    def _load_pem(self) -> str | None:
        pem_b64 = os.environ.get("GH_APP_PEM", "")
        if pem_b64:
            try:
                return base64.b64decode(pem_b64).decode("utf-8")
            except Exception as e:
                log.error("Failed to decode GH_APP_PEM: %s", e)
                return None
        pem_path = os.environ.get("GH_APP_PEM_PATH", "")
        if pem_path and Path(pem_path).exists():
            return Path(pem_path).read_text()
        return None

    def _generate_jwt(self) -> str:
        if not pyjwt:
            raise RuntimeError("PyJWT not installed — cannot generate JWT")
        now = int(time.time())
        payload = {"iat": now - 60, "exp": now + 540, "iss": self.app_id}
        return pyjwt.encode(payload, self.pem_key, algorithm="RS256")

    async def create_scoped_token(self, repos: list[str]) -> dict:
        app_jwt = self._generate_jwt()
        repo_names = [r.split("/")[-1] for r in repos]
        body = {
            "repositories": repo_names,
            "permissions": {
                "contents": "write",
                "pull_requests": "write",
                "metadata": "read",
            },
        }
        url = f"https://api.github.com/app/installations/{self.install_id}/access_tokens"
        async with ClientSession() as session:
            async with session.post(
                url,
                json=body,
                headers={
                    "Authorization": f"Bearer {app_jwt}",
                    "Accept": "application/vnd.github.v3+json",
                },
            ) as resp:
                if resp.status != 201:
                    text = await resp.text()
                    raise RuntimeError(f"GitHub API {resp.status}: {text[:300]}")
                data = await resp.json()
                return {"token": data["token"], "expires_at": data["expires_at"]}

    async def register_task(self, task_id: str, repos: list[str], lobster_type: str):
        db = await get_db()
        now_iso = datetime.now(timezone.utc).isoformat()
        await db.execute(
            """INSERT OR REPLACE INTO broker_tasks
               (task_id, repos, lobster_type, registered_at, status, token_count)
               VALUES (?, ?, ?, ?, 'active', 0)""",
            (task_id, json.dumps(repos), lobster_type, now_iso),
        )
        await self._audit(db, "task_registered", task_id, repos)
        await db.commit()
        log.info("Registered task %s: repos=%s type=%s", task_id, repos, lobster_type)

    async def deregister_task(self, task_id: str):
        db = await get_db()
        async with db.execute(
            "SELECT repos FROM broker_tasks WHERE task_id = ?", (task_id,)
        ) as cur:
            row = await cur.fetchone()
        if row:
            repos = json.loads(row["repos"])
            await self._audit(db, "task_deregistered", task_id, repos)
            await db.execute("DELETE FROM broker_tasks WHERE task_id = ?", (task_id,))
            await db.commit()
            log.info("Deregistered task %s", task_id)

    async def get_token_for_task(self, task_id: str) -> dict:
        if not self.enabled:
            raise RuntimeError("Token broker not configured (no PEM key)")
        db = await get_db()
        async with db.execute(
            "SELECT * FROM broker_tasks WHERE task_id = ?", (task_id,)
        ) as cur:
            row = await cur.fetchone()
        if not row:
            raise ValueError(f"Task {task_id} not registered")
        if row["status"] != "active":
            raise ValueError(f"Task {task_id} is {row['status']}, not active")
        repos = json.loads(row["repos"])
        token_data = await self.create_scoped_token(repos)
        await db.execute(
            "UPDATE broker_tasks SET token_count = token_count + 1 WHERE task_id = ?",
            (task_id,),
        )
        await self._audit(db, "token_issued", task_id, repos)
        await db.commit()
        return token_data

    async def cleanup_expired(self):
        db = await get_db()
        threshold_seconds = TASK_MAX_AGE_HOURS * 3600
        # SQLite datetime comparison
        async with db.execute(
            """SELECT task_id, repos FROM broker_tasks
               WHERE (julianday('now') - julianday(registered_at)) * 86400 > ?""",
            (threshold_seconds,),
        ) as cur:
            expired = await cur.fetchall()
        for row in expired:
            task_id = row["task_id"]
            repos = json.loads(row["repos"])
            log.info("Expiring stale task registration: %s", task_id)
            await self._audit(db, "task_deregistered", task_id, repos)
            await db.execute("DELETE FROM broker_tasks WHERE task_id = ?", (task_id,))
        if expired:
            await db.commit()

    async def _audit(self, db, action: str, task_id: str, repos: list[str]):
        now_iso = datetime.now(timezone.utc).isoformat()
        await db.execute(
            "INSERT INTO token_audit (task_id, repos, action, created_at) VALUES (?, ?, ?, ?)",
            (task_id, json.dumps(repos), action, now_iso),
        )
        # Trim old entries
        await db.execute(
            """DELETE FROM token_audit WHERE id NOT IN
               (SELECT id FROM token_audit ORDER BY id DESC LIMIT ?)""",
            (AUDIT_MAX_ENTRIES,),
        )

    async def get_tasks(self) -> dict:
        db = await get_db()
        async with db.execute("SELECT * FROM broker_tasks") as cur:
            rows = await cur.fetchall()
        return {
            row["task_id"]: {
                "repos": json.loads(row["repos"]),
                "lobster_type": row["lobster_type"],
                "registered_at": row["registered_at"],
                "status": row["status"],
                "token_count": row["token_count"],
            }
            for row in rows
        }

    async def get_audit_log(self, task_id: str | None = None, limit: int = 200) -> list:
        db = await get_db()
        if task_id:
            async with db.execute(
                "SELECT * FROM token_audit WHERE task_id = ? ORDER BY id DESC LIMIT ?",
                (task_id, limit),
            ) as cur:
                rows = await cur.fetchall()
        else:
            async with db.execute(
                "SELECT * FROM token_audit ORDER BY id DESC LIMIT ?", (limit,)
            ) as cur:
                rows = await cur.fetchall()
        return [
            {
                "timestamp": row["created_at"],
                "task_id": row["task_id"],
                "repos": json.loads(row["repos"]) if row["repos"] else [],
                "action": row["action"],
            }
            for row in rows
        ]

    async def get_summary(self) -> dict:
        db = await get_db()
        async with db.execute(
            "SELECT COUNT(*) as cnt FROM broker_tasks WHERE status = 'active'"
        ) as cur:
            active = (await cur.fetchone())["cnt"]
        async with db.execute(
            "SELECT COALESCE(SUM(token_count), 0) as total FROM broker_tasks"
        ) as cur:
            total_tokens = (await cur.fetchone())["total"]
        async with db.execute("SELECT COUNT(*) as cnt FROM token_audit") as cur:
            audit_count = (await cur.fetchone())["cnt"]
        return {
            "enabled": self.enabled,
            "app_id": self.app_id or None,
            "active_tasks": active,
            "total_tokens_issued": total_tokens,
            "audit_entries": audit_count,
        }
