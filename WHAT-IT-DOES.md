# What It Does

This document provides a high-level overview of the Secure SSH Manager (ssm)
project for humans. It explains the purpose of the codebase, its main
components and how to get started. For detailed setup and development
instructions, see the project README.md.

## Purpose

Secure SSH Manager (SSM) is a modern web application that centralizes
management of SSH public keys across multiple servers. It provides a
user-friendly web interface for adding, removing and rotating keys on
remote hosts, viewing diffs of `authorized_keys`, and scheduling automatic
updates via cron-style rules.

The application is built with a modern split architecture featuring a
React frontend and Rust backend for optimal performance and maintainability.

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

The application uses a modern split architecture with separate frontend and backend services:

### Frontend (`frontend/`)
- **Framework**: React 19 with TypeScript
- **Styling**: Tailwind CSS with component library
- **State Management**: Zustand + React Context
- **Build**: Vite for fast development and production builds

### Backend (`backend/`)
- **Framework**: Rust + Actix Web
- **Database**: SQLite (default) with PostgreSQL/MySQL support
- **Authentication**: Session-based with htpasswd
- **SSH Client**: russh for remote host connections

### Project Structure
```text
ssh-key-manager/
├── frontend/                 # React frontend application
│   ├── src/
│   │   ├── components/      # Reusable React components
│   │   ├── pages/          # Route components
│   │   ├── services/       # API communication
│   │   └── types/          # TypeScript definitions
│   ├── package.json
│   └── vite.config.ts
├── backend/                  # Rust API backend
│   ├── src/
│   │   ├── main.rs          # Server setup and entry point
│   │   ├── middleware.rs    # Authentication middleware
│   │   ├── routes/          # API endpoint handlers
│   │   ├── ssh/             # SSH client and caching logic
│   │   ├── db/              # Database models
│   │   └── scheduler.rs     # Cron-based job scheduler
│   ├── migrations/          # Database migrations
│   ├── Cargo.toml
│   └── config.toml
├── docker/                   # Docker deployment configuration
├── start-dev.sh              # Development environment startup
└── README.md                 # Detailed setup guide
```

## Getting Started (Quickstart)

1. **Install prerequisites**:
   - Rust toolchain (stable)
   - Node.js (18+)
   - SQLite or PostgreSQL/MySQL server
   - Diesel CLI (`cargo install diesel_cli --no-default-features --features sqlite`)
   - `htpasswd` (for authentication)

2. **Set up backend**:
   - Navigate to `backend/` directory
   - Copy or edit `config.toml` to set `database_url`, listening `port`,
     `ssh.private_key_file`, cron schedules, etc.
   - Create an htpasswd file:
     ```sh
     htpasswd -Bc .htpasswd admin
     ```
   - Initialize the database:
     ```sh
     cd backend
     diesel setup
     diesel migration run
     ```

3. **Set up frontend**:
   - Navigate to `frontend/` directory
   - Install dependencies:
     ```sh
     cd frontend
     npm install
     ```

4. **Run development servers**:
   ```sh
   # From project root
   ./start-dev.sh
   ```

5. **Open the UI**:
   - Frontend: `http://localhost:5173`
   - Backend API: `http://localhost:8000`

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