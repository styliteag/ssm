"""``/api/v2/activity-log`` — paginated read of the activity_log table."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Query
from pydantic import BaseModel, ConfigDict
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse, Meta
from ssm.db.deps import db_session
from ssm.db.models import ActivityLog

router = protected_router(prefix="/activity-log", tags=["activity-log"])


class ActivityLogEntry(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    activity_type: str
    action: str
    target: str
    user_id: int | None
    actor_username: str
    timestamp: int
    meta: str | None = None


@router.get("", response_model=ApiResponse[list[ActivityLogEntry]])
async def list_activity(
    session: Annotated[AsyncSession, Depends(db_session)],
    page: Annotated[int, Query(ge=1)] = 1,
    page_size: Annotated[int, Query(ge=1, le=200)] = 50,
    activity_type: Annotated[str | None, Query(max_length=32)] = None,
) -> ApiResponse[list[ActivityLogEntry]]:
    stmt = select(ActivityLog)
    count_stmt = select(func.count()).select_from(ActivityLog)
    if activity_type is not None:
        stmt = stmt.where(ActivityLog.activity_type == activity_type)
        count_stmt = count_stmt.where(ActivityLog.activity_type == activity_type)

    total = int((await session.execute(count_stmt)).scalar_one())

    stmt = (
        stmt.order_by(ActivityLog.timestamp.desc(), ActivityLog.id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    )
    rows = (await session.execute(stmt)).scalars().all()
    items = [ActivityLogEntry.model_validate(r) for r in rows]

    return ApiResponse[list[ActivityLogEntry]].ok(
        items, meta=Meta(total=total, page=page, page_size=page_size)
    )
