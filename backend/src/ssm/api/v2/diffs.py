"""``/api/v2/diffs/{host_id}`` — compare the host's authorized_keys to the DB.

For each distinct ``login`` authorized on the host we:
  1. Build the set of key lines the DB says should be present for that login.
  2. Read ``/home/<login>/.ssh/authorized_keys`` over SSH.
  3. Return one :class:`KeyDiff` per expected-or-observed line, tagged as
     ``present``, ``missing_on_host``, or ``extra_on_host``.

Disabled hosts short-circuit with ``HOST_DISABLED`` before any SSH happens.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Annotated

from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse
from ssm.core.errors import HostNotFound, SshConnectFailed
from ssm.db.deps import db_session
from ssm.db.models import Authorization, Host, UserKey
from ssm.ssh.deps import get_ssh_client
from ssm.ssh.protocol import SshClient, SshTarget
from ssm.ssh.safety import ensure_host_not_disabled, ensure_writable

router = protected_router(prefix="/diffs", tags=["diffs"])


class DiffStatus(StrEnum):
    PRESENT = "present"
    MISSING_ON_HOST = "missing_on_host"
    EXTRA_ON_HOST = "extra_on_host"


class KeyDiff(BaseModel):
    status: DiffStatus
    line: str


class LoginDiff(BaseModel):
    login: str
    read_error: str | None = None
    items: list[KeyDiff]


class HostDiff(BaseModel):
    host_id: int
    host_name: str
    disabled: bool
    logins: list[LoginDiff]


def _format_key_line(key_type: str, key_base64: str, label: str | None) -> str:
    if label:
        return f"{key_type} {key_base64} {label}"
    return f"{key_type} {key_base64}"


def _parse_authorized_keys(text: str) -> list[str]:
    """Strip comments and blank lines; preserve the remaining verbatim."""
    lines: list[str] = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        lines.append(stripped)
    return lines


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


async def _expected_keys_for_login(
    session: AsyncSession, host_id: int, login: str
) -> tuple[list[int], list[str]]:
    """Return (user_ids authorized as ``login``, expected key lines)."""
    stmt = select(Authorization.user_id).where(
        Authorization.host_id == host_id, Authorization.login == login
    )
    user_ids = list((await session.execute(stmt)).scalars().all())
    if not user_ids:
        return [], []

    keys_stmt = select(UserKey).where(UserKey.user_id.in_(user_ids))
    rows = (await session.execute(keys_stmt)).scalars().all()
    lines = [_format_key_line(k.key_type, k.key_base64, k.name) for k in rows]
    return user_ids, lines


async def _diff_for_login(
    client: SshClient, target: SshTarget, login: str, expected: list[str]
) -> LoginDiff:
    expected_set = set(expected)
    actual_set: set[str] = set()
    read_error: str | None = None

    path = f"/home/{login}/.ssh/authorized_keys"
    try:
        file = await client.read_file(target, path)
        actual_set = set(_parse_authorized_keys(file.content))
    except SshConnectFailed as exc:
        read_error = str(exc)

    items: list[KeyDiff] = []
    for line in sorted(expected_set & actual_set):
        items.append(KeyDiff(status=DiffStatus.PRESENT, line=line))
    for line in sorted(expected_set - actual_set):
        items.append(KeyDiff(status=DiffStatus.MISSING_ON_HOST, line=line))
    for line in sorted(actual_set - expected_set):
        items.append(KeyDiff(status=DiffStatus.EXTRA_ON_HOST, line=line))
    return LoginDiff(login=login, read_error=read_error, items=items)


@router.get("/{host_id}", response_model=ApiResponse[HostDiff])
async def get_host_diff(
    host_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
    ssh: Annotated[SshClient, Depends(get_ssh_client)],
) -> ApiResponse[HostDiff]:
    host = await session.get(Host, host_id)
    if host is None:
        raise HostNotFound(f"host {host_id} not found")
    ensure_host_not_disabled(disabled=host.disabled, host_name=host.name)

    target = await _build_target(session, host)

    logins_stmt = (
        select(Authorization.login)
        .where(Authorization.host_id == host_id)
        .distinct()
        .order_by(Authorization.login)
    )
    logins = list((await session.execute(logins_stmt)).scalars().all())

    login_diffs: list[LoginDiff] = []
    for login in logins:
        _, expected = await _expected_keys_for_login(session, host_id, login)
        login_diffs.append(await _diff_for_login(ssh, target, login, expected))

    return ApiResponse[HostDiff].ok(
        HostDiff(host_id=host.id, host_name=host.name, disabled=host.disabled, logins=login_diffs)
    )


class SyncedLogin(BaseModel):
    login: str
    written_keys: int


class SyncResult(BaseModel):
    host_id: int
    host_name: str
    logins: list[SyncedLogin]


@router.post("/{host_id}/sync", response_model=ApiResponse[SyncResult])
async def sync_host(
    host_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
    ssh: Annotated[SshClient, Depends(get_ssh_client)],
) -> ApiResponse[SyncResult]:
    host = await session.get(Host, host_id)
    if host is None:
        raise HostNotFound(f"host {host_id} not found")
    ensure_host_not_disabled(disabled=host.disabled, host_name=host.name)

    target = await _build_target(session, host)

    logins_stmt = (
        select(Authorization.login)
        .where(Authorization.host_id == host_id)
        .distinct()
        .order_by(Authorization.login)
    )
    logins = list((await session.execute(logins_stmt)).scalars().all())

    # Fail loudly and early on any readonly login so we never partial-write.
    for login in logins:
        await ensure_writable(ssh, target, login)

    synced: list[SyncedLogin] = []
    for login in logins:
        _, expected = await _expected_keys_for_login(session, host_id, login)
        content = "".join(f"{line}\n" for line in expected)
        path = f"/home/{login}/.ssh/authorized_keys"
        await ssh.write_file(target, path, content)
        synced.append(SyncedLogin(login=login, written_keys=len(expected)))

    return ApiResponse[SyncResult].ok(
        SyncResult(host_id=host.id, host_name=host.name, logins=synced)
    )
