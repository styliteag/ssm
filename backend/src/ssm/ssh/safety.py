"""Enforce host-level safety guards before any SSH write.

Two layers:

1. ``host.disabled`` flag from the database — checked before we even open a
   connection (see :func:`ensure_host_not_disabled`). Disabled hosts are a
   pure-Python signal; we never phone home to find this out.

2. Readonly sentinels on the remote host — ``~/.ssh/system_readonly`` (global
   for the SSH user) and the login user's ``~/.ssh/user_readonly`` (per-login).
   Non-empty contents of either file freeze writes and the contents become the
   reason surfaced to the UI.
"""

from __future__ import annotations

import shlex

from ssm.core.errors import HostDisabled, SshReadOnly
from ssm.ssh.protocol import SshClient, SshTarget

_READONLY_SCRIPT = r"""
set -u
system="$HOME/.ssh/system_readonly"
if [ -s "$system" ]; then
    printf 'system_readonly: %s\n' "$(cat "$system")"
    exit 0
fi
home_dir="$(getent passwd "$1" | cut -d: -f6)"
if [ -n "$home_dir" ]; then
    user_file="$home_dir/.ssh/user_readonly"
    if [ -s "$user_file" ]; then
        printf 'user_readonly: %s\n' "$(cat "$user_file")"
        exit 0
    fi
fi
"""


def ensure_host_not_disabled(*, disabled: bool, host_name: str) -> None:
    """Raise :class:`HostDisabled` when ``disabled`` is ``True``."""
    if disabled:
        raise HostDisabled(f"host {host_name!r} is disabled")


async def check_readonly(client: SshClient, target: SshTarget, login: str) -> str | None:
    """Return the readonly reason for ``login`` on ``target``, or ``None``."""
    command = f"sh -c {shlex.quote(_READONLY_SCRIPT)} sh {shlex.quote(login)}"
    result = await client.exec(target, command)
    reason = result.stdout.strip()
    return reason or None


async def ensure_writable(client: SshClient, target: SshTarget, login: str) -> None:
    """Raise :class:`SshReadOnly` if either readonly sentinel is set."""
    reason = await check_readonly(client, target, login)
    if reason is not None:
        raise SshReadOnly(f"host {target.name!r} is read-only for {login!r}: {reason}")
