"""Custom MCP tools for lobboss (discord_post, spawn_lobster, lobster_status)."""

import logging
from typing import Any

from claude_agent_sdk import create_sdk_mcp_server, tool

logger = logging.getLogger("lobboss.mcp_tools")

# Reference to the Discord bot, injected at startup
_bot = None


def set_bot(bot: Any) -> None:
    """Inject the Discord bot instance for discord_post to use."""
    global _bot
    _bot = bot


@tool("discord_post", "Post a message to a Discord channel or thread", {
    "channel_id": str,
    "content": str,
})
async def discord_post(args: dict[str, Any]) -> dict[str, Any]:
    """Post a message to a Discord channel or thread."""
    if _bot is None:
        return {"content": [{"type": "text", "text": "Error: Discord bot not initialized"}]}

    channel_id = int(args["channel_id"])
    content = args["content"]

    channel = _bot.get_channel(channel_id)
    if channel is None:
        return {"content": [{"type": "text", "text": f"Error: Channel {channel_id} not found"}]}

    msg = await channel.send(content)
    logger.info("Posted to channel %s: message %s", channel_id, msg.id)
    return {"content": [{"type": "text", "text": f"Posted message {msg.id} to channel {channel_id}"}]}


@tool("spawn_lobster", "Spawn a lobster worker agent for a task", {
    "task_id": str,
    "lobster_type": str,
    "workflow": str,
})
async def spawn_lobster(args: dict[str, Any]) -> dict[str, Any]:
    """Spawn a lobster worker. Stub — replaced with real k8s Job creation in Phase 3."""
    task_id = args["task_id"]
    lobster_type = args["lobster_type"]
    workflow = args.get("workflow", "default")

    if lobster_type not in ("swe", "qa", "research"):
        return {"content": [{"type": "text", "text": f"Error: Invalid lobster_type '{lobster_type}'. Must be swe, qa, or research."}]}

    job_name = f"lobster-{lobster_type}-{task_id}"
    logger.info("STUB: Would spawn %s lobster for task %s (workflow=%s)", lobster_type, task_id, workflow)

    return {"content": [{"type": "text", "text": f"[STUB] Spawned job: {job_name} (type={lobster_type}, workflow={workflow})"}]}


@tool("lobster_status", "Get status of lobster workers", {
    "task_id": str,
})
async def lobster_status(args: dict[str, Any]) -> dict[str, Any]:
    """Get lobster worker status. Stub — replaced with real k8s queries in Phase 3."""
    task_id = args.get("task_id", "")
    logger.info("STUB: Would query lobster status for task_id=%s", task_id)

    return {"content": [{"type": "text", "text": "[STUB] No active lobsters (k8s integration pending)"}]}


# MCP server instance — wire into ClaudeAgentOptions.mcp_servers
lobmob_mcp = create_sdk_mcp_server(
    name="lobmob",
    version="1.0.0",
    tools=[discord_post, spawn_lobster, lobster_status],
)
