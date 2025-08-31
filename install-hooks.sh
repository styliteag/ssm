#!/bin/bash
#
# Git Hooks Installation Script
# 
# This script installs the project's git hooks for all developers.
# Run this after cloning the repository to enable secret detection.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
HOOKS_DIR="$REPO_ROOT/.git/hooks"
SHARED_HOOKS_DIR="$REPO_ROOT/.githooks"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🔧 Installing Git Hooks...${NC}"

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}❌ Error: Not in a git repository${NC}"
    exit 1
fi

# Check if shared hooks directory exists
if [[ ! -d "$SHARED_HOOKS_DIR" ]]; then
    echo -e "${RED}❌ Error: Shared hooks directory not found: $SHARED_HOOKS_DIR${NC}"
    exit 1
fi

# Install each hook from the shared directory
installed_hooks=()
for hook_file in "$SHARED_HOOKS_DIR"/*; do
    [[ ! -f "$hook_file" ]] && continue
    
    hook_name=$(basename "$hook_file")
    target_hook="$HOOKS_DIR/$hook_name"
    
    # Backup existing hook if it exists
    if [[ -f "$target_hook" ]]; then
        echo -e "${YELLOW}⚠️  Backing up existing $hook_name hook...${NC}"
        cp "$target_hook" "$target_hook.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Copy and make executable
    echo -e "   📋 Installing $hook_name hook..."
    cp "$hook_file" "$target_hook"
    chmod +x "$target_hook"
    installed_hooks+=("$hook_name")
done

if [[ ${#installed_hooks[@]} -eq 0 ]]; then
    echo -e "${YELLOW}⚠️  No hooks found to install${NC}"
    exit 0
fi

echo
echo -e "${GREEN}✅ Successfully installed git hooks:${NC}"
for hook in "${installed_hooks[@]}"; do
    echo -e "   • $hook"
done

echo
echo -e "${GREEN}🛡️  Security features now active:${NC}"
echo -e "   • Pre-commit secret detection"
echo -e "   • Allowlisted test/example values"
echo -e "   • File pattern whitelisting"

echo
echo -e "${YELLOW}📋 Next steps:${NC}"
echo -e "   • Review .secrets-whitelist for your project needs"
echo -e "   • Add any legitimate test keys with VALUE: prefix"
echo -e "   • Test with: git add <file> && git commit -m 'test'"

echo
echo -e "${GREEN}🚀 Git hooks installation complete!${NC}"