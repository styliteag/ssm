"""Verify the Alembic initial migration produces the expected schema."""

from __future__ import annotations

from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect

BACKEND_ROOT = Path(__file__).resolve().parents[2]


def _alembic_config(url: str) -> Config:
    cfg = Config(str(BACKEND_ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_ROOT / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    return cfg


def test_upgrade_creates_all_tables(tmp_path: Path) -> None:
    db_path = tmp_path / "alembic-test.db"
    sync_url = f"sqlite:///{db_path}"
    async_url = f"sqlite+aiosqlite:///{db_path}"

    cfg = _alembic_config(async_url)
    command.upgrade(cfg, "head")

    engine = create_engine(sync_url)
    try:
        names = set(inspect(engine).get_table_names())
    finally:
        engine.dispose()

    expected = {"host", "user", "authorization", "user_key", "activity_log"}
    missing = expected - names
    assert not missing, f"missing tables after upgrade: {missing}"


@pytest.mark.parametrize(
    ("table", "columns"),
    [
        (
            "host",
            {
                "id",
                "name",
                "username",
                "address",
                "port",
                "key_fingerprint",
                "jump_via",
                "disabled",
                "comment",
            },
        ),
        ("user", {"id", "username", "enabled", "comment"}),
        (
            "authorization",
            {"id", "host_id", "user_id", "login", "options", "comment"},
        ),
        (
            "user_key",
            {"id", "key_type", "key_base64", "name", "extra_comment", "user_id"},
        ),
        (
            "activity_log",
            {
                "id",
                "activity_type",
                "action",
                "target",
                "user_id",
                "actor_username",
                "timestamp",
                "metadata",
            },
        ),
    ],
)
def test_upgrade_creates_expected_columns(tmp_path: Path, table: str, columns: set[str]) -> None:
    db_path = tmp_path / f"schema-{table}.db"
    cfg = _alembic_config(f"sqlite+aiosqlite:///{db_path}")
    command.upgrade(cfg, "head")

    engine = create_engine(f"sqlite:///{db_path}")
    try:
        cols = {c["name"] for c in inspect(engine).get_columns(table)}
    finally:
        engine.dispose()

    assert columns <= cols, f"{table} missing columns: {columns - cols}"


def test_downgrade_drops_all_tables(tmp_path: Path) -> None:
    db_path = tmp_path / "downgrade.db"
    cfg = _alembic_config(f"sqlite+aiosqlite:///{db_path}")
    command.upgrade(cfg, "head")
    command.downgrade(cfg, "base")

    engine = create_engine(f"sqlite:///{db_path}")
    try:
        names = set(inspect(engine).get_table_names())
    finally:
        engine.dispose()

    app_tables = {"host", "user", "authorization", "user_key", "activity_log"}
    assert app_tables & names == set()
