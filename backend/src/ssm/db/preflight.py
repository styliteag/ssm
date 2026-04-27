"""Pre-migration check for legacy (Rust-era) databases.

The previous Rust backend used Diesel and produced a SQLite schema that is
identical to alembic revision ``0001``. Such databases have the application
tables (``host``, ``user``, ...) but no ``alembic_version`` table, so
``alembic upgrade head`` fails with ``table host already exists``.

This script detects that situation and stamps the database as ``0001`` so
the subsequent ``alembic upgrade head`` becomes a no-op (or applies any
later revisions). Behaviour:

* No ``DATABASE_URL`` set, or non-SQLite URL → exit 0 (let alembic handle it).
* SQLite file does not exist → exit 0 (fresh install).
* ``alembic_version`` table present → exit 0 (already managed).
* ``host`` table present, no ``alembic_version`` → run ``alembic stamp 0001``.
* Otherwise (empty file) → exit 0.
"""

from __future__ import annotations

import os
import sqlite3
import subprocess
import sys
from pathlib import Path

from sqlalchemy.engine.url import make_url

LEGACY_REVISION = "0001"


def _sqlite_path(database_url: str) -> Path | None:
    url = make_url(database_url)
    if url.get_backend_name() != "sqlite":
        return None
    if not url.database or url.database == ":memory:":
        return None
    return Path(url.database)


def main() -> int:
    raw_url = os.environ.get("DATABASE_URL")
    if not raw_url:
        return 0

    db_path = _sqlite_path(raw_url)
    if db_path is None or not db_path.exists():
        return 0

    with sqlite3.connect(db_path) as conn:
        tables = {
            row[0]
            for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }

    if "alembic_version" in tables:
        return 0
    if "host" not in tables:
        return 0

    print(
        f"Detected legacy database at {db_path} without alembic_version table; "
        f"stamping as revision {LEGACY_REVISION}.",
        flush=True,
    )
    return subprocess.call(["alembic", "stamp", LEGACY_REVISION])


if __name__ == "__main__":
    sys.exit(main())
