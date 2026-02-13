"""Claude Agent SDK integration for lobster workers."""

import logging
import os
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    TextBlock,
    query,
)

from lobster.config import LobsterConfig
from lobster.hooks import create_tool_checker

logger = logging.getLogger("lobster.agent")


async def _as_stream(prompt: str) -> AsyncIterator[dict[str, Any]]:
    """Wrap a string prompt as an async iterable of message dicts.

    Required when using can_use_tool with the one-shot query() function.
    """
    yield {
        "type": "user",
        "message": {"role": "user", "content": prompt},
    }

MODEL_MAP = {
    "opus": "claude-opus-4-6",
    "sonnet": "claude-sonnet-4-5",
    "haiku": "claude-haiku-4-5",
}


def _load_system_prompt(config: LobsterConfig) -> str:
    """Load the type-specific system prompt."""
    prompt_path = Path(__file__).parent / "prompts" / f"{config.lobster_type}.md"
    if prompt_path.exists():
        return prompt_path.read_text()

    # Fallback for container path
    container_path = Path("/app/lobster/prompts") / f"{config.lobster_type}.md"
    if container_path.exists():
        return container_path.read_text()

    logger.warning("No prompt found for type %s, using default", config.lobster_type)
    return f"You are a {config.lobster_type} lobster agent. Complete the assigned task."


async def run_task(config: LobsterConfig, task_body: str) -> dict:
    """Execute a task via Agent SDK query(). Returns result summary.

    Uses one-shot query() since lobsters are ephemeral.
    """
    system_prompt = _load_system_prompt(config)
    model = MODEL_MAP.get(config.model, config.model)

    # Build the full prompt with task context
    prompt = f"## Task: {config.task_id}\n\n{task_body}"

    # Determine allowed tools based on type
    allowed_tools = ["Read", "Glob", "Grep"]
    if config.lobster_type in ("swe", "research"):
        allowed_tools.extend(["Edit", "Write", "Bash"])
    elif config.lobster_type == "qa":
        allowed_tools.append("Bash")  # read-only bash (enforced by hooks)

    options = ClaudeAgentOptions(
        system_prompt=system_prompt,
        model=model,
        allowed_tools=allowed_tools,
        permission_mode="acceptEdits",
        max_turns=50,
        max_budget_usd=10.0,
        cwd=os.environ.get("WORKSPACE", "/workspace"),
        can_use_tool=create_tool_checker(config.lobster_type),
        stderr=lambda line: logger.debug("CLI: %s", line.rstrip()),
    )

    result = {
        "task_id": config.task_id,
        "model": model,
        "responses": [],
        "cost_usd": None,
        "num_turns": 0,
        "is_error": False,
        "session_id": None,
    }

    try:
        async for message in query(prompt=_as_stream(prompt), options=options):
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        result["responses"].append(block.text)

            elif isinstance(message, ResultMessage):
                result["cost_usd"] = message.total_cost_usd
                result["num_turns"] = message.num_turns
                result["is_error"] = message.is_error
                result["session_id"] = message.session_id
                if message.is_error:
                    logger.error("Agent SDK error: %s", message.result)
                else:
                    logger.info(
                        "Task %s complete: %d turns, $%.4f",
                        config.task_id,
                        message.num_turns,
                        message.total_cost_usd or 0,
                    )

    except Exception:
        logger.exception("Agent SDK query failed for task %s", config.task_id)
        result["is_error"] = True

    return result
