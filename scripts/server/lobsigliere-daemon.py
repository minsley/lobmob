#!/usr/bin/env python3
"""
lobsigliere autonomous task processor daemon.

Polls vault every 30s for type=system tasks and executes them
via Agent SDK. Runs as a background process in the lobsigliere container.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from common.vault import commit_and_push, pull_vault, read_task, write_task
from lobster.agent import run_task
from lobster.config import LobsterConfig

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("lobsigliere-daemon")

VAULT_PATH = os.environ.get("VAULT_PATH", "/home/engineer/vault")
WORKSPACE = os.environ.get("SYSTEM_WORKSPACE", "/home/engineer/lobmob")
POLL_INTERVAL = 30  # seconds
PR_URL_RE = re.compile(r"https://github\.com/[^\s]+/pull/\d+")


async def find_system_task() -> tuple[str | None, dict | None]:
    """Find first queued system task in the vault."""
    active_dir = Path(VAULT_PATH) / "010-tasks" / "active"
    if not active_dir.exists():
        return None, None

    for task_file in sorted(active_dir.glob("*.md")):
        try:
            task_data = read_task(VAULT_PATH, task_file.stem)
            meta = task_data["metadata"]
            if meta.get("type") == "system" and meta.get("status") == "queued":
                return task_file.stem, task_data
        except Exception as e:
            logger.warning("Error reading %s: %s", task_file.name, e)
    return None, None


async def claim_task(task_id: str, task_data: dict) -> bool:
    """Atomically claim task by updating to system-active and pushing.

    Returns True if claim succeeded, False if another instance claimed it first.
    """
    meta = task_data["metadata"].copy()
    meta["status"] = "system-active"
    meta["assigned_to"] = "lobsigliere"
    meta["assigned_at"] = datetime.now(timezone.utc).isoformat()

    write_task(VAULT_PATH, task_id, meta, task_data["body"])

    try:
        await commit_and_push(
            VAULT_PATH,
            message=f"[lobsigliere] Claim task {task_id}",
            files=[f"010-tasks/active/{task_id}.md"],
        )
        return True
    except Exception as e:
        logger.info("Claim conflict for %s: %s", task_id, e)
        await pull_vault(VAULT_PATH)
        return False


async def prepare_workspace(task_id: str) -> str:
    """Ensure workspace is on a fresh branch from develop. Returns branch name."""
    branch = f"system/{task_id}"

    cmds = [
        ["git", "-C", WORKSPACE, "fetch", "origin"],
        ["git", "-C", WORKSPACE, "checkout", "develop"],
        ["git", "-C", WORKSPACE, "reset", "--hard", "origin/develop"],
        ["git", "-C", WORKSPACE, "checkout", "-b", branch],
    ]
    for cmd in cmds:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
        if proc.returncode != 0:
            err = stderr.decode().strip()
            # Branch already exists — abort
            if "already exists" in err:
                raise RuntimeError(f"Branch {branch} already exists — skipping task")
            raise RuntimeError(f"Workspace prep failed: {err}")

    logger.info("Workspace ready on branch %s", branch)
    return branch


async def cleanup_workspace():
    """Return workspace to develop after task completes."""
    proc = await asyncio.create_subprocess_exec(
        "git", "-C", WORKSPACE, "checkout", "develop",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    await asyncio.wait_for(proc.communicate(), timeout=15)


def extract_pr_url(result: dict) -> str | None:
    """Extract a PR URL from agent result text."""
    for response in result.get("responses", []):
        match = PR_URL_RE.search(response)
        if match:
            return match.group(0)
    return None


async def execute_task(task_id: str, task_body: str) -> dict:
    """Execute a system task via Agent SDK."""
    config = LobsterConfig.from_env()
    config.task_id = task_id
    config.lobster_type = "system"
    config.model = "opus"

    # Point Agent SDK at the lobmob workspace
    os.environ["WORKSPACE"] = WORKSPACE

    logger.info("Executing task %s via Agent SDK...", task_id)
    result = await run_task(config, task_body)

    logger.info(
        "Task %s finished: turns=%d cost=$%.4f error=%s",
        task_id,
        result.get("num_turns", 0),
        result.get("cost_usd") or 0,
        result.get("is_error", False),
    )
    return result


async def process_task(task_id: str, task_data: dict):
    """Full task processing: prepare workspace, execute, update vault."""
    logger.info("Processing task: %s", task_id)
    meta = task_data["metadata"].copy()
    body = task_data["body"]

    try:
        branch = await prepare_workspace(task_id)
        result = await execute_task(task_id, body)

        pr_url = extract_pr_url(result)
        is_error = result.get("is_error", False)

        if is_error:
            meta["status"] = "failed"
            body += f"\n\n## Error\n\nAgent execution failed (branch: `{branch}`)."
        else:
            meta["status"] = "completed"
            meta["completed_at"] = datetime.now(timezone.utc).isoformat()
            pr_line = f"PR: {pr_url}" if pr_url else "No PR created."
            body += f"\n\n## Result\n\n{pr_line}\n\nAgent execution completed."

        write_task(VAULT_PATH, task_id, meta, body)
        await commit_and_push(
            VAULT_PATH,
            message=f"[lobsigliere] {'Complete' if not is_error else 'Fail'} task {task_id}",
            files=[f"010-tasks/active/{task_id}.md"],
        )
        logger.info("Task %s %s", task_id, "completed" if not is_error else "failed")

    except Exception as e:
        logger.error("Task %s failed: %s", task_id, e)
        meta["status"] = "failed"
        body += f"\n\n## Error\n\n```\n{e}\n```"
        try:
            write_task(VAULT_PATH, task_id, meta, body)
            await commit_and_push(
                VAULT_PATH,
                message=f"[lobsigliere] Fail task {task_id}",
                files=[f"010-tasks/active/{task_id}.md"],
            )
        except Exception as e2:
            logger.error("Failed to update vault for %s: %s", task_id, e2)

    finally:
        await cleanup_workspace()


async def _get_broker_token() -> str:
    """Fetch a service token from the lobwife broker."""
    lobwife_url = os.environ.get("LOBWIFE_URL", "")
    service = os.environ.get("SERVICE_NAME", "lobsigliere")
    if not lobwife_url:
        return ""
    try:
        import aiohttp
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{lobwife_url}/api/v1/service-token",
                json={"service": service},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return data["token"]
                logger.warning("Broker token request failed: HTTP %d", resp.status)
    except Exception as e:
        logger.warning("Failed to fetch broker token: %s", e)
    return ""


async def ensure_vault() -> bool:
    """Clone vault if not present, otherwise pull. Returns True if vault is ready."""
    vault = Path(VAULT_PATH)
    if (vault / ".git").is_dir():
        await pull_vault(VAULT_PATH)
        return True

    # Derive vault repo from env
    vault_repo = os.environ.get("VAULT_REPO", "")
    if not vault_repo:
        env = os.environ.get("LOBMOB_ENV", "prod")
        vault_repo = "minsley/lobmob-vault-dev" if env == "dev" else "minsley/lobmob-vault"

    # Get token from broker (preferred) or fall back to env
    token = await _get_broker_token()
    if not token:
        token = os.environ.get("GH_TOKEN", "")
    if not token:
        logger.error("No GitHub token available for vault clone")
        return False

    clone_url = f"https://x-access-token:{token}@github.com/{vault_repo}.git"
    clean_url = f"https://github.com/{vault_repo}.git"

    logger.info("Cloning vault from %s...", vault_repo)
    proc = await asyncio.create_subprocess_exec(
        "git", "clone", clone_url, str(vault),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)
    if proc.returncode != 0:
        logger.error("Vault clone failed: %s", stderr.decode().strip())
        return False

    # Strip credentials from remote — gh auth handles future operations
    await asyncio.create_subprocess_exec(
        "git", "-C", str(vault), "remote", "set-url", "origin", clean_url,
    )
    logger.info("Vault cloned successfully")
    return True


async def main_loop():
    """Main polling loop."""
    logger.info("lobsigliere daemon starting...")
    logger.info("Vault: %s | Workspace: %s | Interval: %ds", VAULT_PATH, WORKSPACE, POLL_INTERVAL)

    while True:
        try:
            if not await ensure_vault():
                logger.warning("Vault not available, retrying in %ds...", POLL_INTERVAL)
                await asyncio.sleep(POLL_INTERVAL)
                continue

            task_id, task_data = await find_system_task()
            if task_id:
                if await claim_task(task_id, task_data):
                    # Process synchronously — one task at a time for workspace safety
                    await process_task(task_id, task_data)

        except Exception as e:
            logger.error("Daemon loop error: %s", e)

        await asyncio.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    asyncio.run(main_loop())
