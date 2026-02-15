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


def _resolve_prompt_path(filename: str) -> Path | None:
    """Find a prompt file in local source or container path."""
    local = Path(__file__).parent / "prompts" / filename
    if local.exists():
        return local
    container = Path("/app/lobster/prompts") / filename
    if container.exists():
        return container
    return None


def _load_system_prompt(config: LobsterConfig) -> str:
    """Load the type-specific system prompt, with optional workflow overlay."""
    # Base prompt for the lobster type
    base_path = _resolve_prompt_path(f"{config.lobster_type}.md")
    if base_path:
        prompt = base_path.read_text()
    else:
        logger.warning("No prompt found for type %s, using default", config.lobster_type)
        prompt = f"You are a {config.lobster_type} lobster agent. Complete the assigned task."

    # Workflow overlay (e.g. swe-android.md, swe-unity.md)
    if config.workflow != "default":
        overlay_path = _resolve_prompt_path(f"{config.lobster_type}-{config.workflow}.md")
        if overlay_path:
            prompt += f"\n\n---\n\n# Workflow: {config.workflow}\n\n"
            prompt += overlay_path.read_text()
            logger.info("Loaded workflow overlay: %s-%s", config.lobster_type, config.workflow)
        else:
            logger.warning("No overlay found for %s-%s", config.lobster_type, config.workflow)

    return prompt


def _load_retry_prompt(missing: list[str]) -> str:
    """Load the retry prompt template and fill in the missing steps."""
    path = _resolve_prompt_path("retry.md")
    if path:
        template = path.read_text()
    else:
        template = (
            "Your previous session did not complete all steps.\n"
            "Missing steps:\n{missing_steps}\n"
            "Complete them now."
        )
    formatted = "\n".join(f"- **{step}**" for step in missing)
    return template.replace("{missing_steps}", formatted)


async def run_retry(config: LobsterConfig, missing: list[str]) -> dict:
    """Run a focused retry query to complete missing workflow steps.

    Uses a smaller budget and the retry-specific prompt.
    """
    system_prompt = _load_retry_prompt(missing)
    model = MODEL_MAP.get(config.model, config.model)

    prompt = (
        f"## Retry for task: {config.task_id}\n\n"
        f"Complete the missing steps listed in your system prompt.\n"
        f"Vault path: {config.vault_path}\n"
    )

    allowed_tools = ["Read", "Glob", "Grep", "Edit", "Write", "Bash"]

    options = ClaudeAgentOptions(
        system_prompt=system_prompt,
        model=model,
        allowed_tools=allowed_tools,
        permission_mode="acceptEdits",
        max_turns=15,
        max_budget_usd=2.0,
        cwd=os.environ.get("WORKSPACE", "/workspace"),
        can_use_tool=create_tool_checker(config.lobster_type),
        stderr=lambda line: logger.debug("CLI (retry): %s", line.rstrip()),
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
                    logger.error("Retry agent error: %s", message.result)
                else:
                    logger.info(
                        "Retry for %s complete: %d turns, $%.4f",
                        config.task_id,
                        message.num_turns,
                        message.total_cost_usd or 0,
                    )
    except Exception:
        logger.exception("Retry query failed for task %s", config.task_id)
        result["is_error"] = True

    return result


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
    if config.lobster_type in ("swe", "research", "system"):
        allowed_tools.extend(["Edit", "Write", "Bash"])
    elif config.lobster_type == "qa":
        allowed_tools.append("Bash")  # read-only bash (enforced by hooks)
    elif config.lobster_type == "image-gen":
        allowed_tools.extend(["Write", "Bash"])  # save images, run git for vault

    # MCP servers for specialized types
    mcp_servers = []
    if config.lobster_type == "image-gen":
        from lobster.mcp_gemini import gemini_mcp
        mcp_servers.append(gemini_mcp)

    options = ClaudeAgentOptions(
        system_prompt=system_prompt,
        model=model,
        allowed_tools=allowed_tools,
        permission_mode="acceptEdits",
        max_turns=50,
        max_budget_usd=10.0,
        cwd=os.environ.get("WORKSPACE", "/workspace"),
        can_use_tool=create_tool_checker(config.lobster_type),
        mcp_servers=mcp_servers or None,
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
