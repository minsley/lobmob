"""Post-agent completion verification for lobster workers.

Checks whether the agent completed all required workflow steps.
Returns a list of missing steps (empty list = fully complete).
"""

import asyncio
import logging
import os
import re
from pathlib import Path

import yaml

from common.vault import FRONTMATTER_RE

logger = logging.getLogger("lobster.verify")

# Repo for SWE code PRs — configurable via env, defaults to minsley/lobmob
CODE_REPO = os.environ.get("LOBMOB_GITHUB_REPO", "minsley/lobmob")

# Regex for populated (non-empty) sections
RESULT_RE = re.compile(r"^## Result\s*\n\s*\S", re.MULTILINE)
NOTES_RE = re.compile(r"^## Lobster Notes\s*\n\s*\S", re.MULTILINE)


async def _run(cmd: str, cwd: str) -> tuple[int, str]:
    """Run a shell command, return (returncode, stdout)."""
    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
        if proc.returncode != 0 and stderr:
            logger.debug("Command failed: %s — %s", cmd, stderr.decode().strip()[:200])
        return proc.returncode, stdout.decode().strip()
    except asyncio.TimeoutError:
        logger.warning("Command timed out (30s): %s", cmd)
        return 1, ""


def _parse_frontmatter(content: str) -> dict:
    """Extract YAML frontmatter as a dict."""
    match = FRONTMATTER_RE.match(content)
    if match:
        return yaml.safe_load(match.group(1)) or {}
    return {}


async def verify_completion(task_id: str, lobster_type: str, vault_path: str) -> list[str]:
    """Check completion criteria for a finished lobster run.

    Returns list of missing steps (empty = all complete).
    """
    missing = []

    # --- Task file checks ---
    task_file = _find_task_file(vault_path, task_id)
    if task_file is None:
        missing.append("task_file_missing: Cannot find task file in vault")
        return missing

    content = task_file.read_text()
    meta = _parse_frontmatter(content)

    if meta.get("status") != "completed":
        missing.append(f"task_status: status is '{meta.get('status', 'unset')}', expected 'completed'")

    if not meta.get("completed_at"):
        missing.append("completed_at: frontmatter field not set")

    if not RESULT_RE.search(content):
        missing.append("result_section: '## Result' section is empty or missing")

    if not NOTES_RE.search(content):
        missing.append("notes_section: '## Lobster Notes' section is empty or missing")

    # --- Branch + PR checks vary by lobster type ---
    if lobster_type in ("qa", "research", "swe", "image-gen"):
        await _check_vault_pr(task_id, vault_path, missing)
    elif lobster_type == "system":
        # System tasks (lobsigliere) create PRs in the code repo, not vault
        await _check_code_pr(task_id, vault_path, missing)
    else:
        logger.warning("Unknown lobster type %r — skipping PR checks", lobster_type)

    # SWE additionally needs a code PR
    if lobster_type == "swe":
        await _check_code_pr(task_id, vault_path, missing)

    return missing


def _find_task_file(vault_path: str, task_id: str) -> Path | None:
    """Find the task file in active/, completed/, or failed/."""
    for subdir in ("active", "completed", "failed"):
        p = Path(vault_path) / "010-tasks" / subdir / f"{task_id}.md"
        if p.exists():
            return p
    return None


async def _check_vault_pr(task_id: str, vault_path: str, missing: list[str]) -> None:
    """Check if a vault PR exists for this task."""
    rc, output = await _run(
        f"gh pr list --state all --search '{task_id}' --json number --jq 'length'",
        cwd=vault_path,
    )
    if rc != 0 or output in ("", "0"):
        missing.append("vault_pr: No vault PR found for this task")


async def _check_code_pr(task_id: str, vault_path: str, missing: list[str]) -> None:
    """Check if a code PR exists in the lobmob repo (for SWE/system tasks)."""
    rc, output = await _run(
        f"gh pr list --repo {CODE_REPO} --state all --search '{task_id}' --json number --jq 'length'",
        cwd=vault_path,
    )
    if rc != 0 or output in ("", "0"):
        missing.append(f"code_pr: No code PR found in {CODE_REPO} for this task")
