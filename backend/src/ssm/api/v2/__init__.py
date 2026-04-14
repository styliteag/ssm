"""v2 API routers mounted under ``/api/v2``."""

from __future__ import annotations

from fastapi import APIRouter

from ssm.api.v2 import auth, authorizations, diffs, hosts, keys, users

v2_router = APIRouter(prefix="/api/v2")
v2_router.include_router(auth.router)
v2_router.include_router(hosts.router)
v2_router.include_router(users.router)
v2_router.include_router(keys.router)
v2_router.include_router(authorizations.router)
v2_router.include_router(diffs.router)
