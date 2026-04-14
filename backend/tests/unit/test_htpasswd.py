"""Tests for ssm.auth.htpasswd — bcrypt-backed .htpasswd verification."""

from __future__ import annotations

from pathlib import Path

import bcrypt
import pytest

from ssm.auth.htpasswd import HtpasswdStore, verify_password


def _bcrypt_hash(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(rounds=4)).decode("utf-8")


def _write_htpasswd(path: Path, entries: dict[str, str]) -> None:
    path.write_text("".join(f"{user}:{h}\n" for user, h in entries.items()))


def test_verify_correct_password(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    _write_htpasswd(path, {"admin": _bcrypt_hash("secret")})

    store = HtpasswdStore(path)
    assert store.verify("admin", "secret") is True


def test_verify_wrong_password(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    _write_htpasswd(path, {"admin": _bcrypt_hash("secret")})

    store = HtpasswdStore(path)
    assert store.verify("admin", "wrong") is False


def test_verify_unknown_user(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    _write_htpasswd(path, {"admin": _bcrypt_hash("secret")})

    store = HtpasswdStore(path)
    assert store.verify("ghost", "secret") is False


def test_verify_accepts_2y_bcrypt_variant(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    # Convert $2b$ to $2y$ — Apache's htpasswd emits the 2y variant.
    h = _bcrypt_hash("secret").replace("$2b$", "$2y$", 1)
    _write_htpasswd(path, {"admin": h})

    store = HtpasswdStore(path)
    assert store.verify("admin", "secret") is True


def test_missing_file_means_no_users(tmp_path: Path) -> None:
    store = HtpasswdStore(tmp_path / "missing")
    assert store.verify("admin", "secret") is False
    assert store.list_users() == []


def test_empty_password_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    _write_htpasswd(path, {"admin": _bcrypt_hash("secret")})

    store = HtpasswdStore(path)
    assert store.verify("admin", "") is False


def test_malformed_lines_are_skipped(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    path.write_text(f"# a comment\n\nnot-a-valid-line\nadmin:{_bcrypt_hash('secret')}\n")

    store = HtpasswdStore(path)
    assert store.verify("admin", "secret") is True
    assert store.list_users() == ["admin"]


def test_reload_picks_up_new_entries(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    _write_htpasswd(path, {"admin": _bcrypt_hash("secret")})
    store = HtpasswdStore(path)
    assert store.verify("alice", "pw") is False

    _write_htpasswd(path, {"admin": _bcrypt_hash("secret"), "alice": _bcrypt_hash("pw")})
    store.reload()

    assert store.verify("alice", "pw") is True


def test_unsupported_hash_returns_false(tmp_path: Path) -> None:
    path = tmp_path / ".htpasswd"
    _write_htpasswd(path, {"legacy": "{SHA}oldSchemeWouldGoHere"})

    store = HtpasswdStore(path)
    assert store.verify("legacy", "anything") is False


@pytest.mark.parametrize("password", ["with spaces", "üñïçödé", "1234567890" * 5])
def test_module_level_verify_password(password: str) -> None:
    h = _bcrypt_hash(password)
    assert verify_password(password, h) is True
    assert verify_password(password + "x", h) is False
