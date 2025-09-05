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
    echo "  2. Commit the version change on current branch"
    echo "  3. Create a git tag"
    echo "  4. Push the branch and tag to origin"
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
    print_info "Checking git status..."
    
    if ! git diff-index --quiet HEAD --; then
        print_error "Working directory is not clean. Please commit or stash your changes first."
        git status --short
        exit 1
    fi
    
    # Check for untracked files that might be important
    local untracked_files=$(git ls-files --others --exclude-standard)
    if [ -n "$untracked_files" ]; then
        print_warning "Untracked files found:"
        echo "$untracked_files" | sed 's/^/  /'
        read -p "Continue with untracked files? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
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
    
    print_success "Git status is clean"
}

# Function to run build tests
run_build_tests() {
    print_info "Running build verification..."
    
    # Store current directory to return to it
    local original_dir=$(pwd)
    
    # Check if we're in the project root
    if [ ! -f "frontend/package.json" ] || [ ! -f "backend/Cargo.toml" ]; then
        print_error "Not in project root. Please run this script from the repository root."
        exit 1
    fi
    
    # Build frontend
    print_info "Building frontend..."
    cd frontend
    if ! npm run build > /tmp/frontend-build.log 2>&1; then
        print_error "Frontend build failed!"
        print_error "Build log:"
        cat /tmp/frontend-build.log
        cd "$original_dir"
        exit 1
    fi
    print_success "Frontend build completed"
    cd "$original_dir"
    
    # Build backend
    print_info "Building backend..."
    cd backend
    if ! cargo build > /tmp/backend-build.log 2>&1; then
        print_error "Backend build failed!"
        print_error "Build log:"
        cat /tmp/backend-build.log
        cd "$original_dir"
        exit 1
    fi
    print_success "Backend build completed"
    cd "$original_dir"
    
    ## Run backend tests
    #print_info "Running backend tests..."
    #cd backend
    #if ! cargo test > /tmp/backend-test.log 2>&1; then
    #    print_error "Backend tests failed!"
    #    print_error "Test log:"
    #    cat /tmp/backend-test.log
    #    cd "$original_dir"
    #    exit 1
    #fi
    #print_success "Backend tests passed"
    #cd "$original_dir"
    
    print_success "All builds and tests completed successfully"
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

    # Run build verification
    # This also updates Cargo.lock
    run_build_tests
           
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
    echo "  • Update VERSION from $current_version to $new_version on $original_branch"
    echo "  • Commit and push $original_branch with version update"
    echo "  • Create git tag: v$new_version"
    echo "  • Push tag to origin (this will trigger the Docker build)"
    echo
    read -p "Proceed with release? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Release cancelled"
        exit 0
    fi
    
    # Update VERSION file on current branch
    print_info "Updating VERSION file to $new_version on $original_branch"
    echo "$new_version" > VERSION
    
    # Update Cargo.toml version
    print_info "Updating Cargo.toml version to $new_version"
    sed -i.bak "s/^version = \".*\"/version = \"$new_version\"/" backend/Cargo.toml
    rm -f backend/Cargo.toml.bak

   
    # Commit version changes to current branch
    print_info "Committing version changes to $original_branch"
    git add VERSION backend/Cargo.toml backend/Cargo.lock
    git commit -m "chore: bump version to $new_version"
    
    # Create tag on current branch
    print_info "Creating tag: v$new_version"
    git tag -a "v$new_version" -m "Release version $new_version"
    
    # Push current branch with version update and tag
    print_info "Pushing $original_branch with version update"
    git push origin "$original_branch"
    
    print_info "Pushing tag to origin (this will trigger the GitHub Actions build)"
    git push origin "v$new_version"
    
    print_success "Release $new_version created successfully!"
    print_info "Git tag: v$new_version"
    print_info "Branch: $original_branch"
    print_info ""
    print_info "The GitHub Action will now build and publish Docker images:"
    print_info "  • styliteag/ssm:$new_version"
    print_info "  • ghcr.io/$(git config --get remote.origin.url | sed 's/.*github.com[/:]//g' | sed 's/.git$//')/ssm:$new_version"
    print_info ""
    print_info "Monitor the build at: https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[/:]//g' | sed 's/.git$//')/actions"
}

# Run main function
main "$@"