"""Autonomous task poller — picks up queued tasks from API and spawns lobsters.

Queries lobwife API for queued tasks (source of truth), spawns k8s Jobs,
and dual-writes to vault frontmatter for Obsidian visibility (Phase 2).
"""

import asyncio
import logging
from datetime import datetime, timezone

from common.vault import commit_and_push, pull_vault, read_task, write_task
from common.lobwife_client import (
    list_tasks as api_list_tasks,
    update_task as api_update_task,
    log_event as api_log_event,
    register_broker as api_register_broker,
    LobwifeAPIError,
)
from lobboss.mcp_tools import (
    NAMESPACE, VAULT_REPO, _get_k8s_clients, _sanitize_k8s_name, _spawn_lobster_core,
)

logger = logging.getLogger("lobboss.task_poller")

PRIORITY_ORDER = {"critical": 0, "high": 1, "normal": 2, "low": 3}


def _count_active_lobster_jobs() -> int:
    """Count k8s lobster Jobs that are still active (not succeeded/failed)."""
    batch_api, _ = _get_k8s_clients()
    jobs = batch_api.list_namespaced_job(
        namespace=NAMESPACE,
        label_selector="app.kubernetes.io/name=lobster",
    )
    return sum(
        1 for j in jobs.items
        if j.status and j.status.active and j.status.active > 0
    )


def _job_exists_for_task(task_id: str) -> bool:
    """Check if a k8s Job already exists for this task-id (any state)."""
    batch_api, _ = _get_k8s_clients()
    label = f"lobmob.io/task-id={_sanitize_k8s_name(task_id)}"
    jobs = batch_api.list_namespaced_job(
        namespace=NAMESPACE,
        label_selector=label,
    )
    return len(jobs.items) > 0


async def poll_and_spawn(vault_path: str, max_concurrent: int, bot=None) -> int:
    """Single poll cycle. Returns number of tasks spawned."""
    # Pull vault for reading task body (lobster needs the file)
    await pull_vault(vault_path)

    active_count = _count_active_lobster_jobs()
    available = max_concurrent - active_count
    if available <= 0:
        logger.debug("At capacity (%d/%d active lobsters), skipping", active_count, max_concurrent)
        return 0

    # Query lobwife API for queued tasks (source of truth)
    try:
        queued = await api_list_tasks(status="queued")
    except (LobwifeAPIError, RuntimeError) as e:
        logger.error("Failed to query lobwife API for queued tasks: %s", e)
        return 0

    # Filter out system tasks
    queued = [t for t in queued if t.get("type") != "system"]

    if not queued:
        return 0

    # Sort: priority (critical first), then oldest first (by queued_at or id)
    queued.sort(key=lambda t: (
        PRIORITY_ORDER.get(t.get("priority", "normal"), 2),
        t.get("queued_at", t.get("created_at", "")),
    ))

    logger.info("Found %d queued task(s), %d slot(s) available", len(queued), available)

    spawned = 0
    for task in queued[:available]:
        db_id = task["id"]
        task_id = task["task_id"]  # "T42"
        lobster_type = task.get("type", "research")
        workflow = task.get("workflow", "default")

        if _job_exists_for_task(task_id):
            logger.warning("Job already exists for task %s, skipping", task_id)
            continue

        try:
            job_name = await _spawn_lobster_core(task_id, lobster_type, workflow)
        except (ValueError, RuntimeError) as e:
            logger.error("Failed to spawn for task %s: %s", task_id, e)
            continue

        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # PATCH API: claim the task (source of truth)
        try:
            await api_update_task(
                db_id,
                status="active",
                assigned_to=job_name,
                assigned_at=now,
                actor="task_poller",
            )
            await api_log_event(db_id, "spawned", f"Job {job_name} ({lobster_type})", "task_poller")
        except (LobwifeAPIError, RuntimeError) as e:
            logger.error("Failed to PATCH API for %s: %s (continuing with vault-only)", task_id, e)

        # Register broker on tasks table
        try:
            task_repos = [VAULT_REPO]
            if task.get("repos"):
                repos = task["repos"] if isinstance(task["repos"], list) else []
                task_repos.extend(repos)
            await api_register_broker(db_id, task_repos, lobster_type)
        except (LobwifeAPIError, RuntimeError) as e:
            logger.warning("Failed to register broker via API for %s: %s", task_id, e)

        # Dual-write: update vault frontmatter for Obsidian visibility
        # Try T-format first, then fall back to slug (for migrated tasks)
        vault_task_id = task_id
        try:
            task_data = read_task(vault_path, task_id)
        except FileNotFoundError:
            slug = task.get("slug")
            if slug and slug != task_id:
                try:
                    task_data = read_task(vault_path, slug)
                    vault_task_id = slug
                except FileNotFoundError:
                    task_data = None
            else:
                task_data = None

        if task_data:
            try:
                meta = task_data["metadata"]
                meta["status"] = "active"
                meta["assigned_to"] = job_name
                meta["assigned_at"] = now
                rel_path = write_task(vault_path, vault_task_id, meta, task_data["body"])
                await commit_and_push(
                    vault_path,
                    f"[poller] Spawn {lobster_type} for {task_id}",
                    [rel_path],
                )
            except Exception as e:
                logger.error("Failed to dual-write vault for %s: %s", task_id, e)
        else:
            logger.warning("Vault file not found for %s (task may be API-only)", task_id)

        # Post to Discord thread if configured
        thread_id = task.get("discord_thread_id")
        if thread_id and bot:
            try:
                channel = bot.get_channel(int(thread_id))
                if channel:
                    await channel.send(
                        f"**[poller]** Spawned **{lobster_type}** lobster `{job_name}` for **{task_id}**"
                    )
            except Exception as e:
                logger.warning("Failed to post Discord notification for %s: %s", task_id, e)

        logger.info("Spawned and claimed: %s -> %s", task_id, job_name)
        spawned += 1

    return spawned


async def run_poller(vault_path: str, interval: int, max_concurrent: int, bot=None) -> None:
    """Background loop that polls for queued tasks."""
    logger.info("Task poller started (interval=%ds, max_concurrent=%d)", interval, max_concurrent)
    while True:
        try:
            spawned = await poll_and_spawn(vault_path, max_concurrent, bot)
            if spawned:
                logger.info("Poll cycle complete: spawned %d task(s)", spawned)
        except Exception:
            logger.exception("Task poller cycle failed")
        await asyncio.sleep(interval)
