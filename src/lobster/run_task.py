"""Lobster task runner — entrypoint for ephemeral agent sessions."""

import argparse
import asyncio
import logging
import sys

from common.logging import setup_logging, log_structured
from common.vault import pull_vault, read_task
from lobster.agent import run_task
from lobster.config import LobsterConfig

logger = logging.getLogger("lobster.run_task")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lobster task runner")
    parser.add_argument("--task", required=True, help="Task ID (e.g. task-2026-02-12-a1b2)")
    parser.add_argument("--type", default=None, help="Lobster type: swe, qa, research (overrides env)")
    parser.add_argument("--vault-path", default=None, help="Path to vault repo (overrides env)")
    parser.add_argument("--token-budget", type=int, default=None, help="Max tokens (overrides env)")
    return parser.parse_args()


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

    logger.info("Starting lobster: task=%s type=%s model=%s", config.task_id, config.lobster_type, config.model)

    # Pull latest vault
    try:
        await pull_vault(config.vault_path)
    except Exception:
        logger.exception("Failed to pull vault")
        return 1

    # Read task file
    try:
        task_data = read_task(config.vault_path, config.task_id)
    except FileNotFoundError:
        logger.error("Task %s not found in vault at %s", config.task_id, config.vault_path)
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
    log_structured(
        logger, "Task complete",
        task_id=config.task_id,
        lobster_type=config.lobster_type,
        model=config.model,
        turns=result["num_turns"],
        cost_usd=result["cost_usd"],
        is_error=result["is_error"],
    )

    return 1 if result["is_error"] else 0


def main() -> None:
    setup_logging(json_output=True)
    exit_code = asyncio.run(main_async())
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
