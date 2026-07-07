---
name: add-endpoint
description: Scaffold a new /api/v2 endpoint or resource end-to-end — Pydantic models + protected router + error codes + contract tests + frontend service/types + CHANGELOG. Use for any new API route, resource, or field exposed to the frontend.
---

Every endpoint in this repo follows one canonical shape. Copy the pattern from
`backend/src/ssm/api/v2/hosts.py` — do not invent a new one. Work through the files in
this order; the checklist at the end is the definition of done.

## 1. Backend router — `backend/src/ssm/api/v2/<domain>.py`

Skeleton (mirrors `hosts.py`):

```python
"""``/api/v2/<domain>`` — one-line purpose."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse, Meta
from ssm.core.errors import Conflict  # + the *NotFound you need
from ssm.db.deps import db_session

router = protected_router(prefix="/<domain>", tags=["<domain>"])


class ThingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    # ... mirror the ORM columns you expose


class CreateThingRequest(BaseModel):
    name: str = Field(min_length=1, max_length=128)
    # Field() constraints on every string/number


class UpdateThingRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=128)
    # all-optional twin of Create
```

Handler rules (non-negotiable):

- `response_model=ApiResponse[...]`; return `ApiResponse[...].ok(data)`. List endpoints
  add `meta=Meta(total=len(items))`.
- 404s via a `_get_or_404` helper raising the domain's `*NotFound` `AppError`.
- Create/update: `session.add(...)` / `setattr`, then `await session.flush()` inside
  `try/except IntegrityError` → raise `Conflict(...)`, then `await session.refresh(obj)`.
  **Never `session.commit()`** — the `db_session` dependency commits.
- PATCH applies `payload.model_dump(exclude_unset=True)` only.
- New failure mode → new `ErrorCode` member + `AppError` subclass in
  `backend/src/ssm/core/errors.py` (reuse existing codes when they fit).
- SSH involved? Resolve the client through `ssm.ssh.deps` (Protocol, never a concrete
  import), check `host.disabled` → raise `HostDisabled`, honor readonly markers →
  `SshReadOnly`.

## 2. Register — `backend/src/ssm/api/v2/__init__.py`

Add the module to the import block and `v2_router.include_router(<domain>.router)`.
Forgetting this compiles fine and 404s at runtime — the contract test catches it.

## 3. Contract tests — `backend/tests/contract/test_<domain>_routes.py`

Fixtures `auth_client` / `auth_headers` / `mock_ssh` come from
`tests/contract/conftest.py` (in-memory SQLite, real JWT, `MockSshClient`). Minimum set:

```python
def test_list_requires_auth(auth_client: TestClient) -> None:
    resp = auth_client.get("/api/v2/<domain>")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"
```

plus: happy path per verb (assert `status_code`, `body["success"] is True`, the
envelope `data` shape, and `meta` on lists); each domain error asserted by
`error.code` (e.g. `HOST_NOT_FOUND`, `CONFLICT` on duplicates); SSH behavior (if any)
asserted against `mock_ssh`, including the disabled-host and readonly paths.
pytest runs `asyncio_mode="auto"` — plain sync `TestClient` tests are the norm here.

## 4. Frontend types — `frontend/src/types/index.ts`

Add/extend the interface mirroring `ThingOut` exactly (there is no codegen — you are
the codegen). Optional-nullable numbers stay `number | null` on the wire; forms hold
strings and convert once on submit (`jump_via` pattern, see `HostEditModal.tsx`).

## 5. Frontend service — `frontend/src/services/api/<domain>.ts`

```typescript
import { api } from './base';
import type { Thing } from '../../types';

export const thingsService = {
  async getThings(): Promise<Thing[]> {
    const response = await api.get<Thing[]>('/<domain>');
    return response.data ?? [];
  },
  async createThing(payload: CreateThingPayload): Promise<Thing> {
    const response = await api.post<Thing>('/<domain>', payload);
    return response.data!;
  },
};
```

- `api.*` already unwraps the envelope and throws on failure; callers branch on the
  **caught** `err.code` (`catch (err) { if (err.code === 'CONFLICT') ... }`). Never
  look for `response.error` — it does not exist after unwrapping.
- Wire-name remaps (like `key_name` ↔ `name`) live here in the service, nowhere else.
- Export from the barrel `frontend/src/services/api/index.ts` (note: the barrel is
  historically incomplete — add yours properly).

## 6. UI wiring (when the endpoint has a face)

Compose from `components/ui/` (DataTable for lists, Modal + schema-driven Form for
editing). Errors surface through `useNotifications().showError(...)`. Use semantic
Tailwind tokens so dark/light both work. New logic goes in a component under
`components/<domain>/`, not appended to the giant pages.

## 7. Definition of done

- [ ] Router on `protected_router()`, registered in `api/v2/__init__.py`
- [ ] All responses enveloped; errors are `AppError` subclasses with stable codes
- [ ] Contract tests: 401 test + happy paths + every error code the endpoint can emit
- [ ] `just verify` passes (all six gates)
- [ ] `frontend/src/types/index.ts` + service + barrel export updated
- [ ] Schema touched? → migration via the `db-migration` skill, same commit
- [ ] `CHANGELOG.md` entry under `[Unreleased]` → `Added`
- [ ] Commit packaged via the `ship` skill

## Escalation

Ask the user first when the new endpoint changes existing wire shapes, needs a new
dependency, or must be public (unauthenticated) — only `auth/login` and `auth/refresh`
are public today, and widening that set is a security decision.
