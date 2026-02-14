"""Lobboss configuration loading."""

import os
from dataclasses import dataclass, field


@dataclass
class DiscordConfig:
    token: str = ""
    guild_id: int = 0
    task_queue_channel_id: int = 0
    swarm_control_channel_id: int = 0
    swarm_logs_channel_id: int = 0

    @property
    def allowed_channel_ids(self) -> set[int]:
        return {
            cid for cid in (
                self.task_queue_channel_id,
                self.swarm_control_channel_id,
                self.swarm_logs_channel_id,
            ) if cid
        }

    @classmethod
    def from_env(cls) -> "DiscordConfig":
        return cls(
            token=os.environ["DISCORD_BOT_TOKEN"],
            guild_id=int(os.environ.get("DISCORD_GUILD_ID", "467002962456084481")),
            task_queue_channel_id=int(os.environ.get("TASK_QUEUE_CHANNEL_ID", "0")),
            swarm_control_channel_id=int(os.environ.get("SWARM_CONTROL_CHANNEL_ID", "0")),
            swarm_logs_channel_id=int(os.environ.get("SWARM_LOGS_CHANNEL_ID", "0")),
        )


@dataclass
class AgentConfig:
    model: str = "sonnet"
    anthropic_api_key: str = ""
    skills_path: str = "/app/skills"
    system_prompt_path: str = "/app/lobboss/system_prompt.md"
    max_session_age_hours: float = 2.0
    max_context_pct: float = 0.6

    @classmethod
    def from_env(cls) -> "AgentConfig":
        return cls(
            model=os.environ.get("LOBBOSS_MODEL", "sonnet"),
            anthropic_api_key=os.environ["ANTHROPIC_API_KEY"],
            skills_path=os.environ.get("SKILLS_PATH", "/app/skills"),
            system_prompt_path=os.environ.get("SYSTEM_PROMPT_PATH", "/app/lobboss/system_prompt.md"),
            max_session_age_hours=float(os.environ.get("MAX_SESSION_AGE_HOURS", "2.0")),
            max_context_pct=float(os.environ.get("MAX_CONTEXT_PCT", "0.6")),
        )


@dataclass
class PollerConfig:
    enabled: bool = True
    interval_seconds: int = 60
    max_concurrent_lobsters: int = 5

    @classmethod
    def from_env(cls) -> "PollerConfig":
        return cls(
            enabled=os.environ.get("TASK_POLLER_ENABLED", "true").lower() in ("true", "1", "yes"),
            interval_seconds=int(os.environ.get("TASK_POLL_INTERVAL", "60")),
            max_concurrent_lobsters=int(os.environ.get("MAX_CONCURRENT_LOBSTERS", "5")),
        )


@dataclass
class Config:
    environment: str = "prod"
    vault_path: str = "/opt/vault"
    discord: DiscordConfig = field(default_factory=DiscordConfig)
    agent: AgentConfig = field(default_factory=AgentConfig)
    poller: PollerConfig = field(default_factory=PollerConfig)

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            environment=os.environ.get("LOBMOB_ENV", "prod"),
            vault_path=os.environ.get("VAULT_PATH", "/opt/vault"),
            discord=DiscordConfig.from_env(),
            agent=AgentConfig.from_env(),
            poller=PollerConfig.from_env(),
        )
