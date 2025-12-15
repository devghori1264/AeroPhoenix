#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PARALLEL="${1:-}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_deploy() { echo -e "${CYAN}[DEPLOY]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLY_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$FLY_DIR")"

deploy_service() {
    local app_name=$1
    local app_dir=$2
    local start_time=$(date +%s)
    
    log_deploy "Deploying $app_name..."
    
    cd "$PROJECT_ROOT"
    
    if fly deploy \
        --config "$app_dir/fly.toml" \
        --remote-only \
        --wait-timeout 300 \
        --strategy rolling; then
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "$app_name deployed successfully (${duration}s)"
        return 0
    else
        log_error "Failed to deploy $app_name"
        return 1
    fi
}

check_status() {
    local app_name=$1
    
    log_info "Checking status of $app_name..."
    fly status -a "$app_name"
}

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           AeroPhoenix Fly.io Deployment                         ║"
    echo "║           Deploying All Services                                 ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    local total_start=$(date +%s)
    
    log_info "Deployment Order:"
    echo "  1. flyd-sim     → Machine lifecycle simulator"
    echo "  2. net-sim      → Chaos engineering"
    echo "  3. orchestrator → Control plane"
    echo "  4. phoenix-ui   → User interface"
    echo ""
    
    log_info "Phase 1: Backend Services"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    deploy_service "aerophoenix-flyd-sim" "$FLY_DIR/flyd-sim"
    deploy_service "aerophoenix-net-sim" "$FLY_DIR/net-sim"
    
    log_info "Phase 2: Control Plane"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    deploy_service "aerophoenix-orchestrator" "$FLY_DIR/orchestrator"
    
    log_info "Phase 3: Frontend"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    deploy_service "aerophoenix" "$FLY_DIR/phoenix-ui"
    
    local total_end=$(date +%s)
    local total_duration=$((total_end - total_start))
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    Deployment Complete!                          ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    log_success "All services deployed in ${total_duration} seconds"
    echo ""
    log_info "Service URLs:"
    echo "  Phoenix UI:   https://aerophoenix.fly.dev"
    echo "  Orchestrator: https://aerophoenix-orchestrator.fly.dev (internal)"
    echo ""
    log_info "Run verification: ./scripts/verify-deployment.sh"
}

main "$@"