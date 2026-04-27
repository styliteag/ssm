"""In-memory :class:`SshClient` for unit tests.

Usage::

    mock = MockSshClient()
    mock.set_file(host_id=1, path=".ssh/authorized_keys", content="key\\n")
    mock.set_exec(host_id=1, command="uname -a", result=SshResult(stdout="Linux", stderr=""))
    ...
    assert mock.exec_calls == [(1, "uname -a")]
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from ssm.core.errors import SshConnectFailed
from ssm.ssh.protocol import SshClient, SshFile, SshResult, SshTarget


@dataclass
class MockSshClient(SshClient):
    """Scriptable SSH client that never touches the network."""

    files: dict[tuple[int, str], SshFile] = field(default_factory=dict)
    exec_responses: dict[tuple[int, str], SshResult] = field(default_factory=dict)
    default_exec: SshResult | None = None
    connect_failures: set[int] = field(default_factory=set)

    connect_calls: list[int] = field(default_factory=list)
    exec_calls: list[tuple[int, str]] = field(default_factory=list)
    exec_inputs: list[tuple[int, str, str | None]] = field(default_factory=list)
    read_calls: list[tuple[int, str]] = field(default_factory=list)
    write_calls: list[tuple[int, str, str]] = field(default_factory=list)
    closed: bool = False

    on_read_missing: Callable[[int, str], SshFile] | None = None

    def set_file(self, *, host_id: int, path: str, content: str, mtime: int | None = None) -> None:
        self.files[(host_id, path)] = SshFile(content=content, mtime=mtime)

    def set_exec(self, *, host_id: int, command: str, result: SshResult) -> None:
        self.exec_responses[(host_id, command)] = result

    def fail_connect(self, host_id: int) -> None:
        self.connect_failures.add(host_id)

    async def connect(self, target: SshTarget) -> None:
        self.connect_calls.append(target.host_id)
        if target.host_id in self.connect_failures:
            raise SshConnectFailed(f"mock: connect failed for host {target.host_id}")

    async def exec(self, target: SshTarget, command: str, *, input: str | None = None) -> SshResult:
        await self.connect(target)
        self.exec_calls.append((target.host_id, command))
        self.exec_inputs.append((target.host_id, command, input))
        scripted = self.exec_responses.get((target.host_id, command))
        if scripted is not None:
            return scripted
        if self.default_exec is not None:
            return self.default_exec
        return SshResult(stdout="", stderr="", exit_code=0)

    async def read_file(self, target: SshTarget, path: str) -> SshFile:
        await self.connect(target)
        self.read_calls.append((target.host_id, path))
        file = self.files.get((target.host_id, path))
        if file is not None:
            return file
        if self.on_read_missing is not None:
            return self.on_read_missing(target.host_id, path)
        raise SshConnectFailed(f"mock: no file scripted for host={target.host_id} path={path!r}")

    async def write_file(self, target: SshTarget, path: str, content: str) -> None:
        await self.connect(target)
        self.write_calls.append((target.host_id, path, content))
        self.files[(target.host_id, path)] = SshFile(content=content)

    async def close(self) -> None:
        self.closed = True
