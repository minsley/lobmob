"""Safety hooks for lobster agents — credential scoping and command restrictions."""

import logging
import re
from typing import Any

from claude_agent_sdk import PermissionResultAllow, PermissionResultDeny, ToolPermissionContext

logger = logging.getLogger("lobster.hooks")

# Commands blocked for ALL lobster types
BLOCKED_COMMANDS_ALL = [
    r"rm\s+-rf\s+/",
    r"\bshutdown\b",
    r"\breboot\b",
    r"\bmkfs\b",
    r"\bdd\s+.*of=/dev/",
    r"\benv\b",           # prevent secret dumping
    r"\bprintenv\b",
    r"\bset\b\s*$",       # bare 'set' dumps env
]

# Commands additionally blocked for QA and image-gen lobsters (no code repo writes)
BLOCKED_COMMANDS_READONLY_GIT = [
    r"git\s+push\b",
    r"git\s+commit\b",
    r"git\s+add\b",
    r"git\s+checkout\s+-b\b",
    r"git\s+merge\b",
    r"git\s+rebase\b",
    r"gh\s+pr\s+create\b",
    r"gh\s+pr\s+merge\b",
]

# Domains allowed for curl/wget (base set for all types)
ALLOWED_DOMAINS = {
    "api.anthropic.com",
    "github.com",
    "api.github.com",
    "raw.githubusercontent.com",
    "pypi.org",
    "registry.npmjs.org",
}

# Additional domains for image-gen lobsters
ALLOWED_DOMAINS_IMAGE_GEN = ALLOWED_DOMAINS | {
    "generativelanguage.googleapis.com",
}

# Regex for curl/wget to non-allowlisted domains
NETWORK_CMD_RE = re.compile(r"\b(curl|wget|http)\b", re.IGNORECASE)

BLOCKED_RE_ALL = re.compile("|".join(BLOCKED_COMMANDS_ALL), re.IGNORECASE)
BLOCKED_RE_READONLY = re.compile("|".join(BLOCKED_COMMANDS_ALL + BLOCKED_COMMANDS_READONLY_GIT), re.IGNORECASE)


def _check_network_access(command: str, allowed: set[str]) -> str | None:
    """Check if a network command targets an allowed domain. Returns block reason or None."""
    if not NETWORK_CMD_RE.search(command):
        return None

    for domain in allowed:
        if domain in command:
            return None

    return f"Network access to non-allowlisted domain. Allowed: {', '.join(sorted(allowed))}"


def create_tool_checker(lobster_type: str):
    """Create a can_use_tool callback for the given lobster type."""
    if lobster_type in ("qa", "image-gen"):
        blocked_re = BLOCKED_RE_READONLY
    else:
        blocked_re = BLOCKED_RE_ALL

    domains = ALLOWED_DOMAINS_IMAGE_GEN if lobster_type == "image-gen" else ALLOWED_DOMAINS

    async def check_tool(
        tool_name: str,
        tool_input: dict[str, Any],
        context: ToolPermissionContext,
    ) -> PermissionResultAllow | PermissionResultDeny:
        if tool_name != "Bash":
            return PermissionResultAllow()

        command = tool_input.get("command", "")

        # Check blocked commands
        if blocked_re.search(command):
            logger.warning("BLOCKED command for %s lobster: %s", lobster_type, command[:200])
            return PermissionResultDeny(message=f"Command blocked by {lobster_type} safety hook")

        # Check network access
        block_reason = _check_network_access(command, domains)
        if block_reason:
            logger.warning("BLOCKED network access: %s", command[:200])
            return PermissionResultDeny(message=block_reason)

        return PermissionResultAllow()

    return check_tool
