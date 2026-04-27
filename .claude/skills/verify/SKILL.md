---
name: verify
description: Run full verification for SSM — backend pytest + ruff + mypy + frontend lint + type-check. Use before marking work done or pushing changes.
---

Run all checks in parallel where possible. Report pass/fail per step. Do not proceed past failures without surfacing them.

## Backend

```bash
cd backend && uv run pytest
cd backend && uv run ruff check
cd backend && uv run mypy --strict src
```

## Frontend

```bash
cd frontend && npm run lint
cd frontend && npm run type-check
```

## Report format

For each of the 4 checks: `✅ pass` or `❌ fail` with the first ~20 lines of failure output. If all pass, one-line summary.
