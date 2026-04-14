"""Tests for ssm.scheduler.setup — build + URL translation."""

from __future__ import annotations

from pathlib import Path

from apscheduler.jobstores.sqlalchemy import SQLAlchemyJobStore
from apscheduler.schedulers.asyncio import AsyncIOScheduler

from ssm.scheduler.setup import _sync_jobstore_url, build_scheduler


def test_sync_jobstore_url_translates_aiosqlite() -> None:
    assert _sync_jobstore_url("sqlite+aiosqlite:///db.sqlite") == "sqlite:///db.sqlite"


def test_sync_jobstore_url_translates_asyncpg() -> None:
    got = _sync_jobstore_url("postgresql+asyncpg://user:pw@h/db")
    assert got == "postgresql://user:pw@h/db"


def test_sync_jobstore_url_passes_through_sync_sqlite() -> None:
    assert _sync_jobstore_url("sqlite:///already.sync") == "sqlite:///already.sync"


def test_build_scheduler_uses_sqlalchemy_jobstore(tmp_path: Path) -> None:
    sched = build_scheduler(f"sqlite+aiosqlite:///{tmp_path / 'jobs.db'}")

    assert isinstance(sched, AsyncIOScheduler)
    store = sched._jobstores["default"]  # type: ignore[attr-defined]
    assert isinstance(store, SQLAlchemyJobStore)
