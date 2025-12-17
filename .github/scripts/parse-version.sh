#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION_REGEX='^v([0-9]+)\.([0-9]+)\.([0-9]+)(-((alpha|beta|rc)\.([0-9]+)))?$'

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

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <version>

Arguments:
    version    Semantic version string (e.g., v1.2.3, v1.2.3-rc.1)

Supported Formats:
    v1.2.3           Stable release
    v1.2.3-alpha.1   Alpha pre-release
    v1.2.3-beta.1    Beta pre-release
    v1.2.3-rc.1      Release candidate

Examples:
    ${SCRIPT_NAME} v1.0.0
    ${SCRIPT_NAME} v2.1.3-rc.5

EOF
}

validate_version() {
    local version="$1"
    
    if [[ ! "$version" =~ $VERSION_REGEX ]]; then
        log_error "Invalid semantic version: ${version}"
        log_error "Expected format: v<major>.<minor>.<patch>[-<channel>.<number>]"
        return 1
    fi
    
    return 0
}

parse_version() {
    local version="$1"
    
    if ! validate_version "$version"; then
        return 1
    fi
    
    [[ "$version" =~ $VERSION_REGEX ]]
    
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    local prerelease="${BASH_REMATCH[4]:-}"
    local channel="${BASH_REMATCH[6]:-stable}"
    local prerelease_num="${BASH_REMATCH[7]:-0}"
    
    local is_prerelease="false"
    if [[ -n "$prerelease" ]]; then
        is_prerelease="true"
    fi
    
    local version_bare="${version#v}"
    
    local stability_order=4
    case "$channel" in
        alpha) stability_order=1 ;;
        beta)  stability_order=2 ;;
        rc)    stability_order=3 ;;
        *)     stability_order=4 ;;
    esac
    
    output "version" "$version"
    output "version_bare" "$version_bare"
    output "major" "$major"
    output "minor" "$minor"
    output "patch" "$patch"
    output "prerelease" "$prerelease"
    output "channel" "$channel"
    output "prerelease_num" "$prerelease_num"
    output "is_prerelease" "$is_prerelease"
    output "stability_order" "$stability_order"
    
    log_info "Parsed version: ${version}"
    log_info "  Major: ${major}, Minor: ${minor}, Patch: ${patch}"
    log_info "  Channel: ${channel}, Pre-release: ${is_prerelease}"
    
    return 0
}

main() {
    if [[ $# -lt 1 ]]; then
        usage
        log_error "Missing version argument"
        exit 1
    fi
    
    local version="$1"
    
    if [[ -z "${version// /}" ]]; then
        log_error "Version cannot be empty"
        exit 1
    fi
    
    if ! parse_version "$version"; then
        exit 1
    fi
    
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
