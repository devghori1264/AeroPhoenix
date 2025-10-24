.PHONY: fmt lint test build docker

fmt:
	# Elixir
	cd apps/orchestrator && mix format
	cd apps/phoenix_ui && mix format
	# Go
	cd apps/flyd-sim && go fmt ./...
	cd cli/aeropctl && go fmt ./...
	# Rust
	cd apps/net-sim && cargo fmt

lint:
	cd apps/orchestrator && mix credo || true
	cd apps/phoenix_ui && mix credo || true
	cd apps/flyd-sim && go vet ./...
	cd cli/aeropctl && go vet ./...
	cd apps/net-sim && cargo clippy -- -D warnings || true

test:
	cd apps/flyd-sim && go test ./... -v
	cd cli/aeropctl && go test ./... -v || true
	cd apps/net-sim && cargo test || true
	cd apps/orchestrator && mix test || true
	cd apps/phoenix_ui && mix test || true
