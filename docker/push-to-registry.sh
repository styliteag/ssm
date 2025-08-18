#!/bin/bash

# SSM Registry Push Script with Multi-Architecture Support

set -e

# Configuration
REGISTRY_URL="${DOCKER_REGISTRY:-docker.io}"  # Default to Docker Hub
NAMESPACE="${DOCKER_NAMESPACE:-styliteag}"  # Change this to your username/organization

# Function to show usage
show_usage() {
    echo "Usage: $0 [ARCHITECTURE] [--nopush]"
    echo ""
    echo "ARCHITECTURE options:"
    echo "  auto    - Build AMD64 always, ARM64 only if on ARM64 system (default)"
    echo "  all     - Build both AMD64 and ARM64"
    echo "  amd64   - Build AMD64 only"
    echo "  arm64   - Build ARM64 only"
    echo ""
    echo "Flags:"
    echo "  --nopush - Do not push to registry. For single-arch builds, image is loaded into local Docker."
    echo ""
    echo "Examples:"
    echo "  $0                 # Auto-detect (default behavior)"
    echo "  $0 all             # Build both architectures and push"
    echo "  $0 amd64 --nopush  # Build AMD64 only and load locally (no push)"
    echo "  $0 arm64           # Build ARM64 only and push"
    exit 1
}

# Parse command line arguments
NOPUSH=false
ARCH_ARG="auto"

# Accept either an architecture arg and/or the --nopush flag (in any order)
for arg in "$@"; do
    case "$arg" in
        --nopush)
            NOPUSH=true
            ;;
        auto|all|amd64|arm64)
            ARCH_ARG="$arg"
            ;;
        help|--help|-h)
            show_usage
            ;;
        "")
            ;;
        *)
            echo "❌ Invalid argument: $arg"
            echo ""
            show_usage
            ;;
    esac
done



# Validate architecture argument (already parsed from args)
case "$ARCH_ARG" in
    auto|all|amd64|arm64)
        ;;
    *)
        echo "❌ Invalid architecture argument: $ARCH_ARG"
        echo ""
        show_usage
        ;;
esac

# Read version from VERSION file
if [ -f "../VERSION" ]; then
    VERSION=$(cat "../VERSION")
    VERSION_TAG="v${VERSION}"
else
    VERSION_TAG="latest"
fi

echo "🚀 Building ssm images..."
echo "Registry: ${REGISTRY_URL}"
echo "Namespace: ${NAMESPACE}"
echo "Version Tag: ${VERSION_TAG}"
echo "Architecture Mode: ${ARCH_ARG}"
if [ "$NOPUSH" = true ]; then
    echo "Action: build and load locally (no push)"
else
    echo "Action: build and push to registry"
fi
echo ""

# Set the external URL for the app so the container will be able to access the API behind a reverse proxy
EXTERNAL_URL=/api
export EXTERNAL_URL

# Create and use a multi-platform builder if it doesn't exist
BUILDER_NAME="ssm-builder"
if ! docker buildx inspect $BUILDER_NAME >/dev/null 2>&1; then
    echo "🔨 Creating multi-platform builder: $BUILDER_NAME"
    docker buildx create --name $BUILDER_NAME --use
else
    echo "🔨 Using existing multi-platform builder: $BUILDER_NAME"
    docker buildx use $BUILDER_NAME
fi

# Determine build platforms based on argument
case "$ARCH_ARG" in
    auto)
        PLATFORMS="linux/amd64"
        CURRENT_ARCH=$(uname -m)
        if [[ "$CURRENT_ARCH" == "arm64" || "$CURRENT_ARCH" == "aarch64" ]]; then
            PLATFORMS="linux/amd64,linux/arm64"
            echo "🏗️  Building for AMD64 and ARM64 (detected ARM64 system)"
        else
            echo "🏗️  Building for AMD64 only (detected non-ARM64 system)"
        fi
        ;;
    all)
        PLATFORMS="linux/amd64,linux/arm64"
        echo "🏗️  Building for AMD64 and ARM64 (forced)"
        ;;
    amd64)
        PLATFORMS="linux/amd64"
        echo "🏗️  Building for AMD64 only (forced)"
        ;;
    arm64)
        PLATFORMS="linux/arm64"
        echo "🏗️  Building for ARM64 only (forced)"
        ;;
esac

# Build and push images
echo "Platforms: $PLATFORMS"

# Determine output mode based on --nopush and platform count
if [ "$NOPUSH" = true ]; then
    if [[ "$PLATFORMS" == *","* ]]; then
        echo "❌ --nopush only supports a single platform (amd64 or arm64). Use 'amd64' or 'arm64' with --nopush, or omit --nopush to push multi-arch images."
        exit 1
    fi
    OUTPUT_FLAG="--load"
else
    OUTPUT_FLAG="--push"
fi

docker buildx build \
    --platform $PLATFORMS \
    --tag ${REGISTRY_URL}/${NAMESPACE}/ssm:${VERSION_TAG} \
    --tag ${REGISTRY_URL}/${NAMESPACE}/ssm:latest \
    --file app/Dockerfile \
    ${OUTPUT_FLAG} \
    ..

echo ""
if [ "$NOPUSH" = true ]; then
    echo "✅ Image built and loaded into local Docker successfully!"
else
    echo "✅ Images built and pushed successfully!"
fi
echo ""
echo "📋 Image URLs:"
echo "   App:      ${REGISTRY_URL}/${NAMESPACE}/ssm:${VERSION_TAG}"
echo "   Latest:   ${REGISTRY_URL}/${NAMESPACE}/ssm:latest"
echo ""
echo "🏗️  Built architectures:"
case "$PLATFORMS" in
    *amd64*arm64*|*arm64*amd64*)
        echo "   - linux/amd64 (x86_64)"
        echo "   - linux/arm64 (ARM64)"
        ;;
    *amd64*)
        echo "   - linux/amd64 (x86_64)"
        ;;
    *arm64*)
        echo "   - linux/arm64 (ARM64)"
        ;;
esac
echo ""
echo "🚀 To deploy these images, use:"
echo "   DOCKER_NAMESPACE=${NAMESPACE} docker compose -f compose.prod.yml up -d"