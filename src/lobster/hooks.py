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

# Commands additionally blocked for QA lobsters (read-only enforcement)
BLOCKED_COMMANDS_QA = [
    r"git\s+push\b",
    r"git\s+commit\b",
    r"git\s+add\b",
    r"git\s+checkout\s+-b\b",
    r"git\s+merge\b",
    r"git\s+rebase\b",
    r"gh\s+pr\s+create\b",
    r"gh\s+pr\s+merge\b",
]

# Domains allowed for curl/wget
ALLOWED_DOMAINS = {
    "api.anthropic.com",
    "github.com",
    "api.github.com",
    "raw.githubusercontent.com",
    "pypi.org",
    "registry.npmjs.org",
}

# Regex for curl/wget to non-allowlisted domains
NETWORK_CMD_RE = re.compile(r"\b(curl|wget|http)\b", re.IGNORECASE)

BLOCKED_RE_ALL = re.compile("|".join(BLOCKED_COMMANDS_ALL), re.IGNORECASE)
BLOCKED_RE_QA = re.compile("|".join(BLOCKED_COMMANDS_ALL + BLOCKED_COMMANDS_QA), re.IGNORECASE)


def _check_network_access(command: str) -> str | None:
    """Check if a network command targets an allowed domain. Returns block reason or None."""
    if not NETWORK_CMD_RE.search(command):
        return None

    # Extract URLs/domains from the command
    for domain in ALLOWED_DOMAINS:
        if domain in command:
            return None

    # If curl/wget is present but no allowed domain found, block it
    return f"Network access to non-allowlisted domain. Allowed: {', '.join(sorted(ALLOWED_DOMAINS))}"


def create_tool_checker(lobster_type: str):
    """Create a can_use_tool callback for the given lobster type."""
    blocked_re = BLOCKED_RE_QA if lobster_type == "qa" else BLOCKED_RE_ALL

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
        block_reason = _check_network_access(command)
        if block_reason:
            logger.warning("BLOCKED network access: %s", command[:200])
            return PermissionResultDeny(message=block_reason)

        return PermissionResultAllow()

    return check_tool
