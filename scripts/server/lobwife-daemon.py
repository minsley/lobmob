#!/usr/bin/env python3
"""lobwife-daemon — persistent cron scheduler + GitHub token broker.

Replaces k8s CronJobs with in-process scheduling via APScheduler.
Runs bash scripts on schedule, exposes HTTP API for status/control.
Also serves as the centralized GitHub credential broker for lobster agents.
"""

import asyncio
import base64
import json
import logging
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from aiohttp import web, ClientSession

try:
    import jwt as pyjwt
except ImportError:
    pyjwt = None

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path("/opt/lobmob/scripts/server")
STATE_DIR = Path(os.environ.get("HOME", "/home/lobwife")) / "state"
STATE_FILE = STATE_DIR / "jobs.json"
DAEMON_PORT = 8081  # Web dashboard on 8080, daemon API on 8081
VAULT_PATH = os.environ.get("VAULT_PATH", "/home/lobwife/vault")
MAX_OUTPUT_LINES = 200  # Truncate stored output

# Token broker config
TASKS_FILE = STATE_DIR / "tasks.json"
AUDIT_FILE = STATE_DIR / "token-audit.json"
TASK_MAX_AGE_HOURS = 24
AUDIT_MAX_ENTRIES = 500

# Job definitions: name -> {script, schedule (cron), description}
JOB_DEFS = {
    "task-manager": {
        "script": "lobmob-task-manager.sh",
        "schedule": "*/5 * * * *",
        "description": "Task assignment, timeout detection, orphan recovery",
        "concurrency": "forbid",
    },
    "review-prs": {
        "script": "lobmob-review-prs.sh",
        "schedule": "*/2 * * * *",
        "description": "Deterministic PR validation and auto-merge",
        "concurrency": "forbid",
    },
    "status-reporter": {
        "script": "lobmob-status-reporter.sh",
        "schedule": "*/30 * * * *",
        "description": "Fleet summary posted to Discord",
        "concurrency": "forbid",
    },
    "gh-token-refresh": {
        "script": "lobmob-gh-token.sh",
        "schedule": "*/45 * * * *",
        "description": "GitHub App installation token refresh",
        "concurrency": "forbid",
    },
    "flush-logs": {
        "script": "lobmob-flush-logs.sh",
        "schedule": "*/30 * * * *",
        "description": "Flush event logs to vault",
        "concurrency": "forbid",
    },
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("lobwife")

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------


def load_state() -> dict:
    """Load persisted job state from disk."""
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError) as e:
            log.warning("Failed to load state: %s", e)
    return {}


def save_state(state: dict):
    """Persist job state to disk."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, default=str))
    tmp.rename(STATE_FILE)


# ---------------------------------------------------------------------------
# Token broker
# ---------------------------------------------------------------------------


class TokenBroker:
    """GitHub credential broker — generates repo-scoped installation tokens."""

    def __init__(self):
        self.app_id = os.environ.get("GH_APP_ID", "")
        self.install_id = os.environ.get("GH_APP_INSTALL_ID", "")
        self.pem_key = self._load_pem()
        self.tasks: dict = {}
        self.audit_log: list = []
        self._load_state()
        if self.pem_key:
            log.info("Token broker enabled (app_id=%s)", self.app_id)
        else:
            log.warning("Token broker disabled — no PEM key configured")

    @property
    def enabled(self) -> bool:
        return bool(self.pem_key and self.app_id and self.install_id)

    def _load_pem(self) -> str | None:
        """Load PEM from GH_APP_PEM (base64) or GH_APP_PEM_PATH (file)."""
        pem_b64 = os.environ.get("GH_APP_PEM", "")
        if pem_b64:
            try:
                return base64.b64decode(pem_b64).decode("utf-8")
            except Exception as e:
                log.error("Failed to decode GH_APP_PEM: %s", e)
                return None
        pem_path = os.environ.get("GH_APP_PEM_PATH", "")
        if pem_path and Path(pem_path).exists():
            return Path(pem_path).read_text()
        return None

    def _generate_jwt(self) -> str:
        """Create GitHub App JWT signed with PEM (10-min lifetime)."""
        if not pyjwt:
            raise RuntimeError("PyJWT not installed — cannot generate JWT")
        now = int(time.time())
        payload = {"iat": now - 60, "exp": now + 540, "iss": self.app_id}
        return pyjwt.encode(payload, self.pem_key, algorithm="RS256")

    async def create_scoped_token(self, repos: list[str]) -> dict:
        """Generate installation token scoped to specific repos via GitHub API."""
        app_jwt = self._generate_jwt()
        # GitHub API wants repo names without owner prefix
        repo_names = [r.split("/")[-1] for r in repos]
        body = {
            "repositories": repo_names,
            "permissions": {
                "contents": "write",
                "pull_requests": "write",
                "metadata": "read",
            },
        }
        url = f"https://api.github.com/app/installations/{self.install_id}/access_tokens"
        async with ClientSession() as session:
            async with session.post(
                url,
                json=body,
                headers={
                    "Authorization": f"Bearer {app_jwt}",
                    "Accept": "application/vnd.github.v3+json",
                },
            ) as resp:
                if resp.status != 201:
                    text = await resp.text()
                    raise RuntimeError(f"GitHub API {resp.status}: {text[:300]}")
                data = await resp.json()
                return {"token": data["token"], "expires_at": data["expires_at"]}

    def register_task(self, task_id: str, repos: list[str], lobster_type: str):
        """Register a task's repo access. Called by lobboss at spawn."""
        self.tasks[task_id] = {
            "repos": repos,
            "lobster_type": lobster_type,
            "registered_at": datetime.now(timezone.utc).isoformat(),
            "status": "active",
            "token_count": 0,
        }
        self._save_state()
        self._audit("task_registered", task_id, repos)
        log.info("Registered task %s: repos=%s type=%s", task_id, repos, lobster_type)

    def deregister_task(self, task_id: str):
        """Remove task registration."""
        if task_id in self.tasks:
            self._audit("task_deregistered", task_id, self.tasks[task_id]["repos"])
            del self.tasks[task_id]
            self._save_state()
            log.info("Deregistered task %s", task_id)

    async def get_token_for_task(self, task_id: str) -> dict:
        """Validate task is active, return repo-scoped token."""
        if not self.enabled:
            raise RuntimeError("Token broker not configured (no PEM key)")
        task = self.tasks.get(task_id)
        if not task:
            raise ValueError(f"Task {task_id} not registered")
        if task["status"] != "active":
            raise ValueError(f"Task {task_id} is {task['status']}, not active")
        token_data = await self.create_scoped_token(task["repos"])
        task["token_count"] += 1
        self._audit("token_issued", task_id, task["repos"])
        return token_data

    def cleanup_expired(self):
        """Remove task registrations older than TASK_MAX_AGE_HOURS."""
        now = datetime.now(timezone.utc)
        expired = []
        for task_id, task in self.tasks.items():
            registered = datetime.fromisoformat(task["registered_at"])
            age_hours = (now - registered).total_seconds() / 3600
            if age_hours > TASK_MAX_AGE_HOURS:
                expired.append(task_id)
        for task_id in expired:
            log.info("Expiring stale task registration: %s", task_id)
            self.deregister_task(task_id)

    def _audit(self, action: str, task_id: str, repos: list[str]):
        self.audit_log.append({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "task_id": task_id,
            "repos": repos,
            "action": action,
        })
        if len(self.audit_log) > AUDIT_MAX_ENTRIES:
            self.audit_log = self.audit_log[-AUDIT_MAX_ENTRIES:]

    def _load_state(self):
        if TASKS_FILE.exists():
            try:
                self.tasks = json.loads(TASKS_FILE.read_text())
            except (json.JSONDecodeError, OSError) as e:
                log.warning("Failed to load tasks state: %s", e)
        if AUDIT_FILE.exists():
            try:
                self.audit_log = json.loads(AUDIT_FILE.read_text())
            except (json.JSONDecodeError, OSError) as e:
                log.warning("Failed to load audit log: %s", e)

    def _save_state(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = TASKS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.tasks, indent=2, default=str))
        tmp.rename(TASKS_FILE)

    def save_audit(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = AUDIT_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.audit_log, indent=2, default=str))
        tmp.rename(AUDIT_FILE)

    def get_summary(self) -> dict:
        return {
            "enabled": self.enabled,
            "app_id": self.app_id or None,
            "active_tasks": len([t for t in self.tasks.values() if t["status"] == "active"]),
            "total_tokens_issued": sum(t.get("token_count", 0) for t in self.tasks.values()),
            "audit_entries": len(self.audit_log),
        }


# ---------------------------------------------------------------------------
# Job runner
# ---------------------------------------------------------------------------


class JobRunner:
    def __init__(self):
        self.state = load_state()
        self.running = {}  # name -> asyncio.Task
        self.scheduler = AsyncIOScheduler(timezone="UTC")
        self._ensure_state_keys()

    def _ensure_state_keys(self):
        for name in JOB_DEFS:
            if name not in self.state:
                self.state[name] = {
                    "last_run": None,
                    "last_status": None,
                    "last_duration": None,
                    "last_output": None,
                    "run_count": 0,
                    "fail_count": 0,
                    "enabled": True,
                }

    def _get_next_run(self, name: str) -> str | None:
        """Get next run time for a job, or None if not scheduled."""
        job = self.scheduler.get_job(name)
        if job is None:
            return None
        try:
            return str(job.next_run_time)
        except AttributeError:
            return None

    def schedule_all(self):
        for name, defn in JOB_DEFS.items():
            if not self.state.get(name, {}).get("enabled", True):
                log.info("Skipping disabled job: %s", name)
                continue
            trigger = CronTrigger.from_crontab(defn["schedule"])
            self.scheduler.add_job(
                self._run_job,
                trigger=trigger,
                args=[name],
                id=name,
                name=name,
                replace_existing=True,
                misfire_grace_time=60,
            )
            log.info("Scheduled %s (%s)", name, defn["schedule"])

    async def _run_job(self, name: str):
        """Execute a job's bash script via subprocess."""
        defn = JOB_DEFS[name]
        job_state = self.state[name]

        # Concurrency check
        if defn.get("concurrency") == "forbid" and name in self.running:
            log.warning("Skipping %s — previous run still active", name)
            return

        script = SCRIPT_DIR / defn["script"]
        if not script.exists():
            log.error("Script not found: %s", script)
            job_state["last_status"] = "error"
            job_state["last_output"] = f"Script not found: {script}"
            save_state(self.state)
            return

        log.info("Starting job: %s", name)
        start = time.monotonic()
        job_state["last_run"] = datetime.now(timezone.utc).isoformat()
        job_state["run_count"] += 1

        # Build environment for the script (inherit our env + overrides)
        env = os.environ.copy()
        env["VAULT_PATH"] = VAULT_PATH
        env["PATH"] = f"/opt/lobmob/scripts/server:/opt/lobmob/scripts:{env.get('PATH', '')}"
        env["LOBMOB_RUNTIME"] = "k8s"
        env["LOG_DIR"] = "/tmp"
        env["TASK_STATE_DIR"] = "/tmp/lobmob-task-state"

        task = asyncio.current_task()
        self.running[name] = task

        try:
            proc = await asyncio.create_subprocess_exec(
                "bash", str(script),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=300)
            output = stdout.decode("utf-8", errors="replace") if stdout else ""

            # Truncate output for storage
            lines = output.strip().splitlines()
            if len(lines) > MAX_OUTPUT_LINES:
                output = "\n".join(lines[-MAX_OUTPUT_LINES:])
                output = f"[truncated to last {MAX_OUTPUT_LINES} lines]\n{output}"

            duration = round(time.monotonic() - start, 1)
            job_state["last_duration"] = duration
            job_state["last_output"] = output

            if proc.returncode == 0:
                job_state["last_status"] = "success"
                log.info("Job %s completed in %.1fs (exit 0)", name, duration)
            else:
                job_state["last_status"] = "failed"
                job_state["fail_count"] += 1
                log.warning("Job %s failed in %.1fs (exit %d)", name, duration, proc.returncode)

        except asyncio.TimeoutError:
            duration = round(time.monotonic() - start, 1)
            job_state["last_status"] = "timeout"
            job_state["last_duration"] = duration
            job_state["last_output"] = "Job timed out after 300s"
            job_state["fail_count"] += 1
            log.error("Job %s timed out after %.1fs", name, duration)
            if proc.returncode is None:
                proc.kill()

        except Exception as e:
            duration = round(time.monotonic() - start, 1)
            job_state["last_status"] = "error"
            job_state["last_duration"] = duration
            job_state["last_output"] = str(e)
            job_state["fail_count"] += 1
            log.error("Job %s error: %s", name, e)

        finally:
            self.running.pop(name, None)
            save_state(self.state)

    async def trigger(self, name: str) -> str:
        """Manually trigger a job. Returns status message."""
        if name not in JOB_DEFS:
            return f"Unknown job: {name}"
        if name in self.running:
            return f"Job {name} is already running"

        asyncio.create_task(self._run_job(name))
        return f"Job {name} triggered"

    def enable(self, name: str) -> str:
        if name not in JOB_DEFS:
            return f"Unknown job: {name}"
        self.state[name]["enabled"] = True
        # Re-add to scheduler
        defn = JOB_DEFS[name]
        trigger = CronTrigger.from_crontab(defn["schedule"])
        self.scheduler.add_job(
            self._run_job,
            trigger=trigger,
            args=[name],
            id=name,
            name=name,
            replace_existing=True,
            misfire_grace_time=60,
        )
        save_state(self.state)
        return f"Job {name} enabled"

    def disable(self, name: str) -> str:
        if name not in JOB_DEFS:
            return f"Unknown job: {name}"
        self.state[name]["enabled"] = False
        try:
            self.scheduler.remove_job(name)
        except Exception:
            pass
        save_state(self.state)
        return f"Job {name} disabled"

    def get_status(self) -> dict:
        """Full status for all jobs."""
        jobs = {}
        for name, defn in JOB_DEFS.items():
            s = self.state.get(name, {})
            jobs[name] = {
                "description": defn["description"],
                "schedule": defn["schedule"],
                "enabled": s.get("enabled", True),
                "running": name in self.running,
                "last_run": s.get("last_run"),
                "last_status": s.get("last_status"),
                "last_duration": s.get("last_duration"),
                "run_count": s.get("run_count", 0),
                "fail_count": s.get("fail_count", 0),
                "next_run": self._get_next_run(name),
            }
        return jobs

    def get_job_detail(self, name: str) -> dict | None:
        if name not in JOB_DEFS:
            return None
        defn = JOB_DEFS[name]
        s = self.state.get(name, {})
        return {
            "name": name,
            "description": defn["description"],
            "script": defn["script"],
            "schedule": defn["schedule"],
            "concurrency": defn.get("concurrency", "allow"),
            "enabled": s.get("enabled", True),
            "running": name in self.running,
            "last_run": s.get("last_run"),
            "last_status": s.get("last_status"),
            "last_duration": s.get("last_duration"),
            "last_output": s.get("last_output"),
            "run_count": s.get("run_count", 0),
            "fail_count": s.get("fail_count", 0),
            "next_run": self._get_next_run(name),
        }


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------


def build_app(runner: JobRunner, broker: TokenBroker) -> web.Application:
    app = web.Application()

    # --- Health & status ---

    async def handle_health(request):
        return web.json_response({
            "status": "ok",
            "uptime": time.monotonic(),
            "jobs_running": len(runner.running),
            "broker": broker.get_summary(),
        })

    async def handle_status(request):
        return web.json_response({
            "status": "ok",
            "uptime": time.monotonic(),
            "jobs": runner.get_status(),
            "broker": broker.get_summary(),
        })

    # --- Cron job management ---

    async def handle_jobs(request):
        return web.json_response(runner.get_status())

    async def handle_job_detail(request):
        name = request.match_info["name"]
        detail = runner.get_job_detail(name)
        if not detail:
            return web.json_response({"error": f"Unknown job: {name}"}, status=404)
        return web.json_response(detail)

    async def handle_trigger(request):
        name = request.match_info["name"]
        msg = await runner.trigger(name)
        status = 200 if "triggered" in msg else 409 if "running" in msg else 404
        return web.json_response({"message": msg}, status=status)

    async def handle_enable(request):
        name = request.match_info["name"]
        msg = runner.enable(name)
        status = 200 if "enabled" in msg else 404
        return web.json_response({"message": msg}, status=status)

    async def handle_disable(request):
        name = request.match_info["name"]
        msg = runner.disable(name)
        status = 200 if "disabled" in msg else 404
        return web.json_response({"message": msg}, status=status)

    # --- Token broker ---

    async def handle_register_task(request):
        task_id = request.match_info["task_id"]
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)
        repos = data.get("repos", [])
        lobster_type = data.get("lobster_type", "unknown")
        if not repos:
            return web.json_response({"error": "repos required"}, status=400)
        broker.register_task(task_id, repos, lobster_type)
        return web.json_response({"status": "registered", "task_id": task_id})

    async def handle_deregister_task(request):
        task_id = request.match_info["task_id"]
        broker.deregister_task(task_id)
        return web.json_response({"status": "removed", "task_id": task_id})

    async def handle_list_tasks(request):
        return web.json_response(broker.tasks)

    async def handle_get_token(request):
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)
        task_id = data.get("task_id", "")
        if not task_id:
            return web.json_response({"error": "task_id required"}, status=400)
        try:
            token_data = await broker.get_token_for_task(task_id)
            return web.json_response(token_data)
        except ValueError as e:
            return web.json_response({"error": str(e)}, status=403)
        except RuntimeError as e:
            return web.json_response({"error": str(e)}, status=503)

    async def handle_token_audit(request):
        task_id = request.query.get("task_id")
        if task_id:
            filtered = [e for e in broker.audit_log if e["task_id"] == task_id]
            return web.json_response(filtered)
        return web.json_response(broker.audit_log[-200:])

    # --- Routes ---

    app.router.add_get("/health", handle_health)
    app.router.add_get("/api/status", handle_status)
    # Cron jobs
    app.router.add_get("/api/jobs", handle_jobs)
    app.router.add_get("/api/jobs/{name}", handle_job_detail)
    app.router.add_post("/api/jobs/{name}/trigger", handle_trigger)
    app.router.add_post("/api/jobs/{name}/enable", handle_enable)
    app.router.add_post("/api/jobs/{name}/disable", handle_disable)
    # Token broker
    app.router.add_post("/api/tasks/{task_id}/register", handle_register_task)
    app.router.add_delete("/api/tasks/{task_id}", handle_deregister_task)
    app.router.add_get("/api/tasks", handle_list_tasks)
    app.router.add_post("/api/token", handle_get_token)
    app.router.add_get("/api/token/audit", handle_token_audit)

    return app


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


async def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    runner = JobRunner()
    runner.schedule_all()
    runner.scheduler.start()
    log.info("Scheduler started with %d jobs", len(JOB_DEFS))

    broker = TokenBroker()

    # Periodic state persistence + broker cleanup (every 5 min)
    async def persist_loop():
        while True:
            await asyncio.sleep(300)
            save_state(runner.state)
            broker.cleanup_expired()
            broker.save_audit()
            log.debug("State persisted")

    asyncio.create_task(persist_loop())

    # HTTP API server
    app = build_app(runner, broker)
    api_runner = web.AppRunner(app)
    await api_runner.setup()
    site = web.TCPSite(api_runner, "0.0.0.0", DAEMON_PORT)
    await site.start()
    log.info("HTTP API listening on port %d", DAEMON_PORT)

    # Wait for shutdown signal
    stop = asyncio.Event()
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)

    await stop.wait()
    log.info("Shutting down...")
    runner.scheduler.shutdown(wait=False)
    await api_runner.cleanup()
    save_state(runner.state)
    broker._save_state()
    broker.save_audit()
    log.info("Shutdown complete")


if __name__ == "__main__":
    asyncio.run(main())
