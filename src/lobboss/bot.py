"""Discord bot for lobboss — entrypoint."""

import asyncio
import collections
import logging
import signal

import discord

from lobboss.agent import LobbossAgent
from lobboss.config import Config
from lobboss.mcp_tools import set_bot

logger = logging.getLogger("lobboss.bot")

DEDUP_MAX = 1000
MAX_DISCORD_MSG_LEN = 2000


class LobbossBot(discord.Client):
    """Discord client that listens to configured channels and processes messages."""

    def __init__(self, config: Config) -> None:
        intents = discord.Intents.default()
        intents.message_content = True
        intents.guilds = True
        intents.reactions = True
        super().__init__(intents=intents)

        self.config = config
        self._allowed_channels = config.discord.allowed_channel_ids
        self._processed: collections.deque[int] = collections.deque(maxlen=DEDUP_MAX)
        self._queue: asyncio.Queue[discord.Message] = asyncio.Queue()
        self._agent = LobbossAgent(config.agent)
        set_bot(self)

    async def setup_hook(self) -> None:
        """Called after login, before the bot starts receiving events."""
        self.loop.create_task(self._process_queue())

    async def on_ready(self) -> None:
        logger.info("Connected as %s (id=%s)", self.user, self.user.id)
        for guild in self.guilds:
            logger.info("  Guild: %s (id=%s)", guild.name, guild.id)
        if not self._allowed_channels:
            logger.warning("No allowed channels configured — bot will ignore all messages")

    async def on_message(self, message: discord.Message) -> None:
        # Ignore own messages
        if message.author == self.user:
            return

        # Channel allowlist — check both the channel itself and its parent (for threads)
        channel_id = message.channel.id
        parent_id = getattr(message.channel, "parent_id", None)
        if channel_id not in self._allowed_channels and parent_id not in self._allowed_channels:
            return

        # Dedup
        if message.id in self._processed:
            return
        self._processed.append(message.id)

        logger.info(
            "[#%s] %s: %s",
            message.channel.name if hasattr(message.channel, "name") else channel_id,
            message.author.display_name,
            message.content[:200],
        )

        await self._queue.put(message)

    async def _process_queue(self) -> None:
        """Process messages sequentially from the queue."""
        while True:
            message = await self._queue.get()
            try:
                await self._handle_message(message)
            except Exception:
                logger.exception("Error handling message %s", message.id)
            finally:
                self._queue.task_done()

    async def _get_or_create_thread(self, message: discord.Message) -> discord.Thread:
        """Get the thread for a message, or create one if it's a top-level message in task-queue."""
        # Already in a thread — use it
        if isinstance(message.channel, discord.Thread):
            return message.channel

        # Top-level message in task-queue — create a thread
        if message.channel.id == self.config.discord.task_queue_channel_id:
            thread_name = message.content[:100].strip() or f"Task from {message.author.display_name}"
            thread = await message.create_thread(name=thread_name)
            logger.info("Created thread %s (%s) for message %s", thread.name, thread.id, message.id)
            return thread

        # Top-level message in other channels — reply in-channel (use channel id as "thread" key)
        return message.channel

    async def _handle_message(self, message: discord.Message) -> None:
        """Route a message through the Agent SDK and post the response."""
        thread = await self._get_or_create_thread(message)
        thread_id = thread.id

        # Show typing indicator while the agent works
        async with thread.typing():
            responses = await self._agent.query(message.content, thread_id)

        # Post responses, splitting if needed for Discord's 2000 char limit
        for text in responses:
            for chunk in _split_message(text):
                await thread.send(chunk)

    async def close(self) -> None:
        """Shut down agent sessions, then disconnect."""
        await self._agent.close_all()
        await super().close()


def _split_message(text: str) -> list[str]:
    """Split text into chunks that fit in a Discord message."""
    if len(text) <= MAX_DISCORD_MSG_LEN:
        return [text]

    chunks = []
    while text:
        if len(text) <= MAX_DISCORD_MSG_LEN:
            chunks.append(text)
            break
        # Try to split on newline
        split_at = text.rfind("\n", 0, MAX_DISCORD_MSG_LEN)
        if split_at == -1:
            split_at = MAX_DISCORD_MSG_LEN
        chunks.append(text[:split_at])
        text = text[split_at:].lstrip("\n")
    return chunks


def main() -> None:
    # Use JSON logging in containers (LOBMOB_ENV set), human-readable locally
    import os
    from common.logging import setup_logging
    json_output = os.environ.get("LOBMOB_ENV") is not None
    setup_logging(json_output=json_output)

    config = Config.from_env()
    bot = LobbossBot(config)

    # Graceful shutdown on SIGTERM (k8s sends this)
    loop = asyncio.new_event_loop()

    def _shutdown(sig: signal.Signals) -> None:
        logger.info("Received %s, shutting down...", sig.name)
        loop.create_task(bot.close())

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _shutdown, sig)

    loop.run_until_complete(bot.start(config.discord.token))


if __name__ == "__main__":
    main()
