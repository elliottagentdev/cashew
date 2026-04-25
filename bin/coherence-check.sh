#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PROJECTS_ROOT="${SPEC_ROOT:-/mnt/e/agentdev/projects}"

usage() {
    echo "Usage: coherence-check.sh <slug_a> <slug_b>" >&2
}

json_out() {
    local overlap_count="$1"
    local sensitive_overlap="$2"
    local overlapping_files_json="$3"

    jq -n \
        --argjson overlap_count "$overlap_count" \
        --argjson sensitive_overlap "$sensitive_overlap" \
        --argjson overlapping_files "$overlapping_files_json" \
        '{overlap_count:$overlap_count,sensitive_overlap:$sensitive_overlap,overlapping_files:$overlapping_files}'
}

find_spec() {
    local slug="$1"
    local spec_path

    for repo_dir in "$PROJECTS_ROOT"/*; do
        [ -d "$repo_dir" ] || continue
        spec_path="$repo_dir/main/.specs/$slug/plans/SPEC.md"
        if [ -r "$spec_path" ]; then
            printf '%s\n' "$spec_path"
            return 0
        fi
    done

    return 1
}

extract_files() {
    local spec_path="$1"
    grep -oE '[[:alnum:]_./-]+\.(py|ts|js|go|rs|sh|yaml|yml|json|sql)' "$spec_path" \
        | sed 's|^\./||' \
        | sort -u
}

count_sensitive() {
    local overlap_lines="$1"

    if [ -z "$overlap_lines" ]; then
        printf '0\n'
        return 0
    fi

    printf '%s\n' "$overlap_lines" | grep -cE '(schema|migration|types\.|interfaces\.|models\.|api\.)' || true
}

main() {
    if [ "$#" -ne 2 ]; then
        usage
        exit 2
    fi

    command -v grep >/dev/null 2>&1 || exit 2
    command -v sort >/dev/null 2>&1 || exit 2
    command -v comm >/dev/null 2>&1 || exit 2
    command -v jq >/dev/null 2>&1 || exit 2

    local slug_a="$1"
    local slug_b="$2"

    local spec_a spec_b
    if ! spec_a="$(find_spec "$slug_a")"; then
        echo "SPEC not found for slug: $slug_a" >&2
        json_out 0 0 '[]'
        exit 0
    fi

    if ! spec_b="$(find_spec "$slug_b")"; then
        echo "SPEC not found for slug: $slug_b" >&2
        json_out 0 0 '[]'
        exit 0
    fi

    local files_a files_b
    files_a="$(extract_files "$spec_a" || true)"
    files_b="$(extract_files "$spec_b" || true)"

    if [ -z "$files_a" ] || [ -z "$files_b" ]; then
        json_out 0 0 '[]'
        exit 0
    fi

    local overlap_lines
    overlap_lines="$(comm -12 <(printf '%s\n' "$files_a") <(printf '%s\n' "$files_b") || true)"

    if [ -z "$overlap_lines" ]; then
        json_out 0 0 '[]'
        exit 0
    fi

    local overlap_count sensitive_overlap overlapping_files_json
    overlap_count="$(printf '%s\n' "$overlap_lines" | grep -c . || true)"
    sensitive_overlap="$(count_sensitive "$overlap_lines")"
    overlapping_files_json="$(printf '%s\n' "$overlap_lines" | jq -R . | jq -s .)"

    json_out "$overlap_count" "$sensitive_overlap" "$overlapping_files_json"
    exit 1
}

main "$@"
