"""lobwife_client — async HTTP client for the lobwife API.

Shared by lobboss (via mcp_tools), lobsters (via run_task), and
Python cron scripts (task-manager, status-reporter).
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any, Optional

import aiohttp

log = logging.getLogger("common.lobwife_client")

LOBWIFE_URL = os.environ.get(
    "LOBWIFE_URL", "http://lobwife.lobmob.svc.cluster.local:8081"
)

# Retry config: 3 attempts with backoff
_RETRY_DELAYS = (2, 5, 10)


class LobwifeAPIError(Exception):
    """Raised on non-2xx responses from the lobwife API."""

    def __init__(self, status: int, message: str):
        self.status = status
        super().__init__(f"lobwife API {status}: {message}")


async def _request(
    method: str,
    path: str,
    *,
    json: Optional[dict] = None,
    params: Optional[dict] = None,
    session: Optional[aiohttp.ClientSession] = None,
) -> Any:
    """Make an HTTP request to the lobwife API with retry."""
    url = f"{LOBWIFE_URL}{path}"
    own_session = session is None
    if own_session:
        session = aiohttp.ClientSession()

    last_err = None
    try:
        for attempt, delay in enumerate((*_RETRY_DELAYS, None)):
            try:
                async with session.request(
                    method, url, json=json, params=params,
                    timeout=aiohttp.ClientTimeout(total=15),
                ) as resp:
                    body = await resp.json()
                    if resp.status >= 400:
                        msg = body.get("error", str(body)) if isinstance(body, dict) else str(body)
                        raise LobwifeAPIError(resp.status, msg)
                    return body
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                last_err = e
                if delay is not None:
                    log.warning(
                        "lobwife API %s %s failed (attempt %d): %s, retrying in %ds",
                        method, path, attempt + 1, e, delay,
                    )
                    await asyncio.sleep(delay)
        raise RuntimeError(f"lobwife API unreachable after {len(_RETRY_DELAYS)} retries: {last_err}")
    finally:
        if own_session:
            await session.close()


async def create_task(
    name: str,
    type: str = "swe",
    priority: str = "normal",
    *,
    session: Optional[aiohttp.ClientSession] = None,
    **kwargs: Any,
) -> dict:
    """POST /api/v1/tasks — create a task. Returns {id, task_id}."""
    payload = {"name": name, "type": type, "priority": priority, **kwargs}
    return await _request("POST", "/api/v1/tasks", json=payload, session=session)


async def get_task(
    task_id: int,
    *,
    session: Optional[aiohttp.ClientSession] = None,
) -> dict:
    """GET /api/v1/tasks/{id} — get a single task."""
    return await _request("GET", f"/api/v1/tasks/{task_id}", session=session)


async def list_tasks(
    *,
    status: Optional[str] = None,
    type: Optional[str] = None,
    limit: int = 100,
    session: Optional[aiohttp.ClientSession] = None,
) -> list:
    """GET /api/v1/tasks — list tasks with optional filters."""
    params = {"limit": str(limit)}
    if status:
        params["status"] = status
    if type:
        params["type"] = type
    return await _request("GET", "/api/v1/tasks", params=params, session=session)


async def update_task(
    task_id: int,
    *,
    session: Optional[aiohttp.ClientSession] = None,
    **fields: Any,
) -> dict:
    """PATCH /api/v1/tasks/{id} — update task fields."""
    return await _request("PATCH", f"/api/v1/tasks/{task_id}", json=fields, session=session)


async def log_event(
    task_id: int,
    event_type: str,
    detail: Optional[str] = None,
    actor: Optional[str] = None,
    *,
    session: Optional[aiohttp.ClientSession] = None,
) -> dict:
    """POST /api/v1/tasks/{id}/events — log a task event."""
    payload = {"event_type": event_type}
    if detail:
        payload["detail"] = detail
    if actor:
        payload["actor"] = actor
    return await _request("POST", f"/api/v1/tasks/{task_id}/events", json=payload, session=session)


async def register_broker(
    task_id: int,
    repos: list[str],
    lobster_type: str,
    *,
    session: Optional[aiohttp.ClientSession] = None,
) -> dict:
    """PATCH /api/v1/tasks/{id} — set broker fields on a task."""
    from datetime import datetime, timezone
    now_iso = datetime.now(timezone.utc).isoformat()
    return await update_task(
        task_id,
        broker_repos=repos,
        broker_status="active",
        broker_registered_at=now_iso,
        actor=f"broker/{lobster_type}",
        session=session,
    )
