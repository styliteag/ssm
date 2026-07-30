# syntax=docker/dockerfile:1.7
#
# Production image for the Elixir/Phoenix stack. Build context is the
# repository root (mix.exs reads ../VERSION):
#
#   docker build -f phoenix/Dockerfile -t ssm .
#
# Contract parity with the previous python/react image: serves HTTP on :80,
# volumes at /app/db /app/config /app/keys /app/logs, applies database
# migrations on start (the ecto baseline adopts Diesel-/Alembic-era DBs in
# place), health check via /api/health. openssh-client ships in the runtime
# for jump-host chains (ssh -N -L forwarder) and boot-time key decryption
# (ssh-keygen -p).

# ---- builder ----------------------------------------------------------------
FROM elixir:1.20 AS builder

ENV MIX_ENV=prod

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

# Dependencies first for layer caching. VERSION is deliberately NOT copied
# yet: mix.exs falls back to "0.0.0-dev" when it is missing, and copying it
# here would invalidate the expensive deps layers on every release bump
# (lesson from ../dashboard orbit/Dockerfile).
COPY phoenix/mix.exs phoenix/mix.lock ./
RUN mix deps.get --only prod

COPY phoenix/config/config.exs phoenix/config/prod.exs config/
RUN mix deps.compile

# Real version arrives after the deps cache; mix.exs reads ../VERSION.
COPY VERSION /VERSION

COPY phoenix/assets assets
COPY phoenix/priv priv
COPY phoenix/lib lib

# Compile first: phoenix-colocated assets (hooks/css) are emitted during
# compile and imported by app.css, so assets.deploy needs them present.
RUN mix compile && mix assets.setup && mix assets.deploy

COPY phoenix/config/runtime.exs config/
COPY phoenix/rel rel
RUN mix release

# ---- runtime ----------------------------------------------------------------
# Same Debian generation as elixir:1.20 (trixie) so libssl/libstdc++ match.
FROM debian:trixie-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates libncurses6 libstdc++6 openssl openssh-client tini wget \
    && rm -rf /var/lib/apt/lists/*

# ERL_CRASH_DUMP_SECONDS=0: in a container the dump lands in a layer nobody
# keeps and only delays the restart.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PHX_SERVER=true \
    PORT=80 \
    ERL_CRASH_DUMP_SECONDS=0

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/ssm ./
COPY VERSION /app/VERSION
COPY LICENSE /app/LICENSE
COPY THIRD-PARTY-LICENSES.md /app/THIRD-PARTY-LICENSES.md

RUN mkdir -p /app/db /app/keys /app/config /app/logs

EXPOSE 80

ARG VERSION
ARG VCS_REF
LABEL org.opencontainers.image.title="ssm" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.source="https://github.com/styliteag/ssm"

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD /app/bin/health-check.sh || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["/app/bin/start.sh"]
