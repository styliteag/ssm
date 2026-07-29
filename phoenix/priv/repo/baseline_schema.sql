-- Baseline schema: the exact table set the python stack's Alembic head
-- (backend/migrations/versions/0001_initial_schema.py) produces on SQLite,
-- made idempotent with CREATE TABLE IF NOT EXISTS.
--
-- Three database generations exist in the wild, and this file must be a
-- safe no-op-or-fill-gaps on all of them:
--   1. fresh (empty)           -> every table is created here
--   2. Diesel-era (Rust stack) -> tables exist with slightly older DDL and
--                                 WITHOUT activity_log; only the missing
--                                 pieces are created (env.py parity)
--   3. Alembic-era             -> everything exists; all statements no-op
--
-- DDL-text drift on adopted databases (e.g. Diesel's user_key FK without
-- ON DELETE CASCADE) is accepted, exactly as the python stack accepted it.
-- alembic_version, apscheduler_jobs and __diesel_schema_migrations are left
-- untouched so a rollback to the python image keeps working.
--
-- Keep this file pure CREATE TABLE/INDEX IF NOT EXISTS — the migration
-- refuses DROP/TRUNCATE/DELETE/RENAME statements outright.

CREATE TABLE IF NOT EXISTS "host" (
    id INTEGER NOT NULL,
    name TEXT NOT NULL,
    username TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    key_fingerprint TEXT,
    jump_via INTEGER,
    disabled BOOLEAN NOT NULL DEFAULT 0,
    comment TEXT,
    PRIMARY KEY (id),
    CONSTRAINT uq_host_name UNIQUE (name),
    CONSTRAINT unique_address_port UNIQUE (address, port),
    CONSTRAINT fk_host_jump_via FOREIGN KEY (jump_via) REFERENCES "host" (id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS "user" (
    id INTEGER NOT NULL,
    username TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    comment TEXT,
    PRIMARY KEY (id),
    CONSTRAINT uq_user_username UNIQUE (username),
    CONSTRAINT user_enabled_bool CHECK (enabled IN (0, 1))
);

CREATE TABLE IF NOT EXISTS "authorization" (
    id INTEGER NOT NULL,
    host_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    login TEXT NOT NULL,
    options TEXT,
    comment TEXT,
    PRIMARY KEY (id),
    CONSTRAINT unique_user_host_login UNIQUE (user_id, host_id, login),
    CONSTRAINT fk_authorization_host_id FOREIGN KEY (host_id) REFERENCES "host" (id) ON DELETE CASCADE,
    CONSTRAINT fk_authorization_user_id FOREIGN KEY (user_id) REFERENCES "user" (id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS "user_key" (
    id INTEGER NOT NULL,
    key_type TEXT NOT NULL,
    key_base64 TEXT NOT NULL,
    name TEXT,
    extra_comment TEXT,
    user_id INTEGER NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uq_user_key_key_base64 UNIQUE (key_base64),
    CONSTRAINT fk_user_key_user_id FOREIGN KEY (user_id) REFERENCES "user" (id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS activity_log (
    id INTEGER NOT NULL,
    activity_type VARCHAR NOT NULL,
    action TEXT NOT NULL,
    target TEXT NOT NULL,
    user_id INTEGER,
    actor_username TEXT NOT NULL,
    timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    metadata TEXT,
    PRIMARY KEY (id),
    CONSTRAINT activity_log_type_check CHECK (activity_type IN ('key', 'host', 'user', 'auth')),
    CONSTRAINT fk_activity_log_user_id FOREIGN KEY (user_id) REFERENCES "user" (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_activity_log_timestamp ON activity_log (timestamp);

CREATE INDEX IF NOT EXISTS idx_activity_log_type ON activity_log (activity_type);
