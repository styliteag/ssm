# Changelog

All notable changes to this library. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versions: [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] – 2026-11-07

### Added (after the API freeze of 2026-11-06)

- Handled problems in host summaries (US-HST-09, contract section 9):
  `HostSummary` items render `acknowledged` and `in_downtime` (booleans,
  absent = `false`), `counts` renders `handled` (default 0). Items are
  ordered unhandled first, then worst first, so the 50-item cut keeps the
  open problems. OpenAPI documents the new fields as optional; the
  ConformanceCase accepts summaries with or without them.
- Rename (contract section 11): optional Provider callback
  `update_group/3` (`PATCH /groups/{slug}`, scope `setup`, body
  `{"name": …}`, `200` `Group`, `404` unknown, `422` invalid or a slug in
  the body); capability `rename_group` in `GET /me`, the route is
  `404 not_found` and absent from OpenAPI without it. ConformanceCase
  checks `PATCH /customers/{slug}` (200 with the slug kept, idempotent,
  404, 422, 403) and `rename_group` (served or absent).
- `MctlContract.Connect`: create, rotate, revoke and status of the
  UI-created service token `mission-control` (US-API-09) and the
  `MCTL_CONNECTORS_FILE` entry; optional TokenStore callback
  `service_token_status/1`.
- Delete, maintenance, people (contract section 10, US-API-10): optional
  Provider callbacks `delete_host/2` (`DELETE /hosts/{id}`, scope `setup`,
  `202` `Job`), `create_maintenance/3`, `list_maintenance/2`,
  `cancel_maintenance/2` (`POST /hosts/{id}/maintenance` `201`,
  `GET /maintenance` paged with filters `host_id`, `state`,
  `DELETE /maintenance/{id}` `204`), `get_person/2` and `remove_person/3`
  (`GET /people/{key}`, `POST /people/{key}/remove` scope `commands`,
  `202` `Job`). Capabilities `delete_host`, `maintenance`, `people` in
  `GET /me`; each route `404 not_found` without its callbacks. The library
  checks maintenance windows (`end > start`, `end` in the future, at most
  30 days, times passed to the provider as UTC `DateTime`s) and person
  keys (`oidc:<iss>|<sub>`, `email:<address>`, else `400`); `Person`
  renders only fingerprint, comment and hosts per key. OpenAPI and
  ConformanceCase cover each capability (served or absent); new optional
  fixture `person_key/0`. OpenAPI also documents `mode` in `HostUpdate`
  and the `202` `Job` answer of `PATCH /hosts/{id}`. Maintenance windows
  are limited so they cannot mute a host for long: `start` at most 90 days
  ahead, no overlap with a `planned`/`active` window of the host and at
  most 10 `planned` per host (`409 conflict`,
  `MctlContract.MaintenanceLimits`, using the provider's
  `list_maintenance/2`). `Person` lists the matched `emails` and a
  `matched_by` reason per key and authorization.
- `PATCH /hosts/{id}` accepts `mode` (onboarding v2 §3.4); `update_host/3`
  may return `{:accepted, job}`, answered `202` with the `Job` (a mode
  switch that waits for the agent).
- Provider failures are logged with the exception module and an
  argument-free stacktrace only (no messages, reasons or call arguments,
  which may hold secrets). The `Idempotency-Key` request hash leaves out
  values of secret-looking keys (`password`, `secret`, `token`, …).
- Host actions (onboarding v2, `mctl-docs/docs/onboarding-v2.md` §2):
  optional Provider callbacks `host_actions/0` (allow-listed action names)
  and `host_action/3` (`principal, id, %{"action" => name, "params" => map}`
  → `{:ok, job}` | `{:error, error}`); route `POST /hosts/{id}/actions`
  (scope `commands`, `202` `Job`, `Idempotency-Key` supported), `404
  not_found` without both callbacks, unknown action `422 validation_failed`
  `{"action": ["not supported"]}` before the provider is called. `GET /me`
  `capabilities` lists `action:<name>` per action. OpenAPI `HostAction`
  (action enum) and the route only with the capability; ConformanceCase
  checks follow the advertised actions (never runs a real action).
- C4 host summaries (contract section 9): optional Provider callbacks
  `list_host_summaries/2` and `get_host_summary/2`; routes
  `GET /host-summaries` (paged, filters `changed_after`, `host_id`) and
  `GET /hosts/{id}/summary`, both `404 not_found` when the provider lacks
  the callbacks. `GET /me` gains `capabilities` (`"host_summaries"`).
  `MctlContract.Capabilities`, `Render.host_summary/1` (worst items first,
  max 50), OpenAPI `HostSummary` (routes only with the capability) and
  ConformanceCase checks that follow the advertised capability.
- Provider error `{:conflict, message, details}`: 409 `conflict` with `details`
  naming the conflicting fields.

First version of mctl contract v1 (`mctl-docs/docs/contract-v1.md`).
Licensed under Apache-2.0. Tools vendor a tagged release with
`scripts/vendor.sh <tag> <mix-project-dir>` (copy in `vendor/mctl_contract`).

### Added

- `MctlContract.Plug`: the `/api/mctl/v1` router – `/me`, `/openapi.json`,
  hosts, customers, groups, jobs; bearer auth with scopes `read`, `setup`,
  `commands`; the token is checked before the body is read; `max_body`
  limit (default 1 MB); provider errors, exceptions, exits and throws
  answer in the envelope.
- `MctlContract.Parsers`: drop-in for `Plug.Parsers` that leaves contract
  bodies to the contract plug (matched on path segments).
- `MctlContract.AuthHooks`: optional per-IP lockout, auth-failure audit and
  per-token rate limit (`429 rate_limited` with `Retry-After`).
- `MctlContract.Envelope`, `MctlContract.Cursor` (wire-identical to omon
  API v2 keyset cursors), `MctlContract.Page` (limits, filters: strings
  ≤ 1024 bytes, no NUL), `MctlContract.Render`, `MctlContract.Params`.
- `MctlContract.Identity`: `useful_macs/1` (ADR-0006 filter), `normalize_mac/1`.
- `MctlContract.Principal` with the client `ip`.
- Behaviours `MctlContract.Provider`, `MctlContract.TokenStore`,
  `MctlContract.IdempotencyStore`.
- Ecto stores: `MctlContract.Tokens.Ecto` (SHA-256 only, shown prefix =
  tool prefix + 4 characters), `MctlContract.Jobs.Ecto` (inline or task
  runs, `fail_stale/1`, batched `prune/2`), `MctlContract.Idempotency.Ecto`
  (24 h, batched `prune/1`).
- `MctlContract.Migrations` version 1, portable across PostgreSQL, MariaDB
  and SQLite.
- `MctlContract.Bootstrap`: env-managed token `mission-control-env` from
  `MCTL_TOKEN_FILE` / `MCTL_TOKEN_SCOPES`; a revoked secret stays revoked;
  revoked when the variable is removed; file-mode warning.
- `MctlContract.OpenAPI`: OpenAPI 3.1 document of the contract.
- `MctlContract.ConformanceCase`: ExUnit case template every tool runs.
