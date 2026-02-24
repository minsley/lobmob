"""Claude Agent SDK integration for lobster workers."""

import asyncio
import logging
import os
import time
from pathlib import Path
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    PermissionResultDeny,
    ResultMessage,
    TextBlock,
)

from common.models import resolve_model
from common.vault import pull_vault
from lobster.config import LobsterConfig
from lobster.hooks import create_tool_checker
from lobster.verify import verify_completion

logger = logging.getLogger("lobster.agent")

MAX_OUTER_TURNS = 5


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
    base_path = _resolve_prompt_path(f"{config.lobster_type}.md")
    if base_path:
        prompt = base_path.read_text()
    else:
        logger.warning("No prompt found for type %s, using default", config.lobster_type)
        prompt = f"You are a {config.lobster_type} lobster agent. Complete the assigned task."

    if config.workflow != "default":
        overlay_path = _resolve_prompt_path(f"{config.lobster_type}-{config.workflow}.md")
        if overlay_path:
            prompt += f"\n\n---\n\n# Workflow: {config.workflow}\n\n"
            prompt += overlay_path.read_text()
            logger.info("Loaded workflow overlay: %s-%s", config.lobster_type, config.workflow)
        else:
            logger.warning("No overlay found for %s-%s", config.lobster_type, config.workflow)

    return prompt


async def _emit(q: asyncio.Queue | None, event_type: str, data: dict) -> None:
    """Put an event onto the queue. Drops silently if queue is full or absent."""
    if q is None:
        return
    try:
        q.put_nowait({"type": event_type, "ts": time.time(), **data})
    except asyncio.QueueFull:
        logger.warning("Event queue full — dropping %s", event_type)


def _drain_inject_queue(q: asyncio.Queue | None) -> list[str]:
    """Drain all pending injection messages from the queue."""
    if not q:
        return []
    items = []
    while True:
        try:
            items.append(q.get_nowait())
        except asyncio.QueueEmpty:
            break
    return items


def _build_continue_prompt(task_id: str, missing: list[str], injections: list[str]) -> str:
    """Build prompt for verification-failure continuation (may include injections)."""
    path = _resolve_prompt_path("continue.md")
    if path:
        tmpl = path.read_text()
        missing_str = "\n".join(f"- {s}" for s in missing)
        inject_str = "\n".join(f"- {m}" for m in injections) if injections else "(none)"
        return (tmpl
                .replace("{task_id}", task_id)
                .replace("{missing_steps}", missing_str)
                .replace("{operator_messages}", inject_str))
    # Inline fallback
    lines = [f"## Continue: {task_id}", "", "The following steps remain incomplete:"]
    lines += [f"- {s}" for s in missing]
    if injections:
        lines += ["", "Operator messages:"] + [f"- {m}" for m in injections]
    lines += ["", "Review what's already done, then complete only the missing steps."]
    return "\n".join(lines)


def _build_inject_prompt(task_id: str, injections: list[str]) -> str:
    """Build prompt for operator-injection continuation (no verification failure)."""
    path = _resolve_prompt_path("inject.md")
    if path:
        tmpl = path.read_text()
        inject_str = "\n".join(f"- {m}" for m in injections)
        return (tmpl
                .replace("{task_id}", task_id)
                .replace("{operator_messages}", inject_str))
    # Inline fallback
    lines = [
        f"## Operator Guidance: {task_id}",
        "",
        "The operator has interrupted with the following message(s):",
    ]
    lines += [f"- {m}" for m in injections]
    lines += [
        "",
        "Incorporate this guidance and continue your work.",
        "You were interrupted mid-task — review what you've already done,",
        "then proceed with the operator's direction in mind.",
    ]
    return "\n".join(lines)


def _make_tool_checker(
    config: LobsterConfig,
    event_queue: asyncio.Queue | None,
    inject_event: asyncio.Event | None,
) -> Any:
    """Wrap existing tool checker to emit events and check for pending injections."""
    inner = create_tool_checker(config.lobster_type)

    async def check_tool(tool_name: str, tool_input: dict, context: Any) -> Any:
        await _emit(event_queue, "tool_start", {"tool": tool_name, "input": tool_input})

        # Inject pending — interrupt at this tool boundary
        if inject_event and inject_event.is_set():
            logger.info("Injection pending — denying tool %s to interrupt episode", tool_name)
            await _emit(event_queue, "tool_denied", {
                "tool": tool_name,
                "reason": "injection_interrupt",
            })
            return PermissionResultDeny(
                message="The operator has provided new guidance. "
                "Stop what you're doing and wrap up this turn. "
                "You will receive the operator's message in the next prompt."
            )

        return await inner(tool_name, tool_input, context)

    return check_tool


async def run_task(
    config: LobsterConfig,
    task_body: str,
    event_queue: asyncio.Queue | None = None,
    inject_queue: asyncio.Queue | None = None,
    inject_event: asyncio.Event | None = None,
) -> dict:
    """Execute a task via ClaudeSDKClient episode loop. Returns result summary.

    Each episode (outer turn) is a persistent client.query() call. Between episodes
    the agent verifies completion and continues if steps are missing. Operator
    injections interrupt the current episode at the next tool boundary.
    """
    system_prompt = _load_system_prompt(config)
    model = resolve_model(config.model)

    # Determine allowed tools based on type
    allowed_tools = ["Read", "Glob", "Grep"]
    if config.lobster_type in ("swe", "research", "system"):
        allowed_tools.extend(["Edit", "Write", "Bash"])
    elif config.lobster_type == "qa":
        allowed_tools.append("Bash")
    elif config.lobster_type == "image-gen":
        allowed_tools.extend(["Write", "Bash"])

    # MCP servers for specialized types — preserve from prior run_task()
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
        can_use_tool=_make_tool_checker(config, event_queue, inject_event),
        mcp_servers=mcp_servers or None,
        stderr=lambda line: logger.debug("CLI: %s", line.rstrip()),
    )

    result: dict = {
        "task_id": config.task_id,
        "model": model,
        "responses": [],
        "cost_usd": 0,
        "num_turns": 0,
        "is_error": False,
        "session_id": None,
    }

    client = ClaudeSDKClient(options=options)
    await client.connect()
    try:
        prompt = f"## Task: {config.task_id}\n\n{task_body}"
        missing: list[str] = []

        for outer_turn in range(MAX_OUTER_TURNS):
            if outer_turn > 0:
                injections = _drain_inject_queue(inject_queue)
                if injections and not missing:
                    prompt = _build_inject_prompt(config.task_id, injections)
                elif missing:
                    prompt = _build_continue_prompt(config.task_id, missing, injections)
                if injections:
                    await _emit(event_queue, "inject", {"messages": injections})

            await _emit(event_queue, "turn_start", {"outer_turn": outer_turn})
            await client.query(prompt)

            async for message in client.receive_response():
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            result["responses"].append(block.text)
                            await _emit(event_queue, "text", {"text": block.text})
                elif isinstance(message, ResultMessage):
                    result["cost_usd"] += message.total_cost_usd or 0
                    result["num_turns"] += message.num_turns
                    result["is_error"] = message.is_error
                    result["session_id"] = message.session_id
                    await _emit(event_queue, "turn_end", {
                        "outer_turn": outer_turn,
                        "inner_turns": message.num_turns,
                        "cost_usd": message.total_cost_usd,
                        "is_error": message.is_error,
                    })
                    if message.is_error:
                        logger.error(
                            "Agent SDK error on episode %d for task %s",
                            outer_turn, config.task_id,
                        )
                        break

            if result["is_error"]:
                break

            # Was this episode interrupted by an injection?
            if inject_event and inject_event.is_set():
                inject_event.clear()
                await _emit(event_queue, "inject_abort", {"outer_turn": outer_turn})
                # Skip verification — go to next episode with injected guidance
                missing = []
                continue

            try:
                await pull_vault(config.vault_path)
            except Exception:
                pass

            missing = await verify_completion(
                config.task_id, config.lobster_type, config.vault_path
            )
            await _emit(event_queue, "verify", {"outer_turn": outer_turn, "missing": missing})

            if not missing:
                logger.info(
                    "Task %s verified complete after episode %d: %d turns, $%.4f",
                    config.task_id, outer_turn, result["num_turns"], result["cost_usd"],
                )
                # Check for late-arriving injections before exiting
                if inject_event and inject_event.is_set():
                    inject_event.clear()
                    continue
                break
            else:
                logger.warning(
                    "Episode %d: verification missing %d steps, continuing",
                    outer_turn, len(missing),
                )

        else:
            logger.error(
                "Task %s: MAX_OUTER_TURNS (%d) exhausted without verification pass",
                config.task_id, MAX_OUTER_TURNS,
            )

    finally:
        try:
            await client.disconnect()
        except Exception:
            pass

    await _emit(event_queue, "done", {
        "is_error": result["is_error"],
        "cost_usd": result["cost_usd"],
    })
    return result


async def run_retry(config: LobsterConfig, missing: list[str]) -> dict:
    """Deprecated: superseded by episode loop in run_task(). Left intact for reference."""
    logger.warning(
        "run_retry() is deprecated — episode loop handles retries in-session. "
        "This should not be called."
    )
    return {
        "task_id": config.task_id,
        "model": resolve_model(config.model),
        "responses": [],
        "cost_usd": 0,
        "num_turns": 0,
        "is_error": False,
        "session_id": None,
    }
