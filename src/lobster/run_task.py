"""Lobster task runner — entrypoint for ephemeral agent sessions."""

import argparse
import asyncio
import logging
import os
import sys

from common.logging import setup_logging, log_structured
from common.vault import pull_vault, read_task
from lobster.agent import run_retry, run_task
from lobster.config import LobsterConfig
from lobster.verify import verify_completion

logger = logging.getLogger("lobster.run_task")

MAX_RETRIES = 2


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

    # Run the agent
    result = await run_task(config, body)

    # Log summary
    total_turns = result["num_turns"]
    total_cost = result["cost_usd"] or 0
    log_structured(
        logger, "Task complete",
        task_id=config.task_id,
        lobster_type=config.lobster_type,
        model=config.model,
        turns=result["num_turns"],
        cost_usd=result["cost_usd"],
        is_error=result["is_error"],
    )

    # Verify-retry loop: check completion and retry missing steps
    if not result["is_error"]:
        for attempt in range(1, MAX_RETRIES + 1):
            # Pull vault to get fresh state before checking
            try:
                await pull_vault(config.vault_path)
            except Exception:
                pass

            missing = await verify_completion(config.task_id, config.lobster_type, config.vault_path)
            if not missing:
                logger.info("Verification passed — all steps complete")
                break

            logger.warning(
                "Verification attempt %d/%d: missing steps: %s",
                attempt, MAX_RETRIES, ", ".join(missing),
            )
            if db_id:
                await _api_log_event(db_id, "retry", f"Attempt {attempt}: {', '.join(missing)}", "lobster")

            retry_result = await run_retry(config, missing)
            total_turns += retry_result["num_turns"]
            total_cost += retry_result["cost_usd"] or 0

            if retry_result["is_error"]:
                logger.error("Retry %d failed with agent error, stopping", attempt)
                break
        else:
            # Ran all retries without breaking — do one final check
            try:
                await pull_vault(config.vault_path)
            except Exception:
                pass
            final_missing = await verify_completion(config.task_id, config.lobster_type, config.vault_path)
            if final_missing:
                logger.error(
                    "Still missing after %d retries: %s",
                    MAX_RETRIES, ", ".join(final_missing),
                )

    # PATCH API with final status
    now = _now_iso()
    final_status = "failed" if result["is_error"] else "completed"
    if db_id:
        if result["is_error"]:
            await _api_update_status(db_id, "failed", completed_at=now)
            await _api_log_event(db_id, "failed", f"turns={total_turns} cost=${total_cost:.2f}", "lobster")
        else:
            await _api_update_status(db_id, "completed", completed_at=now)
            await _api_log_event(db_id, "completed", f"turns={total_turns} cost=${total_cost:.2f}", "lobster")

    # Dual-write: update vault frontmatter with final status
    # May need to retry if a PR merge overwrites the status change
    try:
        from common.vault import commit_and_push, write_task, _run_git
        vault_tid = await _resolve_vault_tid(config.task_id, db_id)
        # Ensure we're on main before dual-writing (agent may have switched branches)
        try:
            await _run_git(config.vault_path, "checkout", "main")
        except Exception:
            pass
        for attempt in range(2):
            await pull_vault(config.vault_path)
            try:
                task_data = read_task(config.vault_path, vault_tid)
            except FileNotFoundError:
                task_data = read_task(config.vault_path, config.task_id)
                vault_tid = config.task_id
            meta = task_data["metadata"]
            if meta.get("status") == final_status:
                logger.info("Vault already shows %s for %s", final_status, config.task_id)
                break
            meta["status"] = final_status
            meta["completed_at"] = now
            rel_path = write_task(config.vault_path, vault_tid, meta, task_data["body"])
            await commit_and_push(
                config.vault_path,
                f"[lobster] Mark {config.task_id} as {final_status}",
                [rel_path],
            )
            # Verify it stuck (PR merges can overwrite)
            await pull_vault(config.vault_path)
            check = read_task(config.vault_path, vault_tid)
            if check["metadata"].get("status") == final_status:
                logger.info("Vault dual-write: %s -> %s", config.task_id, final_status)
                break
            logger.warning("Vault status overwritten (PR merge race), retrying...")
            await asyncio.sleep(3)
        else:
            logger.warning("Vault dual-write didn't stick after retries")
    except Exception as e:
        logger.warning("Failed to dual-write vault status: %s", e)

    # Always log totals if retries were attempted
    if total_turns != result["num_turns"] or total_cost != (result["cost_usd"] or 0):
        log_structured(
            logger, "Final totals (including retries)",
            task_id=config.task_id,
            total_turns=total_turns,
            total_cost_usd=total_cost,
        )

    return 1 if result["is_error"] else 0


async def _setup_gh_token(task_id: str) -> None:
    """Fetch a GitHub token from lobwife broker and export as GH_TOKEN for gh CLI."""
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


async def _resolve_vault_tid(task_id: str, db_id: int | None) -> str:
    """Resolve the vault task ID (may be slug for migrated tasks)."""
    if db_id:
        try:
            from common.lobwife_client import get_task as api_get_task
            api_t = await api_get_task(db_id)
            slug = api_t.get("slug", "")
            if slug and slug != task_id:
                return slug
        except Exception:
            pass
    return task_id


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> None:
    setup_logging(json_output=True)
    exit_code = asyncio.run(main_async())
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
