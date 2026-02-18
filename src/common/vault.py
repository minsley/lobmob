"""Vault git operations shared by lobboss and lobster."""

import asyncio
import logging
import os
import re
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger("common.vault")

FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_frontmatter(content: str) -> dict[str, Any]:
    """Extract YAML frontmatter from markdown content as a dict."""
    match = FRONTMATTER_RE.match(content)
    if match:
        return yaml.safe_load(match.group(1)) or {}
    return {}


class VaultError(Exception):
    """Raised when a vault git operation fails."""


async def _run_git(vault_path: str, *args: str) -> str:
    """Run a git command in the vault directory. Returns stdout."""
    cmd = ["git", "-C", vault_path, *args]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=30)
    if proc.returncode != 0:
        err = stderr.decode().strip()
        raise VaultError(f"git {' '.join(args)} failed: {err}")
    return stdout.decode().strip()


async def pull_vault(vault_path: str) -> None:
    """Pull latest changes from the vault remote."""
    try:
        await _run_git(vault_path, "pull", "--rebase", "origin", "main")
        logger.info("Vault pulled successfully")
    except VaultError:
        # If rebase fails, abort and try a regular pull
        try:
            await _run_git(vault_path, "rebase", "--abort")
        except VaultError:
            pass
        await _run_git(vault_path, "pull", "origin", "main")
        logger.info("Vault pulled (fallback merge)")


async def commit_and_push(vault_path: str, message: str, files: list[str]) -> None:
    """Stage specific files, commit, and push. Retries once on conflict."""
    for f in files:
        await _run_git(vault_path, "add", f)

    await _run_git(vault_path, "commit", "-m", message)

    try:
        await _run_git(vault_path, "push", "origin", "main")
    except VaultError:
        # Conflict — pull and retry once
        logger.warning("Push failed, pulling and retrying...")
        await pull_vault(vault_path)
        await _run_git(vault_path, "push", "origin", "main")

    logger.info("Vault committed and pushed: %s", message)


def read_task(vault_path: str, task_id: str) -> dict[str, Any]:
    """Load and parse a task file. Returns {'metadata': dict, 'body': str}.

    Searches active/, then completed/, then failed/.
    Handles both T-format (T42) and old slug format (task-2026-02-15-a1b2).
    """
    for subdir in ("active", "completed", "failed"):
        task_path = Path(vault_path) / "010-tasks" / subdir / f"{task_id}.md"
        if task_path.exists():
            return _parse_task_file(task_path)

    # Try case-insensitive T-format (e.g. "t42" -> "T42.md")
    if task_id and task_id[0].lower() == "t" and task_id[1:].isdigit():
        upper_id = f"T{task_id[1:]}"
        for subdir in ("active", "completed", "failed"):
            task_path = Path(vault_path) / "010-tasks" / subdir / f"{upper_id}.md"
            if task_path.exists():
                return _parse_task_file(task_path)

    raise FileNotFoundError(f"Task {task_id} not found in vault")


def _parse_task_file(path: Path) -> dict[str, Any]:
    """Parse a task markdown file with YAML frontmatter."""
    content = path.read_text()
    metadata = parse_frontmatter(content)
    match = FRONTMATTER_RE.match(content)
    body = content[match.end():] if match else content
    return {"metadata": metadata, "body": body.strip(), "path": str(path)}


def write_task(vault_path: str, task_id: str, metadata: dict[str, Any], body: str,
               subdir: str = "active") -> str:
    """Serialize and write a task file. Returns the relative file path."""
    task_dir = Path(vault_path) / "010-tasks" / subdir
    task_dir.mkdir(parents=True, exist_ok=True)
    task_path = task_dir / f"{task_id}.md"

    frontmatter = yaml.dump(metadata, default_flow_style=False, sort_keys=False).strip()
    content = f"---\n{frontmatter}\n---\n\n{body}\n"
    task_path.write_text(content)

    return str(task_path.relative_to(vault_path))


async def move_task(vault_path: str, task_id: str, from_dir: str, to_dir: str) -> str:
    """Move a task file between directories (e.g., active → completed).

    Returns the new relative path.
    """
    src = Path(vault_path) / "010-tasks" / from_dir / f"{task_id}.md"
    dst_dir = Path(vault_path) / "010-tasks" / to_dir
    dst_dir.mkdir(parents=True, exist_ok=True)
    dst = dst_dir / f"{task_id}.md"

    if not src.exists():
        raise FileNotFoundError(f"Task file not found: {src}")

    await _run_git(vault_path, "mv", str(src), str(dst))
    logger.info("Moved task %s: %s → %s", task_id, from_dir, to_dir)
    return str(dst.relative_to(vault_path))


def list_tasks(vault_path: str, subdir: str = "active") -> list[dict[str, Any]]:
    """List all tasks in a subdirectory with their metadata."""
    task_dir = Path(vault_path) / "010-tasks" / subdir
    if not task_dir.exists():
        return []

    tasks = []
    for f in sorted(task_dir.glob("*.md")):
        try:
            task = _parse_task_file(f)
            task["metadata"].setdefault("id", f.stem)
            tasks.append(task)
        except Exception:
            logger.warning("Failed to parse task file: %s", f)
    return tasks
