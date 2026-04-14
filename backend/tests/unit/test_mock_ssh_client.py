"""Tests for ssm.ssh.mock — scriptable SSH client behavior."""

from __future__ import annotations

import pytest

from ssm.core.errors import SshConnectFailed
from ssm.ssh.mock import MockSshClient
from ssm.ssh.protocol import SshClient, SshResult, SshTarget


def _target(host_id: int = 1) -> SshTarget:
    return SshTarget(host_id=host_id, name=f"h{host_id}", address="x", port=22, username="root")


def test_mock_implements_ssh_client_protocol() -> None:
    assert isinstance(MockSshClient(), SshClient)


async def test_connect_tracks_host_ids() -> None:
    mock = MockSshClient()
    await mock.connect(_target(1))
    await mock.connect(_target(2))
    assert mock.connect_calls == [1, 2]


async def test_exec_returns_scripted_response() -> None:
    mock = MockSshClient()
    mock.set_exec(
        host_id=1, command="uname", result=SshResult(stdout="Linux", stderr="", exit_code=0)
    )

    result = await mock.exec(_target(1), "uname")

    assert result.stdout == "Linux"
    assert result.ok is True
    assert mock.exec_calls == [(1, "uname")]


async def test_exec_uses_default_when_unscripted() -> None:
    mock = MockSshClient(default_exec=SshResult(stdout="x", stderr="", exit_code=0))
    result = await mock.exec(_target(1), "whatever")
    assert result.stdout == "x"


async def test_read_file_returns_scripted_content() -> None:
    mock = MockSshClient()
    mock.set_file(host_id=1, path=".ssh/authorized_keys", content="key-1\n", mtime=1700000000)

    got = await mock.read_file(_target(1), ".ssh/authorized_keys")

    assert got.content == "key-1\n"
    assert got.mtime == 1700000000


async def test_read_file_raises_if_unscripted_and_no_handler() -> None:
    mock = MockSshClient()
    with pytest.raises(SshConnectFailed):
        await mock.read_file(_target(1), "nope")


async def test_read_file_missing_handler_fills_in() -> None:
    mock = MockSshClient()
    mock.on_read_missing = lambda hid, path: __import__(
        "ssm.ssh.protocol", fromlist=["SshFile"]
    ).SshFile(content=f"{hid}:{path}")

    got = await mock.read_file(_target(2), "x")
    assert got.content == "2:x"


async def test_write_file_persists_for_subsequent_read() -> None:
    mock = MockSshClient()
    await mock.write_file(_target(1), ".ssh/authorized_keys", "new-key\n")

    got = await mock.read_file(_target(1), ".ssh/authorized_keys")
    assert got.content == "new-key\n"
    assert mock.write_calls == [(1, ".ssh/authorized_keys", "new-key\n")]


async def test_connect_failure_propagates() -> None:
    mock = MockSshClient()
    mock.fail_connect(3)
    with pytest.raises(SshConnectFailed):
        await mock.connect(_target(3))


async def test_close_sets_closed_flag() -> None:
    mock = MockSshClient()
    await mock.close()
    assert mock.closed is True
