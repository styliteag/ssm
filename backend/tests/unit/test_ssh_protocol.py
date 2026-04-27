"""Tests for ssm.ssh.protocol — shape of data classes + structural match."""

from __future__ import annotations

import pytest

from ssm.ssh.protocol import SshClient, SshFile, SshResult, SshTarget


class _MinimalClient:
    async def connect(self, target: SshTarget) -> None:
        del target

    async def exec(self, target: SshTarget, command: str) -> SshResult:
        del target, command
        return SshResult(stdout="", stderr="", exit_code=0)

    async def read_file(self, target: SshTarget, path: str) -> SshFile:
        del target, path
        return SshFile(content="")

    async def write_file(self, target: SshTarget, path: str, content: str) -> None:
        del target, path, content

    async def close(self) -> None:
        pass


def test_target_is_frozen() -> None:
    t = SshTarget(host_id=1, name="a", address="1.1.1.1", port=22, username="root")
    with pytest.raises((AttributeError, TypeError)):
        t.port = 2222  # type: ignore[misc]


def test_target_supports_jumphost() -> None:
    bastion = SshTarget(host_id=1, name="b", address="1.1.1.1", port=22, username="root")
    inner = SshTarget(
        host_id=2,
        name="i",
        address="10.0.0.2",
        port=22,
        username="root",
        jump_target=bastion,
    )
    assert inner.jump_target is bastion
    assert inner.jump_target.host_id == 1


def test_ssh_result_ok_true_on_zero() -> None:
    assert SshResult(stdout="", stderr="", exit_code=0).ok is True


def test_ssh_result_ok_false_on_nonzero() -> None:
    assert SshResult(stdout="", stderr="boom", exit_code=1).ok is False


def test_ssh_file_defaults() -> None:
    f = SshFile(content="hello")
    assert f.content == "hello"
    assert f.mtime is None
    assert f.metadata == {}


def test_minimal_client_is_ssh_client() -> None:
    assert isinstance(_MinimalClient(), SshClient)


def test_non_conforming_class_is_not_ssh_client() -> None:
    class Half:
        async def connect(self, target: SshTarget) -> None:
            del target

    # Missing exec/read_file/write_file/close — should not satisfy the Protocol.
    assert not isinstance(Half(), SshClient)
