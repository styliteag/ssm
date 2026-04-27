"""Tests for ssm.ssh.caching — memoised reads + write-through invalidation."""

from __future__ import annotations

from ssm.ssh.caching import CachingSshClient
from ssm.ssh.mock import MockSshClient
from ssm.ssh.protocol import SshClient, SshTarget


def _target(host_id: int = 1) -> SshTarget:
    return SshTarget(host_id=host_id, name=f"h{host_id}", address="x", port=22, username="root")


def _wrapped() -> tuple[CachingSshClient, MockSshClient]:
    inner = MockSshClient()
    return CachingSshClient(inner), inner


def test_caching_client_implements_protocol() -> None:
    assert isinstance(CachingSshClient(MockSshClient()), SshClient)


async def test_first_read_passes_through_to_inner() -> None:
    wrap, inner = _wrapped()
    inner.set_file(host_id=1, path=".ssh/authorized_keys", content="key\n")

    got = await wrap.read_file(_target(1), ".ssh/authorized_keys")

    assert got.content == "key\n"
    assert inner.read_calls == [(1, ".ssh/authorized_keys")]


async def test_second_read_returns_cached_without_calling_inner() -> None:
    wrap, inner = _wrapped()
    inner.set_file(host_id=1, path="p", content="v")

    await wrap.read_file(_target(1), "p")
    await wrap.read_file(_target(1), "p")
    await wrap.read_file(_target(1), "p")

    assert inner.read_calls == [(1, "p")]


async def test_cache_is_keyed_by_host_and_path() -> None:
    wrap, inner = _wrapped()
    inner.set_file(host_id=1, path="p", content="a")
    inner.set_file(host_id=2, path="p", content="b")
    inner.set_file(host_id=1, path="q", content="c")

    assert (await wrap.read_file(_target(1), "p")).content == "a"
    assert (await wrap.read_file(_target(2), "p")).content == "b"
    assert (await wrap.read_file(_target(1), "q")).content == "c"
    assert len(inner.read_calls) == 3

    # Re-read — all cached now.
    assert (await wrap.read_file(_target(1), "p")).content == "a"
    assert (await wrap.read_file(_target(2), "p")).content == "b"
    assert len(inner.read_calls) == 3


async def test_write_file_invalidates_that_path_only() -> None:
    wrap, inner = _wrapped()
    inner.set_file(host_id=1, path="p", content="old-p")
    inner.set_file(host_id=1, path="q", content="old-q")
    await wrap.read_file(_target(1), "p")
    await wrap.read_file(_target(1), "q")

    await wrap.write_file(_target(1), "p", "new-p")

    # Next read of p should hit inner again and pick up the new value.
    got_p = await wrap.read_file(_target(1), "p")
    assert got_p.content == "new-p"
    assert inner.read_calls == [(1, "p"), (1, "q"), (1, "p")]

    # q is still cached; no extra inner call.
    got_q = await wrap.read_file(_target(1), "q")
    assert got_q.content == "old-q"
    assert inner.read_calls == [(1, "p"), (1, "q"), (1, "p")]


async def test_exec_and_connect_pass_through() -> None:
    wrap, inner = _wrapped()
    await wrap.connect(_target(1))
    await wrap.exec(_target(1), "uname")

    assert inner.connect_calls == [1, 1]  # explicit connect + the one exec triggers
    assert inner.exec_calls == [(1, "uname")]


async def test_close_clears_cache_and_closes_inner() -> None:
    wrap, inner = _wrapped()
    inner.set_file(host_id=1, path="p", content="v")
    await wrap.read_file(_target(1), "p")

    await wrap.close()

    assert inner.closed is True
    # Re-seed and re-read: cache was cleared so inner gets called again.
    inner.set_file(host_id=1, path="p", content="v2")
    got = await wrap.read_file(_target(1), "p")
    assert got.content == "v2"


async def test_invalidate_specific_path() -> None:
    wrap, inner = _wrapped()
    inner.set_file(host_id=1, path="p", content="v1")
    await wrap.read_file(_target(1), "p")

    await wrap.invalidate(host_id=1, path="p")
    inner.set_file(host_id=1, path="p", content="v2")

    got = await wrap.read_file(_target(1), "p")
    assert got.content == "v2"


async def test_invalidate_whole_host() -> None:
    wrap, inner = _wrapped()
    inner.set_file(host_id=1, path="p", content="v")
    inner.set_file(host_id=1, path="q", content="v")
    inner.set_file(host_id=2, path="p", content="keep")
    await wrap.read_file(_target(1), "p")
    await wrap.read_file(_target(1), "q")
    await wrap.read_file(_target(2), "p")

    await wrap.invalidate(host_id=1)

    # Host 1 is cold again; host 2 still cached.
    inner.set_file(host_id=1, path="p", content="new")
    inner.set_file(host_id=1, path="q", content="new")
    inner.set_file(host_id=2, path="p", content="changed-but-cached")

    assert (await wrap.read_file(_target(1), "p")).content == "new"
    assert (await wrap.read_file(_target(1), "q")).content == "new"
    assert (await wrap.read_file(_target(2), "p")).content == "keep"
