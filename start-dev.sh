#!/bin/bash

# SSH Key Manager Development Startup Script (Python/FastAPI edition).
# Starts the Python backend + React frontend in development mode.
#
# Usage:
#   ./start-dev.sh                 # uses ./backend/config.toml if present
#   ./start-dev.sh path/to/datadir # looks for $datadir/config/config.toml

CONFDIR=${1:-}

set -e

echo "🚀 Starting SSH Key Manager Development Environment"
echo

# Function to handle cleanup on exit
cleanup() {
    echo
    echo "🛑 Shutting down development servers..."
    jobs -p | xargs -r kill
    exit 0
}

trap cleanup SIGINT SIGTERM

# Sanity-check repo layout.
if [ ! -f "backend/pyproject.toml" ]; then
    echo "❌ Python backend not found at ./backend/pyproject.toml."
    echo "   Run this script from the repository root."
    exit 1
fi

# Check for uv — the backend package/runner.
if ! command -v uv >/dev/null 2>&1; then
    echo "❌ uv is required. Install it: https://docs.astral.sh/uv/getting-started/installation/"
    exit 1
fi

# Install frontend deps on first run.
if [ ! -d "frontend/node_modules" ]; then
    echo "📦 Installing frontend dependencies..."
    (cd frontend && npm install)
fi

# Install / sync backend venv.
echo "📦 Syncing backend dependencies (uv)..."
(cd backend && uv sync --quiet)

# Backend configuration.
BACKEND_ENV=()

if [ -n "$CONFDIR" ]; then
    ABS_CONFDIR="$(cd "$CONFDIR" && pwd)"
    echo "CONFIG: $ABS_CONFDIR/config/config.toml"
    BACKEND_ENV+=("CONFIG=$ABS_CONFDIR/config/config.toml")
fi

# JWT_SECRET is required. Auto-generate an ephemeral one for dev if unset.
if [ -z "${JWT_SECRET:-}" ]; then
    export JWT_SECRET="dev-only-$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))' 2>/dev/null \
        || uv run --project backend python -c 'import secrets;print(secrets.token_urlsafe(32))')"
    echo "🔑 JWT_SECRET auto-generated for this dev session (tokens invalidate on restart)."
fi

# Sensible defaults for a local dev checkout. Override via your shell env.
# All paths resolve to absolute so `cd backend` (below) doesn't break them.
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
: "${DATABASE_URL:=sqlite+aiosqlite:///$REPO_ROOT/backend/ssm.db}"
: "${HTPASSWD:=$REPO_ROOT/backend/.htpasswd}"
: "${SSH_KEY:=$REPO_ROOT/backend/keys/id_ssm}"
: "${LOGLEVEL:=info}"
export DATABASE_URL HTPASSWD SSH_KEY LOGLEVEL

# Run Alembic migrations against the dev DB on every start — safe, idempotent.
echo "🗄️  Applying database migrations..."
(cd backend && DATABASE_URL="$DATABASE_URL" uv run alembic upgrade head >/dev/null)

# Auto-create an .htpasswd with admin:admin if the file is missing.
if [ ! -f "$HTPASSWD" ]; then
    echo "👤 Creating dev .htpasswd with admin/admin at $HTPASSWD"
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -bBc "$HTPASSWD" admin admin
    else
        (cd backend && uv run python -c '
import bcrypt, sys
h = bcrypt.hashpw(b"admin", bcrypt.gensalt(rounds=12)).decode()
open(sys.argv[1], "w").write(f"admin:{h}\n")
' "$HTPASSWD")
    fi
fi

# Auto-generate an SSH key for the backend if missing.
if [ ! -f "$SSH_KEY" ]; then
    echo "🔐 Generating SSH key at $SSH_KEY (for connecting to managed hosts)"
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -q -C "ssm-dev"
    echo "    → public key: $SSH_KEY.pub"
fi

echo
echo "🐍 Starting Python/FastAPI backend (uvicorn, reload)..."
(cd backend && uv run uvicorn ssm.main:app --reload --host 0.0.0.0 --port 8000) &
BACKEND_PID=$!

# Give the backend a beat to bind its port before the frontend proxies to it.
echo "⏳ Waiting for backend to initialize..."
sleep 3

echo "⚛️  Starting React frontend (Vite)..."
(cd frontend && npm run dev) &
FRONTEND_PID=$!

echo
echo "✅ Development servers started successfully!"
echo "📱 Frontend: http://localhost:5173"
echo "🔧 Backend:  http://localhost:8000"
echo "📘 API docs: http://localhost:8000/api/v2/docs"
echo
echo "Default login (if .htpasswd was auto-generated):"
echo "   username: admin"
echo "   password: admin"
echo
echo "Press Ctrl+C to stop both servers"
echo

wait
