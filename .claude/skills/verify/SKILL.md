---
name: verify
description: Run full verification for SSM — compile with warnings-as-errors, mix format check, ExUnit suite (docker-only toolchain). Use before marking work done or pushing changes.
---

The whole gate runs inside the dev container (no local Elixir needed):

```bash
just verify   # = mix precommit: compile --warnings-as-errors + format --check-formatted + test
```

For a faster loop on a subset:

```bash
just test test/ssm_web/api/        # one directory
just test test/ssm/hosts_test.exs  # one file
just format                        # fix formatting before the gate complains
```

## Report format

`✅ pass` or `❌ fail` per stage (compile / format / tests) with the first ~20 lines of
failure output. If all pass, one-line summary. Do not proceed past failures without
surfacing them.
