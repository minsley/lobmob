"""Discord bot for lobboss — entrypoint."""

import asyncio
import collections
import logging
import signal

import discord

from lobboss.config import Config

logger = logging.getLogger("lobboss.bot")

DEDUP_MAX = 1000


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
        self._agent = None  # Set later when Agent SDK is wired in (Task 1.3)

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

    async def _handle_message(self, message: discord.Message) -> None:
        """Handle a single message. Agent SDK integration goes here (Task 1.3)."""
        # For now, just log. Agent SDK wiring replaces this.
        logger.info("Would process message %s from %s", message.id, message.author.display_name)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

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
