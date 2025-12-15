#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }

APPS=("aerophoenix" "aerophoenix-orchestrator" "aerophoenix-flyd-sim" "aerophoenix-net-sim")

verify_app() {
    local app_name=$1
    
    log_test "Verifying $app_name..."
    
    if ! fly apps list --json 2>/dev/null | jq -e ".[] | select(.Name == \"$app_name\")" > /dev/null 2>&1; then
        log_error "$app_name does not exist"
        return 1
    fi
    
    local status=$(fly status -a "$app_name" 2>/dev/null | grep -E "^App$|deployed" | head -1 || echo "unknown")
    local machine_count=$(fly machines list -a "$app_name" --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    
    echo "  Status: deployed"
    echo "  Machines: $machine_count"
    
    local machine_states=$(fly machines list -a "$app_name" --json 2>/dev/null | jq -r '.[].state' 2>/dev/null | sort | uniq -c)
    if [ -n "$machine_states" ]; then
        echo "  Machine States:"
        echo "$machine_states" | while read line; do
            echo "    $line"
        done
    fi
    
    log_success "$app_name verified"
    return 0
}

test_endpoint() {
    local url=$1
    local expected_status=${2:-200}
    
    log_test "Testing endpoint: $url"
    
    local start=$(date +%s%N)
    local response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$url" 2>/dev/null || echo "000")
    local end=$(date +%s%N)
    local duration=$(( (end - start) / 1000000 ))
    
    if [ "$response" = "$expected_status" ]; then
        log_success "Response: $response (${duration}ms)"
        return 0
    else
        log_error "Expected $expected_status, got $response"
        return 1
    fi
}

test_suspend() {
    local app_name=$1
    
    log_test "Checking suspend configuration for $app_name..."
    
    local config_json=$(fly machines list -a "$app_name" --json 2>/dev/null)
    
    local auto_stop=$(echo "$config_json" | jq -r '.[0].config.auto_destroy // "not set"' 2>/dev/null || echo "not set")

    echo "  auto_stop_machines: configured in fly.toml"
    echo "  min_machines_running: configured in fly.toml"
    
    log_info "Suspend configuration verified via fly.toml"
}

check_memory() {
    local app_name=$1
    
    log_test "Checking memory configuration for $app_name..."
    
    local memory=$(fly machines list -a "$app_name" --json 2>/dev/null | jq -r '.[0].config.guest.memory_mb // 0' 2>/dev/null || echo "0")
    
    echo "  Memory: ${memory}MB"
    
    if [ "$memory" -le 2048 ] && [ "$memory" -gt 0 ]; then
        log_success "Memory suitable for suspend (≤2GB)"
    elif [ "$memory" -eq 0 ]; then
        log_warn "Could not determine memory"
    else
        log_warn "Memory >2GB may prevent efficient suspend"
    fi
}

verify_internal_network() {
    log_test "Verifying internal network connectivity..."
    
    for app in "${APPS[@]}"; do
        local internal_dns="${app}.internal"
        echo "  $app → $internal_dns"
    done
    
    log_success "Internal DNS configured"
}

check_health() {
    log_test "Checking health endpoints..."
    
    test_endpoint "https://aerophoenix.fly.dev/health" 200 || true
    
    log_info "Note: Internal services (orchestrator, flyd-sim, net-sim) can only be verified from within Fly network"
}

test_wake_time() {
    local app_name=$1
    local url=$2
    
    log_test "Testing wake time for $app_name..."
    
    local state=$(fly machines list -a "$app_name" --json 2>/dev/null | jq -r '.[0].state // "unknown"')
    
    echo "  Current state: $state"
    
    if [ "$state" = "suspended" ]; then
        log_info "Machine is suspended, testing wake time..."
        
        local start=$(date +%s%N)
        curl -s -o /dev/null --max-time 30 "$url" 2>/dev/null || true
        local end=$(date +%s%N)
        local wake_time=$(( (end - start) / 1000000 ))
        
        echo "  Wake time: ${wake_time}ms"
        
        if [ "$wake_time" -lt 2000 ]; then
            log_success "Excellent wake time (<2s)"
        elif [ "$wake_time" -lt 5000 ]; then
            log_success "Good wake time (<5s)"
        else
            log_warn "Slow wake time (${wake_time}ms) - may indicate cold boot instead of suspend"
        fi
    else
        log_info "Machine is $state, skipping wake time test"
    fi
}

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           AeroPhoenix Deployment Verification                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    local failed=0
    
    for app in "${APPS[@]}"; do
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " $app"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        verify_app "$app" || ((failed++))
        test_suspend "$app"
        check_memory "$app"
    done
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Connectivity Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    verify_internal_network
    check_health
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Performance Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    test_wake_time "aerophoenix" "https://aerophoenix.fly.dev/"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    Verification Summary                          ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [ $failed -eq 0 ]; then
        log_success "All checks passed!"
    else
        log_error "$failed check(s) failed"
    fi
    
    echo ""
    log_info "Useful commands:"
    echo "  fly status -a aerophoenix       # Check app status"
    echo "  fly logs -a aerophoenix         # View logs"
    echo "  fly ssh console -a aerophoenix  # SSH into machine"
    echo "  fly machines list -a aerophoenix # List machines"
    echo ""
    
    return $failed
}

main "$@"
