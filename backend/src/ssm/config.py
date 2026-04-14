"""Configuration loading: env overrides config.toml.

Precedence (highest wins):
    1. Explicit special-cased env vars: DATABASE_URL, JWT_SECRET, SSH_KEY, HTPASSWD
    2. Generic env vars: LOGLEVEL, PORT, LISTEN
    3. Values from the TOML file at ``$CONFIG`` (default: ./config.toml)
    4. Built-in defaults
"""

from __future__ import annotations

import logging
import os
import tomllib
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

DEFAULT_DATABASE_URL = "sqlite:///ssm.db"
DEFAULT_LISTEN = "::"
DEFAULT_PORT = 8000
DEFAULT_LOGLEVEL = "info"
DEFAULT_HTPASSWD_PATH = ".htpasswd"
DEFAULT_PRIVATE_KEY_FILE = "keys/id_ssm"
DEFAULT_TIMEOUT_SECONDS = 120

_RUST_LOG_LEVEL_MAP: dict[str, int] = {
    "trace": logging.DEBUG,
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warn": logging.WARNING,
    "warning": logging.WARNING,
    "error": logging.ERROR,
    "off": logging.CRITICAL,
}


@dataclass(frozen=True, slots=True)
class SshConfig:
    """SSH subsystem configuration."""

    private_key_file: Path = field(default_factory=lambda: Path(DEFAULT_PRIVATE_KEY_FILE))
    private_key_passphrase: str | None = None
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS
    check_schedule: str | None = None
    update_schedule: str | None = None


@dataclass(frozen=True, slots=True)
class Configuration:
    """Top-level application configuration."""

    database_url: str = DEFAULT_DATABASE_URL
    listen: str = DEFAULT_LISTEN
    port: int = DEFAULT_PORT
    loglevel: str = DEFAULT_LOGLEVEL
    jwt_secret: str | None = None
    htpasswd_path: Path = field(default_factory=lambda: Path(DEFAULT_HTPASSWD_PATH))
    ssh: SshConfig = field(default_factory=SshConfig)


def rust_log_to_python_level(value: str) -> int:
    """Map a RUST_LOG-style directive to a Python logging level.

    Accepts either a single level (``debug``) or a comma-separated directive
    list (``ssm=debug,actix=warn``). The lowest-severity (most verbose) known
    level wins, mirroring how ``env_logger`` surfaces log output in practice.
    Unknown tokens fall back to INFO so misconfiguration does not silence logs.
    """
    if not value:
        return logging.INFO

    lowest = logging.CRITICAL
    matched = False
    for part in value.split(","):
        token = part.strip().lower()
        if "=" in token:
            token = token.split("=", 1)[1]
        level = _RUST_LOG_LEVEL_MAP.get(token)
        if level is not None:
            matched = True
            lowest = min(lowest, level)
    return lowest if matched else logging.INFO


def _read_toml(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("rb") as f:
        data = tomllib.load(f)
    return data


def _apply_toml(base: Configuration, data: dict[str, Any]) -> Configuration:
    ssh_data = data.get("ssh", {}) or {}
    ssh = replace(
        base.ssh,
        private_key_file=Path(ssh_data.get("private_key_file", base.ssh.private_key_file)),
        private_key_passphrase=ssh_data.get(
            "private_key_passphrase", base.ssh.private_key_passphrase
        ),
        timeout_seconds=int(ssh_data.get("timeout", base.ssh.timeout_seconds)),
        check_schedule=ssh_data.get("check_schedule", base.ssh.check_schedule),
        update_schedule=ssh_data.get("update_schedule", base.ssh.update_schedule),
    )
    return replace(
        base,
        database_url=str(data.get("database_url", base.database_url)),
        listen=str(data.get("listen", base.listen)),
        port=int(data.get("port", base.port)),
        loglevel=str(data.get("loglevel", base.loglevel)),
        htpasswd_path=Path(data.get("htpasswd_path", base.htpasswd_path)),
        jwt_secret=data.get("jwt_secret", base.jwt_secret),
        ssh=ssh,
    )


def _apply_env(base: Configuration) -> Configuration:
    env = os.environ

    ssh = replace(
        base.ssh,
        private_key_file=(Path(env["SSH_KEY"]) if "SSH_KEY" in env else base.ssh.private_key_file),
    )
    jwt_secret = env.get("JWT_SECRET") or env.get("SESSION_KEY") or base.jwt_secret
    return replace(
        base,
        database_url=env.get("DATABASE_URL", base.database_url),
        listen=env.get("LISTEN", base.listen),
        port=int(env["PORT"]) if "PORT" in env else base.port,
        loglevel=env.get("LOGLEVEL", base.loglevel),
        htpasswd_path=Path(env["HTPASSWD"]) if "HTPASSWD" in env else base.htpasswd_path,
        jwt_secret=jwt_secret,
        ssh=ssh,
    )


def load_configuration() -> Configuration:
    """Load configuration using TOML-then-env precedence."""
    config_path = Path(os.environ.get("CONFIG", "config.toml"))
    toml_data = _read_toml(config_path)

    config = Configuration()
    config = _apply_toml(config, toml_data)
    config = _apply_env(config)
    return config
