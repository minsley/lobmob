"""lobwife_jobs — Cron job runner with SQLite-backed state.

Extracted from lobwife-daemon.py. Replaces JSON load_state/save_state
with async DB queries on the job_state table.
"""

import asyncio
import logging
import os
import time
from datetime import datetime, timezone
from pathlib import Path

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

from lobwife_db import get_db

log = logging.getLogger("lobwife")

SCRIPT_DIR = Path("/opt/lobmob/scripts/server")
VAULT_PATH = os.environ.get("VAULT_PATH", "/home/lobwife/vault")
MAX_OUTPUT_LINES = 200

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
    "flush-logs": {
        "script": "lobmob-flush-logs.sh",
        "schedule": "*/30 * * * *",
        "description": "Flush event logs to vault",
        "concurrency": "forbid",
    },
}


class JobRunner:
    def __init__(self):
        self.running = {}  # name -> asyncio.Task
        self.scheduler = AsyncIOScheduler(timezone="UTC")

    async def init_state(self):
        """Ensure all job definitions have a row in job_state."""
        db = await get_db()
        for name in JOB_DEFS:
            await db.execute(
                """INSERT OR IGNORE INTO job_state (name) VALUES (?)""",
                (name,),
            )
        await db.commit()

    async def _get_job_state(self, name: str) -> dict:
        db = await get_db()
        async with db.execute(
            "SELECT * FROM job_state WHERE name = ?", (name,)
        ) as cur:
            row = await cur.fetchone()
            if row is None:
                return {}
            return dict(row)

    async def _update_job_state(self, name: str, **fields):
        db = await get_db()
        sets = ", ".join(f"{k} = ?" for k in fields)
        vals = list(fields.values()) + [name]
        await db.execute(f"UPDATE job_state SET {sets} WHERE name = ?", vals)
        await db.commit()

    def _get_next_run(self, name: str) -> str | None:
        job = self.scheduler.get_job(name)
        if job is None:
            return None
        try:
            return str(job.next_run_time)
        except AttributeError:
            return None

    async def schedule_all(self):
        for name, defn in JOB_DEFS.items():
            state = await self._get_job_state(name)
            if not state.get("enabled", 1):
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
        defn = JOB_DEFS[name]

        # Concurrency check
        if defn.get("concurrency") == "forbid" and name in self.running:
            log.warning("Skipping %s — previous run still active", name)
            return

        script = SCRIPT_DIR / defn["script"]
        if not script.exists():
            log.error("Script not found: %s", script)
            await self._update_job_state(
                name, last_status="error", last_output=f"Script not found: {script}"
            )
            return

        log.info("Starting job: %s", name)
        start = time.monotonic()
        now_iso = datetime.now(timezone.utc).isoformat()

        # Increment run_count
        state = await self._get_job_state(name)
        run_count = state.get("run_count", 0) + 1
        await self._update_job_state(name, last_run=now_iso, run_count=run_count)

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

            lines = output.strip().splitlines()
            if len(lines) > MAX_OUTPUT_LINES:
                output = "\n".join(lines[-MAX_OUTPUT_LINES:])
                output = f"[truncated to last {MAX_OUTPUT_LINES} lines]\n{output}"

            duration = round(time.monotonic() - start, 1)

            if proc.returncode == 0:
                await self._update_job_state(
                    name, last_status="success", last_duration=duration, last_output=output
                )
                log.info("Job %s completed in %.1fs (exit 0)", name, duration)
            else:
                fail_count = state.get("fail_count", 0) + 1
                await self._update_job_state(
                    name, last_status="failed", last_duration=duration,
                    last_output=output, fail_count=fail_count,
                )
                log.warning("Job %s failed in %.1fs (exit %d)", name, duration, proc.returncode)

        except asyncio.TimeoutError:
            duration = round(time.monotonic() - start, 1)
            fail_count = state.get("fail_count", 0) + 1
            await self._update_job_state(
                name, last_status="timeout", last_duration=duration,
                last_output="Job timed out after 300s", fail_count=fail_count,
            )
            log.error("Job %s timed out after %.1fs", name, duration)
            if proc.returncode is None:
                proc.kill()

        except Exception as e:
            duration = round(time.monotonic() - start, 1)
            fail_count = state.get("fail_count", 0) + 1
            await self._update_job_state(
                name, last_status="error", last_duration=duration,
                last_output=str(e), fail_count=fail_count,
            )
            log.error("Job %s error: %s", name, e)

        finally:
            self.running.pop(name, None)

    async def trigger(self, name: str) -> str:
        if name not in JOB_DEFS:
            return f"Unknown job: {name}"
        if name in self.running:
            return f"Job {name} is already running"
        asyncio.create_task(self._run_job(name))
        return f"Job {name} triggered"

    async def enable(self, name: str) -> str:
        if name not in JOB_DEFS:
            return f"Unknown job: {name}"
        await self._update_job_state(name, enabled=1)
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
        return f"Job {name} enabled"

    async def disable(self, name: str) -> str:
        if name not in JOB_DEFS:
            return f"Unknown job: {name}"
        await self._update_job_state(name, enabled=0)
        try:
            self.scheduler.remove_job(name)
        except Exception:
            pass
        return f"Job {name} disabled"

    async def get_status(self) -> dict:
        jobs = {}
        for name, defn in JOB_DEFS.items():
            s = await self._get_job_state(name)
            jobs[name] = {
                "description": defn["description"],
                "schedule": defn["schedule"],
                "enabled": bool(s.get("enabled", 1)),
                "running": name in self.running,
                "last_run": s.get("last_run"),
                "last_status": s.get("last_status"),
                "last_duration": s.get("last_duration"),
                "run_count": s.get("run_count", 0),
                "fail_count": s.get("fail_count", 0),
                "next_run": self._get_next_run(name),
            }
        return jobs

    async def get_job_detail(self, name: str) -> dict | None:
        if name not in JOB_DEFS:
            return None
        defn = JOB_DEFS[name]
        s = await self._get_job_state(name)
        return {
            "name": name,
            "description": defn["description"],
            "script": defn["script"],
            "schedule": defn["schedule"],
            "concurrency": defn.get("concurrency", "allow"),
            "enabled": bool(s.get("enabled", 1)),
            "running": name in self.running,
            "last_run": s.get("last_run"),
            "last_status": s.get("last_status"),
            "last_duration": s.get("last_duration"),
            "last_output": s.get("last_output"),
            "run_count": s.get("run_count", 0),
            "fail_count": s.get("fail_count", 0),
            "next_run": self._get_next_run(name),
        }
