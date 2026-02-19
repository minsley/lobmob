#!/usr/bin/env python3
"""lobmob-task-manager — timeout detection, orphan recovery, investigation tasks.

Python rewrite of lobmob-task-manager.sh. Runs every 5 min via lobwife daemon.
Queries lobwife API for task state instead of parsing vault frontmatter.
"""

import asyncio
import json
import logging
import os
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

# Ensure sibling modules are importable (scripts/server/)
sys.path.insert(0, str(Path(__file__).parent))
# Ensure src/common is importable
sys.path.insert(0, "/opt/lobmob/src")

import aiohttp

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("task-manager")

LOBWIFE_URL = os.environ.get("LOBWIFE_URL", "http://lobwife.lobmob.svc.cluster.local:8081")
VAULT_DIR = os.environ.get("VAULT_PATH", "/opt/vault")
VAULT_REPO = os.environ.get("VAULT_REPO", "")
DISCORD_BOT_TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "")
TASK_STATE_DIR = os.environ.get("TASK_STATE_DIR", "/tmp/lobmob-task-state")
LOG_FILE = os.path.join(os.environ.get("LOG_DIR", "/var/log"), "lobmob-task-manager.log")
NAMESPACE = "lobmob"


# ── Helpers ──────────────────────────────────────────────────────────

def _run(cmd: str, **kwargs) -> subprocess.CompletedProcess:
    """Run a shell command, returning CompletedProcess."""
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30, **kwargs)


def _log_file(msg: str):
    """Append to the log file."""
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{now} {msg}\n")
    except Exception:
        pass


def _discord_post(thread_id: str, msg: str):
    """Post to a Discord thread via bot API (best-effort)."""
    if not DISCORD_BOT_TOKEN or not thread_id:
        return
    try:
        _run(
            f'curl -s -X POST "https://discord.com/api/v10/channels/{thread_id}/messages" '
            f'-H "Authorization: Bot {DISCORD_BOT_TOKEN}" '
            f'-H "Content-Type: application/json" '
            f'-d \'{json.dumps({"content": msg})}\''
        )
    except Exception:
        pass


async def _api_request(session: aiohttp.ClientSession, method: str, path: str, **kwargs):
    """Make a request to lobwife API."""
    url = f"{LOBWIFE_URL}{path}"
    async with session.request(method, url, timeout=aiohttp.ClientTimeout(total=15), **kwargs) as resp:
        body = await resp.json()
        if resp.status >= 400:
            raise RuntimeError(f"API {resp.status}: {body}")
        return body


async def _api_list_tasks(session, status: str) -> list:
    return await _api_request(session, "GET", f"/api/v1/tasks?status={status}&limit=500")


async def _api_update_task(session, db_id: int, **fields):
    return await _api_request(session, "PATCH", f"/api/v1/tasks/{db_id}", json=fields)


async def _api_log_event(session, db_id: int, event_type: str, detail: str):
    try:
        await _api_request(
            session, "POST", f"/api/v1/tasks/{db_id}/events",
            json={"event_type": event_type, "detail": detail, "actor": "task-manager"},
        )
    except Exception:
        pass


async def _api_create_task(session, **fields):
    return await _api_request(session, "POST", "/api/v1/tasks", json=fields)


def _broker_deregister(task_id: str):
    """Deregister from token broker (best-effort)."""
    try:
        _run(f'curl -sf -X DELETE "{LOBWIFE_URL}/api/tasks/{task_id}" 2>/dev/null')
    except Exception:
        pass


def _elapsed_minutes(iso_time: str) -> int:
    """Calculate minutes elapsed since an ISO timestamp."""
    try:
        dt = datetime.fromisoformat(iso_time.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        return int(delta.total_seconds() / 60)
    except Exception:
        return 0


def _has_open_pr(task_id: str) -> bool:
    """Check if there's an open PR for this task in the vault repo."""
    result = _run(
        f"gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null",
        cwd=VAULT_DIR,
    )
    return task_id.lower() in result.stdout.lower() if result.returncode == 0 else False


def _try_fallback_pr(task_id: str) -> bool:
    """Layer 2: try to create a fallback PR from an existing branch."""
    if not VAULT_REPO:
        return False

    # Look for a branch matching this task
    result = _run(
        f"gh api 'repos/{VAULT_REPO}/branches' --paginate --jq '.[].name' 2>/dev/null"
    )
    if result.returncode != 0:
        return False

    branch = None
    for line in result.stdout.strip().splitlines():
        if task_id.lower() in line.lower():
            branch = line.strip()
            break
    if not branch:
        return False

    # Check if PR already exists
    result = _run(
        f"gh pr list --repo '{VAULT_REPO}' --head '{branch}' --state all --json number --jq 'length' 2>/dev/null"
    )
    if result.returncode == 0 and result.stdout.strip() not in ("", "0"):
        _log_file(f"FALLBACK: PR already exists for branch {branch} ({task_id})")
        return True

    # Check if branch has commits ahead of main
    encoded = urllib.parse.quote(branch, safe="")
    result = _run(
        f"gh api 'repos/{VAULT_REPO}/compare/main...{encoded}' --jq '.ahead_by' 2>/dev/null"
    )
    ahead = int(result.stdout.strip()) if result.returncode == 0 and result.stdout.strip().isdigit() else 0
    if ahead <= 0:
        return False

    # Create the fallback PR
    result = _run(
        f"gh pr create --repo '{VAULT_REPO}' --head '{branch}' --base main "
        f"--title 'Task {task_id} (auto-submitted by task-manager)' "
        f"--body '[task-manager] Lobster completed work on branch but didn\\'t create a PR. {ahead} commit(s) ahead of main.' "
        "2>/dev/null"
    )
    if result.returncode == 0:
        _log_file(f"FALLBACK PR created for {task_id} from branch {branch} ({ahead} commits)")
        return True
    return False


def _get_k8s_jobs() -> dict:
    """Get all lobster jobs from k8s. Returns {job_name: is_active}."""
    result = _run(
        f"kubectl get jobs -n {NAMESPACE} -l app.kubernetes.io/name=lobster "
        "-o jsonpath='{range .items[*]}{.metadata.name} {.status.active}{\"\\n\"}{end}' 2>/dev/null"
    )
    jobs = {}
    if result.returncode == 0:
        for line in result.stdout.strip().splitlines():
            parts = line.strip().split()
            if parts:
                name = parts[0]
                active = parts[1] if len(parts) > 1 else ""
                jobs[name] = active not in ("", "0", "<nil>", "<none>")
    return jobs


# ── 1. Timeout Detection ────────────────────────────────────────────

async def detect_timeouts(session: aiohttp.ClientSession):
    """Check active tasks for timeout conditions."""
    tasks = await _api_list_tasks(session, "active")
    os.makedirs(TASK_STATE_DIR, exist_ok=True)

    for task in tasks:
        db_id = task["id"]
        task_id = task["task_id"]
        assigned_at = task.get("assigned_at")
        assigned_to = task.get("assigned_to", "")
        thread_id = task.get("discord_thread_id", "")
        estimate = task.get("estimate_minutes")

        if not assigned_at:
            continue

        elapsed_min = _elapsed_minutes(assigned_at)

        # Determine thresholds
        if estimate and estimate > 0:
            warn_min = estimate + 15
            fail_min = estimate * 2
        else:
            warn_min = 45
            fail_min = 90

        # Skip if task has an open PR (in review)
        if _has_open_pr(task_id):
            continue

        warn_state = os.path.join(TASK_STATE_DIR, f"{task_id}.timeout")

        if elapsed_min >= fail_min:
            current = ""
            if os.path.exists(warn_state):
                with open(warn_state) as f:
                    current = f.read().strip()
            if current != "failed":
                with open(warn_state, "w") as f:
                    f.write("failed")
                _log_file(f"TIMEOUT FAILURE: {task_id} ({elapsed_min} min, threshold {fail_min})")
                await _api_log_event(session, db_id, "timeout_failure", f"{elapsed_min}m (limit {fail_min}m)")
                _discord_post(thread_id,
                    f"**[task-manager]** Timeout failure: **{task_id}** has been active for "
                    f"{elapsed_min}m (limit: {fail_min}m) with no PR. Assigned to **{assigned_to}**.")

        elif elapsed_min >= warn_min:
            current = ""
            if os.path.exists(warn_state):
                with open(warn_state) as f:
                    current = f.read().strip()
            if current != "warned":
                with open(warn_state, "w") as f:
                    f.write("warned")
                _log_file(f"TIMEOUT WARNING: {task_id} ({elapsed_min} min, threshold {warn_min})")
                await _api_log_event(session, db_id, "timeout_warning", f"{elapsed_min}m (estimate {estimate or '?'}m)")
                _discord_post(thread_id,
                    f"**[task-manager]** Timeout warning: **{task_id}** active for "
                    f"{elapsed_min}m (estimate: {estimate or '?'}m). **{assigned_to}** — please post progress or submit PR.")


# ── 2. Orphan Detection ─────────────────────────────────────────────

async def detect_orphans(session: aiohttp.ClientSession):
    """Find active tasks whose assigned lobster no longer exists in k8s."""
    tasks = await _api_list_tasks(session, "active")
    k8s_jobs = _get_k8s_jobs()
    os.makedirs(TASK_STATE_DIR, exist_ok=True)

    for task in tasks:
        db_id = task["id"]
        task_id = task["task_id"]
        assigned_to = task.get("assigned_to", "")
        thread_id = task.get("discord_thread_id", "")
        assigned_at = task.get("assigned_at", "")
        task_type = task.get("type", "unknown")

        if not assigned_to:
            continue

        # Check if the assigned job exists (any state)
        if assigned_to in k8s_jobs:
            continue

        # Lobster is gone — orphaned task
        elapsed_min = _elapsed_minutes(assigned_at) if assigned_at else 0

        # Check for open PR
        if _has_open_pr(task_id):
            _log_file(f"ORPHAN (has PR): {task_id} — {assigned_to} gone but PR exists")
            _discord_post(thread_id,
                f"**[task-manager]** Note: **{assigned_to}** is offline, but a PR for **{task_id}** exists. Proceeding with review.")
            continue

        # Layer 2: Try fallback PR
        if _try_fallback_pr(task_id):
            _log_file(f"ORPHAN (fallback PR): {task_id} — created PR from {assigned_to} branch")
            await _api_log_event(session, db_id, "fallback_pr", f"Created fallback PR for {assigned_to}")
            _discord_post(thread_id,
                f"**[task-manager]** **{assigned_to}** is offline, but found work for **{task_id}**. Created fallback PR.")
            continue

        if elapsed_min < 30:
            # Re-queue
            _log_file(f"ORPHAN RE-QUEUE: {task_id} — {assigned_to} gone after {elapsed_min}m")
            _broker_deregister(task_id)
            try:
                await _api_update_task(session, db_id,
                    status="queued", assigned_to=None, assigned_at=None,
                    broker_repos=None, broker_status=None,
                    actor="task-manager")
                await _api_log_event(session, db_id, "requeued", f"{assigned_to} offline after {elapsed_min}m")
            except Exception as e:
                log.error("Failed to re-queue %s via API: %s", task_id, e)

            _discord_post(thread_id,
                f"**[task-manager]** Re-queued **{task_id}** — **{assigned_to}** went offline. Will reassign.")
        else:
            # Mark failed
            _log_file(f"ORPHAN FAILED: {task_id} — {assigned_to} gone after {elapsed_min}m, no PR")
            _broker_deregister(task_id)
            try:
                await _api_update_task(session, db_id, status="failed", actor="task-manager")
                await _api_log_event(session, db_id, "failed", f"Orphan: {assigned_to} offline {elapsed_min}m, no PR")
            except Exception as e:
                log.error("Failed to fail %s via API: %s", task_id, e)

            _discord_post(thread_id,
                f"**[task-manager]** Failed **{task_id}** — **{assigned_to}** offline for {elapsed_min}m with no PR.")

            # Layer 3: Create investigation task
            await _create_investigation_task(session, task_id, task_type, assigned_to,
                f"Orphan: lobster offline {elapsed_min}m, no PR, no fallback branch")


async def _create_investigation_task(
    session: aiohttp.ClientSession,
    task_id: str, task_type: str, assigned_to: str, failure_reason: str,
):
    """Layer 3: create an investigation task for lobsigliere."""
    os.makedirs(TASK_STATE_DIR, exist_ok=True)
    inv_state = os.path.join(TASK_STATE_DIR, f"{task_id}.investigation")
    if os.path.exists(inv_state):
        _log_file(f"SKIP investigation: already created for {task_id}")
        return

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Create investigation task via API
    try:
        result = await _api_create_task(session,
            name=f"Investigate failed task: {task_id}",
            type="system",
            priority="high",
            actor="task-manager",
        )
        inv_task_id = result["task_id"]
        inv_db_id = result["id"]
    except Exception as e:
        log.error("Failed to create investigation task via API: %s", e)
        return

    # Write vault file for lobsigliere to read
    inv_file = os.path.join(VAULT_DIR, "010-tasks", "active", f"{inv_task_id}.md")
    body = f"""---
id: {inv_task_id}
db_id: {inv_db_id}
type: system
status: queued
created: {now_iso}
priority: high
tags: [investigation, reliability]
---

# Investigate failed task: {task_id}

## Objective

Task **{task_id}** (type: {task_type}) was assigned to **{assigned_to}** and failed.
Failure reason: {failure_reason}

Investigate why the lobster failed to complete all workflow steps and submit a PR
to the lobmob repo that fixes the root cause.

## Investigation Steps

1. Read the failed task file at 010-tasks/active/{task_id}.md (or failed/)
2. Check if the lobster's vault branch exists and has commits
3. Read the lobster's work log at 020-logs/lobsters/{assigned_to}/
4. Examine the relevant lobster prompt (src/lobster/prompts/{task_type}.md)
5. Check verify.py criteria — which checks failed?
6. Identify the root cause and implement a fix

## Scope

- Fix prompts, verify.py, hooks.py, or run_task.py as needed
- Do NOT fix the original task — fix why the lobster couldn't complete it
- Target: lobsters should reliably complete all workflow steps autonomously
"""

    try:
        with open(inv_file, "w") as f:
            f.write(body)

        result = _run(
            f"cd '{VAULT_DIR}' && git add '{inv_file}' && "
            f"git commit -m '[task-manager] Create investigation task {inv_task_id} for failed {task_id}' --quiet 2>/dev/null && "
            f"git push origin main --quiet 2>/dev/null"
        )
        if result.returncode == 0:
            with open(inv_state, "w") as f:
                f.write(inv_task_id)
            _log_file(f"INVESTIGATION TASK created: {inv_task_id} for failed {task_id}")
        else:
            log.warning("Failed to commit investigation task %s", inv_task_id)
            try:
                os.unlink(inv_file)
            except Exception:
                pass
    except Exception as e:
        log.error("Failed to write investigation task file: %s", e)


# ── Main ─────────────────────────────────────────────────────────────

async def main():
    # Pull vault
    _run(f"cd '{VAULT_DIR}' && git pull origin main --quiet 2>/dev/null")

    async with aiohttp.ClientSession() as session:
        await detect_timeouts(session)
        await detect_orphans(session)


if __name__ == "__main__":
    asyncio.run(main())
