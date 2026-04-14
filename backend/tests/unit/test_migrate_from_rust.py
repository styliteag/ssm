"""Tests for scripts/migrate_from_rust.py — row-preserving Rust→Python DB copy."""

from __future__ import annotations

import importlib.util
import sqlite3
import sys
from pathlib import Path
from types import ModuleType

import pytest
from alembic import command
from alembic.config import Config

BACKEND_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = BACKEND_ROOT / "scripts" / "migrate_from_rust.py"


RUST_INITIAL_SQL = """
CREATE TABLE host (
    id INTEGER NOT NULL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    username TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    key_fingerprint TEXT,
    jump_via INTEGER,
    disabled BOOLEAN NOT NULL DEFAULT 0,
    comment TEXT,
    CONSTRAINT unique_address_port UNIQUE (address, port),
    FOREIGN KEY (jump_via) REFERENCES host(id) ON DELETE CASCADE
);

CREATE TABLE user (
    id INTEGER NOT NULL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    enabled BOOLEAN NOT NULL CHECK (enabled IN (0, 1)) DEFAULT 1,
    comment TEXT
);

CREATE TABLE authorization (
    id INTEGER NOT NULL PRIMARY KEY,
    host_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    login TEXT NOT NULL,
    options TEXT,
    comment TEXT,
    UNIQUE(user_id, host_id, login),
    FOREIGN KEY (host_id) REFERENCES host(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE
);

CREATE TABLE user_key (
    id INTEGER NOT NULL PRIMARY KEY,
    key_type TEXT NOT NULL,
    key_base64 TEXT UNIQUE NOT NULL,
    name TEXT,
    extra_comment TEXT,
    user_id INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE
);

CREATE TABLE activity_log (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    activity_type TEXT NOT NULL CHECK (activity_type IN ('key', 'host', 'user', 'auth')),
    action TEXT NOT NULL,
    target TEXT NOT NULL,
    user_id INTEGER,
    actor_username TEXT NOT NULL,
    timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    metadata TEXT,
    FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE SET NULL
);
"""


def _load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migrate_from_rust", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["migrate_from_rust"] = module
    spec.loader.exec_module(module)
    return module


def _make_rust_db(path: Path) -> None:
    conn = sqlite3.connect(path)
    try:
        conn.executescript(RUST_INITIAL_SQL)
        conn.execute(
            "INSERT INTO host (id, name, username, address, port, disabled)"
            " VALUES (1, 'bastion', 'root', '1.1.1.1', 22, 0)"
        )
        conn.execute(
            "INSERT INTO host (id, name, username, address, port, jump_via, disabled, comment)"
            " VALUES (2, 'inner', 'root', '10.0.0.2', 22, 1, 0, 'behind bastion')"
        )
        conn.execute("INSERT INTO user (id, username, enabled) VALUES (1, 'alice', 1)")
        conn.execute(
            "INSERT INTO user (id, username, enabled, comment) VALUES (2, 'bob', 0, 'disabled')"
        )
        conn.execute(
            "INSERT INTO authorization (id, host_id, user_id, login, options, comment)"
            " VALUES (1, 1, 1, 'root', 'no-pty', 'alice on bastion')"
        )
        conn.execute(
            "INSERT INTO user_key (id, key_type, key_base64, name, user_id)"
            " VALUES (1, 'ssh-ed25519', 'AAAABBBB', 'laptop', 1)"
        )
        conn.execute(
            "INSERT INTO activity_log (id, activity_type, action, target, user_id,"
            " actor_username, timestamp, metadata)"
            " VALUES (1, 'host', 'create', 'bastion', 1, 'admin', 1700000000, '{\"x\":1}')"
        )
        conn.commit()
    finally:
        conn.close()


def _make_new_db(path: Path) -> None:
    cfg = Config(str(BACKEND_ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_ROOT / "migrations"))
    cfg.set_main_option("sqlalchemy.url", f"sqlite+aiosqlite:///{path}")
    command.upgrade(cfg, "head")


def _count(path: Path, table: str) -> int:
    conn = sqlite3.connect(path)
    try:
        # Quote the table name to avoid issues with reserved words like "authorization".
        return int(conn.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])
    finally:
        conn.close()


@pytest.fixture
def rust_and_new_dbs(tmp_path: Path) -> tuple[Path, Path]:
    rust = tmp_path / "rust.db"
    new = tmp_path / "new.db"
    _make_rust_db(rust)
    _make_new_db(new)
    return rust, new


def test_copies_all_rows(rust_and_new_dbs: tuple[Path, Path]) -> None:
    rust, new = rust_and_new_dbs
    module = _load_script()

    result = module.migrate(source=rust, dest=new)

    assert result.ok is True
    for table in ("host", "user", "authorization", "user_key", "activity_log"):
        src = _count(rust, table)
        dst = _count(new, table)
        assert src == dst, f"row count mismatch for {table}: src={src} dst={dst}"


def test_preserves_field_values(rust_and_new_dbs: tuple[Path, Path]) -> None:
    rust, new = rust_and_new_dbs
    module = _load_script()
    module.migrate(source=rust, dest=new)

    conn = sqlite3.connect(new)
    try:
        row = conn.execute(
            "SELECT name, username, address, port, jump_via, disabled, comment"
            " FROM host WHERE id = 2"
        ).fetchone()
    finally:
        conn.close()

    assert row == ("inner", "root", "10.0.0.2", 22, 1, 0, "behind bastion")


def test_fails_if_dest_not_empty(rust_and_new_dbs: tuple[Path, Path]) -> None:
    rust, new = rust_and_new_dbs
    conn = sqlite3.connect(new)
    conn.execute("INSERT INTO user (id, username, enabled) VALUES (99, 'pre-existing', 1)")
    conn.commit()
    conn.close()

    module = _load_script()
    result = module.migrate(source=rust, dest=new)

    assert result.ok is False
    assert "not empty" in result.message.lower()


def test_fails_if_source_missing(tmp_path: Path) -> None:
    new = tmp_path / "new.db"
    _make_new_db(new)

    module = _load_script()
    result = module.migrate(source=tmp_path / "nope.db", dest=new)

    assert result.ok is False
    assert "source" in result.message.lower()


def test_copy_preserves_activity_log_timestamp(rust_and_new_dbs: tuple[Path, Path]) -> None:
    rust, new = rust_and_new_dbs
    module = _load_script()
    module.migrate(source=rust, dest=new)

    conn = sqlite3.connect(new)
    try:
        ts = conn.execute("SELECT timestamp FROM activity_log WHERE id = 1").fetchone()[0]
    finally:
        conn.close()
    assert ts == 1700000000
