#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }

assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "expected '$expected', got '$actual'"
    fi
}

assert_gt_zero() {
    local name="$1" value="$2"
    if [ "$value" -gt 0 ]; then
        pass "$name"
    else
        fail "$name" "expected > 0, got '$value'"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        pass "$name"
    else
        fail "$name" "expected to contain '$needle'"
    fi
}

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

# T1
run_t1() {
    setup_clean
    setup_spec forge t1-a $'src/auth/login.py\nsrc/auth/logout.py'
    setup_spec forge t1-b $'src/api/routes.py\nsrc/api/handlers.py'
    run_check t1-a t1-b
    assert_eq 'T1 exit' "$LAST_CODE" '0'
    assert_eq 'T1 overlap_count' "$(jq -r '.overlap_count' <<<"$LAST_OUT")" '0'
}

# T2
run_t2() {
    setup_clean
    setup_spec forge t2-a $'src/utils/helper.sh\nsrc/auth/login.py'
    setup_spec forge t2-b $'src/utils/helper.sh\nsrc/api/routes.py'
    run_check t2-a t2-b
    assert_eq 'T2 exit' "$LAST_CODE" '1'
    assert_eq 'T2 overlap_count' "$(jq -r '.overlap_count' <<<"$LAST_OUT")" '1'
    assert_eq 'T2 sensitive_overlap' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '0'
}

# T3
run_t3() {
    setup_clean
    setup_spec forge t3-a $'src/utils/a.py\nsrc/utils/b.py'
    setup_spec forge t3-b $'src/utils/a.py\nsrc/utils/b.py\nsrc/other.py'
    run_check t3-a t3-b
    assert_eq 'T3 exit' "$LAST_CODE" '1'
    assert_eq 'T3 overlap_count' "$(jq -r '.overlap_count' <<<"$LAST_OUT")" '2'
    assert_eq 'T3 sensitive_overlap' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '0'
}

# T4
run_t4() {
    setup_clean
    setup_spec forge t4-a $'a.py\nb.py\nc.py\nd.py'
    setup_spec forge t4-b $'a.py\nb.py\nc.py\nd.py\ne.py'
    run_check t4-a t4-b
    assert_eq 'T4 exit' "$LAST_CODE" '1'
    assert_eq 'T4 overlap_count' "$(jq -r '.overlap_count' <<<"$LAST_OUT")" '4'
}

# T5
run_t5() {
    setup_clean
    setup_spec forge t5-a $'db/schema.sql\nsrc/auth.py'
    setup_spec forge t5-b $'db/schema.sql\nsrc/other.py'
    run_check t5-a t5-b
    assert_eq 'T5 sensitive schema' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '1'
}

# T6
run_t6() {
    setup_clean
    setup_spec forge t6-a $'db/migration_001.sql\nsrc/auth.py'
    setup_spec forge t6-b $'db/migration_001.sql\nsrc/other.py'
    run_check t6-a t6-b
    assert_eq 'T6 sensitive migration' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '1'
}

# T7
run_t7() {
    setup_clean
    setup_spec forge t7-a $'src/types.ts\nsrc/auth.py'
    setup_spec forge t7-b $'src/types.ts\nsrc/other.py'
    run_check t7-a t7-b
    assert_eq 'T7 sensitive types' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '1'
}

# T8
run_t8() {
    setup_clean
    setup_spec forge t8-a $'src/interfaces.py\nsrc/auth.py'
    setup_spec forge t8-b $'src/interfaces.py\nsrc/other.py'
    run_check t8-a t8-b
    assert_eq 'T8 sensitive interfaces' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '1'
}

# T9
run_t9() {
    setup_clean
    setup_spec forge t9-a $'src/models.py\nsrc/auth.py'
    setup_spec forge t9-b $'src/models.py\nsrc/other.py'
    run_check t9-a t9-b
    assert_eq 'T9 sensitive models' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '1'
}

# T10
run_t10() {
    setup_clean
    setup_spec forge t10-a $'src/api.yaml\nsrc/auth.py'
    setup_spec forge t10-b $'src/api.yaml\nsrc/other.py'
    run_check t10-a t10-b
    assert_eq 'T10 sensitive api' "$(jq -r '.sensitive_overlap' <<<"$LAST_OUT")" '1'
}

# T11
run_t11() {
    setup_clean
    setup_spec forge t11-b $'src/a.py'
    run_check t11-missing t11-b
    assert_eq 'T11 missing slug_a exit' "$LAST_CODE" '0'
    assert_eq 'T11 missing slug_a overlap' "$(jq -r '.overlap_count' <<<"$LAST_OUT")" '0'
}

# T12
run_t12() {
    setup_clean
    setup_spec forge t12-a $'src/a.py'
    run_check t12-a t12-missing
    assert_eq 'T12 missing slug_b exit' "$LAST_CODE" '0'
    assert_eq 'T12 missing slug_b overlap' "$(jq -r '.overlap_count' <<<"$LAST_OUT")" '0'
}

# T13
run_t13() {
    setup_clean
    setup_spec forge t13-a 'No explicit file paths here.'
    setup_spec forge t13-b 'Still no explicit paths.'
    run_check t13-a t13-b
    assert_eq 'T13 empty extraction exit' "$LAST_CODE" '0'
    assert_eq 'T13 empty extraction overlap' "$(jq -r '.overlap_count' <<<"$LAST_OUT")" '0'
}

# T14
run_t14() {
    setup_clean
    set +e
    bash "$SCRIPT" only-one-arg >/dev/null 2>&1
    local code=$?
    set -e
    assert_eq 'T14 invalid args exit=2' "$code" '2'
}

# T15
run_t15() {
    setup_clean
    setup_spec forge t15-a $'src/a.py'
    setup_spec forge t15-b $'src/b.py'
    run_check t15-a t15-b
    if jq . <<<"$LAST_OUT" >/dev/null 2>&1; then
        pass 'T15 valid JSON'
    else
        fail 'T15 valid JSON' 'output is not valid JSON'
    fi
}

# T16
run_t16() {
    setup_clean
    setup_spec forge t16-a $'src/one.py\nsrc/two.py\nsrc/other.py'
    setup_spec forge t16-b $'src/one.py\nsrc/two.py\nsrc/else.py'
    run_check t16-a t16-b
    local files
    files="$(jq -r '.overlapping_files[]' <<<"$LAST_OUT")"
    assert_contains 'T16 files include src/one.py' "$files" 'src/one.py'
    assert_contains 'T16 files include src/two.py' "$files" 'src/two.py'
}

# T17
run_t17() {
    setup_clean
    setup_spec forge t17-a $'src/a.py\nsrc/b.py\nsrc/c.py'
    run_check t17-a t17-a
    assert_eq 'T17 self-compare exit' "$LAST_CODE" '1'
    assert_gt_zero 'T17 self-compare overlap_count>0' "$(jq -r '.overlap_count' <<<"$LAST_OUT")"
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9
run_t10
run_t11
run_t12
run_t13
run_t14
run_t15
run_t16
run_t17

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
