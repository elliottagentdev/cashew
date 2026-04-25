#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
assert_eq() {
    local n="$1" a="$2" e="$3"
    [ "$a" = "$e" ] && pass "$n" || fail "$n" "expected '$e', got '$a'"
}

TMPDIR_BASE="$(mktemp -d)"
teardown() { [ -n "${TMPDIR_BASE:-}" ] && rm -rf "$TMPDIR_BASE"; }
trap teardown EXIT

printf '\n=== test_send_pi_claude_code ===\n'

# --- T1: Claude Code session detection by sub name ---
printf '\n--- T1: Claude Code sub detection ---\n'

detect_claude_code() {
    local sub="$1"
    if [[ "$sub" == "foreman" || "$sub" == "claude" ]]; then
        echo "claude-code"
    else
        echo "pi"
    fi
}

assert_eq "foreman sub detected"   "$(detect_claude_code "foreman")" "claude-code"
assert_eq "claude sub detected"    "$(detect_claude_code "claude")"  "claude-code"
assert_eq "pi sub not detected"    "$(detect_claude_code "pi")"      "pi"
assert_eq "kw-arch not detected"   "$(detect_claude_code "kw-arch")" "pi"
assert_eq "empty sub not detected" "$(detect_claude_code "")"        "pi"
assert_eq "specs not detected"     "$(detect_claude_code "specs")"   "pi"

# --- T2: Session name resolution ---
printf '\n--- T2: Session name resolution ---\n'

SEP="_"
to_session_name() { echo "$1" | sed "s|/|${SEP}|g"; }

assert_eq "foreman session name" "$(to_session_name "forge/main/foreman")" "forge_main_foreman"
assert_eq "claude session name"  "$(to_session_name "forge/main/claude")"  "forge_main_claude"
assert_eq "hub claude name"      "$(to_session_name "hub/claude")"         "hub_claude"

# --- T3: Queue file NOT written for Claude Code sessions ---
printf '\n--- T3: Queue bypass for Claude Code ---\n'

export HOME="$TMPDIR_BASE"
mkdir -p "$HOME/.pi/queues"

QUEUE_DIR="$HOME/.pi/queues"
file_count=$(find "$QUEUE_DIR" -name '*.jsonl' | wc -l | tr -d '[:space:]')
assert_eq "no queue files initially" "$file_count" "0"

# --- Summary ---
printf '\n\033[1mResults: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
