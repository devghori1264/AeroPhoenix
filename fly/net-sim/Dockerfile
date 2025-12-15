FROM rust:1.92-slim-bookworm as builder

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY apps/net-sim/Cargo.toml apps/net-sim/Cargo.lock ./

RUN mkdir src && echo "fn main() {}" > src/main.rs

RUN cargo build --release && rm -rf src target/release/net_sim*

COPY apps/net-sim/src ./src/

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 netsim && \
    useradd --uid 1000 --gid netsim --shell /bin/bash --create-home netsim

WORKDIR /app

COPY --from=builder /src/target/release/net_sim /usr/local/bin/net_sim

ENV RUST_LOG=info
ENV PORT=7070

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:7070/health || exit 1

USER netsim

EXPOSE 7070

CMD ["net_sim"]
