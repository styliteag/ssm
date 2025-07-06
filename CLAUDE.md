# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SSM (Secure SSH Manager) is a Rust-based web application that manages SSH keys across multiple hosts. It provides a web UI for managing authorized_keys files on remote hosts via SSH connections.

## Development Commands

### Building and Running
- `cargo run` - Build and run the application
- `cargo build` - Build the project
- `just run` - Alternative run command using justfile
- `just watch` - Auto-recompile and run with cargo watch
- `just fmt` - Auto-format source code with treefmt

### Database Operations
- `diesel setup` - Initialize database (requires DATABASE_URL environment variable)
- `diesel migration run` - Run pending migrations
- Database migrations are located in `migrations/` directory

### Testing
- `cargo test` - Run tests
- Check `cargo build` to verify compilation after changes

## Architecture Overview

### Core Components
1. **Web Server** (`src/main.rs`): Actix-web server with session-based authentication
2. **SSH Client** (`src/ssh/`): Handles SSH connections to remote hosts using russh
3. **Database Layer** (`src/db/`): Diesel ORM for SQLite/PostgreSQL/MySQL
4. **Authentication** (`src/middleware.rs`, `src/routes/authentication.rs`): htpasswd-based auth with sessions
5. **Authorization** (`src/db/`): Manages user permissions and host access

### Key Data Models
- **Host**: Remote servers with SSH access details
- **User**: Application users with SSH public keys
- **Authorization**: Maps users to specific accounts on hosts
- **PublicUserKey**: SSH public keys associated with users

### SSH Management Flow
1. Connect to remote hosts via SSH (with optional jump hosts)
2. Deploy and execute `script.sh` on target hosts
3. Retrieve existing authorized_keys files
4. Compare with expected state from database
5. Generate and deploy updated authorized_keys files

## Configuration

### Required Setup Files
- `config.toml` - Main configuration (database, SSH keys, networking)
- `.htpasswd` - User authentication file (create with `htpasswd -B -c .htpasswd user`)
- SSH private key file for connecting to managed hosts

### Environment Variables
- `CONFIG` - Path to config file (default: `./config.toml`)
- `DATABASE_URL` - Database connection string
- `RUST_LOG` - Logging level (overrides config)

## Code Structure

### Database Schema (`src/schema.rs`)
- Diesel-generated schema definitions
- Supports SQLite (default), PostgreSQL, MySQL via features

### Routes (`src/routes/`)
- `authentication.rs` - Login/logout endpoints
- `authorization.rs` - User-host access management
- `host.rs` - Host management CRUD operations
- `user.rs` - User management CRUD operations  
- `key.rs` - SSH key management
- `diff.rs` - Key difference calculation and display

### SSH Operations (`src/ssh/`)
- `sshclient.rs` - Core SSH client implementation
- `caching_client.rs` - Caches SSH responses for performance
- `init.rs` - SSH connection initialization
- Remote script execution for authorized_keys management

### Templates (`templates/`)
- Askama templates for HTML rendering
- Organized by feature (hosts, users, keys, authentication)

## Development Patterns

### Logging Conventions
- Use structured logging with module paths: `ssm::module::function`
- Debug level for detailed flow information
- Info level for significant events
- Warn level for normal operational messages

### Error Handling
- Database errors are logged and converted to generic user messages
- SSH connection errors are handled gracefully with retries
- Authentication failures redirect to login page

### Security Considerations
- All routes require authentication except `/authentication/*`
- SSH connections use key-based authentication
- Session management with secure cookies
- Foreign key constraints enabled in SQLite

## File Management
- `static/` - CSS and JavaScript assets
- `target/` - Rust build artifacts (ignored)
- `*.db*` files - SQLite database files
- `justfile` - Task runner configuration
- `Dockerfile` - Container deployment configuration

## Common Development Tasks

### Adding New Routes
1. Create handler function in appropriate `src/routes/` module
2. Add route configuration in module's `config()` function
3. Include module in `src/routes/mod.rs`
4. Create corresponding HTML templates if needed

### Database Changes
1. Create migration: `diesel migration generate <name>`
2. Write up/down SQL in migration files
3. Run migration: `diesel migration run`
4. Update `src/schema.rs` if needed

### SSH Operations
- All SSH commands go through `SshClient` or `CachingSshClient`
- Use connection pooling for database operations
- Handle SSH errors gracefully with user-friendly messages

## UI/UX Development Guide

### Theme System
- **CSS Variables**: Use standardized theme variables in `static/style.css`
  - Light/Dark themes: `--text-color`, `--bg-color`, `--bg-color-alt`, `--border-color`
  - Accent colors: `--accent-primary`, `--accent-secondary`, `--accent-success`, `--accent-warning`, `--accent-danger`
  - Hover states: `--hover-primary`, `--hover-secondary`
- **Theme Toggle**: JavaScript theme manager in `static/forms.js` with localStorage persistence
- **Implementation**: Use `data-theme` attribute on `<html>` element

### Dialog System
- **Standard Structure**: All dialogs follow consistent pattern:
  ```html
  <dialog class="edit-dialog">
      <p class="dialog-title">Title Here</p>
      <hr>
      <form hx-post="/endpoint" hx-swap="none">
          <div class="form-container">
              <div class="form-grid form-grid-wide">
                  <div class="form-group form-group-full">
                      <label>Label:</label>
                      <input type="text" autocomplete="off">
                      <small class="form-help">Help text</small>
                  </div>
              </div>
              <div class="form-actions">
                  <button type="button" class="button button-secondary">Cancel</button>
                  <button type="submit" class="button">Save Changes</button>
              </div>
          </div>
      </form>
  </dialog>
  ```

### Key Dialog Locations
- **Host Management**: 
  - Main page: `templates/hosts/index.html`
  - Add dialog: `templates/hosts/add_dialog.htm`
  - Edit dialog: `templates/hosts/edit_host.html`
- **User Management**:
  - Main page: `templates/users/index.html`  
  - Add dialog: `templates/users/add_dialog.htm`
- **SSH Key Management**:
  - Main page: `templates/keys/index.html` (contains inline edit dialogs)
  - Delete dialog: `templates/keys/delete_key_dialog.htm`
- **Form Response Builder**: `templates/forms/form_response.html`

### CSS Class Standards
- **Buttons**: `.button` (primary), `.button-secondary`, `.button-small`
- **Forms**: `.form-container`, `.form-grid`, `.form-group`, `.form-actions`, `.form-help`
- **Layouts**: `.form-grid-wide` (2-column), `.form-group-full` (span all columns)
- **Dialog**: `.dialog-title`, custom dialog classes (`.edit-dialog`, etc.)

### Searchable Select Implementation
- **Pattern**: Use `<input type="text" list="datalist-id">` with `<datalist>`
- **JavaScript**: Auto-population and search functionality in `static/forms.js`
- **CSS**: Force left alignment with `text-align: left !important; direction: ltr;`

### Password Manager Prevention
- **Attributes**: Add `autocomplete="off"` and `data-1p-ignore` to inputs
- **Use Cases**: Username fields, search fields, technical inputs

### Common Issues & Solutions
- **Text Alignment**: For searchable inputs, use multiple CSS rules with `!important`
- **Dialog Width**: Use `min-width` and `max-width` with `form-grid-wide` for optimal layout
- **Theme Variables**: Always use CSS variables, never hardcode colors
- **Button Consistency**: Use standard button classes, avoid custom styling

### File Search Patterns
- **Routes**: Look in `src/routes/` - each feature has its own module
- **Templates**: Organized by feature in `templates/` subdirectories
- **Dialogs**: Often inline in main templates or separate `.htm` files
- **CSS**: Global styles in `static/style.css`, component styles in template `<style>` blocks
- **JavaScript**: Theme and form logic in `static/forms.js`