#!/bin/bash

# SSH Key Manager Docker Setup Script
# This script helps set up the required configuration for running SSH Key Manager in Docker

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 SSH Key Manager Docker Setup${NC}"
echo "=================================="
echo

# Check if we're in the right directory
if [ ! -f "compose.yml" ]; then
    echo -e "${RED}Error: Please run this script from the docker/ directory${NC}"
    exit 1
fi

# Create data directories
echo -e "${BLUE}📁 Creating data directories...${NC}"
mkdir -p data/{db,config,auth,ssh-keys,logs}
echo -e "${GREEN}✓ Data directories created${NC}"

# Check if SSH key exists
echo -e "${BLUE}🔑 Setting up SSH keys...${NC}"
if [ ! -f "data/ssh-keys/id_rsa" ]; then
    echo -e "${YELLOW}⚠ SSH private key not found at data/ssh-keys/id_rsa${NC}"
    echo "Please copy your SSH private key:"
    echo "  cp ~/.ssh/id_rsa ./data/ssh-keys/"
    echo "  chmod 600 ./data/ssh-keys/id_rsa"
    echo
else
    chmod 600 data/ssh-keys/id_rsa
    echo -e "${GREEN}✓ SSH key configured${NC}"
fi

# Check if htpasswd file exists
echo -e "${BLUE}🔐 Setting up authentication...${NC}"
if [ ! -f "data/auth/.htpasswd" ]; then
    echo -e "${YELLOW}⚠ Authentication file not found${NC}"
    read -p "Would you like to create an admin user? (y/n): " create_user
    if [[ $create_user =~ ^[Yy]$ ]]; then
        read -p "Enter username (default: admin): " username
        username=${username:-admin}
        
        if command -v htpasswd &> /dev/null; then
            htpasswd -B -c "data/auth/.htpasswd" "$username"
            echo -e "${GREEN}✓ Authentication file created for user: $username${NC}"
        else
            echo -e "${RED}Error: htpasswd command not found${NC}"
            echo "Please install apache2-utils (Ubuntu/Debian) or httpd-tools (RHEL/CentOS)"
            echo "Or create the file manually:"
            echo "  htpasswd -B -c ./data/auth/.htpasswd admin"
        fi
    else
        echo "Please create the authentication file manually:"
        echo "  htpasswd -B -c ./data/auth/.htpasswd admin"
    fi
    echo
else
    echo -e "${GREEN}✓ Authentication file exists${NC}"
fi

# Check configuration
echo -e "${BLUE}⚙️ Checking configuration...${NC}"
if [ ! -f "data/config/config.toml" ]; then
    echo -e "${YELLOW}⚠ Configuration file not found${NC}"
    echo "A default configuration file should have been created during setup."
    echo "You can customize it by editing: ./data/config/config.toml"
else
    echo -e "${GREEN}✓ Configuration file exists${NC}"
fi

echo

# Display next steps
echo -e "${BLUE}🎯 Next Steps:${NC}"
echo "1. Verify your SSH key is in data/ssh-keys/id_rsa"
echo "2. Ensure data/auth/.htpasswd contains your user credentials"
echo "3. Customize data/config/config.toml if needed"
echo "4. Run: docker-compose up --build"
echo "5. Access the application at: http://localhost"
echo

echo -e "${GREEN}✅ Setup complete!${NC}"
echo
echo -e "${BLUE}🏃 Quick start commands:${NC}"
echo "  Development: docker-compose up --build"
echo "  Production:  docker-compose -f compose.prod.yml up --build -d"
echo "  Health check: docker-compose exec app /app/health-check.sh"
echo "  View logs:   docker-compose logs -f app"