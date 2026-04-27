#!/bin/sh
set -e

echo "Starting SSH Key Manager"
echo "Version: $(cat /app/VERSION 2>/dev/null || echo unknown)"

cleanup() {
    echo "Shutting down..."
    [ -n "$NGINX_PID" ] && kill -TERM "$NGINX_PID" 2>/dev/null || true
    [ -n "$SSM_PID" ]   && kill -TERM "$SSM_PID"   2>/dev/null || true
    wait
    exit
}
trap cleanup TERM INT

# Fix ownership of bind-mounted db directory so the runtime user can write.
# Picks up bind mounts left behind by the previous uid-1000 backend image.
chown -R "$(id -u):$(id -g)" /app/db

# Apply database migrations before serving traffic. Idempotent — Alembic
# stamps applied revisions in the alembic_version table, so re-runs are no-ops.
# Legacy databases inherited from the Rust/Diesel backend (schema present,
# no alembic_version) are detected and stamped inside migrations/env.py.
echo "Running database migrations..."
cd /app && alembic upgrade head

echo "Starting nginx reverse proxy on :80..."
nginx -t
nginx -g "daemon off;" &
NGINX_PID=$!

echo "Starting FastAPI backend on 127.0.0.1:8000..."
cd /app && uvicorn ssm.main:app --host 127.0.0.1 --port 8000 &
SSM_PID=$!

wait
