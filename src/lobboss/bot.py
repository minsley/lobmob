"""Discord bot for lobboss — entrypoint."""

import asyncio
import collections
import json
import logging
import os
import signal
import subprocess
import tempfile

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
        await self._setup_git_auth()
        self.loop.create_task(self._process_queue())
        self.loop.create_task(self._write_health_status())
        if self.config.poller.enabled:
            self.loop.create_task(self._run_task_poller())

    async def _setup_git_auth(self) -> None:
        """Configure git to use gh-lobwife wrapper for credentials."""
        try:
            # Wipe stale credential helpers (PVC persists .gitconfig across restarts)
            proc = await asyncio.create_subprocess_exec(
                "git", "config", "--global", "--unset-all",
                "credential.https://github.com.helper",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(proc.communicate(), timeout=5)
            # Use our wrapper (/usr/local/bin/gh) not gh-real, so broker tokens flow through
            proc = await asyncio.create_subprocess_exec(
                "git", "config", "--global",
                "credential.https://github.com.helper",
                "!/usr/local/bin/gh auth git-credential",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await asyncio.wait_for(proc.communicate(), timeout=5)
            logger.info("git credential helper configured (gh-lobwife wrapper)")
        except Exception as e:
            logger.warning("Failed to configure git credential helper: %s", e)

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

    async def _run_task_poller(self) -> None:
        """Background task: poll vault for queued tasks and spawn lobsters."""
        from lobboss.task_poller import run_poller

        logger.info("Starting task poller")
        await run_poller(
            vault_path=self.config.vault_path,
            interval=self.config.poller.interval_seconds,
            max_concurrent=self.config.poller.max_concurrent_lobsters,
            bot=self,
        )

    async def _write_health_status(self) -> None:
        """Periodically write health status JSON for the web server to read."""
        from common.health import HealthChecker

        api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        checker = HealthChecker(api_key=api_key, bot=self)
        health_dir = "/tmp/health"
        health_file = os.path.join(health_dir, "status.json")
        os.makedirs(health_dir, exist_ok=True)

        while True:
            try:
                results = await checker.check_all()
                data = {**results, "checked_at": asyncio.get_event_loop().time()}
                # Atomic write via tmp + rename
                fd, tmp_path = tempfile.mkstemp(dir=health_dir, suffix=".json")
                try:
                    with os.fdopen(fd, "w") as f:
                        json.dump(data, f)
                    os.replace(tmp_path, health_file)
                except Exception:
                    os.unlink(tmp_path)
                    raise
            except Exception:
                logger.exception("Failed to write health status")
            await asyncio.sleep(60)

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


def health_check() -> None:
    """Minimal health check for k8s probes. Exits 0 if the module is importable."""
    pass


def main() -> None:
    from common.logging import setup_logging
    json_output = os.environ.get("LOBMOB_ENV") is not None
    setup_logging(json_output=json_output)

    config = Config.from_env()
    bot = LobbossBot(config)

    # Start web server subprocess
    web_script = "/app/scripts/lobmob-web.js"
    web_proc = None
    if os.path.exists(web_script):
        logger.info("Starting web server: %s", web_script)
        web_proc = subprocess.Popen(["node", web_script])
    else:
        logger.warning("Web server script not found at %s, skipping", web_script)

    # Graceful shutdown on SIGTERM (k8s sends this)
    loop = asyncio.new_event_loop()

    def _shutdown(sig: signal.Signals) -> None:
        logger.info("Received %s, shutting down...", sig.name)
        if web_proc and web_proc.poll() is None:
            web_proc.terminate()
        loop.create_task(bot.close())

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _shutdown, sig)

    try:
        loop.run_until_complete(bot.start(config.discord.token))
    finally:
        if web_proc and web_proc.poll() is None:
            web_proc.terminate()
            web_proc.wait(timeout=5)


if __name__ == "__main__":
    main()
