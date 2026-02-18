#!/usr/bin/env python3
"""lobwife-daemon — persistent cron scheduler + GitHub token broker + state DB.

Slim orchestrator that initializes the SQLite database, starts the job
scheduler and token broker, serves the HTTP API, and handles shutdown.
All business logic lives in extracted modules:
  - lobwife_db.py     — DB init, migration, connection
  - lobwife_jobs.py   — JobRunner (cron scheduling)
  - lobwife_broker.py — TokenBroker (GitHub credential broker)
  - lobwife_api.py    — HTTP routes (existing + Task CRUD)
"""

import asyncio
import logging
import os
import shutil
import signal
import sys
from pathlib import Path

from aiohttp import web

# Ensure sibling modules are importable (scripts/server/)
sys.path.insert(0, str(Path(__file__).parent))

from lobwife_db import init_db, close_db, get_db, DB_PATH, STATE_DIR
from lobwife_jobs import JobRunner, JOB_DEFS
from lobwife_broker import TokenBroker
from lobwife_api import build_app
from lobwife_sync import VaultSyncDaemon

DAEMON_PORT = 8081

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
# Main
# ---------------------------------------------------------------------------


async def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    # Initialize database (schema + migration)
    await init_db()

    # Job runner
    runner = JobRunner()
    await runner.init_state()
    await runner.schedule_all()
    runner.scheduler.start()
    log.info("Scheduler started with %d jobs", len(JOB_DEFS))

    # Token broker
    broker = TokenBroker()

    # Vault sync daemon
    sync_daemon = VaultSyncDaemon()
    asyncio.create_task(sync_daemon.run())
    log.info("Vault sync daemon started")

    # Periodic maintenance loop (every 5 min)
    backup_counter = 0

    async def persist_loop():
        nonlocal backup_counter
        while True:
            await asyncio.sleep(300)
            try:
                db = await get_db()
                # WAL checkpoint
                await db.execute("PRAGMA wal_checkpoint(PASSIVE)")
                # Broker cleanup
                await broker.cleanup_expired()
                # Hourly backup (every 12 iterations of 5-min loop)
                backup_counter += 1
                if backup_counter >= 12:
                    backup_counter = 0
                    backup_path = DB_PATH.with_suffix(".db.bak")
                    # Use file copy for backup (aiosqlite doesn't expose .backup)
                    shutil.copy2(str(DB_PATH), str(backup_path))
                    log.info("Database backed up to %s", backup_path)
                log.debug("Persist loop completed")
            except Exception as e:
                log.warning("Persist loop error: %s", e)

    asyncio.create_task(persist_loop())

    # HTTP API server
    app = build_app(runner, broker, sync_daemon)
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
    sync_daemon.stop()
    runner.scheduler.shutdown(wait=False)
    await api_runner.cleanup()
    await close_db()
    log.info("Shutdown complete")


if __name__ == "__main__":
    asyncio.run(main())
