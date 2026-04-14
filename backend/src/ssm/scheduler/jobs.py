"""Periodic scheduler jobs."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from sqlalchemy import select

from ssm.core.errors import SshConnectFailed
from ssm.db.models import Host
from ssm.ssh.protocol import SshTarget

if TYPE_CHECKING:
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

    from ssm.ssh.protocol import SshClient

_log = logging.getLogger(__name__)


@dataclass(slots=True)
class HostStatus:
    host_id: int
    name: str
    reachable: bool
    error: str | None = None


@dataclass(slots=True)
class PollResult:
    """Aggregate outcome of one poll_connection_status run."""

    checked: int = 0
    reachable: int = 0
    failed: int = 0
    skipped_disabled: int = 0
    statuses: list[HostStatus] = field(default_factory=list)


async def _build_target(session: AsyncSession, host: Host) -> SshTarget:
    jump: SshTarget | None = None
    if host.jump_via is not None:
        jump_host = await session.get(Host, host.jump_via)
        if jump_host is not None:
            jump = await _build_target(session, jump_host)
    return SshTarget(
        host_id=host.id,
        name=host.name,
        address=host.address,
        port=host.port,
        username=host.username,
        jump_target=jump,
    )


async def poll_connection_status(
    sessionmaker: async_sessionmaker[AsyncSession],
    ssh: SshClient,
) -> PollResult:
    """Open an SSH session to every non-disabled host and record reachability.

    The job does no writes; it only calls :meth:`SshClient.connect`. Disabled
    hosts are skipped entirely — they count toward ``skipped_disabled`` so
    operators can verify the guard is working.
    """
    result = PollResult()
    async with sessionmaker() as session:
        hosts = (await session.execute(select(Host).order_by(Host.id))).scalars().all()
        for host in hosts:
            if host.disabled:
                result.skipped_disabled += 1
                continue
            result.checked += 1
            try:
                target = await _build_target(session, host)
                await ssh.connect(target)
            except SshConnectFailed as exc:
                result.failed += 1
                result.statuses.append(
                    HostStatus(host_id=host.id, name=host.name, reachable=False, error=str(exc))
                )
                _log.warning("host %s unreachable: %s", host.name, exc)
            except Exception as exc:
                result.failed += 1
                result.statuses.append(
                    HostStatus(host_id=host.id, name=host.name, reachable=False, error=str(exc))
                )
                _log.exception("unexpected error probing host %s", host.name, exc_info=exc)
            else:
                result.reachable += 1
                result.statuses.append(HostStatus(host_id=host.id, name=host.name, reachable=True))
    return result
