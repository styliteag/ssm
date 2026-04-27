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

### Backend (Rust + Actix Web)
```bash
cd backend
cargo run                    # Start development server (http://localhost:8000)
cargo watch -x run          # Auto-reload development server
cargo test                  # Run all tests
cargo test test_name        # Run specific test
diesel migration run        # Apply database migrations
diesel migration generate <name>  # Create new migration
```

### Development Environment
```bash
./start-dev.sh              # Start both frontend and backend servers
```

### Database Operations
```bash
cd backend
diesel setup                # Initialize database
diesel migration run        # Apply migrations
```

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

# Set session key for production security
export SESSION_KEY="super-secret-session-key-for-production"
```

### API Testing with curl
```bash
# Login to establish session
curl -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}' \
  -c cookies.txt

# Use authenticated session for API calls
curl -b cookies.txt http://localhost:8000/api/host
curl -b cookies.txt http://localhost:8000/api/user
curl -b cookies.txt http://localhost:8000/api/key

# Logout when done
curl -X POST http://localhost:8000/api/auth/logout -b cookies.txt
```

### Security Implementation Notes
- All routes except `/api/auth/*` need auth via `require_auth()` func
- Session middleware check cookies every request
- No-auth requests get `401 Unauthorized`
- Set session keys via `SESSION_KEY` env var in prod

### API Endpoint Structure
API use singular resource names in URL:
- Hosts: `/api/host` (not `/api/hosts`)
- Users: `/api/user` (not `/api/users`)  
- Keys: `/api/key` (not `/api/keys`)
- Authentication: `/api/auth/*`
- Authorization: `/api/authorization/*`
- Diff: `/api/diff/*`

## Architecture Overview

### Split Frontend/Backend Architecture
- **Frontend**: React 19 + TypeScript + Tailwind CSS, port 5173 (dev) / 80 (prod)
- **Backend**: Rust + Actix Web REST API, port 8000
- **Database**: SQLite (default), PostgreSQL/MySQL via Diesel ORM
- **Authentication**: Session-based + htpasswd file

### Key Backend Components
- **Routes** (`backend/src/routes/`): RESTful API endpoints by domain (host, user, key, auth, authorization, diff)
- **Database Models** (`backend/src/db/`): Diesel ORM models for core entities
- **SSH Client** (`backend/src/ssh/`): Custom SSH client w/ caching (`CachingSshClient`) for remote host ops
- **Tests**: Inline `#[cfg(test)]` modules (e.g., in `ssh/sshclient.rs`, `main.rs`) — mock SSH client, no real conns

### Frontend Architecture
- **State Management**: Zustand stores + React Context for auth/notifications/theme
- **API Layer** (`frontend/src/services/api/`): Central Axios API client w/ base config
- **Component Structure**: Reusable UI components (`ui/`), domain components, page-level components
- **Routing**: React Router w/ protected routes via AuthContext

### Core Data Flow
1. Frontend call API to backend REST endpoints
2. Backend auth via session middleware
3. Backend do DB ops via Diesel ORM
4. SSH ops: backend use SSH client connect remote hosts
5. `authorized_keys` file changes tracked + previewable via diff system

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
- Use `russh` library for SSH conns
- Caching layer (`CachingSshClient`) for many ops
- Safety controls: `.ssh/system_readonly` + `.ssh/user_readonly` files stop edits
- Test isolation via mock SSH client stop prod system access in tests

### Testing Infrastructure
- **Backend**: Inline `#[cfg(test)]` modules w/ mock SSH client — no real SSH conns
- **Run**: `cargo test` from `backend/`; single test via `cargo test <name>`
- **Frontend**: No test framework yet

### Configuration
- Main config: `config.toml` (optional - DB URL, SSH private key, server settings)
- Authentication: `.htpasswd` file for user creds (bcrypt, auto-create if missing)
- Environment variables: `DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, `SESSION_KEY` (override config file), `RUST_LOG`, `CONFIG`, `VITE_API_URL`
- SSH key need: Server need valid SSH private key file (gives gen instructions if missing, or use `SSH_KEY` env var)
- Security: All API endpoints need auth except `/api/auth/login` + `/api/auth/logout`

## Critical Frontend/Backend Data Type Compatibility Issues

### Jump Host (jump_via) Field Handling
**⚠️ CRITICAL**: `jump_via` field need special handling cuz type system differs:

- **Backend Expectation**: `UpdateHostRequest.jump_via` field use custom deserializer `empty_string_as_none_int` expect **STRING** parsed to `Option<i32>`
  - Empty string `""` → `None` (no jump host)
  - Non-empty string like `"123"` → `Some(123)` (jump host w/ ID 123)

- **Frontend Type System**: `Host.jump_via` typed `number | undefined` in TypeScript

- **Solution Applied**: `hostsService.updateHost()` func in `frontend/src/services/api/hosts.ts` auto-convert `jump_via` to string before send backend:
  ```typescript
  const requestData = {
    ...host,
    jump_via: host.jump_via !== undefined ? String(host.jump_via) : ''
  };
  ```

**No modify jump_via handling w/o keeping compat between:**
1. Frontend TypeScript types (`Host.jump_via?: number`)
2. Backend Rust deserializer (`empty_string_as_none_int` expect string)
3. Conversion logic in `hostsService.updateHost()`

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