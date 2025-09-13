# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

## Release Process

#### CHANGELOG Maintenance
⚠️ **IMPORTANT**: Always update `CHANGELOG.md` when making commits!
- Add new changes under `[Unreleased]` section before committing
- Move to new version section when releasing
- Use semantic versioning format

### Creating a New Release
Use the automated release script to create new versions:

```bash
# Create a patch release (bug fixes)
./release.sh patch

# Create a minor release (new features)
./release.sh minor

# Create a major release (breaking changes)
./release.sh major
```

### Release Workflow
The release process:
1. **Validates**: Ensures working directory is clean and builds succeed
2. **Updates versions**: Updates VERSION file and backend/Cargo.toml
3. **Commits**: Creates a version commit on current branch (typically main)
4. **Tags**: Creates a git tag (e.g., `v1.2.3`)
5. **Pushes**: Pushes branch and tag to origin
6. **Triggers CI**: Tag push automatically triggers Docker image builds

### GitHub Actions Release Pipeline
- **Trigger**: Git tags matching `v*.*.*` (e.g., `v1.0.0`)
- **Cache Strategy**: Uses GitHub Actions cache with branch continuity for optimal performance
- **Multi-arch**: Builds for both AMD64 and ARM64 architectures
- **Registries**: Publishes to both Docker Hub and GitHub Container Registry
- **Manifests**: Creates multi-arch manifests with version, latest, and semantic version tags

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

**🔐 CRITICAL**: This application requires authentication for all API endpoints except login/logout.

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
- All routes except `/api/auth/*` require authentication via `require_auth()` function
- Session middleware validates cookies on every request
- Unauthenticated requests return `401 Unauthorized`
- Session keys should be set via `SESSION_KEY` environment variable in production

### API Endpoint Structure
The API uses singular resource names in the URL paths:
- Hosts: `/api/host` (not `/api/hosts`)
- Users: `/api/user` (not `/api/users`)  
- Keys: `/api/key` (not `/api/keys`)
- Authentication: `/api/auth/*`
- Authorization: `/api/authorization/*`
- Diff: `/api/diff/*`

## Architecture Overview

### Split Frontend/Backend Architecture
- **Frontend**: React 19 + TypeScript + Tailwind CSS served on port 5173 (dev) / 80 (prod)
- **Backend**: Rust + Actix Web REST API on port 8000
- **Database**: SQLite (default) with PostgreSQL/MySQL support via Diesel ORM
- **Authentication**: Session-based with htpasswd file integration

### Key Backend Components
- **Routes** (`backend/src/routes/`): RESTful API endpoints organized by domain (host, user, key, auth, authorization, diff)
- **Database Models** (`backend/src/db/`): Diesel ORM models for core entities
- **SSH Client** (`backend/src/ssh/`): Custom SSH client with caching (`CachingSshClient`) for remote host operations
- **Safety System** (`backend/src/tests/safety.rs`): Test-only SSH mock system preventing production system modification during testing

### Frontend Architecture
- **State Management**: Zustand stores + React Context for auth/notifications/theme
- **API Layer** (`frontend/src/services/api/`): Centralized Axios-based API client with base configuration
- **Component Structure**: Reusable UI components (`ui/`), domain components, and page-level components
- **Routing**: React Router with protected routes via AuthContext

### Core Data Flow
1. Frontend makes API calls to backend REST endpoints
2. Backend authenticates via session middleware
3. Backend performs database operations via Diesel ORM
4. For SSH operations, backend uses SSH client to connect to remote hosts
5. Changes to `authorized_keys` files are tracked and can be previewed via diff system

### Database Schema
- **Users**: SSH key owners
- **Hosts**: Remote servers to manage (with `disabled` flag to prevent SSH operations)
- **Keys**: SSH public keys belonging to users  
- **Authorizations**: Links users to hosts with specific remote usernames

### Host Disabling Feature
- **Database**: Hosts table includes `disabled` boolean field (default: false)
- **Backend Behavior**: 
  - Disabled hosts skip all SSH connection attempts
  - `/api/diff/{host}` returns "Host is disabled" without SSH operations
  - `/api/diff/{host}/sync` blocks sync attempts with error message
  - Connection status polling skips disabled hosts
- **Frontend Behavior**:
  - Shows "Disabled" status with Ban icon in UI
  - No async loading operations for disabled hosts
  - All SSH operations (test, sync, refresh) blocked with user feedback
- **Use Cases**: Maintenance windows, decommissioned servers, temporary disconnection

### SSH Management System
- Uses `russh` library for SSH connections
- Caching layer (`CachingSshClient`) to optimize multiple operations
- Safety controls: `.ssh/system_readonly` and `.ssh/user_readonly` files prevent modifications
- Test isolation via mock SSH client to prevent production system access during testing

### Testing Infrastructure
- **Backend**: Comprehensive test suite (107+ tests) with mock SSH client
- **Safety**: `src/tests/safety.rs` enforces test-only database/SSH operations
- **Test Categories**: HTTP endpoints, SSH integration, authentication, authorization, security
- All tests use mock SSH client - no real SSH connections during testing

### Configuration
- Main config: `config.toml` (optional - database URL, SSH private key, server settings)
- Authentication: `.htpasswd` file for user credentials (bcrypt encrypted, auto-created if missing)
- Environment variables: `DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, `SESSION_KEY` (take precedence over config file), `RUST_LOG`, `CONFIG`, `VITE_API_URL`
- SSH key requirement: Server requires valid SSH private key file (provides generation instructions if missing, or use `SSH_KEY` env var)
- Security: All API endpoints require authentication except `/api/auth/login` and `/api/auth/logout`

## Critical Frontend/Backend Data Type Compatibility Issues

### Jump Host (jump_via) Field Handling
**⚠️ CRITICAL**: The `jump_via` field requires special handling due to type system differences:

- **Backend Expectation**: `UpdateHostRequest.jump_via` field uses custom deserializer `empty_string_as_none_int` that expects a **STRING** which gets parsed to `Option<i32>`
  - Empty string `""` → `None` (no jump host)
  - Non-empty string like `"123"` → `Some(123)` (jump host with ID 123)

- **Frontend Type System**: `Host.jump_via` is typed as `number | undefined` in TypeScript

- **Solution Applied**: The `hostsService.updateHost()` function in `frontend/src/services/api/hosts.ts` automatically converts the `jump_via` field to string before sending to backend:
  ```typescript
  const requestData = {
    ...host,
    jump_via: host.jump_via !== undefined ? String(host.jump_via) : ''
  };
  ```

**Never modify the jump_via handling without ensuring compatibility between:**
1. Frontend TypeScript types (`Host.jump_via?: number`)
2. Backend Rust deserializer (`empty_string_as_none_int` expecting string)
3. The conversion logic in `hostsService.updateHost()`

## Git Hooks Setup

**🔒 SECURITY**: This repository includes git hooks to prevent accidental commit of secrets, passwords, and private keys.

### Initial Setup (Required for all developers)
```bash
# After cloning the repository, install the git hooks:
./install-hooks.sh
```

### What the hooks protect against:
- Private SSH keys (`-----BEGIN PRIVATE KEY-----`)
- API keys, secret keys, access tokens (20+ chars)
- Passwords (8+ chars)
- Session keys and JWT secrets
- Database URLs with embedded passwords
- Bearer tokens
- Password hashes (bcrypt format)

### Whitelist Configuration
The hooks use `.secrets-whitelist` for legitimate exceptions:

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
1. **Remove real secrets** from your staged files
2. **Add test/example files** to `.secrets-whitelist` file patterns
3. **Add known safe values** to `.secrets-whitelist` with `VALUE:` prefix
4. **Use environment variables** for production secrets

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

**🌐 MULTI-LAYER SECURITY**: The repository includes both local git hooks AND server-side GitHub protection.

### GitHub Secret Scanning Setup
1. **Enable GitHub Secret Scanning** (Repository Settings > Code security):
   - Secret scanning: ✅ Enabled
   - Push protection: ✅ Enabled  
   - Historical scanning: ✅ Enabled

2. **GitHub Actions Workflow** (`.github/workflows/security-scan.yml`):
   - Runs TruffleHog OSS for secret detection
   - Runs GitLeaks for additional patterns
   - Custom pattern matching for project-specific secrets
   - Dependency vulnerability scanning with Trivy
   - Verifies git hooks infrastructure

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
- **Local**: Git hook blocks commit with detailed output
- **GitHub Push**: Push protection prevents push with secret detected
- **GitHub Actions**: PR/build fails with security scan results
- **Branch Protection**: Merge blocked until security checks pass

### Bypassing Protection (Emergency):
```bash
# Local only (NOT recommended):
git commit --no-verify -m "emergency fix"

# GitHub: Cannot bypass server-side protection
# Must remove secrets or add to whitelist properly
```