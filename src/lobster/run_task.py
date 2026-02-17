"""Lobster task runner — entrypoint for ephemeral agent sessions."""

import argparse
import asyncio
import logging
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
    if db_id:
        now = _now_iso()
        if result["is_error"]:
            await _api_update_status(db_id, "failed", completed_at=now)
            await _api_log_event(db_id, "failed", f"turns={total_turns} cost=${total_cost:.2f}", "lobster")
        else:
            await _api_update_status(db_id, "completed", completed_at=now)
            await _api_log_event(db_id, "completed", f"turns={total_turns} cost=${total_cost:.2f}", "lobster")

    # Always log totals if retries were attempted
    if total_turns != result["num_turns"] or total_cost != (result["cost_usd"] or 0):
        log_structured(
            logger, "Final totals (including retries)",
            task_id=config.task_id,
            total_turns=total_turns,
            total_cost_usd=total_cost,
        )

    return 1 if result["is_error"] else 0


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> None:
    setup_logging(json_output=True)
    exit_code = asyncio.run(main_async())
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
