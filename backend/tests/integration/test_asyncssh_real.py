"""Integration tests exercising :class:`AsyncSshClient` against a real SSH server.

The server is spun up via testcontainers. Tests are skipped automatically if
Docker is not reachable so ``uv run pytest`` still works on machines without
a Docker daemon.
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
from collections.abc import Iterator
from pathlib import Path

import pytest

testcontainers = pytest.importorskip("testcontainers.core.container")

from testcontainers.core.container import DockerContainer  # noqa: E402
from testcontainers.core.waiting_utils import wait_for_logs  # noqa: E402

from ssm.core.errors import SshReadOnly  # noqa: E402
from ssm.ssh.asyncssh_client import AsyncSshClient  # noqa: E402
from ssm.ssh.protocol import SshTarget  # noqa: E402
from ssm.ssh.safety import ensure_writable  # noqa: E402


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    try:
        subprocess.run(
            ["docker", "info"],
            check=True,
            capture_output=True,
            timeout=5,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError):
        return False
    return True


pytestmark = pytest.mark.skipif(not _docker_available(), reason="docker daemon not available")


SSH_IMAGE = "linuxserver/openssh-server:latest"


def _generate_keypair(dir_path: Path) -> tuple[Path, str]:
    priv = dir_path / "id_ed25519"
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(priv), "-q"],
        check=True,
    )
    pub = priv.with_suffix(".pub")
    return priv, pub.read_text().strip()


@pytest.fixture(scope="module")
def ssh_server(tmp_path_factory: pytest.TempPathFactory) -> Iterator[tuple[str, int, Path]]:
    key_dir = tmp_path_factory.mktemp("sshkeys")
    priv, pubkey = _generate_keypair(key_dir)

    container = (
        DockerContainer(SSH_IMAGE)
        .with_env("PUID", "1000")
        .with_env("PGID", "1000")
        .with_env("TZ", "UTC")
        .with_env("SUDO_ACCESS", "false")
        .with_env("PASSWORD_ACCESS", "false")
        .with_env("USER_NAME", "ssmuser")
        .with_env("PUBLIC_KEY", pubkey)
        .with_exposed_ports(2222)
    )

    container.start()
    try:
        wait_for_logs(container, r"\[ls\.io-init\] done\.", timeout=120)
    except Exception:
        container.stop()
        raise

    host = container.get_container_host_ip()
    port = int(container.get_exposed_port(2222))
    yield host, port, priv
    container.stop()


async def _await_ready(client: AsyncSshClient, target: SshTarget) -> None:
    """Retry connect for a few seconds — the server may still be warming up."""
    last_exc: BaseException | None = None
    for _ in range(30):
        try:
            await client.connect(target)
        except Exception as exc:
            last_exc = exc
            await asyncio.sleep(1)
        else:
            return
    if last_exc is not None:
        raise last_exc


async def test_connect_exec_read_write_real_ssh(
    ssh_server: tuple[str, int, Path],
) -> None:
    host, port, priv = ssh_server
    client = AsyncSshClient(private_key_file=priv, timeout_seconds=30)
    target = SshTarget(
        host_id=1,
        name="ssm-it",
        address=host,
        port=port,
        username="ssmuser",
    )

    try:
        await _await_ready(client, target)

        result = await client.exec(target, "echo hello-$(id -un)")
        assert result.ok is True
        assert "hello-ssmuser" in result.stdout

        await client.write_file(target, "it-file.txt", "content-from-test\n")
        got = await client.read_file(target, "it-file.txt")
        assert got.content == "content-from-test\n"
    finally:
        await client.close()


async def test_readonly_sentinel_blocks_writes(
    ssh_server: tuple[str, int, Path],
) -> None:
    host, port, priv = ssh_server
    client = AsyncSshClient(private_key_file=priv, timeout_seconds=30)
    target = SshTarget(
        host_id=1,
        name="ssm-it",
        address=host,
        port=port,
        username="ssmuser",
    )

    try:
        await _await_ready(client, target)

        # Drop a non-empty system_readonly sentinel in the SSH user's ~/.ssh/.
        await client.exec(target, "mkdir -p $HOME/.ssh")
        await client.write_file(target, ".ssh/system_readonly", "maintenance window\n")

        with pytest.raises(SshReadOnly) as exc_info:
            await ensure_writable(client, target, "ssmuser")
        assert "maintenance" in str(exc_info.value)

        # Cleanup so the file doesn't leak into the other test if ordering changes.
        await client.exec(target, "rm -f $HOME/.ssh/system_readonly")
    finally:
        await client.close()
