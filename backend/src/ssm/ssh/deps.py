"""FastAPI dependency for the live :class:`SshClient`."""

from __future__ import annotations

from fastapi import Request

from ssm.ssh.protocol import SshClient


def get_ssh_client(request: Request) -> SshClient:
    client = getattr(request.app.state, "ssh_client", None)
    if client is None:
        msg = "ssh_client not configured on app.state"
        raise RuntimeError(msg)
    return client  # type: ignore[no-any-return]
