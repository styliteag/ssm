# syntax=docker/dockerfile:1.4
# Multi-stage build combining frontend and backend for SSH Key Manager
FROM node:24-alpine AS frontend-builder

# Accept build arguments  
ARG VITE_API_URL

WORKDIR /app

# Copy frontend package files for better caching
COPY frontend/package*.json ./

# Install frontend dependencies
RUN npm ci --no-audit --no-fund

# Copy frontend source
COPY frontend/. .

# Build frontend with environment variable
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build



# Rust backend builder stage with cargo-chef for better dependency caching
FROM rust:1.89-alpine AS chef
#FROM lukemathwalker/cargo-chef:latest-rust-1.89.0 AS chef

# Install build dependencies for static compilation and cross-compilation
RUN apk add --no-cache \
    musl-dev \
    sqlite-dev \
    sqlite-static \
    openssl-dev \
    openssl-libs-static \
    pkgconfig \
    gcc \
    clang \
    lld \
    libgcc \
    curl

WORKDIR /app
# Install cargo-chef in separate layer for better caching
RUN cargo install --locked cargo-chef

# Pre-warm Rust toolchain components to cache downloads
# This prevents rustc/cargo component downloads during build
# Handle both x86_64 and arm64 platforms properly
#RUN ARCH=$(uname -m) && \
#    if [ "$ARCH" = "x86_64" ]; then \
#        rustup toolchain install stable-x86_64-unknown-linux-musl && \
#        rustup default stable-x86_64-unknown-linux-musl; \
#    elif [ "$ARCH" = "aarch64" ]; then \
#        rustup toolchain install stable-aarch64-unknown-linux-musl && \
#        rustup default stable-aarch64-unknown-linux-musl; \
#    fi && \
#    rustup target add x86_64-unknown-linux-musl && \
#    rustup target add aarch64-unknown-linux-musl && \
#    rustup component add rust-src && \
#    cargo version && \
#    rustc --version

WORKDIR /app



FROM chef AS planner
# Copy files needed for dependency analysis and project structure
COPY backend/Cargo.toml backend/Cargo.lock ./
# COPY backend/build.rs ./
# COPY backend/src ./src
RUN mkdir -p src
RUN echo "fn main() {}" > src/main.rs
# RUN echo "fn main() {}" > src/lib.rs

# Create dependency-only Cargo.toml that excludes version changes for better caching
# This ensures recipe generation only rebuilds when dependencies actually change
RUN sed '/^version = /c\version = "0.0.1"' Cargo.toml > Cargo.toml.deps && \
    mv Cargo.toml.deps Cargo.toml

# Generate dependency recipe (this layer is cached unless dependencies in Cargo.toml/Cargo.lock change)
# Version bumps no longer invalidate this expensive step!
# This step is fast, so it's worth caching.
RUN cargo chef prepare --recipe-path recipe.json && rm -rf src



FROM chef AS backend-builder
WORKDIR /app

# Ensure toolchain is set correctly for current architecture
#RUN ARCH=$(uname -m) && \
#    if [ "$ARCH" = "x86_64" ]; then \
#        rustup default stable-x86_64-unknown-linux-musl; \
#    elif [ "$ARCH" = "aarch64" ]; then \
#        rustup default stable-aarch64-unknown-linux-musl; \
#    fi

# Copy the dependency recipe from planner stage
COPY --from=planner /app/recipe.json recipe.json


# Build dependencies based on recipe with enhanced caching
# This layer should be cached unless Cargo.toml/Cargo.lock changes
RUN cargo chef cook --release --recipe-path recipe.json --locked

# Copy backend source and other necessary files
COPY backend/Cargo.toml backend/Cargo.lock ./
COPY backend/build.rs ./
COPY backend/migrations ./migrations/
COPY backend/diesel.toml ./
COPY backend/src ./src/
COPY VERSION /VERSION

# Build the actual application statically with enhanced caching
RUN cargo build --release --locked && \
    apk add --no-cache binutils && \
    strip target/release/ssm && \
    cp target/release/ssm /app/ssm-binary



# Main application stage
FROM alpine:3.20

WORKDIR /app

# Install only runtime dependencies (no dev packages needed for static binary)
RUN apk add --no-cache \
    nginx \
    ca-certificates \
    curl \
    wget

# Copy nginx configuration
COPY docker/app/nginx-main.conf /etc/nginx/nginx.conf

# Copy health check script
COPY docker/app/health-check.sh /app/health-check.sh

# Copy frontend build from builder stage
COPY --from=frontend-builder /app/dist /usr/share/nginx/html

# Copy statically compiled backend binary
COPY --from=backend-builder /app/ssm-binary /app/ssm

# Copy backend migrations and diesel config
COPY --from=backend-builder /app/migrations /app/migrations
COPY --from=backend-builder /app/diesel.toml /app/diesel.toml

# Copy backend static assets and templates (needed for Rust web app)
COPY backend/src/ssh/script.sh /app/script.sh
#COPY static /app/static
#COPY templates /app/templates

# Create necessary directories and startup script
RUN mkdir -p /var/cache/nginx /var/run/nginx /app/db /app/keys /var/log/nginx && \
    chmod +x /app/health-check.sh && \
    chmod +x /app/ssm && \
    printf '#!/bin/sh\n' > /app/start.sh && \
    printf 'set -e\n' >> /app/start.sh && \
    printf 'echo "Starting SSH Key Manager"\n' >> /app/start.sh && \
    printf 'echo "Version: $(cat /app/VERSION 2>/dev/null || echo unknown)"\n' >> /app/start.sh && \
    printf '\n' >> /app/start.sh && \
    printf '# Initialize database directory\n' >> /app/start.sh && \
    printf 'mkdir -p /app/db\n' >> /app/start.sh && \
    printf 'export DATABASE_URL="${DATABASE_URL:-sqlite:///app/db/ssm.db}"\n' >> /app/start.sh && \
    printf '\n' >> /app/start.sh && \
    printf '# Function to handle shutdown gracefully\n' >> /app/start.sh && \
    printf 'cleanup() {\n' >> /app/start.sh && \
    printf '    echo "Shutting down..."\n' >> /app/start.sh && \
    printf '    kill -TERM $NGINX_PID 2>/dev/null || true\n' >> /app/start.sh && \
    printf '    kill -TERM $SSM_PID 2>/dev/null || true\n' >> /app/start.sh && \
    printf '    wait\n' >> /app/start.sh && \
    printf '    exit\n' >> /app/start.sh && \
    printf '}\n' >> /app/start.sh && \
    printf 'trap cleanup SIGTERM SIGINT\n' >> /app/start.sh && \
    printf '\n' >> /app/start.sh && \
    printf '# Start nginx in background\n' >> /app/start.sh && \
    printf 'echo "Starting nginx reverse proxy..."\n' >> /app/start.sh && \
    printf 'echo "Nginx Config:"\n' >> /app/start.sh && \
    printf 'nginx -T\n' >> /app/start.sh && \
    printf 'nginx -t && nginx -g "daemon off;" &\n' >> /app/start.sh && \
    printf 'NGINX_PID=$!\n' >> /app/start.sh && \
    printf 'sleep 2\n' >> /app/start.sh && \
    printf '\n' >> /app/start.sh && \
    printf '# Start backend server in background\n' >> /app/start.sh && \
    printf 'echo "Starting SSH Key Manager backend..."\n' >> /app/start.sh && \
    printf 'cd /app && ./ssm &\n' >> /app/start.sh && \
    printf 'SSM_PID=$!\n' >> /app/start.sh && \
    printf '\n' >> /app/start.sh && \
    printf '# Wait for both processes\n' >> /app/start.sh && \
    printf 'wait\n' >> /app/start.sh && \
    chmod +x /app/start.sh

EXPOSE 80

COPY VERSION /app/VERSION

# Image metadata
ARG VERSION
ARG VCS_REF
LABEL org.opencontainers.image.title="ssh-key-manager" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.source="https://github.com/styliteag/ssm"

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD /app/health-check.sh || exit 1

CMD ["/app/start.sh"]
