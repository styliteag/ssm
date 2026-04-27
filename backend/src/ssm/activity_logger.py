"""Single entry point for appending to the ``activity_log`` table.

Call sites::

    await log_activity(
        session,
        activity_type=ActivityType.HOST,
        action="create",
        target=host.name,
        actor_username=user.username,
        user_id=user.id,
        details={"address": host.address},
    )

``details`` is serialised to JSON and stored in the ``metadata`` column.
The helper does **not** commit — it participates in the surrounding
request-scoped transaction.
"""

from __future__ import annotations

import json
import time
from enum import StrEnum
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from ssm.db.models import ActivityLog


class ActivityType(StrEnum):
    KEY = "key"
    HOST = "host"
    USER = "user"
    AUTH = "auth"


async def log_activity(
    session: AsyncSession,
    *,
    activity_type: ActivityType,
    action: str,
    target: str,
    actor_username: str,
    user_id: int | None = None,
    details: dict[str, Any] | None = None,
    timestamp: int | None = None,
) -> ActivityLog:
    """Insert one row into ``activity_log`` and return the persisted entity."""
    entry = ActivityLog(
        activity_type=activity_type.value,
        action=action,
        target=target,
        actor_username=actor_username,
        user_id=user_id,
        timestamp=timestamp if timestamp is not None else int(time.time()),
        meta=json.dumps(details) if details is not None else None,
    )
    session.add(entry)
    await session.flush()
    return entry
