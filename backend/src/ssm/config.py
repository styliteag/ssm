"""Configuration loading from environment variables.

A ``.env`` file in the current working directory (or pointed at by
``$DOTENV``) is loaded into the environment on import via ``python-dotenv``.
After that, every setting is read straight from ``os.environ``. Existing
shell variables always win over values in ``.env`` — nothing else is layered.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

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


def load_configuration() -> Configuration:
    """Load configuration from a ``.env`` file (if any) plus environment."""
    dotenv_path = os.environ.get("DOTENV") or str(Path.cwd() / ".env")
    load_dotenv(dotenv_path=dotenv_path, override=False)

    env = os.environ
    ssh = SshConfig(
        private_key_file=Path(env.get("SSH_KEY", DEFAULT_PRIVATE_KEY_FILE)),
        private_key_passphrase=env.get("SSH_KEY_PASSPHRASE"),
        timeout_seconds=int(env.get("SSH_TIMEOUT", DEFAULT_TIMEOUT_SECONDS)),
        check_schedule=env.get("SSH_CHECK_SCHEDULE"),
        update_schedule=env.get("SSH_UPDATE_SCHEDULE"),
    )
    return Configuration(
        database_url=env.get("DATABASE_URL", DEFAULT_DATABASE_URL),
        listen=env.get("LISTEN", DEFAULT_LISTEN),
        port=int(env.get("PORT", DEFAULT_PORT)),
        loglevel=env.get("LOGLEVEL", DEFAULT_LOGLEVEL),
        jwt_secret=env.get("JWT_SECRET") or env.get("SESSION_KEY"),
        htpasswd_path=Path(env.get("HTPASSWD", DEFAULT_HTPASSWD_PATH)),
        ssh=ssh,
    )
