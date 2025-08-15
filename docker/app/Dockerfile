# Multi-stage build combining frontend and backend for SSH Key Manager
FROM node:24-alpine AS frontend-builder

# Accept build arguments  
ARG VITE_API_URL

WORKDIR /app

# Copy frontend package files for better caching
COPY frontend/package*.json ./

# Install frontend dependencies
RUN npm ci

# Copy frontend source
COPY frontend/. .

# Build frontend with environment variable
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build

# Rust backend builder stage
FROM rust:1.80-alpine AS backend-builder

WORKDIR /app

# Install build dependencies for static compilation
RUN apk add --no-cache \
    musl-dev \
    sqlite-dev \
    openssl-dev \
    openssl-libs-static \
    pkgconfig

# Add musl target for static compilation
RUN rustup target add x86_64-unknown-linux-musl

# Set environment variables for static compilation
ENV RUSTFLAGS="-C target-feature=+crt-static"
ENV PKG_CONFIG_ALLOW_CROSS=1

# Copy backend project files for better caching
COPY backend/Cargo.toml backend/Cargo.lock ./

# Create a dummy src/main.rs to cache dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs

# Build dependencies
RUN cargo build --release --target x86_64-unknown-linux-musl && rm -rf src/

# Copy backend source and other necessary files
COPY backend/src ./src/
COPY backend/build.rs ./
COPY backend/migrations ./migrations/
COPY backend/diesel.toml ./
COPY backend/rust-toolchain.toml ./

# Build the actual application statically
RUN cargo build --release --target x86_64-unknown-linux-musl

# Main application stage
FROM alpine:3.19

WORKDIR /app

# Install only runtime dependencies (no dev packages needed for static binary)
RUN apk add --no-cache \
    nginx \
    ca-certificates \
    curl

# Copy nginx configuration
COPY docker/app/nginx-main.conf /etc/nginx/nginx.conf

# Copy health check script
COPY docker/app/health-check.sh /app/health-check.sh

# Copy frontend build from builder stage
COPY --from=frontend-builder /app/dist /usr/share/nginx/html

# Copy statically compiled backend binary
COPY --from=backend-builder /app/target/x86_64-unknown-linux-musl/release/ssm /app/ssm

# Copy backend migrations and diesel config
COPY --from=backend-builder /app/migrations /app/migrations
COPY --from=backend-builder /app/diesel.toml /app/diesel.toml

# Copy backend static assets and templates (needed for Rust web app)
COPY backend/src/ssh/script.sh /app/script.sh
COPY static /app/static
COPY templates /app/templates

# Create necessary directories and startup script
RUN mkdir -p /var/cache/nginx /var/run/nginx /app/db /app/keys /var/log/nginx && \
    chmod +x /app/health-check.sh && \
    chmod +x /app/ssm && \
    echo '#!/bin/sh' > /app/start.sh && \
    echo 'set -e' >> /app/start.sh && \
    echo 'echo "Starting SSH Key Manager"' >> /app/start.sh && \
    echo 'echo "Version: $(cat /app/VERSION 2>/dev/null || echo unknown)"' >> /app/start.sh && \
    echo '' >> /app/start.sh && \
    echo '# Initialize database directory' >> /app/start.sh && \
    echo 'mkdir -p /app/db' >> /app/start.sh && \
    echo 'export DATABASE_URL="${DATABASE_URL:-sqlite:///app/db/ssm.db}"' >> /app/start.sh && \
    echo '' >> /app/start.sh && \
    echo '# Start nginx in background' >> /app/start.sh && \
    echo 'echo "Starting nginx reverse proxy..."' >> /app/start.sh && \
    echo 'nginx -t && nginx -g "daemon off;" &' >> /app/start.sh && \
    echo 'NGINX_PID=$!' >> /app/start.sh && \
    echo 'sleep 2' >> /app/start.sh && \
    echo '' >> /app/start.sh && \
    echo '# Start backend server' >> /app/start.sh && \
    echo 'echo "Starting SSH Key Manager backend..."' >> /app/start.sh && \
    echo 'cd /app && exec ./ssm' >> /app/start.sh && \
    chmod +x /app/start.sh

EXPOSE 80

COPY VERSION /app/VERSION
LABEL version="$(cat /app/VERSION)"

CMD ["/app/start.sh"]