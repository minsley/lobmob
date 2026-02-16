#!/usr/bin/env python3
"""migrate-vault-tasks — one-time import of existing vault tasks into lobwife DB.

Parses all task files in 010-tasks/{active,completed,failed}/, extracts
frontmatter metadata, and POSTs to the lobwife API. Outputs a mapping
of old slugs to new DB IDs.

Usage:
    # Against dev
    LOBWIFE_URL=http://localhost:8081 python3 scripts/migrate-vault-tasks.py /path/to/vault

    # Against prod (via port-forward)
    kubectl port-forward svc/lobwife 8081:8081 -n lobmob &
    LOBWIFE_URL=http://localhost:8081 python3 scripts/migrate-vault-tasks.py /path/to/vault

Idempotent: skips tasks whose slug already exists in the DB.
"""

import asyncio
import json
import os
import re
import sys
from pathlib import Path

import aiohttp
import yaml

LOBWIFE_URL = os.environ.get("LOBWIFE_URL", "http://localhost:8081")
FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def parse_frontmatter(content: str) -> dict:
    match = FRONTMATTER_RE.match(content)
    if match:
        return yaml.safe_load(match.group(1)) or {}
    return {}


async def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <vault-path>")
        sys.exit(1)

    vault_path = Path(sys.argv[1])
    if not vault_path.exists():
        print(f"Vault path not found: {vault_path}")
        sys.exit(1)

    tasks_dir = vault_path / "010-tasks"
    if not tasks_dir.exists():
        print(f"No 010-tasks directory found at {tasks_dir}")
        sys.exit(1)

    # Collect all task files
    task_files = []
    for subdir in ("active", "completed", "failed"):
        d = tasks_dir / subdir
        if d.exists():
            task_files.extend(sorted(d.glob("*.md")))

    if not task_files:
        print("No task files found")
        sys.exit(0)

    print(f"Found {len(task_files)} task file(s)")

    # Check existing slugs in DB
    async with aiohttp.ClientSession() as session:
        existing_slugs = set()
        try:
            async with session.get(
                f"{LOBWIFE_URL}/api/v1/tasks",
                params={"limit": "500"},
                timeout=aiohttp.ClientTimeout(total=15),
            ) as resp:
                if resp.status == 200:
                    tasks = await resp.json()
                    for t in tasks:
                        if t.get("slug"):
                            existing_slugs.add(t["slug"])
                        if t.get("name"):
                            existing_slugs.add(t["name"])
        except Exception as e:
            print(f"Warning: failed to check existing tasks: {e}")

        mapping = {}
        skipped = 0
        created = 0
        errors = 0

        for task_file in task_files:
            slug = task_file.stem
            content = task_file.read_text()
            meta = parse_frontmatter(content)

            if not meta:
                print(f"  SKIP (no frontmatter): {task_file.name}")
                skipped += 1
                continue

            # Check if already migrated
            old_id = meta.get("id", slug)
            if old_id in existing_slugs or slug in existing_slugs:
                print(f"  SKIP (exists): {slug}")
                skipped += 1
                continue

            # Map frontmatter fields to API payload
            payload = {
                "name": meta.get("id", slug),
                "slug": slug,
                "type": meta.get("type", "swe"),
                "status": meta.get("status", "queued"),
                "priority": meta.get("priority", "normal"),
                "model": meta.get("model"),
                "assigned_to": meta.get("assigned_to") or None,
                "discord_thread_id": str(meta.get("discord_thread_id", "")) or None,
                "estimate_minutes": meta.get("estimate") or meta.get("estimate_minutes"),
                "requires_qa": bool(meta.get("requires_qa", False)),
                "workflow": meta.get("workflow"),
                "actor": "migration",
            }

            # Handle repos field
            repos = meta.get("repos") or meta.get("repo")
            if repos:
                if isinstance(repos, str):
                    repos = [repos]
                payload["repos"] = repos

            # Clean None values
            payload = {k: v for k, v in payload.items() if v is not None}

            try:
                async with session.post(
                    f"{LOBWIFE_URL}/api/v1/tasks",
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=15),
                ) as resp:
                    body = await resp.json()
                    if resp.status == 201:
                        db_id = body["id"]
                        task_id = body["task_id"]
                        mapping[slug] = {"db_id": db_id, "task_id": task_id}
                        print(f"  OK: {slug} -> {task_id} (id={db_id})")
                        created += 1

                        # Log creation event
                        await session.post(
                            f"{LOBWIFE_URL}/api/v1/tasks/{db_id}/events",
                            json={
                                "event_type": "migrated",
                                "detail": f"Migrated from vault: {slug}",
                                "actor": "migration",
                            },
                            timeout=aiohttp.ClientTimeout(total=5),
                        )

                        # If task has a non-queued status, log that too
                        status = meta.get("status", "queued")
                        if status != "queued":
                            await session.post(
                                f"{LOBWIFE_URL}/api/v1/tasks/{db_id}/events",
                                json={
                                    "event_type": status,
                                    "detail": f"Status at migration time: {status}",
                                    "actor": "migration",
                                },
                                timeout=aiohttp.ClientTimeout(total=5),
                            )
                    else:
                        error_msg = body.get("error", str(body))
                        print(f"  ERROR: {slug} — {resp.status}: {error_msg}")
                        errors += 1
            except Exception as e:
                print(f"  ERROR: {slug} — {e}")
                errors += 1

    print(f"\nDone: {created} created, {skipped} skipped, {errors} errors")

    if mapping:
        mapping_file = "vault-task-mapping.json"
        with open(mapping_file, "w") as f:
            json.dump(mapping, f, indent=2)
        print(f"Mapping written to {mapping_file}")


if __name__ == "__main__":
    asyncio.run(main())
