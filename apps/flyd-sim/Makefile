.PHONY: build run docker run-d test proto clean

PROTO=../../proto/machine.proto
PROTO_OUT=internal/proto

proto:
    protoc -I ../../proto \
           --go_out=$(PROTO_OUT) --go_opt=paths=source_relative \
           --go-grpc_out=$(PROTO_OUT) --go-grpc_opt=paths=source_relative \
           $(PROTO)


build:
	go build -o bin/flyd-sim ./cmd/server

run: build
	./bin/flyd-sim

run-d:
	go run ./cmd/server

docker:
	docker build -t aerophoenix/flyd-sim:local .

test:
	go test ./... -v

clean:
	rm -rf bin
