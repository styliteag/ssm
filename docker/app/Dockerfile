# Multi-stage build combining frontend and backend for SSH Key Manager
FROM node:24-alpine AS frontend-builder

# Accept build arguments  
ARG VITE_API_URL

WORKDIR /app

# Copy frontend package files for better caching
COPY frontend/package*.json ./

# Install frontend dependencies
RUN npm ci --only=production

# Copy frontend source
COPY frontend/. .

# Install all dependencies for build
RUN npm install

# Build frontend with environment variable
ENV VITE_API_URL=${VITE_API_URL}
RUN npm run build:prod

# Rust backend builder stage
FROM rust:1.75-alpine AS backend-builder

WORKDIR /app

# Install build dependencies
RUN apk add --no-cache \
    musl-dev \
    sqlite-dev \
    openssl-dev \
    pkgconfig

# Copy backend project files for better caching
COPY backend/Cargo.toml backend/Cargo.lock ./

# Create a dummy src/main.rs to cache dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs

# Build dependencies
RUN cargo build --release && rm -rf src/

# Copy backend source
COPY backend/src ./src/
COPY backend/build.rs ./

# Build the actual application
RUN cargo build --release

# Main application stage
FROM alpine:3.19

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache \
    nginx \
    sqlite \
    openssl \
    ca-certificates

# Copy nginx configuration
COPY docker/app/nginx-main.conf /etc/nginx/nginx.conf

# Copy health check script
COPY docker/app/health-check.sh /app/health-check.sh

# Copy frontend build from builder stage
COPY --from=frontend-builder /app/dist /usr/share/nginx/html

# Copy backend binary from builder stage
COPY --from=backend-builder /app/target/release/ssm /app/ssm

# Copy backend static assets and templates (needed for Rust web app)
COPY backend/src/ssh/script.sh /app/script.sh
COPY static /app/static
COPY templates /app/templates

# Create necessary directories and startup script
RUN mkdir -p /var/cache/nginx /app/db /app/keys && \
    chmod +x /app/health-check.sh && \
    chmod +x /app/ssm && \
    echo '#!/bin/sh' > /app/start.sh && \
    echo 'echo "Starting SSH Key Manager"' >> /app/start.sh && \
    echo 'echo "Version: $(cat /app/VERSION)"' >> /app/start.sh && \
    echo 'nginx -g "daemon off;" &' >> /app/start.sh && \
    echo 'cd /app && ./ssm' >> /app/start.sh && \
    chmod +x /app/start.sh

EXPOSE 80

COPY VERSION /app/VERSION
LABEL version="$(cat /app/VERSION)"

CMD ["/app/start.sh"]