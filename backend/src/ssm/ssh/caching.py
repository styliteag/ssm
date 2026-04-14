"""Per-host file-read cache layered on top of an inner :class:`SshClient`.

Reading ``authorized_keys`` is the hot path; pooling connections (done by
``AsyncSshClient``) isn't enough to keep list endpoints cheap when the
frontend re-renders. This wrapper memoises the result of ``read_file`` per
``(host_id, path)`` and invalidates the entry whenever ``write_file`` writes
to the same path.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass

from ssm.ssh.protocol import SshClient, SshFile, SshResult, SshTarget


@dataclass(frozen=True, slots=True)
class _CacheKey:
    host_id: int
    path: str


class CachingSshClient(SshClient):
    """Wrap an inner client; cache file reads and invalidate them on writes."""

    def __init__(self, inner: SshClient) -> None:
        self._inner = inner
        self._cache: dict[_CacheKey, SshFile] = {}
        self._lock = asyncio.Lock()

    async def connect(self, target: SshTarget) -> None:
        await self._inner.connect(target)

    async def exec(self, target: SshTarget, command: str) -> SshResult:
        return await self._inner.exec(target, command)

    async def read_file(self, target: SshTarget, path: str) -> SshFile:
        key = _CacheKey(target.host_id, path)
        async with self._lock:
            cached = self._cache.get(key)
            if cached is not None:
                return cached
        value = await self._inner.read_file(target, path)
        async with self._lock:
            self._cache[key] = value
        return value

    async def write_file(self, target: SshTarget, path: str, content: str) -> None:
        await self._inner.write_file(target, path, content)
        async with self._lock:
            self._cache.pop(_CacheKey(target.host_id, path), None)

    async def close(self) -> None:
        async with self._lock:
            self._cache.clear()
        await self._inner.close()

    async def invalidate(self, host_id: int, path: str | None = None) -> None:
        """Drop cache entries for a host. If ``path`` is None, drop all its entries."""
        async with self._lock:
            if path is None:
                stale = [k for k in self._cache if k.host_id == host_id]
                for k in stale:
                    self._cache.pop(k, None)
            else:
                self._cache.pop(_CacheKey(host_id, path), None)
