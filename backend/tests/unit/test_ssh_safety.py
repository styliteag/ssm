"""Tests for ssm.ssh.safety — host.disabled guard + readonly sentinel checks."""

from __future__ import annotations

import pytest

from ssm.core.errors import HostDisabled, SshReadOnly
from ssm.ssh.mock import MockSshClient
from ssm.ssh.protocol import SshResult, SshTarget
from ssm.ssh.safety import check_readonly, ensure_host_not_disabled, ensure_writable


def _target() -> SshTarget:
    return SshTarget(host_id=1, name="web1", address="10.0.0.1", port=22, username="root")


def test_ensure_host_not_disabled_passes_when_enabled() -> None:
    ensure_host_not_disabled(disabled=False, host_name="web1")


def test_ensure_host_not_disabled_raises_when_disabled() -> None:
    with pytest.raises(HostDisabled) as exc_info:
        ensure_host_not_disabled(disabled=True, host_name="web1")
    assert "web1" in str(exc_info.value)


async def test_check_readonly_returns_none_when_no_sentinels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    del monkeypatch
    mock = MockSshClient(default_exec=SshResult(stdout="", stderr="", exit_code=0))
    assert await check_readonly(mock, _target(), "alice") is None


async def test_check_readonly_returns_system_reason() -> None:
    mock = MockSshClient(
        default_exec=SshResult(
            stdout="system_readonly: maintenance window\n", stderr="", exit_code=0
        )
    )
    got = await check_readonly(mock, _target(), "alice")
    assert got == "system_readonly: maintenance window"


async def test_check_readonly_returns_user_reason() -> None:
    mock = MockSshClient(
        default_exec=SshResult(stdout="user_readonly: frozen by ops\n", stderr="", exit_code=0)
    )
    got = await check_readonly(mock, _target(), "alice")
    assert got == "user_readonly: frozen by ops"


async def test_ensure_writable_raises_when_readonly() -> None:
    mock = MockSshClient(
        default_exec=SshResult(stdout="system_readonly: no writes today\n", stderr="", exit_code=0)
    )
    with pytest.raises(SshReadOnly) as exc_info:
        await ensure_writable(mock, _target(), "alice")
    assert "web1" in str(exc_info.value)
    assert "alice" in str(exc_info.value)


async def test_ensure_writable_passes_when_empty() -> None:
    mock = MockSshClient(default_exec=SshResult(stdout="\n", stderr="", exit_code=0))
    await ensure_writable(mock, _target(), "alice")


async def test_readonly_check_runs_exec_on_target() -> None:
    mock = MockSshClient(default_exec=SshResult(stdout="", stderr="", exit_code=0))
    await check_readonly(mock, _target(), "alice")

    # One exec call issued against host 1; command contains "alice" as login arg.
    assert len(mock.exec_calls) == 1
    host_id, cmd = mock.exec_calls[0]
    assert host_id == 1
    assert "alice" in cmd
    assert "system_readonly" in cmd
    assert "user_readonly" in cmd
