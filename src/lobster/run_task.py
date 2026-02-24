"""Lobster task runner — entrypoint for ephemeral agent sessions."""

import argparse
import asyncio
import logging
import os
import sys

from common.logging import setup_logging, log_structured
from common.vault import pull_vault, read_task
from lobster.agent import run_task
from lobster.config import LobsterConfig

logger = logging.getLogger("lobster.run_task")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lobster task runner")
    parser.add_argument("--task", required=True, help="Task ID (e.g. T42 or task-2026-02-12-a1b2)")
    parser.add_argument("--type", default=None, help="Lobster type: swe, qa, research (overrides env)")
    parser.add_argument("--vault-path", default=None, help="Path to vault repo (overrides env)")
    parser.add_argument("--token-budget", type=int, default=None, help="Max tokens (overrides env)")
    return parser.parse_args()


def _parse_db_id(task_id: str) -> int | None:
    """Extract DB id from T-format task ID (e.g. 'T42' -> 42)."""
    if task_id.startswith("T") and task_id[1:].isdigit():
        return int(task_id[1:])
    return None


async def _api_log_event(db_id: int, event_type: str, detail: str = None, actor: str = None):
    """Best-effort API event log."""
    try:
        from common.lobwife_client import log_event
        await log_event(db_id, event_type, detail, actor)
    except Exception as e:
        logger.warning("Failed to log event via API: %s", e)


async def _api_update_status(db_id: int, status: str, **extra):
    """Best-effort API status update."""
    try:
        from common.lobwife_client import update_task
        await update_task(db_id, status=status, actor="lobster", **extra)
    except Exception as e:
        logger.warning("Failed to update task status via API: %s", e)


async def main_async() -> int:
    args = parse_args()

    # Build config from env, then override with CLI args
    config = LobsterConfig.from_env()
    config.task_id = args.task
    if args.type:
        config.lobster_type = args.type
    if args.vault_path:
        config.vault_path = args.vault_path
    if args.token_budget:
        config.token_budget = args.token_budget

    db_id = _parse_db_id(config.task_id)

    logger.info("Starting lobster: task=%s type=%s model=%s", config.task_id, config.lobster_type, config.model)

    # Set GH_TOKEN for gh CLI (agent subprocess inherits env).
    # The gh-lobwife wrapper also refreshes tokens per-invocation for long tasks,
    # but setting env here ensures auth works even if the wrapper isn't in PATH.
    await _setup_gh_token(config.task_id)

    # Log started event via API
    if db_id:
        await _api_log_event(db_id, "started", f"type={config.lobster_type} model={config.model}", "lobster")

    # Pull latest vault (non-fatal — vault may be bind-mounted in local dev)
    try:
        await pull_vault(config.vault_path)
    except Exception:
        logger.warning("Failed to pull vault (continuing with local copy): %s", config.vault_path)

    # Read task file (try T-format, then slug from API)
    try:
        task_data = read_task(config.vault_path, config.task_id)
    except FileNotFoundError:
        task_data = None
        if db_id:
            try:
                from common.lobwife_client import get_task
                api_task = await get_task(db_id)
                slug = api_task.get("slug", "")
                if slug and slug != config.task_id:
                    try:
                        task_data = read_task(config.vault_path, slug)
                        logger.info("Found task by slug fallback: %s -> %s", config.task_id, slug)
                    except FileNotFoundError:
                        pass
            except Exception as e:
                logger.warning("Failed to look up slug via API: %s", e)
        if not task_data:
            logger.error("Task %s not found in vault at %s", config.task_id, config.vault_path)
            if db_id:
                await _api_update_status(db_id, "failed", completed_at=_now_iso())
                await _api_log_event(db_id, "failed", "Task file not found in vault", "lobster")
            return 1

    metadata = task_data["metadata"]
    body = task_data["body"]

    # Override model from task metadata if present
    if metadata.get("model"):
        config.model = metadata["model"]

    logger.info("Task loaded: status=%s, type=%s", metadata.get("status"), metadata.get("type"))

    # Set up event queues and IPC server for attach/inject support
    event_queue: asyncio.Queue = asyncio.Queue(maxsize=500)
    inject_queue: asyncio.Queue = asyncio.Queue(maxsize=100)
    inject_event = asyncio.Event()

    ipc_server = None
    try:
        from lobster.ipc import LobsterIPC
        ipc_server = LobsterIPC(event_queue, inject_queue, inject_event)
        await ipc_server.start()
    except Exception as e:
        logger.warning("IPC server unavailable (attach disabled): %s", e)

    try:
        result = await run_task(
            config, body,
            event_queue=event_queue,
            inject_queue=inject_queue,
            inject_event=inject_event,
        )
    finally:
        if ipc_server:
            await ipc_server.stop()

    total_turns = result["num_turns"]
    total_cost = result["cost_usd"]

    log_structured(
        logger, "Task complete",
        task_id=config.task_id,
        lobster_type=config.lobster_type,
        model=config.model,
        turns=total_turns,
        cost_usd=total_cost,
        is_error=result["is_error"],
    )

    # Safety net: ensure vault PR exists (agent may have forgotten)
    vault_repo = os.environ.get("VAULT_REPO", "")
    if vault_repo and not result["is_error"]:
        try:
            await _ensure_vault_pr(config, vault_repo)
        except Exception as e:
            logger.warning("Vault PR safety net failed: %s", e)

    # PATCH API with final status
    now = _now_iso()
    if db_id:
        if result["is_error"]:
            await _api_update_status(db_id, "failed", completed_at=now)
            await _api_log_event(db_id, "failed", f"turns={total_turns} cost=${total_cost:.2f}", "lobster")
        else:
            await _api_update_status(db_id, "completed", completed_at=now)
            await _api_log_event(db_id, "completed", f"turns={total_turns} cost=${total_cost:.2f}", "lobster")

    return 1 if result["is_error"] else 0


async def _setup_gh_token(task_id: str) -> None:
    """Fetch a GitHub token from lobwife broker, set GH_TOKEN, configure git to use gh."""
    lobwife_url = os.environ.get("LOBWIFE_URL", "")
    if not lobwife_url:
        return
    try:
        import aiohttp
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{lobwife_url}/api/token",
                json={"task_id": task_id},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    os.environ["GH_TOKEN"] = data["token"]
                    logger.info("GH_TOKEN set from broker")
                else:
                    logger.warning("Broker token request failed: HTTP %d", resp.status)
    except Exception as e:
        logger.warning("Failed to fetch broker token for gh CLI: %s", e)
        return

    # Wire git credentials through gh-lobwife wrapper (not gh-real, so broker tokens flow)
    try:
        proc = await asyncio.create_subprocess_exec(
            "git", "config", "--global",
            "credential.https://github.com.helper",
            "!/usr/local/bin/gh auth git-credential",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await asyncio.wait_for(proc.communicate(), timeout=5)
        logger.info("git credential helper configured (gh-lobwife wrapper)")
    except Exception as e:
        logger.warning("Failed to configure git credential helper: %s", e)


async def _ensure_vault_pr(config, vault_repo: str) -> None:
    """Safety net: create vault PR if the agent forgot to.

    Checks if a PR exists for this task's branch. If not, creates one
    using a lightweight agent query for the PR description.
    """
    import subprocess

    task_id = config.task_id
    branch_prefix = f"lobster-swe-{task_id.lower()}"

    # Check if there's a remote branch for this task
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{vault_repo}/pulls",
             "--jq", f'[.[] | select(.head.ref | startswith("{branch_prefix}"))][0].html_url'],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode == 0 and result.stdout.strip():
            logger.info("Vault PR already exists: %s", result.stdout.strip())
            return
    except Exception as e:
        logger.warning("Failed to check for existing PR: %s", e)
        return

    # List remote branches matching this task
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{vault_repo}/branches",
             "--jq", f'[.[] | select(.name | startswith("{branch_prefix}"))][0].name'],
            capture_output=True, text=True, timeout=15,
        )
        branch_name = result.stdout.strip()
        if not branch_name:
            logger.info("No remote branch found for %s — no PR to create", task_id)
            return
    except Exception as e:
        logger.warning("Failed to list branches: %s", e)
        return

    # Create PR with template description
    logger.info("Creating safety-net vault PR for %s (branch: %s)", task_id, branch_name)
    try:
        title = f"[lobster] {task_id} — vault changes"
        body = f"Automated PR created by lobster safety net.\n\nTask: {task_id}\nBranch: {branch_name}"
        result = subprocess.run(
            ["gh", "api", f"repos/{vault_repo}/pulls",
             "-f", f"title={title}",
             "-f", f"body={body}",
             "-f", f"head={branch_name}",
             "-f", "base=main"],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode == 0:
            import json as _json
            pr_data = _json.loads(result.stdout)
            logger.info("Created safety-net PR: %s", pr_data.get("html_url", ""))
        else:
            logger.warning("Failed to create safety-net PR: %s", result.stderr.strip())
    except Exception as e:
        logger.warning("Failed to create safety-net PR: %s", e)


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> None:
    setup_logging(json_output=True)
    exit_code = asyncio.run(main_async())
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
