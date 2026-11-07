# TODO

Findings carried over from omon (styliteag/omon, 2026-10-26). Same release
setup and same Phoenix stack, so the same problems apply here.

## Security: update Bandit (HIGH)

- [x] Done (fix/dependabot): bandit 1.14.1. Was: `phoenix/mix.lock` pins `bandit 1.12.4`. On 2026-10-26, 11 advisories
  were published against Bandit < 1.14.0 (9 HIGH): HTTP request smuggling via
  chunk extensions, WebSocket fragment size bypass, HTTP/2 frames resetting the
  body read timeout (EEF-CVE-2026-108525 … EEF-CVE-2026-115269). In omon,
  `mix deps.audit` blocked the release. Fix: `mix deps.update bandit` (1.14.0),
  then `mix deps.audit`.

## Release: rebuilding an old version rolls back `latest`

- [ ] `.github/workflows/release-docker.yml` always moves `latest` and `X.Y` to
  the built version, also for `workflow_dispatch` with an old `version` and for
  a hotfix tag on an older series (e.g. `v1.2.5` after `v1.3.0`). Anything that
  follows `latest` (watchtower, `docker compose pull`) then runs the old version
  on a database already migrated by the newer one. Startup migrations only go
  forward.
  Fix used in omon (commit fda060d): check out with `fetch-depth: 0` and
  `fetch-tags: true`, then move a floating tag only if the built version is the
  newest tag of that series:

  ```bash
  newest() {
    { git tag -l "$1" || true; } | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
      | sort -V | tail -n1 | sed 's/^v//'
  }
  TAGS=""
  [ "$(newest "v$MAJOR.$MINOR.*")" = "$V" ] && TAGS="$TAGS $MAJOR.$MINOR"
  [ "$(newest "v$MAJOR.*")" = "$V" ] && TAGS="$TAGS $MAJOR"
  [ "$(newest 'v*')" = "$V" ] && TAGS="$TAGS latest"
  ```

  Apply it to the Docker Hub and the GHCR manifests.

## LiveView: second host name gets 403 on the socket

- [ ] `phoenix/config/runtime.exs` sets `check_origin: true` when `PHX_HOST` is
  set, so the LiveView WebSocket only accepts `Origin: https://$PHX_HOST`. A
  second name for the same instance (e.g. an internal NetBird name like
  `ssm.nb.sty`) loads the page, but the socket gets 403 and LiveView keeps
  reconnecting.
  Fix used in omon (commit ca8e4c4): `check_origin: :conn`. The Origin must
  then match the request's own host/scheme/port: every name works, and
  cross-site socket hijacking stays blocked. Do not use `check_origin: false`.
  `PHX_HOST` stays the name for absolute URLs.
