"""One-shot Rust→Python DB copy.

Reads rows from the Rust backend's SQLite database and inserts them into an
already-Alembic-migrated Python database. Both schemas are identical, so the
copy is row-for-row with no transformation. Verifies row counts afterwards.

Usage
-----
    uv run python scripts/migrate_from_rust.py \\
        --source ../backend-rust/ssm.db \\
        --dest ./ssm.db
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path

# Foreign-key dependency order; each table references only earlier ones.
TABLES: tuple[str, ...] = ("host", "user", "authorization", "user_key", "activity_log")


@dataclass(frozen=True, slots=True)
class MigrationResult:
    ok: bool
    message: str
    copied: dict[str, int]


def _columns(conn: sqlite3.Connection, table: str) -> list[str]:
    rows = conn.execute(f'PRAGMA table_info("{table}")').fetchall()
    return [str(r[1]) for r in rows]


def _row_count(conn: sqlite3.Connection, table: str) -> int:
    return int(conn.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0])  # noqa: S608


def _dest_is_empty(dest: sqlite3.Connection) -> bool:
    return all(_row_count(dest, t) == 0 for t in TABLES)


def _copy_table(src: sqlite3.Connection, dest: sqlite3.Connection, table: str) -> int:
    src_cols = _columns(src, table)
    dest_cols = _columns(dest, table)
    shared = [c for c in src_cols if c in dest_cols]
    if not shared:
        msg = f"no shared columns between source and destination for table {table!r}"
        raise RuntimeError(msg)

    col_list = ", ".join(f'"{c}"' for c in shared)
    placeholders = ", ".join(["?"] * len(shared))
    select_sql = f'SELECT {col_list} FROM "{table}"'  # noqa: S608
    insert_sql = f'INSERT INTO "{table}" ({col_list}) VALUES ({placeholders})'  # noqa: S608

    rows = src.execute(select_sql).fetchall()
    dest.executemany(insert_sql, rows)
    return len(rows)


def _fail(message: str, copied: dict[str, int] | None = None) -> MigrationResult:
    return MigrationResult(ok=False, message=message, copied=copied or {})


def _do_copy(src: sqlite3.Connection, dest: sqlite3.Connection) -> MigrationResult:
    try:
        if not _dest_is_empty(dest):
            return _fail("destination database is not empty; refusing to copy")
    except sqlite3.OperationalError as exc:
        return _fail(f"destination schema missing expected tables: {exc}")

    dest.execute("PRAGMA foreign_keys = OFF")
    copied: dict[str, int] = {}
    try:
        for table in TABLES:
            copied[table] = _copy_table(src, dest, table)
        dest.commit()
    except Exception as exc:  # pragma: no cover — defensive rollback
        dest.rollback()
        return _fail(f"copy failed: {exc}", copied)
    finally:
        dest.execute("PRAGMA foreign_keys = ON")

    for table in TABLES:
        src_n = _row_count(src, table)
        dest_n = _row_count(dest, table)
        if src_n != dest_n:
            return _fail(f"row count mismatch for {table}: source={src_n} dest={dest_n}", copied)
    return MigrationResult(
        ok=True,
        message=f"copied {sum(copied.values())} rows across {len(TABLES)} tables",
        copied=copied,
    )


def migrate(source: Path, dest: Path) -> MigrationResult:
    """Copy all application tables from ``source`` into ``dest``."""
    if not source.exists():
        return _fail(f"source database not found: {source}")
    if not dest.exists():
        return _fail(f"destination database not found (run alembic upgrade first): {dest}")

    src_conn = sqlite3.connect(source)
    dest_conn = sqlite3.connect(dest)
    try:
        return _do_copy(src_conn, dest_conn)
    finally:
        src_conn.close()
        dest_conn.close()


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Copy Rust backend SQLite into Python DB.")
    parser.add_argument("--source", type=Path, required=True, help="Rust SQLite database path")
    parser.add_argument(
        "--dest", type=Path, required=True, help="Alembic-migrated target database path"
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    result = migrate(source=args.source, dest=args.dest)
    if result.ok:
        sys.stdout.write(result.message + "\n")
        for table, count in result.copied.items():
            sys.stdout.write(f"  {table}: {count}\n")
        return 0
    sys.stderr.write(result.message + "\n")
    return 1


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
