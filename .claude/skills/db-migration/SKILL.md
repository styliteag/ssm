---
name: db-migration
description: Create and verify an Alembic migration for SSM. Use for ANY change to backend/src/ssm/db/models.py or the DB schema. Covers autogenerate review, the fresh/legacy/downgrade verification matrix, the Diesel legacy-DB trap, and same-commit packaging.
---

Schema changes are the highest-risk edits in this repo: five of the last ten releases
were spent fixing migration behavior against inherited Diesel-era databases. Follow
every step; do not skip the legacy check because the change "looks simple".

## Step 1 — Change the model first

Edit `backend/src/ssm/db/models.py`. Keep Diesel parity conventions: singular table
names, `Boolean` for SQLite 0/1 integers, named constraints (SQLite + `render_as_batch`
cannot alter anonymous constraints later).

## Step 2 — Generate the revision

```bash
cd backend && uv run alembic revision --autogenerate -m "<short description>"
```

Rename the generated file to the next sequential prefix (`0002_<slug>.py`, `0003_...`)
matching the existing `0001_initial_schema.py` style, and set `revision`/`down_revision`
accordingly.

## Step 3 — Hand-review the generated SQL

Autogenerate output is a draft, not a result. Check:

- **SQLite compatibility**: column alters/drops must work under batch mode
  (`render_as_batch=True` is set in `migrations/env.py`). Use
  `with op.batch_alter_table("host") as batch_op:` for ALTERs.
- **New constraints/indexes are named** explicitly.
- **Server defaults**: existing rows need a `server_default` (or a data backfill) when
  adding a NOT NULL column.
- **Data backfills** are explicit `op.execute(...)` statements — autogenerate never
  writes them for you.
- **`downgrade()` actually reverses `upgrade()`**. If it genuinely cannot (data loss),
  write a comment in the migration explaining why and say so in your report.

## Step 4 — The legacy-DB trap (read before adding tables)

`migrations/env.py` stamps Diesel-era databases (schema present, no/empty
`alembic_version`) as revision `0001` — but first it runs
`Base.metadata.create_all(checkfirst=True)`, which creates **every table in current
metadata**, including tables your new revision is about to create. On the legacy path
your revision then runs and `op.create_table` crashes with "table already exists".

Therefore, when a revision > 0001 creates a table, guard it:

```python
from sqlalchemy import inspect

def upgrade() -> None:
    bind = op.get_bind()
    if not inspect(bind).has_table("my_new_table"):
        op.create_table("my_new_table", ...)
```

(Alternative: change the `env.py` stamp logic to create only revision-0001 tables —
that is a bigger, separately-reviewed change.)

Column additions to existing tables are also affected: on the legacy path, the
`create_all` gives new *tables* the current schema, but existing legacy *tables* keep
their old columns — your `op.add_column` still runs and must succeed there.

## Step 5 — Verification matrix (all three must pass)

Run from `backend/`, using throwaway DBs in a temp dir — never against `ssm.db` files
in the working tree:

```bash
TMP=$(mktemp -d)

# 1. Fresh DB: full history applies cleanly
DATABASE_URL="sqlite:///$TMP/fresh.db" uv run alembic upgrade head
DATABASE_URL="sqlite:///$TMP/fresh.db" uv run alembic current   # must print head revision

# 2. Legacy Diesel DB: stamp path + your revision
sqlite3 "$TMP/legacy.db" "CREATE TABLE host (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, username TEXT NOT NULL, address TEXT NOT NULL, port INTEGER NOT NULL, key_fingerprint TEXT, jump_via INTEGER REFERENCES host(id), disabled INTEGER NOT NULL DEFAULT 0, comment TEXT);"
sqlite3 "$TMP/legacy.db" "CREATE TABLE user (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL DEFAULT 1, comment TEXT);"
DATABASE_URL="sqlite:///$TMP/legacy.db" uv run alembic upgrade head
# expect: "Legacy database detected ... stamping as 0001", then your revision applies
DATABASE_URL="sqlite:///$TMP/legacy.db" uv run alembic current  # must print head revision

# 3. Downgrade roundtrip
DATABASE_URL="sqlite:///$TMP/fresh.db" uv run alembic downgrade -1
DATABASE_URL="sqlite:///$TMP/fresh.db" uv run alembic upgrade head
```

If the user has a copy of a production database available, also run
`alembic upgrade head` against a **copy** of it (never the original).

Then run the test suite (contract tests exercise the schema via `create_all`):

```bash
uv run pytest tests/unit/test_migrations.py && uv run pytest -q
```

## Step 6 — Package

One commit containing:

- [ ] `backend/src/ssm/db/models.py` change
- [ ] the new `backend/migrations/versions/NNNN_*.py`
- [ ] any router/Pydantic model updates the column change implies
- [ ] matching `frontend/src/types/index.ts` update if the wire format changed
- [ ] `CHANGELOG.md` entry under `[Unreleased]` → `Changed` (or `Added`), wording
      focused on operator impact ("databases are migrated automatically on upgrade")

## Escalation

Stop and ask the user before writing a migration that **drops or renames** a table or
column that could hold production data, and before touching `migrations/env.py`'s
stamping logic. Report the verification-matrix output verbatim in your summary.
