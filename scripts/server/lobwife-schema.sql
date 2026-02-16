-- lobwife SQLite schema — vault-scaling Phase 1
-- Applied by lobwife_db.init_db() on startup

-- Schema versioning
CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER NOT NULL,
    applied_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- Tasks (metadata only — body lives in vault)
CREATE TABLE IF NOT EXISTS tasks (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    name                TEXT    NOT NULL,
    slug                TEXT,
    type                TEXT    NOT NULL DEFAULT 'swe',
    status              TEXT    NOT NULL DEFAULT 'queued',
    priority            TEXT    NOT NULL DEFAULT 'normal',
    model               TEXT,
    assigned_to         TEXT,
    repos               TEXT,
    discord_thread_id   TEXT,
    estimate_minutes    INTEGER,
    requires_qa         INTEGER NOT NULL DEFAULT 0,
    workflow            TEXT,
    created_at          TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at          TEXT    NOT NULL DEFAULT (datetime('now')),
    queued_at           TEXT    NOT NULL DEFAULT (datetime('now')),
    assigned_at         TEXT,
    completed_at        TEXT
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_type   ON tasks(type);

-- Task event log (audit trail)
CREATE TABLE IF NOT EXISTS task_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id     INTEGER NOT NULL REFERENCES tasks(id),
    event_type  TEXT    NOT NULL,
    detail      TEXT,
    actor       TEXT,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_task_events_task_id ON task_events(task_id);

-- Cron job state (replaces jobs.json)
CREATE TABLE IF NOT EXISTS job_state (
    name            TEXT PRIMARY KEY,
    last_run        TEXT,
    last_status     TEXT,
    last_duration   REAL,
    last_output     TEXT,
    run_count       INTEGER NOT NULL DEFAULT 0,
    fail_count      INTEGER NOT NULL DEFAULT 0,
    enabled         INTEGER NOT NULL DEFAULT 1
);

-- Token broker registrations (replaces tasks.json)
-- Separate from tasks table in Phase 1; unified in Phase 2
CREATE TABLE IF NOT EXISTS broker_tasks (
    task_id         TEXT PRIMARY KEY,
    repos           TEXT    NOT NULL,
    lobster_type    TEXT    NOT NULL DEFAULT 'unknown',
    registered_at   TEXT    NOT NULL DEFAULT (datetime('now')),
    status          TEXT    NOT NULL DEFAULT 'active',
    token_count     INTEGER NOT NULL DEFAULT 0
);

-- Token audit log (replaces token-audit.json)
CREATE TABLE IF NOT EXISTS token_audit (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id     TEXT    NOT NULL,
    repos       TEXT,
    action      TEXT    NOT NULL,
    created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_token_audit_task_id ON token_audit(task_id);
