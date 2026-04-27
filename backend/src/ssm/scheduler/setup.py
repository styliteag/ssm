"""Build and wire an :class:`AsyncIOScheduler`.

The job store lives in the application database (``SQLAlchemyJobStore``) so
cron-style jobs survive process restarts. APScheduler speaks the synchronous
SQLAlchemy URL, so we translate the ``sqlite+aiosqlite://`` form back to the
sync ``sqlite:///`` form used everywhere else.
"""

from __future__ import annotations

from apscheduler.jobstores.sqlalchemy import SQLAlchemyJobStore
from apscheduler.schedulers.asyncio import AsyncIOScheduler


def _sync_jobstore_url(database_url: str) -> str:
    """APScheduler wants a sync URL; convert the async aiosqlite form back."""
    if database_url.startswith("sqlite+aiosqlite://"):
        return "sqlite://" + database_url[len("sqlite+aiosqlite://") :]
    if database_url.startswith("postgresql+asyncpg://"):
        return "postgresql://" + database_url[len("postgresql+asyncpg://") :]
    return database_url


def build_scheduler(database_url: str) -> AsyncIOScheduler:
    """Return a configured :class:`AsyncIOScheduler` (not yet started)."""
    jobstore = SQLAlchemyJobStore(url=_sync_jobstore_url(database_url))
    return AsyncIOScheduler(jobstores={"default": jobstore})
