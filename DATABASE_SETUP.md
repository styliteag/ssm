# Database Setup Guide

This guide explains how to properly set up an empty database for the SSH Manager (SSM).

## What Happens with Empty Database

### Current Behavior (v0.2.x)
When you start with an empty database, the system:

1. ✅ **Migrations run automatically** via Diesel
2. ✅ **Tables are created** (host, user, user_key, authorization)  
3. ✅ **Backend starts successfully**
4. ✅ **Frontend loads** but shows no data (empty tables)
5. ✅ **All functionality works** - you can add hosts, users, keys

### Database Schema Created
```sql
-- Core tables created automatically:
host                    -- SSH hosts/servers
user                    -- SSH key owners  
user_key               -- SSH public keys
authorization          -- User access to specific hosts
__diesel_schema_migrations  -- Migration tracking
```

## How to Create Fresh Empty Database

### Method 1: Diesel Database Setup (Recommended)
```bash
cd backend

# Setup fresh database with all migrations
diesel database setup

# This creates:
# 1. Empty database file (if it doesn't exist)
# 2. Runs all migrations to create tables
# 3. Database ready for use
```

### Method 2: Manual Database File
```bash
cd backend

# Create empty database file
touch ssm.db

# Let backend run migrations on startup
# (Diesel will automatically run pending migrations)
cargo run
```

### Method 3: Reset Existing Database
```bash
cd backend

# ⚠️  WARNING: This deletes all data!
diesel database reset

# This will:
# 1. Drop existing database
# 2. Recreate empty database  
# 3. Run all migrations
# 4. Ready for fresh start
```

## Database Configuration

### Default Configuration
```toml
# config.toml
database_url = "sqlite://ssm.db"
```

### Custom Database Location
```bash
# Via environment variable
export DATABASE_URL="sqlite://./data/custom.db"
cargo run

# Via config file
# Edit config.toml:
database_url = "sqlite://./data/custom.db"
```

## First Time Setup Workflow

### 1. Fresh Installation
```bash
# Clone repository
git clone <repository>
cd ssm/backend

# Install Diesel CLI (if not already installed)
cargo install diesel_cli --no-default-features --features sqlite

# Setup database
diesel database setup

# Start backend
cargo run
```

### 2. Verify Database Setup
```bash
# Check tables were created
sqlite3 ssm.db ".tables"

# Expected output:
# __diesel_schema_migrations  user
# authorization               user_key  
# host

# Check migrations applied
sqlite3 ssm.db "SELECT version FROM __diesel_schema_migrations;"

# Expected output:
# 20240620111844
# 20241230001554  
# 20250113102408
# 20250906145959
```

### 3. Access Web Interface
1. Start backend: `cargo run` (port 8000)
2. Start frontend: `npm run dev` (port 5173)  
3. Navigate to http://localhost:5173
4. Login with credentials from `.htpasswd`
5. Begin adding hosts, users, and keys

## Migration Details

### Current Migrations Applied
1. **2024-06-20** - Initial database creation
2. **2024-12-30** - Allow null key fingerprints
3. **2025-01-13** - Rename user_in_host → authorization  
4. **2025-09-06** - Add disabled column to hosts

### What Each Migration Does
- **Migration 1**: Creates core tables (host, user, user_key, user_in_host)
- **Migration 2**: Makes key_fingerprint optional, adds address+port unique constraint
- **Migration 3**: Renames table and column for clarity (user_in_host.user → authorization.login)
- **Migration 4**: Adds disabled flag to hosts table

## Troubleshooting

### Database Locked Error
If you see "database is locked":
```bash
# Check for running processes
lsof ssm.db

# Kill any running backend processes
pkill ssm

# Restart backend
cargo run
```

### Migration Errors
If migrations fail:
```bash
# Check migration status
diesel migration list

# Force reset (⚠️  deletes data)
diesel database reset

# Manual migration run
diesel migration run
```

### Permission Issues
```bash
# Ensure database file is writable
chmod 644 ssm.db

# Ensure directory is writable  
chmod 755 $(dirname ssm.db)
```

## Authentication Setup

### Create Admin User
```bash
# Create htpasswd file
htpasswd -cB .htpasswd admin

# Set session key for production
export SESSION_KEY="your-secure-session-key"
```

### First Login
1. Navigate to http://localhost:5173
2. Login with admin credentials
3. System is ready for use

## Production Deployment

### Database Preparation
```bash
# Production database setup
DATABASE_URL="sqlite:///app/data/ssm.db" diesel database setup

# Set secure session key
export SESSION_KEY="$(openssl rand -base64 32)"

# Ensure proper permissions
chown app:app /app/data/ssm.db
chmod 644 /app/data/ssm.db
```

### Backup Strategy
```bash
# Regular backups
sqlite3 ssm.db ".backup backup-$(date +%Y%m%d).db"

# Before migrations/updates
cp ssm.db ssm.db.pre-update
```

## Summary

✅ **Empty database setup is fully automated**  
✅ **Diesel handles all migrations automatically**  
✅ **No manual SQL required**  
✅ **Backend starts successfully with empty DB**  
✅ **Frontend works with empty data**

The current migration system works correctly for fresh installations. For v1.0.0 release, consider consolidating migrations into a single baseline for cleaner setup.