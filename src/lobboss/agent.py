"""Claude Agent SDK integration for lobboss."""

import logging
import os
import time
from dataclasses import dataclass, field

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    TextBlock,
)

from lobboss.config import AgentConfig
from lobboss.hooks import check_bash_command, check_spawn_lobster
from lobboss.mcp_tools import lobmob_mcp

logger = logging.getLogger("lobboss.agent")

MAX_SESSION_AGE_SECS = 2 * 3600  # 2 hours default
MAX_CONTEXT_PCT = 0.6


@dataclass
class SessionInfo:
    """Tracks an active Agent SDK session mapped to a Discord thread."""
    session_id: str | None = None
    client: ClaudeSDKClient | None = None
    turn_count: int = 0
    created_at: float = field(default_factory=time.monotonic)
    total_tokens: int = 0


class LobbossAgent:
    """Wraps ClaudeSDKClient for lobboss multi-turn conversations."""

    def __init__(self, config: AgentConfig) -> None:
        self.config = config
        self._sessions: dict[int, SessionInfo] = {}  # thread_id → SessionInfo
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
        )

    async def _can_use_tool(self, tool_name: str, tool_input: dict) -> dict | None:
        """Permission callback for tool use. Returns None to allow, or block dict."""
        if tool_name == "Bash":
            return await check_bash_command(tool_input)
        if tool_name == "mcp__lobmob__spawn_lobster":
            return await check_spawn_lobster(tool_input)
        return None

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
        # Age check
        age = time.monotonic() - session.created_at
        if age > self._max_age:
            logger.info("Session rotation: age %.0fs exceeds max %.0fs", age, self._max_age)
            return True

        # Context usage check (estimate: ~4 chars per token, 200K context window)
        context_window = 200_000
        if session.total_tokens > context_window * self._max_context_pct:
            logger.info(
                "Session rotation: %d tokens exceeds %.0f%% of %d window",
                session.total_tokens, self._max_context_pct * 100, context_window,
            )
            return True

        return False

    def _build_rotation_summary(self, session: SessionInfo) -> str:
        """Build a state summary for the new session after rotation."""
        return (
            f"[Session rotated] Previous session had {session.turn_count} turns, "
            f"{session.total_tokens} tokens, age {time.monotonic() - session.created_at:.0f}s. "
            f"Continue where you left off. Active threads and tasks should be "
            f"re-read from the vault at /opt/vault if needed."
        )

    async def _rotate_session(self, thread_id: int) -> SessionInfo:
        """Rotate a session: close old, create new with state summary."""
        old = self._sessions.get(thread_id)
        summary = self._build_rotation_summary(old) if old else ""

        # Close old session
        await self.close_session(thread_id)

        # Create new session
        new_session = SessionInfo()
        self._sessions[thread_id] = new_session
        logger.info("Session rotated for thread %s", thread_id)

        # Inject the summary as context if we have one
        if summary:
            new_session._rotation_summary = summary

        return new_session

    async def get_or_create_session(self, thread_id: int) -> SessionInfo:
        """Get existing session for a thread, or create a new one. Auto-rotates stale sessions."""
        if thread_id in self._sessions:
            session = self._sessions[thread_id]
            if self._needs_rotation(session):
                return await self._rotate_session(thread_id)
            return session

        info = SessionInfo()
        self._sessions[thread_id] = info
        logger.info("Created new session for thread %s", thread_id)
        return info

    async def query(self, prompt: str, thread_id: int) -> list[str]:
        """Send a prompt to the Agent SDK and return text responses.

        Returns a list of text blocks from the assistant's response.
        """
        session = await self.get_or_create_session(thread_id)
        responses: list[str] = []

        options = self._build_options()

        # Resume existing session if we have one
        if session.session_id:
            options.resume = session.session_id

        # Prepend rotation summary if this is a freshly rotated session
        rotation_summary = getattr(session, "_rotation_summary", None)
        if rotation_summary:
            prompt = f"{rotation_summary}\n\n---\n\n{prompt}"
            delattr(session, "_rotation_summary")

        try:
            async with ClaudeSDKClient(options=options) as client:
                session.client = client
                await client.query(prompt)

                async for message in client.receive_response():
                    if isinstance(message, AssistantMessage):
                        for block in message.content:
                            if isinstance(block, TextBlock):
                                responses.append(block.text)

                    elif isinstance(message, ResultMessage):
                        session.session_id = message.session_id
                        session.turn_count += 1
                        # Track token usage for rotation decisions
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
            responses.append("I encountered an error processing that request. Please try again.")
        finally:
            session.client = None

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
