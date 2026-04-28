# CLAUDE.md

Guide Claude Code (claude.ai/code) for repo work.

## Development Commands

### Frontend (React + TypeScript + Vite)
```bash
cd frontend
npm run dev          # Start development server (http://localhost:5173)
npm run build        # Production build
npm run lint         # ESLint with TypeScript
npm run type-check   # TypeScript type checking without emit
```

### Backend (Python + FastAPI)
```bash
cd backend
uv sync                                     # Install/update dependencies
uv run uvicorn ssm.main:app --reload        # Dev server on :8000
uv run pytest                               # Run all tests
uv run pytest tests/unit/test_jwt.py        # Run a specific test file
uv run ruff check                           # Lint
uv run ruff format --check                  # Format check
uv run mypy --strict src                    # Type check
uv run alembic upgrade head                 # Apply migrations
uv run alembic revision -m "<description>"  # Create new migration
```

### Development Environment
```bash
./start-dev.sh              # Start both frontend and backend servers
```

### Database Operations
```bash
cd backend
uv run alembic upgrade head        # Apply all pending migrations
uv run alembic history --verbose   # Inspect migration history
uv run alembic downgrade -1        # Roll back one revision
```

A one-shot copier from a Diesel-era SQLite DB into a fresh Alembic-managed
DB lives at `backend/scripts/migrate_from_rust.py` (also wired up as
`just migrate-from-rust <source.db>`).

### Production Deployment
```bash
docker-compose -f docker/compose.prod.yml up --build
```

## Database Changes — Mandatory: use alembic

⚠️ **All schema change need alembic migration.** No edit `backend/src/ssm/db/models.py` (or ORM model) w/o matching migration in `backend/migrations/versions/`.

**Rules:**
- Make migration: `cd backend && alembic revision -m "<short description>"` (or `--autogenerate` if model already changed — always review SQL).
- Run `alembic upgrade head` local; verify clean apply on fresh DB + prod DB copy before commit.
- Give working `downgrade()` when can.
- New tables: check legacy-stamp path in `backend/migrations/env.py` still cover legacy (Diesel-era) DBs. `metadata.create_all(checkfirst=True)` make tables in model metadata; data backfills + non-reflected indexes need explicit work.
- Stage migration file + model change same commit, w/ `CHANGELOG.md` entry under `Changed`.
- No ad-hoc `metadata.create_all()` or hand `CREATE TABLE` on prod-shape DB outside reviewed alembic revision.

## CHANGELOG Maintenance — Mandatory

⚠️ **Every commit need `CHANGELOG.md` update.** Rule load-bearing — releases 1.1.4 to 1.1.7 ship empty cuz commits skip it, must backfill by hand.

**Rules:**
- Stage `CHANGELOG.md` w/ code change same commit (no follow-up).
- Add entry under `[Unreleased]` w/ Keep-a-Changelog section: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Write user-visible words (what change + why matter), no commit-msg phrasing.
- Pure chore/version-bump commit by `release.sh` no need entry — `release.sh` move `[Unreleased]` to new version section auto.

## Release Process

### Creating a New Release
Use auto release script for new versions:

```bash
# Create a patch release (bug fixes)
./release.sh patch

# Create a minor release (new features)
./release.sh minor

# Create a major release (breaking changes)
./release.sh major
```

### Release Workflow
Release steps:
1. **Validates**: Check working dir clean + builds pass
2. **Updates versions**: Update VERSION file + backend/Cargo.toml
3. **Commits**: Make version commit on current branch (usually main)
4. **Tags**: Make git tag (e.g., `v1.2.3`)
5. **Pushes**: Push branch + tag to origin
6. **Triggers CI**: Tag push auto trigger Docker builds

### GitHub Actions Release Pipeline
- **Trigger**: Git tags match `v*.*.*` (e.g., `v1.0.0`)
- **Cache Strategy**: GitHub Actions cache w/ branch continuity for best perf
- **Multi-arch**: Build AMD64 + ARM64
- **Registries**: Push Docker Hub + GitHub Container Registry
- **Manifests**: Multi-arch manifests w/ version, latest, semver tags

### Manual Release (Alternative)
```bash
# Update version manually
echo "1.2.3" > VERSION
sed -i 's/^version = ".*"/version = "1.2.3"/' backend/Cargo.toml

# Commit and tag
git add VERSION backend/Cargo.toml
git commit -m "chore: bump version to 1.2.3"
git tag -a v1.2.3 -m "Release version 1.2.3"

# Push (this triggers the build)
git push origin main
git push origin v1.2.3
```

## Authentication Setup

**🔐 CRITICAL**: App need auth for all API endpoints except login/logout.

### Initial Authentication Setup
```bash
cd backend
# Create htpasswd file with bcrypt encryption
htpasswd -cB .htpasswd admin

# Set JWT secret (32+ chars) for production. SESSION_KEY is accepted as
# a fallback for compatibility with old configs.
export JWT_SECRET="replace-me-with-a-long-random-string-32+chars"
```

### API Testing with curl
```bash
# Login → returns access + refresh tokens
TOKEN=$(curl -sX POST http://localhost:8000/api/v2/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}' \
  | jq -r '.data.access_token')

# Use the access token as a Bearer credential
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v2/hosts
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v2/users
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v2/keys

# Logout
curl -X POST http://localhost:8000/api/v2/auth/logout \
  -H "Authorization: Bearer $TOKEN"
```

### Security Implementation Notes
- All routes except `/api/v2/auth/login` and `/api/v2/auth/refresh` require a JWT access token via `Authorization: Bearer <token>`.
- Tokens are signed HS256 with `JWT_SECRET`; `type` (access/refresh) is in the payload so a refresh token cannot be used as an access token.
- Unauthenticated requests get `401` with envelope `error.code == "AUTH_REQUIRED"`.
- `SESSION_KEY` is accepted as a fallback for `JWT_SECRET` so old configs keep working.

### API Endpoint Structure
All API routes are mounted under `/api/v2/*` and use plural resource names:
- Hosts: `/api/v2/hosts`
- Users: `/api/v2/users`
- Keys: `/api/v2/keys`
- Authorizations: `/api/v2/authorizations`
- Activity log: `/api/v2/activity-log`
- Diffs: `/api/v2/diffs/*`
- Auth: `/api/v2/auth/{login,refresh,logout,me}`
- Server info: `/api/v2/info`

Every response uses the `ApiResponse[T]` envelope: `{success, data, error, meta}`. Frontends switch on `error.code` (a stable enum), not `error.message`.

## Architecture Overview

### Split Frontend/Backend Architecture
- **Frontend**: React 19 + TypeScript + Tailwind CSS, port 5173 (dev) / 80 (prod)
- **Backend**: Python 3.12 + FastAPI + uvicorn, port 8000
- **Database**: SQLite (default) via SQLAlchemy 2.0 async + Alembic migrations
- **Authentication**: JWT (HS256, access + refresh tokens) backed by an htpasswd file

### Key Backend Components
- **Routers** (`backend/src/ssm/api/v2/`): FastAPI routers per domain (auth, hosts, users, keys, authorizations, diffs, activity_log, info)
- **Database Models** (`backend/src/ssm/db/models.py`): SQLAlchemy 2.0 declarative models
- **SSH Client** (`backend/src/ssm/ssh/asyncssh_client.py`): asyncssh-based client with connection caching
- **Auth** (`backend/src/ssm/auth/`): JWT service + htpasswd store, exposed via `protected_router()`
- **Tests** (`backend/tests/`): pytest with `unit/` and `e2e/` subdirs; SSH calls hit a mock client so no real connections happen

### Frontend Architecture
- **State Management**: Zustand stores + React Context for auth/notifications/theme
- **API Layer** (`frontend/src/services/api/`): Central Axios API client w/ base config
- **Component Structure**: Reusable UI components (`ui/`), domain components, page-level components
- **Routing**: React Router w/ protected routes via AuthContext

### Core Data Flow
1. Frontend calls `/api/v2/*` REST endpoints with a Bearer JWT.
2. FastAPI dependency `get_current_user` verifies the token via `JwtService`.
3. Handlers run DB ops through SQLAlchemy 2.0 async sessions.
4. SSH ops go through `asyncssh` (with a connection cache) to remote hosts.
5. `authorized_keys` changes are tracked and previewable via the diff endpoints.

### Database Schema
- **Users**: SSH key owners
- **Hosts**: Remote servers to manage (`disabled` flag stop SSH ops)
- **Keys**: SSH public keys of users  
- **Authorizations**: Link users to hosts w/ specific remote usernames

### Host Disabling Feature
- **Database**: Hosts table has `disabled` bool field (default: false)
- **Backend Behavior**: 
  - Disabled hosts skip all SSH connection tries
  - `/api/diff/{host}` return "Host is disabled" no SSH ops
  - `/api/diff/{host}/sync` block sync w/ error msg
  - Connection status poll skip disabled hosts
- **Frontend Behavior**:
  - Show "Disabled" status w/ Ban icon in UI
  - No async load ops for disabled hosts
  - All SSH ops (test, sync, refresh) blocked + user feedback
- **Use Cases**: Maintenance windows, decommissioned servers, temp disconnect

### SSH Management System
- Uses `asyncssh` for SSH connections with an in-process connection cache
- Safety controls: `.ssh/system_readonly` + `.ssh/user_readonly` files on the remote host stop edits
- Test isolation via a mock SSH client — tests never reach real hosts

### Testing Infrastructure
- **Backend**: pytest under `backend/tests/{unit,e2e}/`; SSH calls are mocked
- **Run**: `cd backend && uv run pytest`; single test via `uv run pytest tests/unit/test_jwt.py::test_name`
- **Frontend**: No test framework yet

### Configuration
- Source: env vars only. A `backend/.env` (or path from `$DOTENV`) is loaded by python-dotenv on import; shell vars override `.env` values. There is no TOML loader.
- Authentication: `.htpasswd` file for user creds (bcrypt, auto-created if missing)
- Environment variables: `DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, `SSH_KEY_PASSPHRASE`, `SSH_TIMEOUT`, `JWT_SECRET` (or legacy `SESSION_KEY`), `LOGLEVEL`, `PORT`, `LISTEN`, `DOTENV`, `CORS_ORIGINS`, `VITE_API_URL`
- SSH key requirement: Server needs a valid SSH private key file (prints generation instructions if missing, or use `SSH_KEY` env var)
- Security: All API endpoints require auth except `/api/v2/auth/login` and `/api/v2/auth/refresh`

## Frontend/Backend Wire Format Notes

### `jump_via` field
`jump_via` travels as `int | null` on the wire. The Pydantic model
`UpdateHostRequest.jump_via: int | None` accepts JSON numbers or `null`
directly — there is no string-coercion deserializer (the Rust backend's
`empty_string_as_none_int` is gone).

In `frontend/src/components/HostEditModal.tsx` the form value is
converted from string to number once on submit; `hostsService.updateHost()`
sends the resulting `jump_via?: number | null`. Don't reintroduce
empty-string sentinels.

## Git Hooks Setup

**🔒 SECURITY**: Repo has git hooks to stop accidental commit of secrets, passwords, private keys.

### Initial Setup (Required for all developers)
```bash
# After cloning the repository, install the git hooks:
./install-hooks.sh
```

### What the hooks protect against:
- Private SSH keys (`-----BEGIN PRIVATE KEY-----`)
- API keys, secret keys, access tokens (20+ chars)
- Passwords (8+ chars)
- Session keys + JWT secrets
- Database URLs w/ embedded passwords
- Bearer tokens
- Password hashes (bcrypt format)

### Whitelist Configuration
Hooks use `.secrets-whitelist` for valid exceptions:

**File Patterns** (allow entire files):
```
*.example           # Example config files
*test*.rs          # Test files
README.md          # Documentation
```

**Specific Values** (allow known safe secrets):
```
VALUE:sk_test_12345678901234567890123456789012345678
VALUE:test-password-for-example-only
VALUE:ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB... test@example.com
```

### When commits are blocked:
1. **Remove real secrets** from staged files
2. **Add test/example files** to `.secrets-whitelist` file patterns
3. **Add known safe values** to `.secrets-whitelist` w/ `VALUE:` prefix
4. **Use env vars** for prod secrets

### Hook Management:
```bash
# Install/update hooks for all users
./install-hooks.sh

# Test hooks manually
git add <file-with-secrets> && git commit -m "test"

# View hook output
cat .git/hooks/pre-commit
```

## GitHub Server-Side Secret Protection

**🌐 MULTI-LAYER SECURITY**: Repo has local git hooks AND server-side GitHub protection.

### GitHub Secret Scanning Setup
1. **Enable GitHub Secret Scanning** (Repo Settings > Code security):
   - Secret scanning: ✅ Enabled
   - Push protection: ✅ Enabled  
   - Historical scanning: ✅ Enabled

2. **GitHub Actions Workflow** (`.github/workflows/security-scan.yml`):
   - Run TruffleHog OSS for secret detect
   - Run GitLeaks for more patterns
   - Custom pattern match for project-specific secrets
   - Dep vuln scan w/ Trivy
   - Verify git hooks infra

3. **Branch Protection Rules** (Recommended):
   ```bash
   # Require security scan to pass before merge
   gh api repos/:owner/:repo/branches/main/protection \
     --method PUT \
     --field required_status_checks='{"strict":true,"contexts":["Secret Detection"]}'
   ```

### Security Layers Overview:
```
Developer Commits
       ↓
🛡️ Local Git Hook (pre-commit)    ← Catches secrets before commit
       ↓
📤 Push to GitHub
       ↓  
🛡️ GitHub Secret Scanning        ← Server-side detection + push protection
       ↓
🛡️ GitHub Actions Workflow       ← Additional patterns + dependency scan
       ↓
🔒 Protected Branch Rules         ← Requires all checks to pass
       ↓
✅ Code merged to main branch
```

### When secrets are detected:
- **Local**: Git hook block commit + detailed output
- **GitHub Push**: Push protection stop push w/ secret detect
- **GitHub Actions**: PR/build fail w/ security scan results
- **Branch Protection**: Merge blocked til security checks pass

### Bypassing Protection (Emergency):
```bash
# Local only (NOT recommended):
git commit --no-verify -m "emergency fix"

# GitHub: Cannot bypass server-side protection
# Must remove secrets or add to whitelist properly
```

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes` or `query_graph` instead of Grep
- **Understanding impact**: `get_impact_radius` instead of manually tracing imports
- **Code review**: `detect_changes` + `get_review_context` instead of reading entire files
- **Finding relationships**: `query_graph` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview` + `list_communities`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
|------|----------|
| `detect_changes` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context` | Need source snippets for review — token-efficient |
| `get_impact_radius` | Understanding blast radius of a change |
| `get_affected_flows` | Finding which execution paths are impacted |
| `query_graph` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes` | Finding functions/classes by name or keyword |
| `get_architecture_overview` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes` for code review.
3. Use `get_affected_flows` to understand impact.
4. Use `query_graph` pattern="tests_for" to check coverage.
