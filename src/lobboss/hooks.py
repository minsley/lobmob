"""Safety guardrail hooks for the lobboss agent."""

import logging
import re
from typing import Any

logger = logging.getLogger("lobboss.hooks")

# Commands that should never be run by the agent
BLOCKED_COMMANDS = [
    r"rm\s+-rf\s+/",
    r"git\s+push\s+--force",
    r"git\s+push\s+-f\b",
    r"\bshutdown\b",
    r"\breboot\b",
    r"\bmkfs\b",
    r"\bdd\s+.*of=/dev/",
    r"\b(systemctl|service)\s+(stop|disable)\s+",
]

BLOCKED_RE = re.compile("|".join(BLOCKED_COMMANDS), re.IGNORECASE)

# Allowed lobster types
VALID_LOBSTER_TYPES = {"swe", "qa", "research"}


async def check_bash_command(tool_input: dict[str, Any]) -> dict[str, Any] | None:
    """PreToolUse hook for Bash: block dangerous commands.

    Returns None to allow, or a dict with 'decision': 'block' to deny.
    """
    command = tool_input.get("command", "")
    if BLOCKED_RE.search(command):
        logger.warning("BLOCKED dangerous command: %s", command[:200])
        return {
            "decision": "block",
            "reason": f"Command blocked by safety hook: {command[:100]}",
        }
    return None


async def check_spawn_lobster(tool_input: dict[str, Any]) -> dict[str, Any] | None:
    """PreToolUse hook for spawn_lobster: validate inputs."""
    lobster_type = tool_input.get("lobster_type", "")
    if lobster_type not in VALID_LOBSTER_TYPES:
        logger.warning("BLOCKED invalid lobster_type: %s", lobster_type)
        return {
            "decision": "block",
            "reason": f"Invalid lobster_type '{lobster_type}'. Must be one of: {VALID_LOBSTER_TYPES}",
        }

    task_id = tool_input.get("task_id", "")
    if not task_id:
        return {
            "decision": "block",
            "reason": "task_id is required for spawn_lobster",
        }
    return None


async def log_discord_post(tool_input: dict[str, Any], tool_output: dict[str, Any]) -> None:
    """PostToolUse hook for discord_post: log all Discord posts."""
    channel_id = tool_input.get("channel_id", "")
    content = tool_input.get("content", "")
    logger.info("Discord post to %s: %s", channel_id, content[:200])
