#!/usr/bin/env python3
"""lobmob-status-reporter — periodic fleet summary.

Python rewrite of lobmob-status-reporter.sh. Task counts come from
lobwife API instead of vault grep. Worker counts from kubectl.
"""

import asyncio
import json
import logging
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Ensure sibling modules are importable
sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, "/opt/lobmob/src")

import aiohttp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("status-reporter")

LOBWIFE_URL = os.environ.get("LOBWIFE_URL", "http://lobwife.lobmob.svc.cluster.local:8081")
VAULT_DIR = os.environ.get("VAULT_PATH", "/opt/vault")
DISCORD_BOT_TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "")
DISCORD_CHANNEL_SWARM_LOGS = os.environ.get("DISCORD_CHANNEL_SWARM_LOGS", "")
LOG_FILE = os.path.join(os.environ.get("LOG_DIR", "/var/log"), "lobmob-status-reporter.log")
NAMESPACE = "lobmob"


def _run(cmd: str) -> str:
    """Run a shell command, return stdout."""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return result.stdout.strip() if result.returncode == 0 else ""
    except Exception:
        return ""


def _count_lines(output: str) -> int:
    """Count non-empty lines in command output."""
    return len([l for l in output.splitlines() if l.strip()]) if output else 0


def _log_file(msg: str):
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{now} {msg}\n")
    except Exception:
        pass


async def main():
    # Task counts from API
    tasks_queued = 0
    tasks_active = 0
    tasks_completed = 0
    tasks_failed = 0

    try:
        async with aiohttp.ClientSession() as session:
            url = f"{LOBWIFE_URL}/api/v1/tasks"
            for status in ("queued", "active", "completed", "failed"):
                async with session.get(
                    url, params={"status": status, "limit": "500"},
                    timeout=aiohttp.ClientTimeout(total=10),
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        count = len(data)
                        if status == "queued":
                            tasks_queued = count
                        elif status == "active":
                            tasks_active = count
                        elif status == "completed":
                            tasks_completed = count
                        elif status == "failed":
                            tasks_failed = count
    except Exception as e:
        log.warning("Failed to get task counts from API, falling back to vault: %s", e)
        # Fallback to vault grep
        tasks_queued = _count_lines(_run(
            f"ls '{VAULT_DIR}'/010-tasks/active/*.md 2>/dev/null | xargs grep -l '^status: queued' 2>/dev/null"))
        tasks_active = _count_lines(_run(
            f"ls '{VAULT_DIR}'/010-tasks/active/*.md 2>/dev/null | xargs grep -l '^status: active' 2>/dev/null"))
        tasks_completed = _count_lines(_run(f"ls '{VAULT_DIR}'/010-tasks/completed/*.md 2>/dev/null"))
        tasks_failed = _count_lines(_run(f"ls '{VAULT_DIR}'/010-tasks/failed/*.md 2>/dev/null"))

    # Worker counts from kubectl
    active_pods = _count_lines(_run(
        f"kubectl get pods -n {NAMESPACE} -l app.kubernetes.io/name=lobster "
        "--field-selector=status.phase=Running --no-headers 2>/dev/null"))
    pending_pods = _count_lines(_run(
        f"kubectl get pods -n {NAMESPACE} -l app.kubernetes.io/name=lobster "
        "--field-selector=status.phase=Pending --no-headers 2>/dev/null"))
    total_pods = active_pods + pending_pods

    type_research = _count_lines(_run(
        f"kubectl get jobs -n {NAMESPACE} -l lobmob.io/lobster-type=research --no-headers 2>/dev/null"))
    type_swe = _count_lines(_run(
        f"kubectl get jobs -n {NAMESPACE} -l lobmob.io/lobster-type=swe --no-headers 2>/dev/null"))
    type_qa = _count_lines(_run(
        f"kubectl get jobs -n {NAMESPACE} -l lobmob.io/lobster-type=qa --no-headers 2>/dev/null"))

    # Open PRs
    vault_prs = _run(
        f"gh pr list --state open --json number --jq 'length' 2>/dev/null") or "0"

    # Cost estimate
    node_count = _count_lines(_run(
        f"kubectl get nodes -l lobmob.io/role=lobster --no-headers 2>/dev/null"))
    monthly_cost = node_count * 24 + 24
    hourly_cost = monthly_cost / 730

    now_utc = datetime.now(timezone.utc).strftime("%H:%M")

    msg = (
        f"**[status-report]** Fleet Summary — {now_utc} UTC\n"
        f"**Lobsters:** {total_pods} total ({active_pods} running, {pending_pods} pending)\n"
        f"**Types:** research={type_research}, swe={type_swe}, qa={type_qa}\n"
        f"**Tasks:** {tasks_queued} queued, {tasks_active} active, {tasks_completed} completed, {tasks_failed} failed\n"
        f"**PRs:** {vault_prs} open\n"
        f"**Cost:** ~${hourly_cost:.2f}/hr (${monthly_cost}/mo est.)"
    )

    _log_file(f"[status-report] {msg}")
    log.info("Status report:\n%s", msg)


if __name__ == "__main__":
    asyncio.run(main())
