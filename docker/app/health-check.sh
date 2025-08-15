#!/bin/sh

# Comprehensive health check for SSH Key Manager
# Checks nginx, Rust backend, and frontend static files

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 SSH Key Manager Health Check"
echo "==============================="

# Check 1: Nginx process
echo -n "1. Checking nginx process... "
if pgrep nginx > /dev/null; then
    echo -e "${GREEN}✓ Running${NC}"
else
    echo -e "${RED}✗ Not running${NC}"
    exit 1
fi

# Check 2: Nginx listening on port 80
echo -n "2. Checking nginx on port 80... "
if wget --no-verbose --tries=1 --spider http://127.0.0.1:80 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Responding${NC}"
else
    echo -e "${RED}✗ Not responding${NC}"
    exit 1
fi

# Check 3: Frontend static files
echo -n "3. Checking frontend static files... "
if [ -f "/usr/share/nginx/html/index.html" ]; then
    echo -e "${GREEN}✓ Present${NC}"
else
    echo -e "${RED}✗ Missing${NC}"
    exit 1
fi

# Check 4: Rust backend process (SSM)
echo -n "4. Checking SSH Key Manager backend process... "
if pgrep -f "ssm" > /dev/null; then
    echo -e "${GREEN}✓ Running${NC}"
else
    echo -e "${RED}✗ Not running${NC}"
    exit 1
fi

# Check 5: Backend responding on expected port
echo -n "5. Checking backend connectivity... "
# Try multiple potential endpoints since we don't know the exact health endpoint
backend_ok=false
for endpoint in "/health" "/api/health" "/authentication/status"; do
    if wget --no-verbose --tries=1 --spider "http://127.0.0.1:8000${endpoint}" > /dev/null 2>&1; then
        backend_ok=true
        break
    fi
done

if [ "$backend_ok" = true ]; then
    echo -e "${GREEN}✓ Responding${NC}"
else
    echo -e "${RED}✗ Not responding${NC}"
    exit 1
fi

# Check 6: Frontend served by nginx
echo -n "6. Checking frontend served by nginx... "
if wget --no-verbose --tries=1 --spider http://127.0.0.1:80/ > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Accessible${NC}"
else
    echo -e "${RED}✗ Not accessible${NC}"
    exit 1
fi

# Check 7: Database accessibility (optional check)
echo -n "7. Checking database file... "
if [ -f "/app/db/ssm.db" ] || [ -f "/app/ssm.db" ]; then
    echo -e "${GREEN}✓ Present${NC}"
else
    echo -e "${YELLOW}⚠ Not found (may be created on first run)${NC}"
fi

echo ""
echo -e "${GREEN}✅ All critical health checks passed!${NC}"
echo "SSH Key Manager is running properly."
echo ""
echo "Access points:"
echo "  • Frontend: http://localhost/"
echo "  • API: http://localhost/api/"
echo "  • Authentication: http://localhost/authentication/"