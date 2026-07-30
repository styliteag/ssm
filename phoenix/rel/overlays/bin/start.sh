#!/bin/sh
# Container entrypoint — parity with the python image's start.sh contract:
# fix bind-mount ownership, migrate, then serve. PORT defaults to 80 via the
# image ENV; DATABASE_URL/HTPASSWD/SSH_KEY come from the operator.
set -e

echo "Starting SSM (Elixir)"
echo "Version: $(cat /app/VERSION 2>/dev/null || echo unknown)"

# Bind mounts inherited from earlier images may carry foreign ownership.
chown -R "$(id -u):$(id -g)" /app/db 2>/dev/null || true

echo "Running database migrations..."
/app/bin/migrate

echo "Starting server on :${PORT:-80}..."
exec /app/bin/server
