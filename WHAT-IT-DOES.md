# What It Does

This document provides a high-level overview of the Secure SSH Manager (ssm)
project for humans. It explains the purpose of the codebase, its main
components and how to get started. For detailed setup and development
instructions, see the project README.md.

## Purpose

Secure SSH Manager (ssm) is a Rust-based web application that centralizes
management of SSH public keys across multiple servers. It offers a user-
friendly web UI for adding, removing and rotating keys on remote hosts,
viewing diffs of `authorized_keys`, and scheduling automatic updates via
cron-style rules.

## Key Features

- **Web UI**: Browse hosts, view or edit their authorized_keys plate,
  see key diffs and history.
- **Authentication**: HTTP Basic auth via htpasswd and session cookies.
- **SSH Automation**: Uses the `russh` crate to connect and apply key changes
  on remote servers.
- **Scheduler**: Cron-style schedules to trigger periodic checks or updates.
- **Database**: SQLite (default) or PostgreSQL/MySQL via Diesel ORM with
  migrations.
- **Import Hosts**: Optional Python script to import entries from
  `~/.ssh/config` into the database.
- **Container & Nix Support**: Dockerfile and Nix flakes for reproducible
  builds and development.

## Architecture Overview

```text
ssm/                          # Project root
├── Cargo.toml                # Rust manifest and dependencies
├── build.rs                  # Embed static assets and migrations
├── config.toml               # Default configuration file (TOML)
├── convert_ssh_config.py     # Helper to import ~/.ssh/config entries
├── migrations/               # Diesel database migrations
├── src/                      # Rust source code
│   ├── main.rs               # Server setup and entry point
│   ├── scheduler.rs          # Cron-based job scheduler
│   ├── ssh/                  # SSH client and caching logic
│   ├── routes/               # Actix-web route handlers
│   ├── models.rs, schema.rs  # Diesel ORM models and schema
│   └── templates.rs          # Generated Askama templates
├── static/                   # CSS & JavaScript assets
├── templates/                # HTML templates for the web UI
├── Dockerfile                # Container image definition
├── justfile                  # Convenience task runner (just)
└── README.md                 # Detailed setup and developer guide
```

## Getting Started (Quickstart)

1. **Install prerequisites**:
   - Rust toolchain (stable)
   - SQLite or PostgreSQL/MySQL server
   - Diesel CLI (`cargo install diesel_cli --no-default-features --features sqlite`)
   - `htpasswd` (for Basic auth)

2. **Configure**:
   - Copy or edit `config.toml` to set `database_url`, listening `port`,
     `ssh.private_key_file`, cron schedules, etc.
   - Create an htpasswd file:
     ```sh
     htpasswd -Bc .htpasswd admin
     ```

3. **Initialize the database** (migrations will also run automatically on startup):
   ```sh
   diesel setup
   ```

4. **(Optional) Import hosts from SSH config**:
   ```sh
   ./convert_ssh_config.py
   ```

5. **Run the server**:
   ```sh
   cargo run
   ```

6. **Open the UI**:
   Visit `http://localhost:8080` and log in with your htpasswd user.

## Advanced Usage

- **Docker**:
  Build the Docker image:
  ```sh
  docker build -t ssm .
  ```

  Run the container:
  ```sh
  docker run -d \
    --name ssm \
    -p 8080:8080 \
    -v $(pwd)/config.toml:/app/config.toml \
    -v $(pwd)/.htpasswd:/app/.htpasswd \
    -v $(pwd)/ssm.sqlite:/app/ssm.sqlite \
    -v $(pwd)/id:/app/id:ro \
    ssm
  ```

- **Nix**:
  ```sh
  nix develop   # enters a shell with all dependencies
  just run      # or `cargo run`
  ```

- **Scheduling**:
  Adjust `ssh.check_schedule` and `ssh.update_schedule` in `config.toml`
  using cron syntax (supports 5 or 6 fields; seconds default to 0).

---

*Created by ssh-key-manager tooling.*