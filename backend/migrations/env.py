import asyncio
import os
from logging.config import fileConfig

import sqlalchemy as sa
from alembic import context
from sqlalchemy import inspect, pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from ssm.db import models  # noqa: F401  — register models with Base.metadata
from ssm.db.base import Base

# Revision matching the schema produced by the legacy Rust/Diesel backend.
LEGACY_REVISION = "0001"

config = context.config

# Allow overriding the DB URL from env (e.g. DATABASE_URL in CI).
if env_url := os.environ.get("DATABASE_URL"):
    if env_url.startswith("sqlite://") and not env_url.startswith("sqlite+aiosqlite://"):
        env_url = "sqlite+aiosqlite://" + env_url[len("sqlite://") :]
    config.set_main_option("sqlalchemy.url", env_url)

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

# other values from the config, defined by the needs of env.py,
# can be acquired:
# my_important_option = config.get_main_option("my_important_option")
# ... etc.


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode.

    This configures the context with just a URL
    and not an Engine, though an Engine is acceptable
    here as well.  By skipping the Engine creation
    we don't even need a DBAPI to be available.

    Calls to context.execute() here emit the given string to the
    script output.

    """
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def _stamp_legacy_database_if_needed(connection: Connection) -> None:
    """Stamp databases inherited from the Rust/Diesel backend as ``0001``.

    Those databases already contain the application schema (``host``,
    ``user``, ...) but no recorded alembic revision. Two flavours occur in
    the wild:

    * No ``alembic_version`` table at all — pure Diesel-era database.
    * ``alembic_version`` exists but is empty — created by an earlier,
      crashed migration attempt or partial bootstrap.

    Either way a plain ``alembic upgrade head`` would re-run revision
    0001 and fail with ``table host already exists``. Detect both cases
    and seed ``alembic_version`` so the upgrade becomes a no-op for
    revision 0001 and proceeds with any later revisions.
    """
    inspector = inspect(connection)
    if not inspector.has_table("host"):
        return  # genuinely fresh DB; let alembic create everything

    if inspector.has_table("alembic_version"):
        existing = connection.execute(
            sa.text("SELECT version_num FROM alembic_version LIMIT 1")
        ).first()
        if existing is not None:
            return  # already stamped — nothing to do
        print(
            f"Legacy database detected (host table present, alembic_version "
            f"empty); stamping as {LEGACY_REVISION}.",
            flush=True,
        )
    else:
        print(
            f"Legacy database detected (host table present, no "
            f"alembic_version table); stamping as {LEGACY_REVISION}.",
            flush=True,
        )
        connection.execute(
            sa.text(
                "CREATE TABLE alembic_version ("
                "version_num VARCHAR(32) NOT NULL, "
                "CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num))"
            )
        )

    connection.execute(
        sa.text("INSERT INTO alembic_version (version_num) VALUES (:rev)"),
        {"rev": LEGACY_REVISION},
    )
    connection.commit()


def do_run_migrations(connection: Connection) -> None:
    _stamp_legacy_database_if_needed(connection)

    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        render_as_batch=True,
    )

    with context.begin_transaction():
        context.run_migrations()

    # SQLite uses non-transactional DDL, so DDL statements auto-commit but
    # the alembic_version stamp INSERT does not. The async ``connect()``
    # context manager would otherwise roll back the autobegun transaction
    # when it closes, leaving the schema created but unstamped.
    connection.commit()


async def run_async_migrations() -> None:
    """In this scenario we need to create an Engine
    and associate a connection with the context.

    """

    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)

    await connectable.dispose()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode."""

    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
