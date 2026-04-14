"""Drive ``script.sh`` on the remote host for every authorized_keys op.

The script is the Rust backend's shell probe (bundled here verbatim). It does
three things we cannot express in plain SFTP:

1. **Home-directory lookup** — via ``getent passwd`` with an ``/etc/passwd``
   fallback — so logins on BSD / TrueNAS / pfSense / anything non-Linux still
   find their ``~/.ssh/authorized_keys``.
2. **Readonly probe + vendor fingerprints** — ``system_readonly``,
   ``user_readonly``, pfSense, TrueNAS Core/Scale, Sophos UTM.
3. **``has_pragma`` detection** — tells the UI whether a file was last written
   by ssm vs. edited by hand.

All writes to ``authorized_keys`` MUST go through
:meth:`ScriptRunner.set_authorized_keyfile` — never ``write_file`` directly —
so the script can back up handwritten files and enforce the readonly flag.
"""

from __future__ import annotations

import hashlib
import json
import shlex
from dataclasses import dataclass
from importlib import resources
from typing import Any

from ssm.core.errors import SshConnectFailed, SshReadOnly
from ssm.ssh.protocol import SshClient, SshTarget

REMOTE_SCRIPT_PATH = ".ssm/script.sh"
_SCRIPT_PACKAGE = "ssm.ssh"
_SCRIPT_RESOURCE = "script.sh"


@dataclass(frozen=True, slots=True)
class LoginKeyfile:
    login: str
    has_pragma: bool
    readonly_condition: str | None
    keyfile: str


def _local_script_source() -> str:
    return resources.files(_SCRIPT_PACKAGE).joinpath(_SCRIPT_RESOURCE).read_text(encoding="utf-8")


def _local_script_sha256() -> str:
    return hashlib.sha256(_local_script_source().encode("utf-8")).hexdigest()


def _parse_keyfile_entry(raw: dict[str, Any]) -> LoginKeyfile:
    reason = raw.get("readonly_condition") or None
    return LoginKeyfile(
        login=str(raw["login"]),
        has_pragma=bool(raw["has_pragma"]),
        readonly_condition=reason if reason else None,
        # The shell script encodes "\n" as a literal two-char escape.
        keyfile=str(raw.get("keyfile", "")).replace("\\n", "\n"),
    )


class ScriptRunner:
    """High-level ops that delegate to the remote ``script.sh``."""

    def __init__(self, client: SshClient, *, remote_path: str = REMOTE_SCRIPT_PATH) -> None:
        self._client = client
        self._remote_path = remote_path

    async def ensure_uploaded(self, target: SshTarget) -> None:
        """Upload / refresh the script if the remote copy is missing or stale."""
        expected_sha = _local_script_sha256()
        probe = await self._client.exec(
            target,
            f"sh {shlex.quote(self._remote_path)} version 2>/dev/null || true",
        )
        if probe.stdout.strip():
            try:
                payload = json.loads(probe.stdout)
                if payload.get("sha256") == expected_sha:
                    return
            except json.JSONDecodeError:
                pass

        # Upload via a shell heredoc-free approach: stdin → cat → destination.
        await self._client.exec(
            target,
            (
                f"mkdir -p {shlex.quote(self._remote_path.rsplit('/', 1)[0])} "
                f"&& cat > {shlex.quote(self._remote_path)} "
                f"&& chmod 0700 {shlex.quote(self._remote_path)}"
            ),
            input=_local_script_source(),
        )

    async def get_ssh_keyfiles(self, target: SshTarget) -> list[LoginKeyfile]:
        """Return one :class:`LoginKeyfile` per login that has authorized_keys."""
        await self.ensure_uploaded(target)
        result = await self._client.exec(
            target, f"sh {shlex.quote(self._remote_path)} get_ssh_keyfiles"
        )
        if result.exit_code != 0:
            raise SshConnectFailed(
                f"script.sh get_ssh_keyfiles failed on {target.name}: {result.stderr.strip()}"
            )
        text = result.stdout.strip()
        if not text:
            return []
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise SshConnectFailed(f"script.sh returned non-JSON on {target.name}: {exc}") from exc
        if not isinstance(payload, list):
            raise SshConnectFailed(f"script.sh returned non-list on {target.name}")
        return [_parse_keyfile_entry(entry) for entry in payload]

    async def set_authorized_keyfile(self, target: SshTarget, *, login: str, content: str) -> None:
        """Replace ``login``'s ``authorized_keys`` with ``content``.

        Respects the readonly sentinel honored by the script itself; raises
        :class:`SshReadOnly` when the script refuses to overwrite.
        """
        await self.ensure_uploaded(target)
        command = f"sh {shlex.quote(self._remote_path)} set_authorized_keyfile {shlex.quote(login)}"
        result = await self._client.exec(target, command, input=content)
        if result.exit_code == 0:
            return
        stderr = result.stderr.strip() or result.stdout.strip()
        if "readonly" in stderr.lower():
            raise SshReadOnly(f"host {target.name!r} refused write for {login!r}: {stderr}")
        raise SshConnectFailed(
            f"script.sh set_authorized_keyfile failed on {target.name}: {stderr}"
        )

    async def version(self, target: SshTarget) -> dict[str, str]:
        """Return the remote script's ``{version, sha256}`` self-report."""
        result = await self._client.exec(target, f"sh {shlex.quote(self._remote_path)} version")
        if result.exit_code != 0:
            raise SshConnectFailed(
                f"script.sh version failed on {target.name}: {result.stderr.strip()}"
            )
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise SshConnectFailed(f"script.sh version non-JSON on {target.name}: {exc}") from exc
        return {str(k): str(v) for k, v in payload.items()}
