"""Claude Agent SDK integration for lobboss."""

import logging
import os
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


@dataclass
class SessionInfo:
    """Tracks an active Agent SDK session mapped to a Discord thread."""
    session_id: str | None = None
    client: ClaudeSDKClient | None = None
    turn_count: int = 0


class LobbossAgent:
    """Wraps ClaudeSDKClient for lobboss multi-turn conversations."""

    def __init__(self, config: AgentConfig) -> None:
        self.config = config
        self._sessions: dict[int, SessionInfo] = {}  # thread_id → SessionInfo
        self._system_prompt = self._load_system_prompt()

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

    async def get_or_create_session(self, thread_id: int) -> SessionInfo:
        """Get existing session for a thread, or create a new one."""
        if thread_id in self._sessions:
            return self._sessions[thread_id]

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
                        if message.total_cost_usd:
                            logger.info(
                                "Thread %s turn %d: $%.4f (%d turns in SDK)",
                                thread_id,
                                session.turn_count,
                                message.total_cost_usd,
                                message.num_turns,
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
