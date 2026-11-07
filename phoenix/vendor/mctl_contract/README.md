# MctlContract

Shared Elixir library for **mctl contract v1**: the API that omon, the
dashboard and ssm serve to Mission Control (mctl) at `/api/mctl/v1`. It
holds everything that must be identical in every tool: routing, bearer
auth with scopes, the `{data, meta}` / `{error}` envelope, keyset cursors,
`Idempotency-Key`, the OpenAPI document, token and job storage, and a
conformance test suite. Domain logic stays in each tool behind the
`MctlContract.Provider` behaviour.

Binding specification: [`mctl-docs/docs/contract-v1.md`](../mctl-docs/docs/contract-v1.md)
(decisions: ADR-0006, ADR-0007, ADR-0009, ADR-0010). `READY` lists the
public modules and callbacks in one page.

## Install

Tools vendor a tagged release, so CI and Docker builds need nothing but the
tool's own repo (the contract changes rarely):

```sh
scripts/vendor.sh v0.1.0 ../omon          # writes ../omon/vendor/mctl_contract (+ VENDORED)
```

```elixir
# mix.exs – MCTL_CONTRACT_PATH=../mctl_contract while working on the library itself
{:mctl_contract, path: System.get_env("MCTL_CONTRACT_PATH", "vendor/mctl_contract")}

# config/config.exs
config :mctl_contract, repo: MyApp.Repo, token_prefix: "ssm_"
```

Dependencies: `plug`, `jason`, `ecto_sql`.

## Mount

```elixir
# endpoint.ex: instead of Plug.Parsers – contract bodies are left to the
# contract plug, which reads them only after the token check
plug MctlContract.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Jason,
  mctl_prefix: "/api/mctl/v1"

# router.ex
forward "/api/mctl/v1", MctlContract.Plug,
  provider: MyApp.MctlProvider,            # MctlContract.Provider
  token_store: MctlContract.Tokens.Ecto,   # default
  auth_hooks: MyApp.MctlAuthHooks,         # optional: IP lockout, audit, rate limit
  max_body: 1_000_000                      # optional, bytes
```

## Migrations

Portable across PostgreSQL, MariaDB and SQLite (tables `mctl_tokens`,
`mctl_jobs`, `mctl_idempotency`):

```elixir
defmodule MyApp.Repo.Migrations.AddMctlContract do
  use Ecto.Migration
  def up, do: MctlContract.Migrations.up(version: 1)
  def down, do: MctlContract.Migrations.down(version: 1)
end
```

`only: [:jobs, :idempotency]` skips tables a tool does not need (omon keeps
its own token table).

## Bootstrap

`MCTL_TOKEN_FILE` holds the full service token (a Docker secret, mode
0400); `MCTL_TOKEN_SCOPES` limits it (default `read,setup,commands`). Call
at boot, after the repo started:

```elixir
MctlContract.Bootstrap.ensure_service_token(MctlContract.Tokens.Ecto, prefix: "ssm_")
```

It installs the token `mission-control-env` (hash only). A new secret
replaces it; the same secret never undoes a revocation; without the
variable an active env token is revoked. Prune old rows periodically with
`MctlContract.Idempotency.Ecto.prune/1` and `MctlContract.Jobs.Ecto.prune/2`.

## Behaviours

* `MctlContract.Provider` – the tool's hosts, customers, groups and jobs
* `MctlContract.TokenStore` – `verify/1`, `touch/2`,
  `ensure_service_token/4`, optional `revoke_service_token/1`
  (default `MctlContract.Tokens.Ecto`)
* `MctlContract.IdempotencyStore` – default `MctlContract.Idempotency.Ecto`
* `MctlContract.AuthHooks` – optional `before_auth/1`,
  `on_auth_failure/2`, `rate_limit/2`

Optional job store: `MctlContract.Jobs.Ecto` (`run/4`, `progress/2`,
`succeed/2`, `fail/3`, `fail_stale/1`).

## Conformance

Every tool runs the same requests and assertions against its own endpoint:

```elixir
defmodule MyAppWeb.MctlConformanceTest do
  use MctlContract.ConformanceCase,
    endpoint: MyAppWeb.Endpoint,
    base: "/api/mctl/v1",
    fixtures: MyApp.MctlFixtures   # MctlContract.ConformanceCase.Fixtures
end
```

## Development

```sh
mix deps.get
mix test                       # SQLite via ecto_sqlite3 (test only)
mix format --check-formatted
```

`test/support/` holds an in-memory provider, token store and fixtures that
double as examples.

## Licence

Apache-2.0 (see `LICENSE`, `NOTICE`). Copyright 2026 STYLiTE AG. Permissive on
purpose: omon (AGPL-3.0-only), ssm and the dashboard (BSL 1.1) all link it.
