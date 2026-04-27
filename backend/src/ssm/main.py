"""Production app factory used by ``uvicorn ssm.main:app``."""

from __future__ import annotations

import logging
import sys

from fastapi import FastAPI

from ssm.app import AppDependencies, create_app
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService
from ssm.config import Configuration, load_configuration, rust_log_to_python_level
from ssm.db.session import make_engine, make_sessionmaker
from ssm.scheduler.setup import build_scheduler
from ssm.ssh.asyncssh_client import AsyncSshClient
from ssm.ssh.caching import CachingSshClient


def _configure_logging(config: Configuration) -> None:
    level = rust_log_to_python_level(config.loglevel)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )


def build() -> FastAPI:
    """Build the production FastAPI app from environment + config.toml."""
    config = load_configuration()
    _configure_logging(config)

    if not config.jwt_secret:
        msg = "JWT_SECRET (or SESSION_KEY) must be set in the environment or config.toml"
        raise RuntimeError(msg)

    htpasswd = HtpasswdStore(config.htpasswd_path)
    jwt_service = JwtService(secret=config.jwt_secret)

    engine = make_engine(config.database_url)
    sessionmaker = make_sessionmaker(engine)

    inner_ssh = AsyncSshClient(
        private_key_file=config.ssh.private_key_file,
        private_key_passphrase=config.ssh.private_key_passphrase,
        timeout_seconds=config.ssh.timeout_seconds,
    )
    ssh_client = CachingSshClient(inner_ssh)

    scheduler = build_scheduler(config.database_url)

    deps = AppDependencies(
        htpasswd_store=htpasswd,
        jwt_service=jwt_service,
        sessionmaker=sessionmaker,
        ssh_client=ssh_client,
        scheduler=scheduler,
    )
    return create_app(deps)


app = build()
