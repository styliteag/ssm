"""Parse and verify Apache-style ``.htpasswd`` files.

Only bcrypt hashes are accepted (``$2a$``, ``$2b$``, ``$2y$``); other historical
Apache hash formats are rejected so a weak hash in the file cannot authenticate
anyone. Callers should run ``htpasswd -cB`` which emits the bcrypt variant.
"""

from __future__ import annotations

import logging
from pathlib import Path

import bcrypt

_log = logging.getLogger(__name__)
_BCRYPT_PREFIXES: tuple[str, ...] = ("$2a$", "$2b$", "$2y$")


def verify_password(password: str, hashed: str) -> bool:
    """Return True iff ``password`` matches the bcrypt ``hashed`` value.

    Non-bcrypt or malformed hashes yield False rather than an exception so a
    single bad line in ``.htpasswd`` can never grant access.
    """
    if not password or not hashed:
        return False
    if not hashed.startswith(_BCRYPT_PREFIXES):
        return False
    # bcrypt.checkpw requires $2a/$2b; normalize the Apache $2y$ variant.
    normalized = hashed.replace("$2y$", "$2b$", 1) if hashed.startswith("$2y$") else hashed
    try:
        return bcrypt.checkpw(password.encode("utf-8"), normalized.encode("utf-8"))
    except (ValueError, TypeError):
        return False


class HtpasswdStore:
    """In-memory cache of ``username → bcrypt hash`` loaded from disk."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._entries: dict[str, str] = {}
        self.reload()

    def reload(self) -> None:
        """Re-read the file. Missing or unreadable files leave the store empty."""
        self._entries = _parse_htpasswd(self._path)

    def list_users(self) -> list[str]:
        return sorted(self._entries)

    def verify(self, username: str, password: str) -> bool:
        hashed = self._entries.get(username)
        if hashed is None:
            return False
        return verify_password(password, hashed)


def _parse_htpasswd(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        _log.warning("could not read htpasswd %s: %s", path, exc)
        return {}

    entries: dict[str, str] = {}
    for lineno, raw_line in enumerate(raw.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            _log.warning("skipping malformed htpasswd line %d in %s", lineno, path)
            continue
        username, _, hashed = line.partition(":")
        username = username.strip()
        hashed = hashed.strip()
        if not username or not hashed:
            _log.warning("skipping malformed htpasswd line %d in %s", lineno, path)
            continue
        entries[username] = hashed
    return entries
