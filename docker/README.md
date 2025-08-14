# SSH Key Manager Docker Configuration

This directory contains the complete Docker configuration for the SSH Key Manager application, following a multi-stage build pattern that combines a React frontend with a Rust backend.

## Quick Start

1. **Prepare configuration and data**:
   ```bash
   # Copy your SSH private key for connecting to managed hosts
   cp ~/.ssh/id_rsa ./data/ssh-keys/
   
   # Create htpasswd file for authentication
   htpasswd -B -c ./data/auth/.htpasswd admin
   
   # Customize configuration if needed
   vi ./data/config/config.toml
   ```

2. **Build and run**:
   ```bash
   cd docker
   docker-compose up --build
   ```

3. **Access the application**:
   - Frontend: http://localhost
   - API: http://localhost/api/
   - Authentication: http://localhost/authentication/

## Architecture

### Multi-Stage Build
1. **Frontend Builder**: Node.js 24 Alpine builds the React application with Vite
2. **Backend Builder**: Rust 1.75 Alpine compiles the Actix-web backend
3. **Runtime**: Alpine Linux with nginx serving frontend and proxying to backend

### Components
- **Nginx**: Serves React static files on port 80, proxies API requests to backend
- **Rust Backend**: Actix-web server running on port 8000 inside container
- **Database**: SQLite database persisted in mounted volume
- **SSH Keys**: Mounted read-only from host for security

## Directory Structure

```
docker/
├── app/
│   ├── Dockerfile           # Multi-stage build definition
│   ├── nginx-main.conf      # Nginx configuration for frontend/API routing
│   └── health-check.sh      # Health check script for both services
├── data/                    # Persistent data (mounted volumes)
│   ├── db/                 # SQLite database files
│   ├── config/             # Application configuration
│   ├── auth/               # Authentication files (.htpasswd)
│   ├── ssh-keys/           # SSH private keys (read-only)
│   └── logs/               # Application logs
├── compose.yml             # Docker Compose configuration
└── README.md              # This file
```

## Configuration

### Required Files

Before running, ensure these files exist:

1. **SSH Private Key** (`./data/ssh-keys/id_rsa`):
   ```bash
   cp ~/.ssh/id_rsa ./data/ssh-keys/
   chmod 600 ./data/ssh-keys/id_rsa
   ```

2. **Authentication File** (`./data/auth/.htpasswd`):
   ```bash
   htpasswd -B -c ./data/auth/.htpasswd admin
   ```

3. **Configuration** (`./data/config/config.toml`):
   - Pre-configured for Docker environment
   - Customize SSH settings and hosts as needed

### Environment Variables

Set in `compose.yml`:
- `CONFIG=/app/config.toml` - Configuration file path
- `DATABASE_URL=sqlite:///app/db/ssm.db` - Database connection
- `RUST_LOG=info` - Logging level

### Volume Mounts

- `./data/db:/app/db` - Database persistence
- `./data/config/config.toml:/app/config.toml:ro` - Configuration (read-only)
- `./data/auth/.htpasswd:/app/.htpasswd:ro` - Authentication (read-only)
- `./data/ssh-keys:/app/keys:ro` - SSH keys (read-only for security)
- `./data/logs:/app/logs` - Application logs

## Health Checks

The health check script (`health-check.sh`) verifies:
1. Nginx process running
2. Nginx responding on port 80
3. Frontend static files present
4. Backend process running
5. Backend API responding
6. Frontend accessible through nginx
7. Database file present (optional)

## Production Considerations

### Security
- SSH keys are mounted read-only
- Configuration files are read-only
- Use strong passwords in `.htpasswd`
- Consider using secrets management for production

### Scaling
- Single container runs both frontend and backend
- Database is SQLite (consider PostgreSQL for multi-instance deployments)
- Nginx handles static file serving efficiently

### Monitoring
- Health checks every 60 seconds
- Logs sent to stdout/stderr for container logging
- Access logs available for monitoring

## Development

### Building
```bash
# Build without cache
docker-compose build --no-cache

# Build specific service
docker-compose build app
```

### Debugging
```bash
# View logs
docker-compose logs -f app

# Execute shell in container
docker-compose exec app sh

# Check health status
docker-compose exec app /app/health-check.sh
```

### Database Administration

Optional SQLite web interface (uncomment in `compose.yml`):
```bash
# Uncomment sqlite-web service in compose.yml
docker-compose up -d sqlite-web
# Access at http://localhost:81
```

## Troubleshooting

### Common Issues

1. **Permission Denied on SSH Keys**:
   ```bash
   chmod 600 ./data/ssh-keys/*
   ```

2. **Database Migration Issues**:
   ```bash
   # Remove database and restart
   rm -f ./data/db/ssm.db
   docker-compose restart app
   ```

3. **Frontend Not Loading**:
   - Check nginx logs: `docker-compose logs app | grep nginx`
   - Verify build completed: `docker-compose exec app ls /usr/share/nginx/html`

4. **Backend API Not Responding**:
   - Check backend logs: `docker-compose logs app | grep ssm`
   - Verify configuration: `docker-compose exec app cat /app/config.toml`

### Port Conflicts

If port 80 is in use:
```yaml
# In compose.yml, change port mapping
ports:
  - "8080:80"  # Use port 8080 instead
```

## Version Information

- Frontend: React with Vite build system
- Backend: Rust with Actix-web framework
- Database: SQLite with Diesel ORM
- Reverse Proxy: Nginx
- Container OS: Alpine Linux

For more information about the application itself, see the main project README.