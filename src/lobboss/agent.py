"""Claude Agent SDK integration for lobboss."""

import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    PermissionResultAllow,
    PermissionResultDeny,
    ResultMessage,
    TextBlock,
    ToolPermissionContext,
)

from lobboss.config import AgentConfig
from lobboss.hooks import check_bash_command, check_spawn_lobster
from lobboss.mcp_tools import lobmob_mcp

logger = logging.getLogger("lobboss.agent")


@dataclass
class SessionInfo:
    """Tracks an active Agent SDK session mapped to a Discord thread."""
    client: ClaudeSDKClient | None = None
    turn_count: int = 0
    created_at: float = field(default_factory=time.monotonic)
    total_tokens: int = 0


class LobbossAgent:
    """Wraps ClaudeSDKClient for lobboss multi-turn conversations.

    Keeps one persistent ClaudeSDKClient per Discord thread. The CLI subprocess
    stays alive between turns, so multi-turn context is maintained in-process
    without needing session resume.
    """

    def __init__(self, config: AgentConfig) -> None:
        self.config = config
        self._sessions: dict[int, SessionInfo] = {}  # thread_id -> SessionInfo
        self._system_prompt = self._load_system_prompt()
        self._max_age = config.max_session_age_hours * 3600
        self._max_context_pct = config.max_context_pct

    def _load_system_prompt(self) -> str:
        path = self.config.system_prompt_path
        if os.path.exists(path):
            with open(path) as f:
                return f.read()
        logger.warning("System prompt not found at %s, using default", path)
        return "You are lobboss, a task coordination agent for the lobmob swarm."

    def _build_options(self) -> ClaudeAgentOptions:
        return ClaudeAgentOptions(
            system_prompt=self._system_prompt,
            model=self._resolve_model(self.config.model),
            allowed_tools=[
                "Read", "Edit", "Bash", "Glob", "Grep",
                "mcp__lobmob__discord_post",
                "mcp__lobmob__spawn_lobster",
                "mcp__lobmob__lobster_status",
            ],
            mcp_servers={"lobmob": lobmob_mcp},
            permission_mode="acceptEdits",
            max_turns=25,
            can_use_tool=self._can_use_tool,
            stderr=lambda line: logger.debug("CLI: %s", line.rstrip()),
        )

    async def _can_use_tool(
        self,
        tool_name: str,
        tool_input: dict[str, Any],
        context: ToolPermissionContext,
    ) -> PermissionResultAllow | PermissionResultDeny:
        """Permission callback for tool use."""
        if tool_name == "Bash":
            result = await check_bash_command(tool_input)
            if result:
                return PermissionResultDeny(message=result.get("reason", "Blocked"))
        if tool_name == "mcp__lobmob__spawn_lobster":
            result = await check_spawn_lobster(tool_input)
            if result:
                return PermissionResultDeny(message=result.get("reason", "Blocked"))
        return PermissionResultAllow()

    @staticmethod
    def _resolve_model(short: str) -> str:
        models = {
            "opus": "claude-opus-4-6",
            "sonnet": "claude-sonnet-4-5",
            "haiku": "claude-haiku-4-5",
        }
        return models.get(short, short)

    def _needs_rotation(self, session: SessionInfo) -> bool:
        """Check if a session needs rotation due to age or context usage."""
        age = time.monotonic() - session.created_at
        if age > self._max_age:
            logger.info("Session rotation: age %.0fs exceeds max %.0fs", age, self._max_age)
            return True

        context_window = 200_000
        if session.total_tokens > context_window * self._max_context_pct:
            logger.info(
                "Session rotation: %d tokens exceeds %.0f%% of %d window",
                session.total_tokens, self._max_context_pct * 100, context_window,
            )
            return True

        return False

    async def _rotate_session(self, thread_id: int) -> SessionInfo:
        """Rotate a session: close old, create new with state summary."""
        old = self._sessions.get(thread_id)
        summary = ""
        if old:
            summary = (
                f"[Session rotated] Previous session had {old.turn_count} turns, "
                f"{old.total_tokens} tokens, age {time.monotonic() - old.created_at:.0f}s. "
                f"Continue where you left off. Active threads and tasks should be "
                f"re-read from the vault at /opt/vault if needed."
            )

        await self.close_session(thread_id)
        new_session = await self._create_session(thread_id)

        if summary:
            new_session._rotation_summary = summary

        return new_session

    async def _create_session(self, thread_id: int) -> SessionInfo:
        """Create a new persistent session with a connected client."""
        options = self._build_options()
        client = ClaudeSDKClient(options=options)
        await client.connect()

        info = SessionInfo(client=client)
        self._sessions[thread_id] = info
        logger.info("Created new session for thread %s", thread_id)
        return info

    async def get_or_create_session(self, thread_id: int) -> SessionInfo:
        """Get existing session for a thread, or create a new one. Auto-rotates stale sessions."""
        if thread_id in self._sessions:
            session = self._sessions[thread_id]
            if self._needs_rotation(session):
                return await self._rotate_session(thread_id)
            return session

        return await self._create_session(thread_id)

    async def query(self, prompt: str, thread_id: int) -> list[str]:
        """Send a prompt to the Agent SDK and return text responses."""
        session = await self.get_or_create_session(thread_id)
        responses: list[str] = []

        # Prepend rotation summary if this is a freshly rotated session
        rotation_summary = getattr(session, "_rotation_summary", None)
        if rotation_summary:
            prompt = f"{rotation_summary}\n\n---\n\n{prompt}"
            delattr(session, "_rotation_summary")

        try:
            await session.client.query(prompt)

            async for message in session.client.receive_response():
                if isinstance(message, AssistantMessage):
                    for block in message.content:
                        if isinstance(block, TextBlock):
                            responses.append(block.text)

                elif isinstance(message, ResultMessage):
                    session.turn_count += 1
                    if message.usage:
                        input_tokens = message.usage.get("input_tokens", 0)
                        output_tokens = message.usage.get("output_tokens", 0)
                        session.total_tokens += input_tokens + output_tokens
                    if message.total_cost_usd:
                        logger.info(
                            "Thread %s turn %d: $%.4f (%d turns, %d tokens)",
                            thread_id,
                            session.turn_count,
                            message.total_cost_usd,
                            message.num_turns,
                            session.total_tokens,
                        )
                    if message.is_error:
                        logger.error("Agent SDK error for thread %s: %s", thread_id, message.result)

        except Exception:
            logger.exception("Agent SDK query failed for thread %s", thread_id)
            # Session is likely dead — remove it so next message creates a fresh one
            self._sessions.pop(thread_id, None)
            responses.append("I encountered an error processing that request. Please try again.")

        return responses

    async def close_session(self, thread_id: int) -> None:
        """Close and clean up a session for a thread."""
        info = self._sessions.pop(thread_id, None)
        if info and info.client:
            try:
                await info.client.disconnect()
            except Exception:
                logger.exception("Error closing session for thread %s", thread_id)

    async def close_all(self) -> None:
        """Close all active sessions."""
        thread_ids = list(self._sessions.keys())
        for tid in thread_ids:
            await self.close_session(tid)
