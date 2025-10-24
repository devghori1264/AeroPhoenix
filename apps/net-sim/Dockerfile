FROM rust:latest as builder
WORKDIR /src

COPY . .

RUN cargo build --release

FROM debian:bookworm-slim
WORKDIR /app

RUN apt-get update && apt-get install -y openssl && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/net_sim /usr/local/bin/net_sim

EXPOSE 7070
CMD ["net_sim"]