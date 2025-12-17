#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

log_error() {
    echo "[ERROR] ${SCRIPT_NAME}: $1" >&2
}

log_info() {
    echo "[INFO] ${SCRIPT_NAME}: $1" >&2
}

output() {
    local key="$1"
    local value="$2"
    
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "${key}=${value}" >> "$GITHUB_OUTPUT"
    fi
    echo "${key}=${value}"
}

extract_go_version() {
    local go_mod_path="$1"
    
    if [[ ! -f "$go_mod_path" ]]; then
        log_error "go.mod not found: ${go_mod_path}"
        return 1
    fi
    
    local version
    version=$(grep -E '^go [0-9]+\.[0-9]+' "$go_mod_path" | head -1 | awk '{print $2}')
    
    if [[ -z "$version" ]]; then
        log_error "Could not extract Go version from ${go_mod_path}"
        return 1
    fi
    
    echo "$version"
}

extract_elixir_version() {
    local mix_exs_path="$1"
    
    if [[ ! -f "$mix_exs_path" ]]; then
        log_error "mix.exs not found: ${mix_exs_path}"
        return 1
    fi
    
    local version
    version=$(grep -E 'elixir:.*"~>' "$mix_exs_path" | head -1 | grep -oE '[0-9]+\.[0-9]+')
    
    if [[ -z "$version" ]]; then
        log_error "Could not extract Elixir version from ${mix_exs_path}"
        return 1
    fi
    
    echo "$version"
}

extract_rust_edition() {
    local cargo_toml_path="$1"
    
    if [[ ! -f "$cargo_toml_path" ]]; then
        log_error "Cargo.toml not found: ${cargo_toml_path}"
        return 1
    fi
    
    local edition
    edition=$(grep -E '^edition\s*=' "$cargo_toml_path" | head -1 | grep -oE '[0-9]+')
    
    if [[ -z "$edition" ]]; then
        log_error "Could not extract Rust edition from ${cargo_toml_path}"
        return 1
    fi
    
    echo "$edition"
}

main() {
    local project_root="${1:-.}"
    
    log_info "Extracting versions from project: ${project_root}"
    
    local go_version
    if go_version=$(extract_go_version "${project_root}/apps/flyd-sim/go.mod" 2>/dev/null); then
        output "go_version" "$go_version"
        log_info "Go version: ${go_version}"
    elif go_version=$(extract_go_version "${project_root}/cli/aeropctl/go.mod" 2>/dev/null); then
        output "go_version" "$go_version"
        log_info "Go version (from CLI): ${go_version}"
    else
        output "go_version" "1.23"
        log_info "Go version: 1.23 (default)"
    fi
    
    local elixir_version
    if elixir_version=$(extract_elixir_version "${project_root}/apps/orchestrator/mix.exs" 2>/dev/null); then
        output "elixir_version" "${elixir_version}"
        log_info "Elixir version: ${elixir_version}"
    else
        output "elixir_version" "1.15"
        log_info "Elixir version: 1.15 (default)"
    fi
    
    local rust_edition
    if rust_edition=$(extract_rust_edition "${project_root}/apps/net-sim/Cargo.toml" 2>/dev/null); then
        output "rust_edition" "$rust_edition"
        log_info "Rust edition: ${rust_edition}"
    else
        output "rust_edition" "2021"
        log_info "Rust edition: 2021 (default)"
    fi
    
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
