"""Lobster configuration loading."""

import os
from dataclasses import dataclass


@dataclass
class LobsterConfig:
    task_id: str = ""
    lobster_type: str = "research"  # research, swe, qa, image-gen
    workflow: str = "default"  # default, android, unity (applies to swe type)
    vault_path: str = "/opt/vault"
    skills_path: str = "/app/skills"
    anthropic_api_key: str = ""
    model: str = ""  # derived from type if not set
    token_budget: int = 500_000  # default for research/qa

    @classmethod
    def from_env(cls) -> "LobsterConfig":
        lobster_type = os.environ.get("LOBSTER_TYPE", "research")
        return cls(
            task_id=os.environ.get("TASK_ID", ""),
            lobster_type=lobster_type,
            workflow=os.environ.get("LOBSTER_WORKFLOW", "default"),
            vault_path=os.environ.get("VAULT_PATH", "/opt/vault"),
            skills_path=os.environ.get("SKILLS_PATH", "/app/skills"),
            anthropic_api_key=os.environ["ANTHROPIC_API_KEY"],
            model=os.environ.get("LOBSTER_MODEL", "opus" if lobster_type == "swe" else "sonnet"),
            token_budget=int(os.environ.get("TOKEN_BUDGET", "1000000" if lobster_type == "swe" else "500000")),
        )
