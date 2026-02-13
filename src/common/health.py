"""Health checks for external dependencies (Anthropic, GitHub, Discord)."""

import asyncio
import logging
import time
from typing import Any

import anthropic

logger = logging.getLogger("lobboss.health")

CIRCUIT_BREAKER_THRESHOLD = 3
CIRCUIT_BREAKER_COOLDOWN = 300  # seconds


class CircuitBreaker:
    """Tracks consecutive failures for a dependency. Opens after threshold."""

    def __init__(self, name: str, threshold: int = CIRCUIT_BREAKER_THRESHOLD) -> None:
        self.name = name
        self.threshold = threshold
        self.failures = 0
        self.open_until = 0.0

    @property
    def is_open(self) -> bool:
        if self.failures >= self.threshold:
            if time.monotonic() < self.open_until:
                return True
            # Cooldown expired, allow half-open attempt
            self.failures = self.threshold - 1
        return False

    def record_success(self) -> None:
        if self.failures > 0:
            logger.info("Circuit breaker %s: recovered", self.name)
        self.failures = 0

    def record_failure(self) -> None:
        self.failures += 1
        if self.failures >= self.threshold:
            self.open_until = time.monotonic() + CIRCUIT_BREAKER_COOLDOWN
            logger.error(
                "Circuit breaker %s: OPEN after %d failures (cooldown %ds)",
                self.name, self.failures, CIRCUIT_BREAKER_COOLDOWN,
            )


class HealthChecker:
    """Checks external dependencies with circuit breaker pattern."""

    def __init__(self, api_key: str = "", bot: Any = None) -> None:
        self._api_key = api_key
        self._bot = bot
        self._breakers = {
            "anthropic": CircuitBreaker("anthropic"),
            "github": CircuitBreaker("github"),
            "discord": CircuitBreaker("discord"),
        }

    async def check_anthropic(self) -> bool:
        """Check Anthropic API is reachable via a lightweight token count."""
        breaker = self._breakers["anthropic"]
        if breaker.is_open:
            return False
        try:
            client = anthropic.AsyncAnthropic(api_key=self._api_key)
            await client.messages.count_tokens(
                model="claude-haiku-4-5",
                messages=[{"role": "user", "content": "ping"}],
            )
            breaker.record_success()
            return True
        except Exception as e:
            logger.warning("Anthropic health check failed: %s", e)
            breaker.record_failure()
            return False

    async def check_github(self) -> bool:
        """Check GitHub API is reachable via rate limit endpoint."""
        breaker = self._breakers["github"]
        if breaker.is_open:
            return False
        try:
            proc = await asyncio.create_subprocess_exec(
                "gh", "api", "/rate_limit", "--jq", ".rate.remaining",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
            if proc.returncode == 0:
                breaker.record_success()
                return True
            breaker.record_failure()
            return False
        except Exception as e:
            logger.warning("GitHub health check failed: %s", e)
            breaker.record_failure()
            return False

    async def check_discord(self) -> bool:
        """Check Discord bot is connected and responsive."""
        breaker = self._breakers["discord"]
        if breaker.is_open:
            return False
        try:
            if self._bot is None:
                breaker.record_failure()
                return False
            if not self._bot.is_ready():
                breaker.record_failure()
                return False
            if self._bot.latency > 5.0:
                logger.warning("Discord latency high: %.1fs", self._bot.latency)
                breaker.record_failure()
                return False
            breaker.record_success()
            return True
        except Exception as e:
            logger.warning("Discord health check failed: %s", e)
            breaker.record_failure()
            return False

    async def check_all(self) -> dict[str, bool]:
        """Run all health checks and return results."""
        results = await asyncio.gather(
            self.check_anthropic(),
            self.check_github(),
            self.check_discord(),
            return_exceptions=True,
        )
        names = ["anthropic", "github", "discord"]
        return {
            name: result if isinstance(result, bool) else False
            for name, result in zip(names, results)
        }

    def all_healthy(self) -> bool:
        """Quick check: are all circuit breakers closed?"""
        return not any(b.is_open for b in self._breakers.values())
