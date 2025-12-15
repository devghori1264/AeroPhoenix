FROM golang:1.25-alpine as builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /src

COPY apps/flyd-sim/go.mod apps/flyd-sim/go.sum ./apps/flyd-sim/

COPY proto ./proto/

WORKDIR /src/apps/flyd-sim

RUN go mod download

COPY apps/flyd-sim/ ./

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s -X main.version=$(git describe --tags --always 2>/dev/null || echo 'dev')" \
    -o /bin/flyd-sim \
    ./cmd/server

FROM alpine:3.19

RUN apk add --no-cache \
    ca-certificates \
    curl \
    tzdata \
    && rm -rf /var/cache/apk/*

RUN addgroup -g 1000 flyd && \
    adduser -u 1000 -G flyd -s /bin/sh -D flyd

WORKDIR /app

RUN mkdir -p /data/badger && chown -R flyd:flyd /data

COPY --from=builder /bin/flyd-sim /bin/flyd-sim

ENV GRPC_PORT=50051
ENV HTTP_PORT=8080
ENV METRICS_PORT=9090
ENV DB_PATH=/data/badger

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/ping || exit 1

USER flyd

EXPOSE 8080 50051 9090

VOLUME ["/data"]

CMD ["/bin/flyd-sim", "--db", "/data/badger"]
