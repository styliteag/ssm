"""``/api/v2/diffs/{host_id}`` — compare the host's authorized_keys to the DB.

Every read and write goes through :class:`~ssm.ssh.script_runner.ScriptRunner`
— never raw SFTP — so we get the shell script's home-dir probing,
``has_pragma`` detection, readonly-sentinel check, and managed-file backup
behaviour for free.

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
from ssm.ssh.safety import ensure_host_not_disabled
from ssm.ssh.script_runner import LoginKeyfile, ScriptRunner

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
    has_pragma: bool = False
    readonly_condition: str | None = None
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


async def _expected_keys_for_login(session: AsyncSession, host_id: int, login: str) -> list[str]:
    stmt = select(Authorization.user_id).where(
        Authorization.host_id == host_id, Authorization.login == login
    )
    user_ids = list((await session.execute(stmt)).scalars().all())
    if not user_ids:
        return []
    keys_stmt = select(UserKey).where(UserKey.user_id.in_(user_ids))
    rows = (await session.execute(keys_stmt)).scalars().all()
    return [_format_key_line(k.key_type, k.key_base64, k.name) for k in rows]


def _compute_diff(expected: list[str], actual: list[str]) -> list[KeyDiff]:
    exp_set, act_set = set(expected), set(actual)
    items: list[KeyDiff] = []
    for line in sorted(exp_set & act_set):
        items.append(KeyDiff(status=DiffStatus.PRESENT, line=line))
    for line in sorted(exp_set - act_set):
        items.append(KeyDiff(status=DiffStatus.MISSING_ON_HOST, line=line))
    for line in sorted(act_set - exp_set):
        items.append(KeyDiff(status=DiffStatus.EXTRA_ON_HOST, line=line))
    return items


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
    runner = ScriptRunner(ssh)

    # Collect every login the script sees on the host AND every login the DB
    # authorizes. A login present only on one side still needs a diff row.
    observed: dict[str, LoginKeyfile] = {}
    read_error: str | None = None
    try:
        for observed_entry in await runner.get_ssh_keyfiles(target):
            observed[observed_entry.login] = observed_entry
    except SshConnectFailed as exc:
        read_error = str(exc)

    logins_stmt = select(Authorization.login).where(Authorization.host_id == host_id).distinct()
    expected_logins = set((await session.execute(logins_stmt)).scalars().all())
    all_logins = sorted(expected_logins | set(observed))

    login_diffs: list[LoginDiff] = []
    for login in all_logins:
        expected = await _expected_keys_for_login(session, host_id, login)
        entry = observed.get(login)
        actual = _parse_authorized_keys(entry.keyfile) if entry is not None else []
        login_diffs.append(
            LoginDiff(
                login=login,
                has_pragma=bool(entry and entry.has_pragma),
                readonly_condition=entry.readonly_condition if entry else None,
                read_error=read_error if entry is None and read_error else None,
                items=_compute_diff(expected, actual),
            )
        )

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
    runner = ScriptRunner(ssh)

    logins_stmt = (
        select(Authorization.login)
        .where(Authorization.host_id == host_id)
        .distinct()
        .order_by(Authorization.login)
    )
    logins = list((await session.execute(logins_stmt)).scalars().all())

    synced: list[SyncedLogin] = []
    for login in logins:
        expected = await _expected_keys_for_login(session, host_id, login)
        content = "".join(f"{line}\n" for line in expected)
        # set_authorized_keyfile raises SshReadOnly if the sentinel is set, so
        # we bail out atomically on the first readonly login and never
        # partial-write the host.
        await runner.set_authorized_keyfile(target, login=login, content=content)
        synced.append(SyncedLogin(login=login, written_keys=len(expected)))

    return ApiResponse[SyncResult].ok(
        SyncResult(host_id=host.id, host_name=host.name, logins=synced)
    )
