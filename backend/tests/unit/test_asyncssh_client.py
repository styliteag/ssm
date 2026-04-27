"""Tests for ssm.ssh.asyncssh_client — connection pooling + jump-host wiring.

These tests never touch a real SSH server. ``asyncssh.connect`` is monkeypatched
with a fake that records the arguments it was called with so we can assert
connection pooling and jump-host chaining behaviour.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from typing import Any

import asyncssh
import pytest

from ssm.core.errors import SshConnectFailed
from ssm.ssh.asyncssh_client import AsyncSshClient
from ssm.ssh.protocol import SshTarget


class FakeSftpFile:
    def __init__(self, read_content: bytes = b"") -> None:
        self.written: list[str] = []
        self._read_content = read_content

    async def __aenter__(self) -> FakeSftpFile:
        return self

    async def __aexit__(self, *_: object) -> None: ...

    async def write(self, data: str) -> None:
        self.written.append(data)

    async def read(self) -> bytes:
        return self._read_content


class FakeSftp:
    def __init__(self, files: dict[str, bytes]) -> None:
        self.files = files
        self.write_handle = FakeSftpFile()

    async def __aenter__(self) -> FakeSftp:
        return self

    async def __aexit__(self, *_: object) -> None: ...

    async def stat(self, _remote: str) -> SimpleNamespace:
        return SimpleNamespace(mtime=1700000000)

    def open(self, path: str, mode: str) -> FakeSftpFile:
        if mode == "r":
            return FakeSftpFile(read_content=self.files.get(path, b""))
        return self.write_handle


class FakeConnection:
    def __init__(self, name: str, registry: ConnectionRegistry) -> None:
        self.name = name
        self._closed = False
        self._registry = registry

    def is_closed(self) -> bool:
        return self._closed

    def close(self) -> None:
        self._closed = True

    async def wait_closed(self) -> None:
        return

    async def run(
        self,
        cmd: str,
        *,
        check: bool,
        timeout: int,  # noqa: ASYNC109 — mirror asyncssh.run signature
    ) -> SimpleNamespace:
        del check, timeout
        self._registry.commands.append((self.name, cmd))
        return SimpleNamespace(stdout="hi\n", stderr="", exit_status=0)

    def start_sftp_client(self) -> FakeSftp:
        return self._registry.sftp_for(self.name)


class ConnectionRegistry:
    """Tracks every fake ``connect`` call so assertions can inspect them."""

    def __init__(self) -> None:
        self.connects: list[dict[str, Any]] = []
        self.commands: list[tuple[str, str]] = []
        self._files: dict[str, dict[str, bytes]] = {}
        self._sftps: dict[str, FakeSftp] = {}

    def seed_file(self, host_name: str, path: str, content: bytes) -> None:
        self._files.setdefault(host_name, {})[path] = content

    def sftp_for(self, host_name: str) -> FakeSftp:
        if host_name not in self._sftps:
            self._sftps[host_name] = FakeSftp(self._files.get(host_name, {}))
        return self._sftps[host_name]

    async def connect(self, **kwargs: Any) -> FakeConnection:
        self.connects.append(kwargs)
        return FakeConnection(kwargs["host"], self)


@pytest.fixture
def registry(monkeypatch: pytest.MonkeyPatch) -> ConnectionRegistry:
    reg = ConnectionRegistry()
    monkeypatch.setattr(asyncssh, "connect", reg.connect)
    return reg


def _target(host_id: int, name: str, address: str, jump: SshTarget | None = None) -> SshTarget:
    return SshTarget(
        host_id=host_id,
        name=name,
        address=address,
        port=22,
        username="root",
        jump_target=jump,
    )


def _client(tmp_path: Path) -> AsyncSshClient:
    key = tmp_path / "id_ssm"
    key.write_text("dummy")
    return AsyncSshClient(private_key_file=key, timeout_seconds=5)


async def test_connect_opens_connection_to_address(
    tmp_path: Path, registry: ConnectionRegistry
) -> None:
    client = _client(tmp_path)
    await client.connect(_target(1, "a", "10.0.0.1"))

    assert len(registry.connects) == 1
    assert registry.connects[0]["host"] == "10.0.0.1"
    assert registry.connects[0]["port"] == 22
    assert registry.connects[0]["username"] == "root"


async def test_connection_is_reused_for_same_host(
    tmp_path: Path, registry: ConnectionRegistry
) -> None:
    client = _client(tmp_path)
    target = _target(1, "a", "10.0.0.1")
    await client.connect(target)
    await client.exec(target, "echo 1")
    await client.exec(target, "echo 2")

    assert len(registry.connects) == 1


async def test_jump_host_chains_tunnel(tmp_path: Path, registry: ConnectionRegistry) -> None:
    client = _client(tmp_path)
    bastion = _target(10, "b", "1.1.1.1")
    inner = _target(20, "inner", "10.0.0.2", jump=bastion)
    await client.connect(inner)

    assert len(registry.connects) == 2
    assert registry.connects[0]["host"] == "1.1.1.1"
    assert registry.connects[0].get("tunnel") is None
    assert registry.connects[1]["host"] == "10.0.0.2"
    assert registry.connects[1].get("tunnel") is not None


async def test_exec_returns_result(tmp_path: Path, registry: ConnectionRegistry) -> None:
    client = _client(tmp_path)
    result = await client.exec(_target(1, "a", "10.0.0.1"), "whoami")

    assert result.ok is True
    assert result.stdout == "hi\n"
    assert registry.commands == [("10.0.0.1", "whoami")]


async def test_read_file_decodes_utf8_and_returns_mtime(
    tmp_path: Path, registry: ConnectionRegistry
) -> None:
    registry.seed_file("10.0.0.1", ".ssh/authorized_keys", b"key-1\nkey-2\n")
    client = _client(tmp_path)

    got = await client.read_file(_target(1, "a", "10.0.0.1"), ".ssh/authorized_keys")

    assert got.content == "key-1\nkey-2\n"
    assert got.mtime == 1700000000


async def test_write_file_delegates_to_sftp(tmp_path: Path, registry: ConnectionRegistry) -> None:
    client = _client(tmp_path)
    target = _target(1, "a", "10.0.0.1")
    await client.write_file(target, ".ssh/authorized_keys", "key-only\n")

    sftp = registry.sftp_for("10.0.0.1")
    assert sftp.write_handle.written == ["key-only\n"]


async def test_connect_failure_raises_ssh_connect_failed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def _fail(**_kwargs: Any) -> None:
        raise OSError("tcp reset")

    monkeypatch.setattr(asyncssh, "connect", _fail)
    client = AsyncSshClient(private_key_file=tmp_path / "id", timeout_seconds=1)

    with pytest.raises(SshConnectFailed):
        await client.connect(_target(1, "a", "10.0.0.1"))


async def test_close_releases_all_connections(tmp_path: Path, registry: ConnectionRegistry) -> None:
    client = _client(tmp_path)
    await client.connect(_target(1, "a", "10.0.0.1"))
    await client.connect(_target(2, "b", "10.0.0.2"))

    await client.close()

    # A subsequent exec on the same host must re-open.
    await client.exec(_target(1, "a", "10.0.0.1"), "echo")
    assert len(registry.connects) == 3
