# Changelog

All notable changes to SSM (Secure SSH Manager) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Comprehensive CHANGELOG.md file for tracking all changes
- Automatic CHANGELOG.md updates in release.sh script

## [0.2.17] - 2025-09-13

### Added
- **Environment Variable Support**: Full support for `DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, and `SESSION_KEY` environment variables that take precedence over config file settings
- **Automatic Htpasswd Creation**: Server automatically creates htpasswd file with random admin password if none exists, displayed in beautiful ASCII art during startup
- **Enhanced SSH Key Error Handling**: Detailed error messages with step-by-step SSH key generation instructions using ed25519 keys
- **Comprehensive Startup Logging**: Server now logs database URL, htpasswd path, SSH key path, and log level during startup for transparency
- **Config File Optional**: Server can start without `config.toml` using sensible defaults and environment variables
- **Docker Environment Configuration**: Proper environment variable setup in docker-compose.yml with detailed comments

### Changed
- **Configuration Loading**: Environment variables now override config file settings for all critical paths
- **Default SSH Key Path**: Changed from `/app/id` to `keys/id_ssm` for better Docker compatibility
- **Error Messages**: All error messages now use beautiful box drawing characters for better readability
- **Documentation**: Updated README.md, CLAUDE.md, and config examples with comprehensive environment variable documentation

### Fixed
- **CORS Configuration**: Confirmed that `cors_origins` config setting is unused (server uses hardcoded localhost origins)
- **SSH Key Path Resolution**: Consistent default paths across development and Docker environments

### Security
- **Automatic Password Generation**: Secure random password generation using cryptographically secure RNG
- **Bcrypt Hashing**: All auto-generated passwords use proper bcrypt hashing with default cost factor

## [0.2.16] - 2025-09-13

### Changed
- Update .gitignore to exclude backup files with .bak extension

### Fixed
- Reposition logout button in sidebar for improved accessibility
- Move logout button under user info section in sidebar

## [0.2.15] - 2025-09-13

### Changed
- Update Nginx configuration to comment out rate limiting for SSH and API endpoints

## [0.2.14] - 2025-09-13

### Refactored
- Enhance authorization mapping in UsersPage for type safety
- Update UsersPage to use RawAuthorizationResponse type for improved type safety

## [0.2.13] - 2025-09-13

### Fixed
- Resolve TypeScript compilation errors for production build

### Changed
- Update dependencies in package.json and package-lock.json
- Update Cargo.toml dependency versions
- Remove deprecated test files and modules

### Security
- Remove git-secure wrapper script that enforced SSH commit signing
- Enforce SSH commit signing and update dependencies

## [0.2.12] - 2025-09-XX

## [0.2.11] - 2025-09-XX

## [0.2.10] - 2025-09-XX

---

## Development Notes

### How to Update This Changelog

1. **Before committing**: Add new changes under `[Unreleased]` section
2. **When releasing**: Move `[Unreleased]` items to new version section with date
3. **Version format**: Use semantic versioning (MAJOR.MINOR.PATCH)
4. **Categories**:
   - `Added` for new features
   - `Changed` for changes in existing functionality
   - `Deprecated` for soon-to-be removed features
   - `Removed` for now removed features
   - `Fixed` for any bug fixes
   - `Security` for vulnerability fixes

### Recent Changes Made (2025-09-13 Session)

This changelog was created as part of a major enhancement session that included:
- Environment variable configuration system
- Auto-generation of credentials
- Improved error handling and user experience
- Docker configuration improvements
- Comprehensive documentation updates

**Note to self**: Always update CHANGELOG.md when making significant changes. Use the git history to reconstruct changes if needed.</contents>
</xai:function_call">Create CHANGELOG.md with comprehensive documentation of all changes.
