#!/bin/sh

# Minimal health check for SSH Key Manager
# Checks if ports 80 (nginx) and 8000 (backend) are accessible

set -e

# Check nginx on port 80
if ! wget --no-verbose --tries=1 --spider http://127.0.0.1:80 > /dev/null 2>&1; then
    echo "Port 80 not accessible"
    exit 1
fi

# Check backend on port 8000 (accept 404 as success)
if ! wget --quiet --tries=1 --timeout=5 --server-response http://127.0.0.1:8000 2>&1 | head -1 | grep -q "HTTP/"; then
    echo "Port 8000 not accessible"
    exit 1
fi

echo "OK"
