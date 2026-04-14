#!/bin/bash

# SSH Key Manager Development Startup Script (Python/FastAPI edition).
# Starts the Python backend + React frontend in development mode.
#
# Usage:
#   ./start-dev.sh                 # uses ./backend/config.toml if present
#   ./start-dev.sh path/to/datadir # looks for $datadir/config/config.toml
#
# Precedence for configuration (highest wins):
#   1. Environment variables set in your shell (SSH_KEY, HTPASSWD,
#      DATABASE_URL, JWT_SECRET, LOGLEVEL).
#   2. config.toml at the resolved CONFIG_FILE path. This file is in
#      .gitignore, so it's a safe place for your personal dev settings
#      like `[ssh] private_key_file = "/Users/you/.ssh/id_ssm"`.
#   3. Dev defaults this script auto-generates (admin/admin htpasswd,
#      throwaway ssh key, sqlite at backend/ssm.db).
#
# The script only ever touches disk (generates keys/htpasswd) if the
# effective path it chose doesn't exist yet.

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

# Paths resolve to absolute so `cd backend` (below) doesn't change their meaning.
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Resolve the config.toml path:
#   * $1 (CONFDIR) → $1/config/config.toml
#   * otherwise    → backend/config.toml
# If the file exists, the backend loads it. Env vars still win over TOML if set.
if [ -n "$CONFDIR" ]; then
    ABS_CONFDIR="$(cd "$CONFDIR" && pwd)"
    CONFIG_FILE="$ABS_CONFDIR/config/config.toml"
else
    CONFIG_FILE="$REPO_ROOT/backend/config.toml"
fi
export CONFIG="$CONFIG_FILE"

if [ -f "$CONFIG_FILE" ]; then
    echo "📝 Loading config from $CONFIG_FILE"
    echo "   ↳ Values in config.toml take precedence. Any env vars you set beforehand"
    echo "     (SSH_KEY, HTPASSWD, DATABASE_URL, JWT_SECRET, LOGLEVEL) still override it."
else
    echo "📝 No config.toml at $CONFIG_FILE — using dev defaults."
    echo "   Drop a config.toml there (gitignored) to override; shell env still wins."
fi

# JWT_SECRET is required. Auto-generate an ephemeral one for dev if unset AND
# config.toml doesn't supply one either.
if [ -z "${JWT_SECRET:-}" ] && ! grep -qs '^[[:space:]]*jwt_secret' "$CONFIG_FILE"; then
    export JWT_SECRET="dev-only-$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))' 2>/dev/null \
        || uv run --project backend python -c 'import secrets;print(secrets.token_urlsafe(32))')"
    echo "🔑 JWT_SECRET auto-generated for this dev session (tokens invalidate on restart)."
fi

# Dev defaults — only applied when neither the shell nor config.toml set them.
toml_has() {
    # crude but good enough: match `key = …` at top-level or inside [ssh].
    grep -qs "^[[:space:]]*$1[[:space:]]*=" "$CONFIG_FILE"
}

if [ -z "${DATABASE_URL:-}" ] && ! toml_has "database_url"; then
    export DATABASE_URL="sqlite+aiosqlite:///$REPO_ROOT/backend/ssm.db"
fi
if [ -z "${HTPASSWD:-}" ] && ! toml_has "htpasswd_path"; then
    export HTPASSWD="$REPO_ROOT/backend/.htpasswd"
fi
if [ -z "${SSH_KEY:-}" ] && ! toml_has "private_key_file"; then
    export SSH_KEY="$REPO_ROOT/backend/keys/id_ssm"
fi
: "${LOGLEVEL:=info}"
export LOGLEVEL

# Effective paths the backend will actually use — either the shell env, the
# config.toml value, or the dev default. We have to re-parse TOML to display
# them because the script doesn't load Python itself before this point.
read_toml_value() {
    local key="$1"
    [ -f "$CONFIG_FILE" ] || return 1
    uv run --project backend python - "$CONFIG_FILE" "$key" <<'PY' 2>/dev/null
import sys, tomllib
from pathlib import Path

with Path(sys.argv[1]).open("rb") as f:
    data = tomllib.load(f)

key = sys.argv[2]
value = data.get("ssh", {}).get(key) if key in ("private_key_file",) else data.get(key)
if value is not None:
    print(value)
PY
}

EFFECTIVE_DATABASE_URL="${DATABASE_URL:-$(read_toml_value database_url)}"
EFFECTIVE_HTPASSWD="${HTPASSWD:-$(read_toml_value htpasswd_path)}"
EFFECTIVE_SSH_KEY="${SSH_KEY:-$(read_toml_value private_key_file)}"
: "${EFFECTIVE_DATABASE_URL:=sqlite+aiosqlite:///$REPO_ROOT/backend/ssm.db}"
: "${EFFECTIVE_HTPASSWD:=$REPO_ROOT/backend/.htpasswd}"
: "${EFFECTIVE_SSH_KEY:=$REPO_ROOT/backend/keys/id_ssm}"

echo "   DATABASE_URL = $EFFECTIVE_DATABASE_URL"
echo "   HTPASSWD     = $EFFECTIVE_HTPASSWD"
echo "   SSH_KEY      = $EFFECTIVE_SSH_KEY"

# Run Alembic migrations against the dev DB on every start — safe, idempotent.
echo "🗄️  Applying database migrations..."
(cd backend && DATABASE_URL="$EFFECTIVE_DATABASE_URL" uv run alembic upgrade head >/dev/null)

# Auto-create an .htpasswd with admin:admin if the file is missing.
if [ ! -f "$EFFECTIVE_HTPASSWD" ]; then
    echo "👤 Creating dev .htpasswd with admin/admin at $EFFECTIVE_HTPASSWD"
    mkdir -p "$(dirname "$EFFECTIVE_HTPASSWD")"
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -bBc "$EFFECTIVE_HTPASSWD" admin admin
    else
        (cd backend && uv run python -c '
import bcrypt, sys
h = bcrypt.hashpw(b"admin", bcrypt.gensalt(rounds=12)).decode()
open(sys.argv[1], "w").write(f"admin:{h}\n")
' "$EFFECTIVE_HTPASSWD")
    fi
fi

# Auto-generate an SSH key for the backend if missing.
if [ ! -f "$EFFECTIVE_SSH_KEY" ]; then
    echo "🔐 Generating SSH key at $EFFECTIVE_SSH_KEY (for connecting to managed hosts)"
    mkdir -p "$(dirname "$EFFECTIVE_SSH_KEY")"
    ssh-keygen -t ed25519 -N '' -f "$EFFECTIVE_SSH_KEY" -q -C "ssm-dev"
    echo "    → public key: $EFFECTIVE_SSH_KEY.pub"
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
