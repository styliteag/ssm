---
name: verify
description: Run full verification for SSM — backend tests + clippy + frontend lint + type-check. Use before marking work done or pushing changes.
---

Run all checks in parallel where possible. Report pass/fail per step. Do not proceed past failures without surfacing them.

## Backend

```bash
cd backend && cargo test
cd backend && cargo clippy -- -D warnings
```

## Frontend

```bash
cd frontend && npm run lint
cd frontend && npm run type-check
```

## Report format

For each of the 4 checks: `✅ pass` or `❌ fail` with the first ~20 lines of failure output. If all pass, one-line summary.
