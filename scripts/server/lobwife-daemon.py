#!/usr/bin/env python3
"""lobwife-daemon — persistent cron scheduler with HTTP API.

Replaces k8s CronJobs with in-process scheduling via APScheduler.
Runs bash scripts on schedule, exposes HTTP API for status/control.
"""

import asyncio
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
from aiohttp import web

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path("/opt/lobmob/scripts/server")
STATE_DIR = Path(os.environ.get("HOME", "/home/lobwife")) / "state"
STATE_FILE = STATE_DIR / "jobs.json"
DAEMON_PORT = 8081  # Web dashboard on 8080, daemon API on 8081
VAULT_PATH = os.environ.get("VAULT_PATH", "/home/lobwife/vault")
MAX_OUTPUT_LINES = 200  # Truncate stored output

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
            nxt = self.scheduler.get_job(name).next_run_time
            log.info("Scheduled %s (%s) — next run: %s", name, defn["schedule"], nxt)

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
            job = self.scheduler.get_job(name)
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
                "next_run": str(job.next_run_time) if job else None,
            }
        return jobs

    def get_job_detail(self, name: str) -> dict | None:
        if name not in JOB_DEFS:
            return None
        defn = JOB_DEFS[name]
        s = self.state.get(name, {})
        job = self.scheduler.get_job(name)
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
            "next_run": str(job.next_run_time) if job else None,
        }


# ---------------------------------------------------------------------------
# HTTP API
# ---------------------------------------------------------------------------


def build_app(runner: JobRunner) -> web.Application:
    app = web.Application()

    async def handle_health(request):
        return web.json_response({
            "status": "ok",
            "uptime": time.monotonic(),
            "jobs_running": len(runner.running),
        })

    async def handle_status(request):
        return web.json_response({
            "status": "ok",
            "uptime": time.monotonic(),
            "jobs": runner.get_status(),
        })

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

    app.router.add_get("/health", handle_health)
    app.router.add_get("/api/status", handle_status)
    app.router.add_get("/api/jobs", handle_jobs)
    app.router.add_get("/api/jobs/{name}", handle_job_detail)
    app.router.add_post("/api/jobs/{name}/trigger", handle_trigger)
    app.router.add_post("/api/jobs/{name}/enable", handle_enable)
    app.router.add_post("/api/jobs/{name}/disable", handle_disable)

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

    # Periodic state persistence (every 5 min)
    async def persist_loop():
        while True:
            await asyncio.sleep(300)
            save_state(runner.state)
            log.debug("State persisted to %s", STATE_FILE)

    asyncio.create_task(persist_loop())

    # HTTP API server
    app = build_app(runner)
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
    log.info("Shutdown complete")


if __name__ == "__main__":
    asyncio.run(main())
