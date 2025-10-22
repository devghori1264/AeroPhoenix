FROM golang:1.25-alpine AS builder
RUN apk add --no-cache git
WORKDIR /src
COPY . .
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /bin/flyd-sim ./cmd/server

FROM alpine:3.18
RUN apk add --no-cache ca-certificates
COPY --from=builder /bin/flyd-sim /bin/flyd-sim
VOLUME ["/data"]
EXPOSE 50051 8080 9090
ENTRYPOINT ["/bin/flyd-sim"]
