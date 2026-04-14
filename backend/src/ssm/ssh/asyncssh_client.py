"""Production SSH client backed by AsyncSSH.

Holds one connection per ``host_id`` so repeated ``exec``/``read_file``/
``write_file`` calls reuse the same TCP/SSH session. Jump-host chains are
built on demand by recursing through ``SshTarget.jump_target``; each jump
host also has a connection cached so a chain with the same bastion
doesn't re-connect to the bastion on every leg.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Any

import asyncssh

from ssm.core.errors import SshConnectFailed
from ssm.ssh.protocol import SshClient, SshFile, SshResult, SshTarget

_log = logging.getLogger(__name__)


class AsyncSshClient(SshClient):
    """AsyncSSH-backed SSH client with per-host connection pooling."""

    def __init__(
        self,
        *,
        private_key_file: Path,
        private_key_passphrase: str | None = None,
        timeout_seconds: int = 120,
        known_hosts: Path | None = None,
    ) -> None:
        self._private_key_file = private_key_file
        self._private_key_passphrase = private_key_passphrase
        self._timeout_seconds = timeout_seconds
        self._known_hosts = known_hosts
        self._connections: dict[int, asyncssh.SSHClientConnection] = {}
        self._lock = asyncio.Lock()

    async def connect(self, target: SshTarget) -> None:
        await self._get_connection(target)

    async def exec(self, target: SshTarget, command: str) -> SshResult:
        conn = await self._get_connection(target)
        try:
            result = await conn.run(command, check=False, timeout=self._timeout_seconds)
        except (asyncssh.Error, OSError, TimeoutError) as exc:
            raise SshConnectFailed(f"ssh exec failed on {target.name}: {exc}") from exc
        exit_code = 0 if result.exit_status is None else int(result.exit_status)
        return SshResult(
            stdout=_as_text(result.stdout),
            stderr=_as_text(result.stderr),
            exit_code=exit_code,
        )

    async def read_file(self, target: SshTarget, path: str) -> SshFile:
        conn = await self._get_connection(target)
        try:
            async with conn.start_sftp_client() as sftp:
                async with sftp.open(path, "r") as fh:
                    raw = await fh.read()
                attrs = await sftp.stat(path)
        except (asyncssh.Error, OSError) as exc:
            raise SshConnectFailed(f"ssh read_file failed on {target.name}: {exc}") from exc
        content = raw if isinstance(raw, str) else raw.decode("utf-8", errors="replace")
        mtime_val = getattr(attrs, "mtime", None)
        mtime = int(mtime_val) if mtime_val is not None else None
        return SshFile(content=content, mtime=mtime)

    async def write_file(self, target: SshTarget, path: str, content: str) -> None:
        conn = await self._get_connection(target)
        try:
            async with (
                conn.start_sftp_client() as sftp,
                sftp.open(path, "w") as fh,
            ):
                await fh.write(content)
        except (asyncssh.Error, OSError) as exc:
            raise SshConnectFailed(f"ssh write_file failed on {target.name}: {exc}") from exc

    async def close(self) -> None:
        async with self._lock:
            conns = list(self._connections.values())
            self._connections.clear()
        for c in conns:
            c.close()
        for c in conns:
            await c.wait_closed()

    async def _get_connection(self, target: SshTarget) -> asyncssh.SSHClientConnection:
        async with self._lock:
            cached = self._connections.get(target.host_id)
            if cached is not None and not cached.is_closed():
                return cached

        tunnel: asyncssh.SSHClientConnection | None = None
        if target.jump_target is not None:
            tunnel = await self._get_connection(target.jump_target)

        opts: dict[str, Any] = {
            "host": target.address,
            "port": target.port,
            "username": target.username,
            "client_keys": [str(self._private_key_file)],
            "known_hosts": str(self._known_hosts) if self._known_hosts else None,
            "connect_timeout": self._timeout_seconds,
        }
        if self._private_key_passphrase is not None:
            opts["passphrase"] = self._private_key_passphrase
        if tunnel is not None:
            opts["tunnel"] = tunnel

        try:
            conn = await asyncssh.connect(**opts)
        except (asyncssh.Error, OSError, TimeoutError) as exc:
            raise SshConnectFailed(f"ssh connect failed for {target.name}: {exc}") from exc

        async with self._lock:
            self._connections[target.host_id] = conn
        return conn


def _as_text(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)
