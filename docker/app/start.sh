#!/bin/sh
set -e

echo "Starting SSH Key Manager"
echo "Version: $(cat /app/VERSION 2>/dev/null || echo unknown)"

# Initialize database directory
mkdir -p /app/db
export DATABASE_URL="${DATABASE_URL:-sqlite:///app/db/ssm.db}"

# Function to handle shutdown gracefully
cleanup() {
    echo "Shutting down..."
    kill -TERM $NGINX_PID 2>/dev/null || true
    kill -TERM $SSM_PID 2>/dev/null || true
    wait
    exit
}
trap cleanup SIGTERM SIGINT

# Start nginx in background
echo "Starting nginx reverse proxy..."
echo "Nginx Config:"
nginx -t && nginx -g "daemon off;" &
NGINX_PID=$!
sleep 2

# Start backend server in background
echo "Starting SSH Key Manager backend..."
cd /app && ./ssm &
SSM_PID=$!

# Wait for both processes
wait
