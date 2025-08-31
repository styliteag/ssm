#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to show usage
show_usage() {
    echo "Usage: $0 [major|minor|patch]"
    echo ""
    echo "This script will:"
    echo "  1. Increment the version in ./VERSION file"
    echo "  2. Create and checkout a new release branch"
    echo "  3. Commit the version change"
    echo "  4. Create a git tag"
    echo "  5. Push the branch and tag to origin"
    echo ""
    echo "Version increment types:"
    echo "  major: X.0.0 (breaking changes)"
    echo "  minor: X.Y.0 (new features, backward compatible)"
    echo "  patch: X.Y.Z (bug fixes, backward compatible)"
    echo ""
    echo "Current version: $(cat VERSION 2>/dev/null || echo 'VERSION file not found')"
}

# Function to increment version
increment_version() {
    local current_version="$1"
    local increment_type="$2"
    
    # Parse current version
    IFS='.' read -r -a version_parts <<< "$current_version"
    local major="${version_parts[0]}"
    local minor="${version_parts[1]}"
    local patch="${version_parts[2]}"
    
    case $increment_type in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
        *)
            print_error "Invalid increment type: $increment_type"
            return 1
            ;;
    esac
    
    echo "$major.$minor.$patch"
}

# Function to validate git status
check_git_status() {
    if ! git diff-index --quiet HEAD --; then
        print_error "Working directory is not clean. Please commit or stash your changes first."
        exit 1
    fi
    
    local current_branch=$(git branch --show-current)
    if [[ ! "$current_branch" =~ ^(main|master|develop)$ ]]; then
        print_warning "Current branch is '$current_branch'. It's recommended to create releases from main/master/develop."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Main script
main() {
    # Check if increment type is provided
    if [ $# -ne 1 ]; then
        show_usage
        exit 1
    fi
    
    local increment_type="$1"
    
    # Validate increment type
    if [[ ! "$increment_type" =~ ^(major|minor|patch)$ ]]; then
        print_error "Invalid increment type: $increment_type"
        show_usage
        exit 1
    fi
    
    # Check if VERSION file exists
    if [ ! -f "VERSION" ]; then
        print_error "VERSION file not found in current directory"
        exit 1
    fi
    
    # Check git status
    check_git_status
    
    # Read current version
    local current_version=$(cat VERSION | tr -d '\n')
    print_info "Current version: $current_version"
    
    # Calculate new version
    local new_version=$(increment_version "$current_version" "$increment_type")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    print_info "New version: $new_version"
    
    # Confirm with user
    echo
    print_warning "This will:"
    echo "  • Update VERSION from $current_version to $new_version"
    echo "  • Create release branch: release-$new_version"
    echo "  • Create git tag: v$new_version"
    echo "  • Push branch and tag to origin"
    echo
    read -p "Proceed with release? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Release cancelled"
        exit 0
    fi
    
    # Create release branch
    local release_branch="release-$new_version"
    print_info "Creating and checking out branch: $release_branch"
    git checkout -b "$release_branch"
    
    # Update VERSION file
    print_info "Updating VERSION file to $new_version"
    echo "$new_version" > VERSION
    
    # Commit version change
    print_info "Committing version change"
    git add VERSION
    git commit -m "chore: bump version to $new_version"
    
    # Create tag
    print_info "Creating tag: v$new_version"
    git tag -a "v$new_version" -m "Release version $new_version"
    
    # Push branch and tag
    print_info "Pushing branch and tag to origin"
    git push origin "$release_branch"
    git push origin "v$new_version"
    
    print_success "Release $new_version created successfully!"
    print_info "Release branch: $release_branch"
    print_info "Git tag: v$new_version"
    print_info ""
    print_info "The GitHub Action will now build and publish Docker images:"
    print_info "  • styliteag/ssh-key-manager:$new_version"
    print_info "  • ghcr.io/$(git config --get remote.origin.url | sed 's/.*github.com[/:]//g' | sed 's/.git$//')/ssh-key-manager:$new_version"
    print_info ""
    print_info "Monitor the build at: https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[/:]//g' | sed 's/.git$//')/actions"
}

# Run main function
main "$@"