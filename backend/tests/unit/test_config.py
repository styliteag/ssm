"""Tests for ssm.config — env-only loader with optional .env file support."""

from __future__ import annotations

import logging
import os
from collections.abc import Generator
from pathlib import Path

import pytest

from ssm.config import (
    DEFAULT_DATABASE_URL,
    DEFAULT_HTPASSWD_PATH,
    DEFAULT_LISTEN,
    DEFAULT_LOGLEVEL,
    DEFAULT_PORT,
    DEFAULT_PRIVATE_KEY_FILE,
    DEFAULT_TIMEOUT_SECONDS,
    Configuration,
    load_configuration,
    rust_log_to_python_level,
)

_TRACKED_VARS = (
    "DOTENV",
    "DATABASE_URL",
    "JWT_SECRET",
    "SSH_KEY",
    "SSH_KEY_PASSPHRASE",
    "SSH_TIMEOUT",
    "SSH_CHECK_SCHEDULE",
    "SSH_UPDATE_SCHEDULE",
    "HTPASSWD",
    "SESSION_KEY",
    "RUST_LOG",
    "LOGLEVEL",
    "PORT",
    "LISTEN",
)


def _clear_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for var in _TRACKED_VARS:
        monkeypatch.delenv(var, raising=False)


@pytest.fixture(autouse=True)
def _isolate_env() -> Generator[None, None, None]:
    """``python-dotenv`` writes straight into ``os.environ`` and bypasses
    pytest's ``monkeypatch``. Snapshot the tracked vars and restore on teardown
    so a leaked value can't bleed into other test modules (notably the alembic
    tests, which read ``DATABASE_URL`` from the environment)."""
    snapshot = {var: os.environ.get(var) for var in _TRACKED_VARS}
    try:
        yield
    finally:
        for var, value in snapshot.items():
            if value is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = value


def test_defaults_when_no_env(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    _clear_env(monkeypatch)

    config = load_configuration()

    assert config.database_url == DEFAULT_DATABASE_URL
    assert config.listen == DEFAULT_LISTEN
    assert config.port == DEFAULT_PORT
    assert config.loglevel == DEFAULT_LOGLEVEL
    assert config.htpasswd_path == Path(DEFAULT_HTPASSWD_PATH)
    assert config.jwt_secret is None
    assert config.ssh.private_key_file == Path(DEFAULT_PRIVATE_KEY_FILE)
    assert config.ssh.private_key_passphrase is None
    assert config.ssh.timeout_seconds == DEFAULT_TIMEOUT_SECONDS


def test_env_vars_applied(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    _clear_env(monkeypatch)
    monkeypatch.setenv("DATABASE_URL", "sqlite:///override.db")
    monkeypatch.setenv("JWT_SECRET", "super-secret")
    monkeypatch.setenv("SSH_KEY", "/keys/env_id")
    monkeypatch.setenv("SSH_TIMEOUT", "30")
    monkeypatch.setenv("HTPASSWD", "/etc/ssm/.htpasswd")
    monkeypatch.setenv("PORT", "9000")
    monkeypatch.setenv("LOGLEVEL", "debug")

    config = load_configuration()

    assert config.database_url == "sqlite:///override.db"
    assert config.jwt_secret == "super-secret"
    assert config.ssh.private_key_file == Path("/keys/env_id")
    assert config.ssh.timeout_seconds == 30
    assert config.htpasswd_path == Path("/etc/ssm/.htpasswd")
    assert config.port == 9000
    assert config.loglevel == "debug"


def test_dotenv_file_is_loaded(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    _clear_env(monkeypatch)
    env_file = tmp_path / ".env"
    env_file.write_text(
        'DATABASE_URL="sqlite:///dotenv.db"\n'
        "PORT=9100\n"
        'JWT_SECRET="from-dotenv"\n',
    )

    config = load_configuration()

    assert config.database_url == "sqlite:///dotenv.db"
    assert config.port == 9100
    assert config.jwt_secret == "from-dotenv"


def test_shell_env_overrides_dotenv(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    _clear_env(monkeypatch)
    env_file = tmp_path / ".env"
    env_file.write_text('DATABASE_URL="sqlite:///dotenv.db"\n')
    monkeypatch.setenv("DATABASE_URL", "sqlite:///shell.db")

    config = load_configuration()

    assert config.database_url == "sqlite:///shell.db"


def test_dotenv_path_can_be_overridden(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    _clear_env(monkeypatch)
    custom_env = tmp_path / "custom.env"
    custom_env.write_text('JWT_SECRET="custom-secret"\n')
    monkeypatch.setenv("DOTENV", str(custom_env))

    config = load_configuration()

    assert config.jwt_secret == "custom-secret"


def test_session_key_env_maps_to_jwt_secret(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """SESSION_KEY from the Rust era is accepted as a fallback for JWT_SECRET."""
    monkeypatch.chdir(tmp_path)
    _clear_env(monkeypatch)
    monkeypatch.setenv("SESSION_KEY", "legacy-secret")

    config = load_configuration()

    assert config.jwt_secret == "legacy-secret"


def test_jwt_secret_wins_over_session_key(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    _clear_env(monkeypatch)
    monkeypatch.setenv("SESSION_KEY", "legacy")
    monkeypatch.setenv("JWT_SECRET", "new")

    config = load_configuration()

    assert config.jwt_secret == "new"


@pytest.mark.parametrize(
    ("rust_log", "expected"),
    [
        ("trace", logging.DEBUG),
        ("debug", logging.DEBUG),
        ("info", logging.INFO),
        ("warn", logging.WARNING),
        ("warning", logging.WARNING),
        ("error", logging.ERROR),
        ("ssm=debug,actix=warn", logging.DEBUG),
        ("", logging.INFO),
        ("bogus", logging.INFO),
    ],
)
def test_rust_log_to_python_level(rust_log: str, expected: int) -> None:
    assert rust_log_to_python_level(rust_log) == expected


def test_configuration_is_frozen() -> None:
    config = Configuration()
    with pytest.raises((AttributeError, TypeError)):
        config.port = 1234  # type: ignore[misc]
