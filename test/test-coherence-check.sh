#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }

SCRIPT="/mnt/e/agentdev/projects/cashew/bin/coherence-check.sh"
TMPDIR_BASE="$(mktemp -d)"
export SPEC_ROOT="$TMPDIR_BASE/projects"

teardown() {
    rm -rf "$TMPDIR_BASE"
}
trap teardown EXIT

setup_clean() {
    rm -rf "$SPEC_ROOT"
    mkdir -p "$SPEC_ROOT"
}

setup_spec() {
    local repo="$1" slug="$2" content="$3"
    local dir="$SPEC_ROOT/$repo/main/.specs/$slug/plans"
    mkdir -p "$dir"
    printf '%s\n' "$content" > "$dir/SPEC.md"
}

LAST_OUT=""
LAST_CODE=0
run_check() {
    local a="$1" b="$2"
    set +e
    LAST_OUT="$(bash "$SCRIPT" "$a" "$b" 2>/dev/null)"
    LAST_CODE=$?
    set -e
}

run_test() {
    local name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name" "check failed"
    fi
}

# T1 Zero overlap
check_t1() {
    setup_clean
    setup_spec forge t1-a $'src/auth/login.py\nsrc/auth/logout.py'
    setup_spec forge t1-b $'src/api/routes.py\nsrc/api/handlers.py'
    run_check t1-a t1-b
    [ "$LAST_CODE" -eq 0 ] && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" = "0" ]
}

# T2 1 non-sensitive overlap
check_t2() {
    setup_clean
    setup_spec forge t2-a $'src/utils/helper.sh\nsrc/auth/login.py'
    setup_spec forge t2-b $'src/utils/helper.sh\nsrc/api/routes.py'
    run_check t2-a t2-b
    [ "$LAST_CODE" -eq 1 ] \
      && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" = "1" ] \
      && [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "0" ]
}

# T3 2 non-sensitive overlaps
check_t3() {
    setup_clean
    setup_spec forge t3-a $'src/utils/a.py\nsrc/utils/b.py'
    setup_spec forge t3-b $'src/utils/a.py\nsrc/utils/b.py\nsrc/other.py'
    run_check t3-a t3-b
    [ "$LAST_CODE" -eq 1 ] \
      && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" = "2" ] \
      && [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "0" ]
}

# T4 3+ overlaps
check_t4() {
    setup_clean
    setup_spec forge t4-a $'a.py\nb.py\nc.py\nd.py'
    setup_spec forge t4-b $'a.py\nb.py\nc.py\nd.py\ne.py'
    run_check t4-a t4-b
    [ "$LAST_CODE" -eq 1 ] && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" = "4" ]
}

# T5 schema sensitive
check_t5() {
    setup_clean
    setup_spec forge t5-a $'db/schema.sql\nsrc/auth.py'
    setup_spec forge t5-b $'db/schema.sql\nsrc/other.py'
    run_check t5-a t5-b
    [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "1" ]
}

# T6 migration sensitive
check_t6() {
    setup_clean
    setup_spec forge t6-a $'db/migration_001.sql\nsrc/auth.py'
    setup_spec forge t6-b $'db/migration_001.sql\nsrc/other.py'
    run_check t6-a t6-b
    [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "1" ]
}

# T7 types sensitive
check_t7() {
    setup_clean
    setup_spec forge t7-a $'src/types.ts\nsrc/auth.py'
    setup_spec forge t7-b $'src/types.ts\nsrc/other.py'
    run_check t7-a t7-b
    [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "1" ]
}

# T8 interfaces sensitive
check_t8() {
    setup_clean
    setup_spec forge t8-a $'src/interfaces.py\nsrc/auth.py'
    setup_spec forge t8-b $'src/interfaces.py\nsrc/other.py'
    run_check t8-a t8-b
    [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "1" ]
}

# T9 models sensitive
check_t9() {
    setup_clean
    setup_spec forge t9-a $'src/models.py\nsrc/auth.py'
    setup_spec forge t9-b $'src/models.py\nsrc/other.py'
    run_check t9-a t9-b
    [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "1" ]
}

# T10 api sensitive
check_t10() {
    setup_clean
    setup_spec forge t10-a $'src/api.yaml\nsrc/auth.py'
    setup_spec forge t10-b $'src/api.yaml\nsrc/other.py'
    run_check t10-a t10-b
    [ "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" = "1" ]
}

# T11 missing slug_a
check_t11() {
    setup_clean
    setup_spec forge t11-b $'src/a.py'
    run_check t11-missing t11-b
    [ "$LAST_CODE" -eq 0 ] && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" = "0" ]
}

# T12 missing slug_b
check_t12() {
    setup_clean
    setup_spec forge t12-a $'src/a.py'
    run_check t12-a t12-missing
    [ "$LAST_CODE" -eq 0 ] && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" = "0" ]
}

# T13 no file paths
check_t13() {
    setup_clean
    setup_spec forge t13-a 'No explicit file paths here.'
    setup_spec forge t13-b 'Still no explicit paths.'
    run_check t13-a t13-b
    [ "$LAST_CODE" -eq 0 ] && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" = "0" ]
}

# T14 invalid args -> exit 2
check_t14() {
    setup_clean
    set +e
    bash "$SCRIPT" only-one-arg >/dev/null 2>&1
    local code=$?
    set -e
    [ "$code" -eq 2 ]
}

# T15 valid JSON
check_t15() {
    setup_clean
    setup_spec forge t15-a $'src/a.py'
    setup_spec forge t15-b $'src/b.py'
    run_check t15-a t15-b
    jq . <<<"$LAST_OUT" >/dev/null 2>&1
}

# T16 overlapping_files content
check_t16() {
    setup_clean
    setup_spec forge t16-a $'src/one.py\nsrc/two.py\nsrc/other.py'
    setup_spec forge t16-b $'src/one.py\nsrc/two.py\nsrc/else.py'
    run_check t16-a t16-b
    local files
    files="$(jq -r '.overlapping_files[]' <<<"$LAST_OUT")"
    printf '%s' "$files" | grep -qF 'src/one.py' && printf '%s' "$files" | grep -qF 'src/two.py'
}

# T17 self-comparison > 0 overlap
check_t17() {
    setup_clean
    setup_spec forge t17-a $'src/a.py\nsrc/b.py\nsrc/c.py'
    run_check t17-a t17-a
    [ "$LAST_CODE" -eq 1 ] && [ "$(jq -r '.overlap_count' <<<"$LAST_OUT")" -gt 0 ]
}

run_test 'T1 zero overlap' check_t1
run_test 'T2 one non-sensitive overlap' check_t2
run_test 'T3 two non-sensitive overlaps' check_t3
run_test 'T4 three-plus overlaps' check_t4
run_test 'T5 sensitive schema' check_t5
run_test 'T6 sensitive migration' check_t6
run_test 'T7 sensitive types' check_t7
run_test 'T8 sensitive interfaces' check_t8
run_test 'T9 sensitive models' check_t9
run_test 'T10 sensitive api' check_t10
run_test 'T11 missing slug_a' check_t11
run_test 'T12 missing slug_b' check_t12
run_test 'T13 no file paths' check_t13
run_test 'T14 invalid args exit 2' check_t14
run_test 'T15 valid JSON output' check_t15
run_test 'T16 overlapping_files array' check_t16
run_test 'T17 self-comparison overlap' check_t17

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
