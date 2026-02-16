"""lobwife_api — HTTP API routes for lobwife daemon.

Extracted from lobwife-daemon.py. Contains all existing route handlers
plus new /api/v1/tasks CRUD endpoints and DB-enriched /health.
"""

import json
import logging
import os
import time

from aiohttp import web

from lobwife_db import get_db, DB_PATH
from lobwife_jobs import JobRunner
from lobwife_broker import TokenBroker

log = logging.getLogger("lobwife")

# Whitelisted fields for PATCH /api/v1/tasks/{id}
TASK_PATCH_FIELDS = {
    "name", "type", "status", "priority", "model", "assigned_to",
    "repos", "discord_thread_id", "estimate_minutes", "requires_qa",
    "workflow", "assigned_at", "completed_at",
    "broker_repos", "broker_status", "token_count", "broker_registered_at",
}

VALID_TASK_STATUSES = {
    "queued", "active", "completed", "failed", "cancelled", "blocked",
}


def build_app(runner: JobRunner, broker: TokenBroker) -> web.Application:
    app = web.Application()

    # === Health & status ===

    async def handle_health(request):
        db_status = {"ok": False}
        try:
            db = await get_db()
            async with db.execute("SELECT 1 FROM schema_version") as cur:
                await cur.fetchone()
            db_size = DB_PATH.stat().st_size if DB_PATH.exists() else 0
            async with db.execute("SELECT COUNT(*) as cnt FROM tasks") as cur:
                task_count = (await cur.fetchone())["cnt"]
            db_status = {"ok": True, "size_bytes": db_size, "task_count": task_count}
        except Exception as e:
            db_status = {"ok": False, "error": str(e)}

        return web.json_response({
            "status": "ok",
            "uptime": time.monotonic(),
            "jobs_running": len(runner.running),
            "broker": await broker.get_summary(),
            "db": db_status,
        })

    async def handle_status(request):
        return web.json_response({
            "status": "ok",
            "uptime": time.monotonic(),
            "jobs": await runner.get_status(),
            "broker": await broker.get_summary(),
        })

    # === Cron job management ===

    async def handle_jobs(request):
        return web.json_response(await runner.get_status())

    async def handle_job_detail(request):
        name = request.match_info["name"]
        detail = await runner.get_job_detail(name)
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
        msg = await runner.enable(name)
        status = 200 if "enabled" in msg else 404
        return web.json_response({"message": msg}, status=status)

    async def handle_disable(request):
        name = request.match_info["name"]
        msg = await runner.disable(name)
        status = 200 if "disabled" in msg else 404
        return web.json_response({"message": msg}, status=status)

    # === Token broker (existing routes, unchanged) ===

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
        await broker.register_task(task_id, repos, lobster_type)
        return web.json_response({"status": "registered", "task_id": task_id})

    async def handle_deregister_task(request):
        task_id = request.match_info["task_id"]
        await broker.deregister_task(task_id)
        return web.json_response({"status": "removed", "task_id": task_id})

    async def handle_list_broker_tasks(request):
        return web.json_response(await broker.get_tasks())

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
        entries = await broker.get_audit_log(task_id=task_id)
        return web.json_response(entries)

    # === Task CRUD (/api/v1/tasks) ===

    async def handle_create_task(request):
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)

        name = data.get("name", "").strip()
        if not name:
            return web.json_response({"error": "name is required"}, status=400)

        task_type = data.get("type", "swe")
        status = data.get("status", "queued")
        if status not in VALID_TASK_STATUSES:
            return web.json_response({"error": f"invalid status: {status}"}, status=400)

        repos = data.get("repos")
        repos_json = json.dumps(repos) if repos else None

        db = await get_db()
        async with db.execute(
            """INSERT INTO tasks (name, slug, type, status, priority, model,
               assigned_to, repos, discord_thread_id, estimate_minutes,
               requires_qa, workflow)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                name,
                data.get("slug"),
                task_type,
                status,
                data.get("priority", "normal"),
                data.get("model"),
                data.get("assigned_to"),
                repos_json,
                data.get("discord_thread_id"),
                data.get("estimate_minutes"),
                1 if data.get("requires_qa") else 0,
                data.get("workflow"),
            ),
        ) as cur:
            task_id = cur.lastrowid

        # Log creation event
        await db.execute(
            "INSERT INTO task_events (task_id, event_type, detail, actor) VALUES (?, ?, ?, ?)",
            (task_id, "created", f"Task created with status={status}", data.get("actor")),
        )
        await db.commit()

        return web.json_response(
            {"id": task_id, "task_id": f"T{task_id}"},
            status=201,
        )

    async def handle_list_tasks(request):
        db = await get_db()
        conditions = []
        params = []

        status_filter = request.query.get("status")
        if status_filter:
            conditions.append("status = ?")
            params.append(status_filter)

        type_filter = request.query.get("type")
        if type_filter:
            conditions.append("type = ?")
            params.append(type_filter)

        where = ""
        if conditions:
            where = "WHERE " + " AND ".join(conditions)

        limit = min(int(request.query.get("limit", 100)), 500)
        params.append(limit)

        query = f"""SELECT id, name, slug, type, status, priority, model,
                    assigned_to, repos, discord_thread_id, estimate_minutes,
                    requires_qa, workflow, created_at, updated_at, queued_at,
                    assigned_at, completed_at
                    FROM tasks {where}
                    ORDER BY id DESC LIMIT ?"""

        async with db.execute(query, params) as cur:
            rows = await cur.fetchall()

        tasks = []
        for row in rows:
            task = dict(row)
            task["task_id"] = f"T{task['id']}"
            task["requires_qa"] = bool(task["requires_qa"])
            if task["repos"]:
                task["repos"] = json.loads(task["repos"])
            tasks.append(task)

        return web.json_response(tasks)

    async def handle_get_task(request):
        task_id = int(request.match_info["id"])
        db = await get_db()
        async with db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)) as cur:
            row = await cur.fetchone()
        if not row:
            return web.json_response({"error": f"Task T{task_id} not found"}, status=404)

        task = dict(row)
        task["task_id"] = f"T{task['id']}"
        task["requires_qa"] = bool(task["requires_qa"])
        if task["repos"]:
            task["repos"] = json.loads(task["repos"])
        return web.json_response(task)

    async def handle_update_task(request):
        task_id = int(request.match_info["id"])
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)

        db = await get_db()
        async with db.execute("SELECT id FROM tasks WHERE id = ?", (task_id,)) as cur:
            if not await cur.fetchone():
                return web.json_response({"error": f"Task T{task_id} not found"}, status=404)

        # Filter to whitelisted fields
        updates = {}
        for key, val in data.items():
            if key in TASK_PATCH_FIELDS:
                if key in ("repos", "broker_repos") and isinstance(val, list):
                    updates[key] = json.dumps(val)
                elif key == "requires_qa":
                    updates[key] = 1 if val else 0
                elif key == "status" and val not in VALID_TASK_STATUSES:
                    return web.json_response({"error": f"invalid status: {val}"}, status=400)
                else:
                    updates[key] = val

        if not updates:
            return web.json_response({"error": "no valid fields to update"}, status=400)

        updates["updated_at"] = "datetime('now')"
        sets = []
        vals = []
        for k, v in updates.items():
            if v == "datetime('now')":
                sets.append(f"{k} = datetime('now')")
            else:
                sets.append(f"{k} = ?")
                vals.append(v)
        vals.append(task_id)

        await db.execute(f"UPDATE tasks SET {', '.join(sets)} WHERE id = ?", vals)

        # Log update event
        changed = [k for k in updates if k != "updated_at"]
        await db.execute(
            "INSERT INTO task_events (task_id, event_type, detail, actor) VALUES (?, ?, ?, ?)",
            (task_id, "updated", f"Updated: {', '.join(changed)}", data.get("actor")),
        )
        await db.commit()

        return web.json_response({"id": task_id, "task_id": f"T{task_id}", "updated": changed})

    async def handle_cancel_task(request):
        task_id = int(request.match_info["id"])
        db = await get_db()
        async with db.execute("SELECT status FROM tasks WHERE id = ?", (task_id,)) as cur:
            row = await cur.fetchone()
        if not row:
            return web.json_response({"error": f"Task T{task_id} not found"}, status=404)
        if row["status"] in ("completed", "cancelled"):
            return web.json_response(
                {"error": f"Task T{task_id} is already {row['status']}"}, status=409
            )

        await db.execute(
            "UPDATE tasks SET status = 'cancelled', updated_at = datetime('now') WHERE id = ?",
            (task_id,),
        )
        await db.execute(
            "INSERT INTO task_events (task_id, event_type, detail) VALUES (?, ?, ?)",
            (task_id, "cancelled", "Task cancelled via API"),
        )
        await db.commit()

        return web.json_response({"id": task_id, "task_id": f"T{task_id}", "status": "cancelled"})

    async def handle_get_task_events(request):
        task_id = int(request.match_info["id"])
        db = await get_db()
        async with db.execute(
            "SELECT * FROM task_events WHERE task_id = ? ORDER BY id DESC", (task_id,)
        ) as cur:
            rows = await cur.fetchall()
        return web.json_response([dict(r) for r in rows])

    async def handle_create_task_event(request):
        task_id = int(request.match_info["id"])
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)

        event_type = data.get("event_type", "").strip()
        if not event_type:
            return web.json_response({"error": "event_type is required"}, status=400)

        db = await get_db()
        async with db.execute("SELECT id FROM tasks WHERE id = ?", (task_id,)) as cur:
            if not await cur.fetchone():
                return web.json_response({"error": f"Task T{task_id} not found"}, status=404)

        await db.execute(
            "INSERT INTO task_events (task_id, event_type, detail, actor) VALUES (?, ?, ?, ?)",
            (task_id, event_type, data.get("detail"), data.get("actor")),
        )
        await db.commit()

        return web.json_response({"status": "logged", "task_id": f"T{task_id}"}, status=201)

    # === Broker registration via tasks table (new) ===

    async def handle_register_task_v1(request):
        """POST /api/v1/tasks/{id}/register — set broker fields on a task."""
        task_id = int(request.match_info["id"])
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)

        repos = data.get("repos", [])
        lobster_type = data.get("lobster_type", "unknown")
        if not repos:
            return web.json_response({"error": "repos required"}, status=400)

        db = await get_db()
        async with db.execute("SELECT id FROM tasks WHERE id = ?", (task_id,)) as cur:
            if not await cur.fetchone():
                return web.json_response({"error": f"Task T{task_id} not found"}, status=404)

        now_iso = __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc
        ).isoformat()
        await db.execute(
            """UPDATE tasks SET broker_repos = ?, broker_status = 'active',
               broker_registered_at = ?, updated_at = datetime('now')
               WHERE id = ?""",
            (json.dumps(repos), now_iso, task_id),
        )
        await db.execute(
            "INSERT INTO task_events (task_id, event_type, detail, actor) VALUES (?, ?, ?, ?)",
            (task_id, "broker_registered", f"repos={repos}", lobster_type),
        )
        await db.commit()
        return web.json_response({"status": "registered", "task_id": f"T{task_id}"})

    # === Broker compat shims (old routes → tasks table lookup) ===

    async def handle_register_task_compat(request):
        """POST /api/tasks/{task_id}/register — compat shim.

        Tries to find task in tasks table by slug or name, sets broker fields.
        Falls back to broker_tasks for unrecognized task IDs.
        """
        slug = request.match_info["task_id"]
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)

        repos = data.get("repos", [])
        lobster_type = data.get("lobster_type", "unknown")
        if not repos:
            return web.json_response({"error": "repos required"}, status=400)

        db = await get_db()

        # Try to find by slug or name in tasks table
        db_task_id = None
        for field in ("slug", "name"):
            async with db.execute(
                f"SELECT id FROM tasks WHERE {field} = ?", (slug,)
            ) as cur:
                row = await cur.fetchone()
                if row:
                    db_task_id = row["id"]
                    break

        # Also try T-format: "T42" → id=42
        if db_task_id is None and slug.startswith("T") and slug[1:].isdigit():
            tid = int(slug[1:])
            async with db.execute("SELECT id FROM tasks WHERE id = ?", (tid,)) as cur:
                row = await cur.fetchone()
                if row:
                    db_task_id = row["id"]

        if db_task_id is not None:
            now_iso = __import__("datetime").datetime.now(
                __import__("datetime").timezone.utc
            ).isoformat()
            await db.execute(
                """UPDATE tasks SET broker_repos = ?, broker_status = 'active',
                   broker_registered_at = ?, updated_at = datetime('now')
                   WHERE id = ?""",
                (json.dumps(repos), now_iso, db_task_id),
            )
            await db.execute(
                "INSERT INTO task_events (task_id, event_type, detail, actor) VALUES (?, ?, ?, ?)",
                (db_task_id, "broker_registered", f"repos={repos} (compat)", lobster_type),
            )
            await db.commit()
            return web.json_response({"status": "registered", "task_id": slug})

        # Fall back to broker_tasks for legacy entries
        await broker.register_task(slug, repos, lobster_type)
        return web.json_response({"status": "registered", "task_id": slug})

    async def handle_get_token_compat(request):
        """POST /api/token — compat shim.

        Looks up task in tasks table first, falls back to broker_tasks.
        """
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

    # === Routes ===

    # Health & status
    app.router.add_get("/health", handle_health)
    app.router.add_get("/api/status", handle_status)

    # Cron jobs
    app.router.add_get("/api/jobs", handle_jobs)
    app.router.add_get("/api/jobs/{name}", handle_job_detail)
    app.router.add_post("/api/jobs/{name}/trigger", handle_trigger)
    app.router.add_post("/api/jobs/{name}/enable", handle_enable)
    app.router.add_post("/api/jobs/{name}/disable", handle_disable)

    # Token broker (compat shims — route through tasks table when possible)
    app.router.add_post("/api/tasks/{task_id}/register", handle_register_task_compat)
    app.router.add_delete("/api/tasks/{task_id}", handle_deregister_task)
    app.router.add_get("/api/tasks", handle_list_broker_tasks)
    app.router.add_post("/api/token", handle_get_token_compat)
    app.router.add_get("/api/token/audit", handle_token_audit)

    # Task CRUD (new, versioned)
    app.router.add_post("/api/v1/tasks", handle_create_task)
    app.router.add_get("/api/v1/tasks", handle_list_tasks)
    app.router.add_get("/api/v1/tasks/{id}", handle_get_task)
    app.router.add_patch("/api/v1/tasks/{id}", handle_update_task)
    app.router.add_delete("/api/v1/tasks/{id}", handle_cancel_task)
    app.router.add_get("/api/v1/tasks/{id}/events", handle_get_task_events)
    app.router.add_post("/api/v1/tasks/{id}/events", handle_create_task_event)
    app.router.add_post("/api/v1/tasks/{id}/register", handle_register_task_v1)

    return app
