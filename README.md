# Secure SSH Manager (SSM)

> [!NOTE]
> This is pre-release software. Use at your own risk.

A modern web application for managing SSH keys across multiple hosts with a **React frontend** and **Rust API backend**.

## 🚀 Quick Start

### Development Environment

Start both frontend and backend development servers:

```bash
./start-dev.sh
```

- **Frontend**: http://localhost:5173 (React + Vite)
- **Backend API**: http://localhost:8000 (Rust + Actix Web)

### Production Deployment

Deploy with Docker:

```bash
docker-compose -f docker/compose.prod.yml up --build
```

- **Application**: http://localhost/ (nginx serves frontend, proxies API)

## 📋 Overview

SSH Key Manager provides a web interface for managing `authorized_keys` files on remote hosts via SSH connections. The application has been refactored from a monolithic Rust application to a modern distributed architecture:

- **Frontend**: React + TypeScript + Tailwind CSS
- **Backend**: Rust + Actix Web REST API  
- **Database**: SQLite (with PostgreSQL/MySQL support)
- **Deployment**: Multi-stage Docker build with nginx proxy
- **Authentication**: Session-based with htpasswd integration

## 🏗️ Architecture

### Frontend (`frontend/`)
- **Framework**: React 19 with TypeScript
- **Styling**: Tailwind CSS with custom component library
- **State Management**: Zustand + React Context
- **Routing**: React Router with protected routes
- **Build Tool**: Vite for fast development and production builds
- **API Communication**: Axios with centralized service layer

### Backend (`backend/`)
- **Framework**: Rust + Actix Web
- **Database**: Diesel ORM (SQLite/PostgreSQL/MySQL)
- **Authentication**: Session-based with htpasswd files
- **SSH Client**: russh for remote host connections
- **API Design**: RESTful JSON endpoints with structured responses

### Deployment
- **Multi-stage Docker**: Frontend build → Backend build → Combined runtime
- **Web Server**: nginx serves React app and proxies API requests
- **Single Container**: Simplified deployment with internal service communication
- **Health Checks**: Built-in monitoring and health endpoints

## 🛠️ Development Setup

### Prerequisites

- **Rust** (1.75+) with Cargo
- **Node.js** (24+) with npm
- **Docker** (optional, for deployment)
- **htpasswd** utility (for authentication)

### Initial Setup

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd ssm
   ```

2. **Set up authentication**:
   ```bash
   htpasswd -B -c .htpasswd admin
   ```

3. **Configure the application**:
   Create `config.toml` (see [Configuration](#configuration) section)

4. **Set up the database** (from `backend/` directory):
   ```bash
   cd backend
   cargo install diesel_cli --no-default-features --features sqlite
   diesel setup
   diesel migration run
   cd ..
   ```

5. **Install frontend dependencies**:
   ```bash
   cd frontend
   npm install
   cd ..
   ```

### Development Workflow

#### Start Development Servers
```bash
# Start both frontend and backend
./start-dev.sh

# Or start individually:
# Backend (from backend/ directory)
cd backend && cargo run

# Frontend (from frontend/ directory)  
cd frontend && npm run dev
```

#### Frontend Development
```bash
cd frontend

# Start dev server
npm run dev

# Build for production
npm run build

# Lint and type check
npm run lint
npm run type-check
```

#### Backend Development
```bash
cd backend

# Run with auto-reload
cargo watch -x run

# Run tests
cargo test

# Database operations
diesel migration run
diesel migration generate <name>
```

## 🐳 Docker Deployment

### Production Deployment

```bash
# Build and start production stack
docker-compose -f docker/compose.prod.yml up --build

# Run in background
docker-compose -f docker/compose.prod.yml up -d --build
```

### Development with Docker

```bash
# Start development stack
docker-compose -f docker/compose.yml up --build
```

### Docker Architecture

The multi-stage build process:

1. **Frontend Build Stage**: Builds React application with Vite
2. **Backend Build Stage**: Compiles Rust application with optimizations
3. **Runtime Stage**: Combines built assets with nginx + Alpine Linux

**Container Structure**:
- nginx serves React frontend from `/usr/share/nginx/html`
- nginx proxies `/api/*` requests to Rust backend on port 8000
- Single container exposes port 80 for all web traffic
- Persistent volumes for database, configuration, and SSH keys

## ⚙️ Configuration

### Main Configuration (`config.toml`)

```toml
# Database URL (SQLite default)
database_url = "sqlite://ssm.db"

# API server configuration
listen = "127.0.0.1"
port = 8000

# Logging level
loglevel = "info"

[ssh]
# Path to private key for SSH connections
private_key_file = "/path/to/ssh/private/key"

# Optional passphrase
private_key_passphrase = "optional_passphrase"
```

### Environment Variables

- `CONFIG` - Path to config file (default: `./config.toml`)
- `DATABASE_URL` - Database connection string
- `RUST_LOG` - Logging level (overrides config)
- `VITE_API_URL` - Frontend API URL (for production builds)
- `SESSION_KEY` - Secure session signing key (production required)

### Authentication Setup

**🔐 IMPORTANT**: Authentication is required for all API endpoints except login/logout.

```bash
# Create htpasswd file with bcrypt encryption
htpasswd -cB .htpasswd admin

# Add additional users
htpasswd -B .htpasswd another_user

# Set secure session key for production
export SESSION_KEY="your-super-secret-session-key-change-in-production"
```

**Security Notes:**
- All API requests (except authentication) require session-based authentication
- Session cookies are `HttpOnly` and secure
- bcrypt encryption is used for password storage
- Unauthenticated requests return `401 Unauthorized`

### Docker Environment

When using Docker, place configuration files in `docker/data/`:

```
docker/data/
├── auth/.htpasswd          # Authentication file
├── config/config.toml      # Main configuration
├── ssh-keys/              # SSH private keys
├── db/                    # Database files
└── logs/                  # Application logs
```

## 🔧 API Documentation

For detailed API documentation including all endpoints, authentication, and examples, see [API_DOCUMENTATION.md](backend/API_DOCUMENTATION.md).

## 📁 Project Structure

```
ssm/
├── frontend/                 # React frontend application
│   ├── src/
│   │   ├── components/      # Reusable React components
│   │   ├── pages/          # Route components
│   │   ├── services/       # API communication
│   │   ├── contexts/       # React contexts
│   │   └── types/          # TypeScript definitions
│   ├── package.json
│   └── vite.config.ts
├── backend/                 # Rust API backend
│   ├── src/
│   │   ├── routes/         # API endpoint handlers
│   │   ├── db/            # Database models
│   │   ├── ssh/           # SSH client implementation
│   │   └── api_types.rs   # API request/response types
│   ├── migrations/        # Database migrations
│   └── Cargo.toml
├── docker/                 # Docker deployment configuration
│   ├── app/Dockerfile     # Multi-stage build configuration
│   ├── compose.prod.yml   # Production deployment
│   └── data/             # Persistent data volumes
├── start-dev.sh           # Development environment startup
├── config.toml           # Application configuration
└── README.md
```

## 🔐 Security Features

**🛡️ Comprehensive Security Implementation:**

- **🔒 Required Authentication**: All API endpoints (except login) require session-based authentication
- **🍪 Secure Sessions**: HttpOnly cookies with session signing keys for protection
- **🔐 bcrypt Encryption**: Industry-standard password hashing for user credentials
- **⚡ Session Validation**: Real-time authentication checks on every API request
- **🚫 Unauthorized Access**: 401 responses for unauthenticated requests
- **🔑 SSH Key Security**: Key-based authentication for all remote SSH connections
- **✅ Input Validation**: Comprehensive validation and sanitization of all API inputs
- **🗄️ Database Security**: Prepared statements and foreign key constraints
- **🌐 CORS Configuration**: Controlled cross-origin resource sharing for frontend integration

**Authentication Flow:**
1. Login with `.htpasswd` credentials → Session cookie issued
2. Include session cookie in subsequent API requests
3. Server validates session on every protected endpoint
4. Logout to invalidate session

## 🚫 SSH Key Management Controls

### Host Disabling
- **Disabled Hosts**: Mark hosts as `disabled` to prevent all SSH operations
- **Use Cases**: Maintenance windows, decommissioned servers, temporary disconnection
- **Effects**: No SSH connections, no polling, no diff operations, no syncing

### Readonly Controls
Prevent SSM from modifying keyfiles by creating control files:

- **`.ssh/system_readonly`**: Disables updates for all keyfiles on the host
- **`.ssh/user_readonly`**: Disables updates for specific user keyfiles

Optional: Include a reason in the file that will be displayed in the UI.

## 🤝 Contributing

### Development Guidelines

1. **API-First Development**: Design API endpoints before frontend implementation
2. **Type Safety**: Use TypeScript for frontend and structured types for backend
3. **Component Reusability**: Build modular React components
4. **Error Handling**: Implement comprehensive error handling and user feedback
5. **Testing**: Write tests for both frontend and backend components

### Code Style

- **Frontend**: ESLint + TypeScript for code quality
- **Backend**: `cargo fmt` and `cargo clippy` for Rust code
- **Consistent Naming**: Use clear, descriptive names for variables and functions

### Pull Request Process

1. Fork the repository and create a feature branch
2. Implement changes with appropriate tests
3. Ensure both frontend and backend build successfully
4. Update documentation if needed
5. Submit pull request with clear description

## 📄 License

This project is licensed under GPL-3.0. See LICENSE.txt for details.

## 🔗 Links

- **Repository**: https://github.com/styliteag/ssm
- **Issues**: Report bugs and feature requests
- **Documentation**: Additional documentation in `/docs` (coming soon)

---

For technical implementation details, see [CLAUDE.md](CLAUDE.md) for development guidance.