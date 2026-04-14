"""Structural interface for SSH clients.

The rest of the app talks to an :class:`SshClient` — the concrete
implementations are :class:`AsyncSshClient` (production), :class:`MockSshClient`
(tests), and :class:`CachingSshClient` (wrapper that memoises reads and
reuses connections). Keeping the Protocol minimal makes swapping implementations
safe and keeps the router layer free of AsyncSSH-specific types.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable


@dataclass(frozen=True, slots=True)
class SshTarget:
    """Everything needed to open one SSH session."""

    host_id: int
    name: str
    address: str
    port: int
    username: str
    jump_target: SshTarget | None = None


@dataclass(frozen=True, slots=True)
class SshResult:
    """Outcome of a remote command."""

    stdout: str
    stderr: str
    exit_code: int = 0

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


@dataclass(frozen=True, slots=True)
class SshFile:
    """Contents of a remote file, with a best-effort mtime for cache keys."""

    content: str
    mtime: int | None = None
    metadata: dict[str, str] = field(default_factory=dict)


@runtime_checkable
class SshClient(Protocol):
    """Minimal async SSH surface used by the rest of the app."""

    async def connect(self, target: SshTarget) -> None:
        """Ensure a connection to ``target`` exists; idempotent."""
        ...

    async def exec(self, target: SshTarget, command: str) -> SshResult:
        """Run ``command`` on ``target`` and return its result."""
        ...

    async def read_file(self, target: SshTarget, path: str) -> SshFile:
        """Read a UTF-8 text file from ``target``."""
        ...

    async def write_file(self, target: SshTarget, path: str, content: str) -> None:
        """Atomically write ``content`` to ``path`` on ``target``."""
        ...

    async def close(self) -> None:
        """Close every open connection this client owns."""
        ...
