"""Tests for ssm.config — env > config.toml precedence + special env vars."""

from __future__ import annotations

import logging
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


def test_defaults_when_no_file_and_no_env(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    for var in (
        "CONFIG",
        "DATABASE_URL",
        "JWT_SECRET",
        "SSH_KEY",
        "HTPASSWD",
        "SESSION_KEY",
        "RUST_LOG",
        "LOGLEVEL",
        "PORT",
        "LISTEN",
    ):
        monkeypatch.delenv(var, raising=False)

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


def test_toml_file_sets_values(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    toml = tmp_path / "config.toml"
    toml.write_text(
        'database_url = "sqlite:///data.db"\n'
        "port = 9000\n"
        'loglevel = "debug"\n'
        "[ssh]\n"
        "timeout = 30\n"
        'private_key_file = "/keys/custom_id"\n'
    )
    monkeypatch.setenv("CONFIG", str(toml))
    for var in ("DATABASE_URL", "JWT_SECRET", "SSH_KEY", "HTPASSWD", "RUST_LOG"):
        monkeypatch.delenv(var, raising=False)

    config = load_configuration()

    assert config.database_url == "sqlite:///data.db"
    assert config.port == 9000
    assert config.loglevel == "debug"
    assert config.ssh.timeout_seconds == 30
    assert config.ssh.private_key_file == Path("/keys/custom_id")


def test_env_overrides_toml(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    toml = tmp_path / "config.toml"
    toml.write_text('database_url = "sqlite:///toml.db"\n')
    monkeypatch.setenv("CONFIG", str(toml))
    monkeypatch.setenv("DATABASE_URL", "sqlite:///env.db")

    config = load_configuration()

    assert config.database_url == "sqlite:///env.db"


def test_special_env_vars_applied(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("CONFIG", raising=False)
    monkeypatch.setenv("DATABASE_URL", "sqlite:///override.db")
    monkeypatch.setenv("JWT_SECRET", "super-secret")
    monkeypatch.setenv("SSH_KEY", "/keys/env_id")
    monkeypatch.setenv("HTPASSWD", "/etc/ssm/.htpasswd")

    config = load_configuration()

    assert config.database_url == "sqlite:///override.db"
    assert config.jwt_secret == "super-secret"
    assert config.ssh.private_key_file == Path("/keys/env_id")
    assert config.htpasswd_path == Path("/etc/ssm/.htpasswd")


def test_session_key_env_maps_to_jwt_secret(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """SESSION_KEY from the Rust era is accepted as a fallback for JWT_SECRET."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("CONFIG", raising=False)
    monkeypatch.delenv("JWT_SECRET", raising=False)
    monkeypatch.setenv("SESSION_KEY", "legacy-secret")

    config = load_configuration()

    assert config.jwt_secret == "legacy-secret"


def test_jwt_secret_wins_over_session_key(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("CONFIG", raising=False)
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


def test_missing_config_path_is_not_fatal(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("CONFIG", str(tmp_path / "does-not-exist.toml"))

    config = load_configuration()

    assert config.database_url == DEFAULT_DATABASE_URL
