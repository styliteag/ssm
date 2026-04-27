#!/bin/bash

# SSH Key Manager Development Startup Script (Python/FastAPI edition).
# Starts the Python backend + React frontend in development mode.
#
# Usage:
#   ./start-dev.sh                 # uses ./backend/.env if present
#   ./start-dev.sh path/to/datadir # looks for $datadir/config/.env
#
# Precedence for configuration (highest wins):
#   1. Environment variables already exported in your shell (SSH_KEY,
#      HTPASSWD, DATABASE_URL, JWT_SECRET, LOGLEVEL).
#   2. Variables in the resolved .env file. The file is loaded by the
#      backend on startup via python-dotenv. .env is gitignored, so it's
#      a safe place for personal dev settings.
#   3. Dev defaults this script auto-generates (admin/admin htpasswd,
#      throwaway ssh key, sqlite at backend/ssm.db).

CONFDIR=${1:-}

set -e

echo "🚀 Starting SSH Key Manager Development Environment"
echo

cleanup() {
    echo
    echo "🛑 Shutting down development servers..."
    jobs -p | xargs -r kill
    exit 0
}

trap cleanup SIGINT SIGTERM

if [ ! -f "backend/pyproject.toml" ]; then
    echo "❌ Python backend not found at ./backend/pyproject.toml."
    echo "   Run this script from the repository root."
    exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "❌ uv is required. Install it: https://docs.astral.sh/uv/getting-started/installation/"
    exit 1
fi

if [ ! -d "frontend/node_modules" ]; then
    echo "📦 Installing frontend dependencies..."
    (cd frontend && npm install)
fi

echo "📦 Syncing backend dependencies (uv)..."
(cd backend && uv sync --quiet)

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Resolve the .env path:
#   * $1 (CONFDIR) → $1/config/.env
#   * otherwise    → backend/.env
if [ -n "$CONFDIR" ]; then
    ABS_CONFDIR="$(cd "$CONFDIR" && pwd)"
    ENV_FILE="$ABS_CONFDIR/config/.env"
else
    ENV_FILE="$REPO_ROOT/backend/.env"
fi
export DOTENV="$ENV_FILE"

if [ -f "$ENV_FILE" ]; then
    echo "📝 Loading config from $ENV_FILE"
    echo "   ↳ Shell vars still override .env values."
else
    echo "📝 No .env at $ENV_FILE — using dev defaults."
    echo "   Drop a .env there (gitignored) to override; shell env still wins."
fi

# Read a value from the .env file for display purposes only — does not
# affect what the backend actually loads (python-dotenv handles that).
read_env_value() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 1
    awk -F= -v k="$key" '
        /^[[:space:]]*#/ { next }
        $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/^["'\'']|["'\'']$/, "")
            print
            exit
        }
    ' "$ENV_FILE"
}

env_has() {
    [ -n "$(read_env_value "$1")" ]
}

# JWT_SECRET is required. Auto-generate an ephemeral one if neither shell
# nor .env supplies one.
if [ -z "${JWT_SECRET:-}" ] && ! env_has "JWT_SECRET"; then
    export JWT_SECRET="dev-only-$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))' 2>/dev/null \
        || uv run --project backend python -c 'import secrets;print(secrets.token_urlsafe(32))')"
    echo "🔑 JWT_SECRET auto-generated for this dev session (tokens invalidate on restart)."
fi

# Dev defaults — only applied when neither the shell nor .env set them.
if [ -z "${DATABASE_URL:-}" ] && ! env_has "DATABASE_URL"; then
    export DATABASE_URL="sqlite+aiosqlite:///$REPO_ROOT/backend/ssm.db"
fi
if [ -z "${HTPASSWD:-}" ] && ! env_has "HTPASSWD"; then
    export HTPASSWD="$REPO_ROOT/backend/.htpasswd"
fi
if [ -z "${SSH_KEY:-}" ] && ! env_has "SSH_KEY"; then
    export SSH_KEY="$REPO_ROOT/backend/keys/id_ssm"
fi
: "${LOGLEVEL:=info}"
export LOGLEVEL

# Effective paths — either the shell env, the .env value, or the dev default.
EFFECTIVE_DATABASE_URL="${DATABASE_URL:-$(read_env_value DATABASE_URL)}"
EFFECTIVE_HTPASSWD="${HTPASSWD:-$(read_env_value HTPASSWD)}"
EFFECTIVE_SSH_KEY="${SSH_KEY:-$(read_env_value SSH_KEY)}"
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
