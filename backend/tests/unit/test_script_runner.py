"""Tests for ssm.ssh.script_runner — script probe + JSON parsing + readonly."""

from __future__ import annotations

import json

import pytest

from ssm.core.errors import SshConnectFailed, SshReadOnly
from ssm.ssh.mock import MockSshClient
from ssm.ssh.protocol import SshResult, SshTarget
from ssm.ssh.script_runner import (
    REMOTE_SCRIPT_PATH,
    ScriptRunner,
    _local_script_sha256,
)


def _target() -> SshTarget:
    return SshTarget(host_id=1, name="h", address="x", port=22, username="root")


def _matching_version_probe(mock: MockSshClient) -> None:
    sha = _local_script_sha256()
    mock.set_exec(
        host_id=1,
        command=f"sh {REMOTE_SCRIPT_PATH} version 2>/dev/null || true",
        result=SshResult(
            stdout=json.dumps({"version": "v0.3", "sha256": sha}), stderr="", exit_code=0
        ),
    )


def test_local_script_hash_is_stable() -> None:
    assert len(_local_script_sha256()) == 64


async def test_ensure_uploaded_skips_when_sha_matches() -> None:
    mock = MockSshClient()
    _matching_version_probe(mock)
    mock.default_exec = SshResult(stdout="", stderr="", exit_code=0)

    runner = ScriptRunner(mock)
    await runner.ensure_uploaded(_target())

    # No upload command issued — only the version probe.
    issued = [cmd for _, cmd, _ in mock.exec_inputs]
    assert all("version" in cmd for cmd in issued)


async def test_ensure_uploaded_uploads_when_missing() -> None:
    mock = MockSshClient(default_exec=SshResult(stdout="", stderr="", exit_code=0))
    runner = ScriptRunner(mock)
    await runner.ensure_uploaded(_target())

    upload_inputs = [
        stdin for _, cmd, stdin in mock.exec_inputs if "cat >" in cmd and stdin is not None
    ]
    assert upload_inputs, "script should be uploaded when version probe returns nothing"
    assert "authorized_keys_location" in upload_inputs[0]


async def test_get_ssh_keyfiles_parses_script_json() -> None:
    mock = MockSshClient()
    _matching_version_probe(mock)
    mock.set_exec(
        host_id=1,
        command=f"sh {REMOTE_SCRIPT_PATH} get_ssh_keyfiles",
        result=SshResult(
            stdout=json.dumps(
                [
                    {
                        "login": "deploy",
                        "has_pragma": True,
                        "readonly_condition": "",
                        "keyfile": "ssh-ed25519 AAAA deploy\\n",
                    },
                    {
                        "login": "root",
                        "has_pragma": False,
                        "readonly_condition": "Product is pfSense",
                        "keyfile": "# handwritten\\nssh-rsa ZZZ root\\n",
                    },
                ]
            ),
            stderr="",
            exit_code=0,
        ),
    )

    runner = ScriptRunner(mock)
    entries = await runner.get_ssh_keyfiles(_target())

    assert [e.login for e in entries] == ["deploy", "root"]
    assert entries[0].has_pragma is True
    assert entries[0].readonly_condition is None
    assert entries[0].keyfile == "ssh-ed25519 AAAA deploy\n"
    assert entries[1].has_pragma is False
    assert entries[1].readonly_condition == "Product is pfSense"


async def test_get_ssh_keyfiles_raises_on_nonzero_exit() -> None:
    mock = MockSshClient()
    _matching_version_probe(mock)
    mock.set_exec(
        host_id=1,
        command=f"sh {REMOTE_SCRIPT_PATH} get_ssh_keyfiles",
        result=SshResult(stdout="", stderr="boom", exit_code=1),
    )
    runner = ScriptRunner(mock)
    with pytest.raises(SshConnectFailed):
        await runner.get_ssh_keyfiles(_target())


async def test_set_authorized_keyfile_pipes_stdin() -> None:
    mock = MockSshClient()
    _matching_version_probe(mock)
    mock.set_exec(
        host_id=1,
        command=f"sh {REMOTE_SCRIPT_PATH} set_authorized_keyfile deploy",
        result=SshResult(stdout="", stderr="", exit_code=0),
    )
    runner = ScriptRunner(mock)

    await runner.set_authorized_keyfile(_target(), login="deploy", content="ssh-ed25519 A\n")

    stdin_values = [
        stdin for _, cmd, stdin in mock.exec_inputs if "set_authorized_keyfile deploy" in cmd
    ]
    assert stdin_values == ["ssh-ed25519 A\n"]


async def test_set_authorized_keyfile_readonly_raises_ssh_readonly() -> None:
    mock = MockSshClient()
    _matching_version_probe(mock)
    mock.set_exec(
        host_id=1,
        command=f"sh {REMOTE_SCRIPT_PATH} set_authorized_keyfile deploy",
        result=SshResult(stdout="Keyfile is readonly, aborting.\n", stderr="", exit_code=1),
    )
    runner = ScriptRunner(mock)

    with pytest.raises(SshReadOnly):
        await runner.set_authorized_keyfile(_target(), login="deploy", content="x\n")


async def test_set_authorized_keyfile_unexpected_error_raises_connect_failed() -> None:
    mock = MockSshClient()
    _matching_version_probe(mock)
    mock.set_exec(
        host_id=1,
        command=f"sh {REMOTE_SCRIPT_PATH} set_authorized_keyfile deploy",
        result=SshResult(stdout="", stderr="permission denied", exit_code=1),
    )
    runner = ScriptRunner(mock)

    with pytest.raises(SshConnectFailed):
        await runner.set_authorized_keyfile(_target(), login="deploy", content="x\n")


async def test_version_returns_sha256() -> None:
    mock = MockSshClient()
    _matching_version_probe(mock)
    mock.set_exec(
        host_id=1,
        command=f"sh {REMOTE_SCRIPT_PATH} version",
        result=SshResult(
            stdout=json.dumps({"version": "v0.3", "sha256": "abc"}), stderr="", exit_code=0
        ),
    )
    runner = ScriptRunner(mock)

    got = await runner.version(_target())
    assert got["sha256"] == "abc"
