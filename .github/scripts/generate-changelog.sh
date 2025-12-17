#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"

log_error() {
    echo "[ERROR] ${SCRIPT_NAME}: $1" >&2
}

log_info() {
    echo "[INFO] ${SCRIPT_NAME}: $1" >&2
}

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <from_ref> <to_ref> <output_file>

Arguments:
    from_ref     Starting reference (tag or commit), empty for first release
    to_ref       Ending reference (typically HEAD)
    output_file  Path to output changelog file

Examples:
    ${SCRIPT_NAME} v1.0.0 HEAD CHANGELOG.md
    ${SCRIPT_NAME} "" HEAD CHANGELOG.md

EOF
}

escape_markdown() {
    local text="$1"
    echo "$text" | sed -e 's/`/\\`/g' -e 's/\*/\\*/g' -e 's/_/\\_/g'
}

extract_commits_by_type() {
    local from_ref="$1"
    local to_ref="$2"
    local type="$3"
    local range
    
    if [[ -z "$from_ref" ]]; then
        range="$to_ref"
    else
        range="${from_ref}..${to_ref}"
    fi
    
    git log "$range" --oneline --no-merges 2>/dev/null | \
        grep -iE "^[a-f0-9]+ ${type}(\(.+\))?:" | \
        sed -E "s/^[a-f0-9]+ ${type}(\(.+\))?: /- /" | \
        head -20 || true
}

extract_other_commits() {
    local from_ref="$1"
    local to_ref="$2"
    local range
    
    if [[ -z "$from_ref" ]]; then
        range="$to_ref"
    else
        range="${from_ref}..${to_ref}"
    fi
    
    git log "$range" --oneline --no-merges 2>/dev/null | \
        grep -viE "^[a-f0-9]+ (feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?:" | \
        sed 's/^[a-f0-9]* /- /' | \
        head -15 || true
}

count_commits() {
    local from_ref="$1"
    local to_ref="$2"
    local range
    
    if [[ -z "$from_ref" ]]; then
        git rev-list --count "$to_ref" 2>/dev/null || echo "0"
    else
        git rev-list --count "${from_ref}..${to_ref}" 2>/dev/null || echo "0"
    fi
}

get_contributors() {
    local from_ref="$1"
    local to_ref="$2"
    local range
    
    if [[ -z "$from_ref" ]]; then
        range="$to_ref"
    else
        range="${from_ref}..${to_ref}"
    fi
    
    git log "$range" --format='@%aN' 2>/dev/null | \
        sort -u | \
        head -10 | \
        tr '\n' ', ' | \
        sed 's/,$//' || true
}

generate_changelog() {
    local from_ref="$1"
    local to_ref="$2"
    local output_file="$3"
    
    log_info "Generating changelog: ${from_ref:-'(initial)'}..${to_ref}"
    
    local commit_count
    commit_count=$(count_commits "$from_ref" "$to_ref")
    log_info "Found ${commit_count} commits in range"
    
    cat > "$output_file" << 'HEADER'
## What's Changed

HEADER
    
    local features
    features=$(extract_commits_by_type "$from_ref" "$to_ref" "feat")
    if [[ -n "$features" ]]; then
        echo "### Features" >> "$output_file"
        echo "" >> "$output_file"
        echo "$features" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    local fixes
    fixes=$(extract_commits_by_type "$from_ref" "$to_ref" "fix")
    if [[ -n "$fixes" ]]; then
        echo "### Bug Fixes" >> "$output_file"
        echo "" >> "$output_file"
        echo "$fixes" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    local perf
    perf=$(extract_commits_by_type "$from_ref" "$to_ref" "perf")
    if [[ -n "$perf" ]]; then
        echo "### ⚡ Performance" >> "$output_file"
        echo "" >> "$output_file"
        echo "$perf" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    local docs
    docs=$(extract_commits_by_type "$from_ref" "$to_ref" "docs")
    if [[ -n "$docs" ]]; then
        echo "### Documentation" >> "$output_file"
        echo "" >> "$output_file"
        echo "$docs" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    local other
    other=$(extract_other_commits "$from_ref" "$to_ref")
    if [[ -n "$other" ]]; then
        echo "### Other Changes" >> "$output_file"
        echo "" >> "$output_file"
        echo "$other" >> "$output_file"
        echo "" >> "$output_file"
    fi
    
    if [[ -z "$features" && -z "$fixes" && -z "$perf" && -z "$docs" && -z "$other" ]]; then
        echo "### Changes" >> "$output_file"
        echo "" >> "$output_file"
        if [[ -z "$from_ref" ]]; then
            git log "$to_ref" --oneline --no-merges -20 2>/dev/null | \
                sed 's/^[a-f0-9]* /- /' >> "$output_file" || true
        else
            git log "${from_ref}..${to_ref}" --oneline --no-merges -20 2>/dev/null | \
                sed 's/^[a-f0-9]* /- /' >> "$output_file" || true
        fi
        echo "" >> "$output_file"
    fi
    
    echo "---" >> "$output_file"
    echo "" >> "$output_file"
    echo "**Full Changelog**: ${commit_count} commits" >> "$output_file"
    if [[ -n "$from_ref" ]]; then
        echo "**Compare**: \`${from_ref}...${to_ref}\`" >> "$output_file"
    fi
    
    log_info "Changelog written to: ${output_file}"
    return 0
}

main() {
    if [[ $# -lt 3 ]]; then
        usage
        log_error "Missing required arguments"
        exit 1
    fi
    
    local from_ref="$1"
    local to_ref="$2"
    local output_file="$3"
    
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not a git repository"
        exit 2
    fi
    
    if ! git rev-parse --verify "$to_ref" > /dev/null 2>&1; then
        log_error "Invalid reference: ${to_ref}"
        exit 2
    fi
    
    if [[ -n "$from_ref" ]]; then
        if ! git rev-parse --verify "$from_ref" > /dev/null 2>&1; then
            log_info "Reference ${from_ref} not found, treating as first release"
            from_ref=""
        fi
    fi
    
    if ! generate_changelog "$from_ref" "$to_ref" "$output_file"; then
        log_error "Failed to generate changelog"
        exit 2
    fi
    
    exit 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
