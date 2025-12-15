#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ORG="${FLY_ORG:-personal}"
PRIMARY_REGION="${FLY_PRIMARY_REGION:-iad}"

UI_APP="aerophoenix-ui"
ORCHESTRATOR_APP="aerophoenix-orchestrator"
FLYD_SIM_APP="aerophoenix-flyd-sim"
NET_SIM_APP="aerophoenix-net-sim"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v fly &> /dev/null; then
        log_error "flyctl not found. Install with: brew install flyctl"
        exit 1
    fi
    
    if ! fly auth whoami &> /dev/null; then
        log_error "Not authenticated. Run: fly auth login"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

create_app() {
    local app_name=$1
    local app_dir=$2
    
    log_info "Creating app: $app_name"
    
    if fly apps list | grep -q "^$app_name"; then
        log_warn "App $app_name already exists, skipping creation"
    else
        cd "$app_dir"
        fly apps create "$app_name" --org "$ORG"
        log_success "Created app: $app_name"
    fi
}

create_postgres() {
    local pg_name="aerophoenix-db"
    
    log_info "Setting up Fly Postgres..."
    
    if fly postgres list | grep -q "$pg_name"; then
        log_warn "Postgres cluster $pg_name already exists"
    else
        log_info "Creating Postgres cluster (this may take a few minutes)..."
        fly postgres create \
            --name "$pg_name" \
            --org "$ORG" \
            --region "$PRIMARY_REGION" \
            --vm-size shared-cpu-1x \
            --volume-size 10 \
            --initial-cluster-size 1
        log_success "Created Postgres cluster: $pg_name"
    fi
    
    log_info "Attaching Postgres to orchestrator..."
    fly postgres attach "$pg_name" -a "$ORCHESTRATOR_APP" || log_warn "Postgres may already be attached"
}

set_secrets() {
    local app_name=$1
    
    log_info "Setting secrets for: $app_name"
    
    local secret_key=$(openssl rand -base64 48)
    
    case $app_name in
        "$UI_APP")
            fly secrets set \
                SECRET_KEY_BASE="$secret_key" \
                PHX_HOST="$UI_APP.fly.dev" \
                -a "$app_name"
            ;;
        "$ORCHESTRATOR_APP")
            fly secrets set \
                SECRET_KEY_BASE="$secret_key" \
                PHX_HOST="$ORCHESTRATOR_APP.fly.dev" \
                -a "$app_name"
            ;;
        *)
            log_info "No secrets needed for $app_name"
            ;;
    esac
    
    log_success "Secrets configured for: $app_name"
}

create_volumes() {
    log_info "Creating volumes..."
    
    fly volumes create orchestrator_data \
        -a "$ORCHESTRATOR_APP" \
        -r "$PRIMARY_REGION" \
        -s 10 \
        --yes || log_warn "Volume may already exist"
    
    fly volumes create flyd_sim_data \
        -a "$FLYD_SIM_APP" \
        -r "$PRIMARY_REGION" \
        -s 5 \
        --yes || log_warn "Volume may already exist"
    
    log_success "Volumes created"
}

# Main setup flow
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           AeroPhoenix Fly.io Setup                              ║"
    echo "║           Production-Grade Orchestrator Deployment              ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FLY_DIR="$(dirname "$SCRIPT_DIR")"
    
    check_prerequisites
    
    echo ""
    log_info "Configuration:"
    log_info "  Organization: $ORG"
    log_info "  Primary Region: $PRIMARY_REGION"
    log_info "  Apps: $UI_APP, $ORCHESTRATOR_APP, $FLYD_SIM_APP, $NET_SIM_APP"
    echo ""
    
    read -p "Continue with setup? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Setup cancelled"
        exit 1
    fi
    
    create_app "$UI_APP" "$FLY_DIR/phoenix-ui"
    create_app "$ORCHESTRATOR_APP" "$FLY_DIR/orchestrator"
    create_app "$FLYD_SIM_APP" "$FLY_DIR/flyd-sim"
    create_app "$NET_SIM_APP" "$FLY_DIR/net-sim"
    
    create_postgres
    
    set_secrets "$UI_APP"
    set_secrets "$ORCHESTRATOR_APP"
    
    create_volumes
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    Setup Complete!                               ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    log_success "All apps and resources created successfully!"
    echo ""
    log_info "Next steps:"
    echo "  1. Review fly.toml configurations in each app directory"
    echo "  2. Run: ./scripts/deploy-all.sh"
    echo "  3. Verify: ./scripts/verify-deployment.sh"
    echo ""
}

main "$@"
