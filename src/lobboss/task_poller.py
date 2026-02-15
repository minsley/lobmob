"""Autonomous task poller — picks up queued vault tasks and spawns lobsters."""

import asyncio
import logging
from datetime import datetime, timezone

from common.vault import commit_and_push, list_tasks, pull_vault, write_task
from lobboss.mcp_tools import NAMESPACE, _get_k8s_clients, _sanitize_k8s_name, _spawn_lobster_core

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
    await pull_vault(vault_path)

    active_count = _count_active_lobster_jobs()
    available = max_concurrent - active_count
    if available <= 0:
        logger.debug("At capacity (%d/%d active lobsters), skipping", active_count, max_concurrent)
        return 0

    tasks = list_tasks(vault_path, subdir="active")
    queued = [
        t for t in tasks
        if t["metadata"].get("status") == "queued"
        and t["metadata"].get("type") != "system"
    ]

    if not queued:
        return 0

    # Sort: priority (critical first), then oldest first (by queued_at or id)
    queued.sort(key=lambda t: (
        PRIORITY_ORDER.get(t["metadata"].get("priority", "normal"), 2),
        t["metadata"].get("queued_at", t["metadata"].get("id", "")),
    ))

    logger.info("Found %d queued task(s), %d slot(s) available", len(queued), available)

    spawned = 0
    for task in queued[:available]:
        meta = task["metadata"]
        task_id = meta.get("id", "")
        lobster_type = meta.get("type", "research")
        workflow = meta.get("workflow", "default")

        if _job_exists_for_task(task_id):
            logger.warning("Job already exists for task %s, skipping", task_id)
            continue

        try:
            job_name = await _spawn_lobster_core(task_id, lobster_type, workflow)
        except (ValueError, RuntimeError) as e:
            logger.error("Failed to spawn for task %s: %s", task_id, e)
            continue

        # Claim the task in vault
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        meta["status"] = "active"
        meta["assigned_to"] = job_name
        meta["assigned_at"] = now
        rel_path = write_task(vault_path, task_id, meta, task["body"])

        try:
            await commit_and_push(
                vault_path,
                f"[poller] Spawn {lobster_type} for {task_id}",
                [rel_path],
            )
        except Exception as e:
            logger.error("Failed to push vault claim for %s: %s (orphan detector will clean up)", task_id, e)

        # Post to Discord thread if configured
        thread_id = meta.get("discord_thread_id")
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
