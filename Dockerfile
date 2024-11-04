# SEE https://github.com/LukeMathWalker/cargo-chef

# Build the image with:
# docker build -t ssm .
# TODO test on ARM
# TODO test Cross compilation with buildx
# TODO make musl on ALPINE work

# STAGE 1 - generate a recipe file for dependencies
#FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
FROM rust:1.80 AS chef
WORKDIR /app
ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
# Install musl-dev on Alpine to avoid error "ld: cannot find crti.o: No such file or directory"
RUN rustup toolchain install stable
RUN rustup target add x86_64-unknown-linux-musl
RUN ((cat /etc/os-release | grep ID | grep alpine) && apk add --no-cache musl-dev || true) \
    && cargo install cargo-chef --locked \
    && rm -rf $CARGO_HOME/registry/

# STAGE 2 - Plan the build
FROM chef AS planner

COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# STAGE 3 - Build the application
FROM chef AS builder

COPY --from=planner /app/recipe.json recipe.json
# Build dependencies - this is the caching Docker layer!
RUN cargo chef cook --release --recipe-path recipe.json

# Build application
COPY . .
RUN cargo build --release --bin ssm

# STAGE 4 - Final image
FROM debian:12-slim
WORKDIR /app

RUN apt-get update && apt-get install -y sqlite3 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/ssm   /app/

ENV CONFIG=/app/config.toml
ENV DATABASE_URL=sqlite:///app/ssm.sqlite
ENV "SSH.PRIVATE_KEY_FILE"=/app/id

EXPOSE 8080

CMD ["./ssm"]
