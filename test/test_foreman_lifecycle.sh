#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
assert_eq() {
    local n="$1" a="$2" e="$3"
    [ "$a" = "$e" ] && pass "$n" || fail "$n" "expected '$e', got '$a'"
}
assert_file_exists() {
    local n="$1" f="$2"
    [ -f "$f" ] && pass "$n" || fail "$n" "file not found: $f"
}
assert_dir_exists() {
    local n="$1" d="$2"
    [ -d "$d" ] && pass "$n" || fail "$n" "directory not found: $d"
}

TMPDIR_BASE="$(mktemp -d)"

setup() {
    mkdir -p "$TMPDIR_BASE/.foreman/continuity"
    mkdir -p "$TMPDIR_BASE/.foreman/rc-links"
    mkdir -p "$TMPDIR_BASE/.claude/hooks"
}

teardown() {
    [ -n "$TMPDIR_BASE" ] && rm -rf "$TMPDIR_BASE"
}

# --- Unit Tests ---

# T1: Sentinel file write format (no trailing newline)
test_sentinel_write() {
    printf '%s' "forge_main_foreman" > "$TMPDIR_BASE/.foreman/continuity/.session-name"
    local actual
    actual=$(cat "$TMPDIR_BASE/.foreman/continuity/.session-name")
    assert_eq "T1: sentinel contains session name" "$actual" "forge_main_foreman"
    # Verify no trailing newline
    local byte_count
    byte_count=$(wc -c < "$TMPDIR_BASE/.foreman/continuity/.session-name")
    # "forge_main_foreman" = 18 bytes; no trailing newline from printf '%s'
    assert_eq "T1: sentinel has no trailing newline" "$byte_count" "18"
}

# T2: PreCompact hook writes skeleton when continuity file missing
test_precompact_skeleton() {
    export HOME="$TMPDIR_BASE"
    printf '%s' "forge_main_foreman" > "$TMPDIR_BASE/.foreman/continuity/.session-name"
    local output
    output=$(printf '{"session_id":"test","cwd":"/home/agentdev/.foreman","trigger":"auto"}' | \
        bash /home/agentdev/.claude/hooks/foreman-pre-compact.sh 2>/dev/null)
    assert_file_exists "T2: skeleton written" "$TMPDIR_BASE/.foreman/continuity/forge_main_foreman.yaml"
    printf '%s' "$output" | grep -qF "CONTINUITY CONTEXT" && pass "T2: output has instructions" || fail "T2: output has instructions" "missing CONTINUITY CONTEXT"
}

# T3: SessionStart hook outputs JSON on compact source
test_sessionstart_compact() {
    export HOME="$TMPDIR_BASE"
    cat > "$TMPDIR_BASE/.foreman/continuity/forge_main_foreman.yaml" << 'EOF'
version: "1"
session_name: forge_main_foreman
compaction_count: 0
current_objective: "test"
EOF
    printf '%s' "forge_main_foreman" > "$TMPDIR_BASE/.foreman/continuity/.session-name"
    local output
    output=$(printf '{"source":"compact","cwd":"/home/agentdev/.foreman"}' | \
        bash /home/agentdev/.claude/hooks/foreman-session-start.sh 2>/dev/null)
    printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 && \
        pass "T3: JSON has additionalContext" || fail "T3: JSON has additionalContext" "missing hookSpecificOutput"
}

# T4: SessionStart hook is no-op on startup source
test_sessionstart_startup_noop() {
    local output
    output=$(printf '{"source":"startup","cwd":"/tmp"}' | \
        bash /home/agentdev/.claude/hooks/foreman-session-start.sh 2>/dev/null)
    assert_eq "T4: startup returns empty JSON" "$output" "{}"
}

# T5: PreCompact hook degrades gracefully for non-Foreman sessions
test_precompact_non_foreman() {
    export HOME="$TMPDIR_BASE"
    # Remove sentinel file
    rm -f "$TMPDIR_BASE/.foreman/continuity/.session-name"
    local output
    output=$(printf '{"session_id":"test","cwd":"/mnt/e/agentdev/projects/forge/main","trigger":"auto"}' | \
        bash /home/agentdev/.claude/hooks/foreman-pre-compact.sh 2>/dev/null)
    printf '%s' "$output" | grep -qF "CONTINUITY CONTEXT" && pass "T5: non-foreman gets generic instructions" || fail "T5: non-foreman gets generic instructions" "missing output"
    # Should NOT have written a skeleton file
    [ ! -f "$TMPDIR_BASE/.foreman/continuity/mnt_e_agentdev_projects_forge_main.yaml" ] && \
        pass "T5: no skeleton for non-foreman" || fail "T5: no skeleton for non-foreman" "skeleton was written"
}

# T6: world.yaml seed is valid YAML
test_world_yaml_valid() {
    cat > "$TMPDIR_BASE/.foreman/world.yaml" << 'EOF'
updated: null
environment: wsl
foreman_session_id: forge_main_foreman
rc_link: null
project_roots:
  - /mnt/e/agentdev/projects
active_specs: []
active_pi_sessions: []
pending_decisions: {}
foreman_mode:
  autonomous: false
  scope: null
  granted_at: null
  granted_by: null
  exit_conditions:
    - blocker_encountered
    - error_escalation
    - scope_complete
    - explicit_cancel
  excluded_checkpoints:
    - knowledge_promotion
    - deploy_to_production
completed: []
EOF
    python3 -c "import yaml; yaml.safe_load(open('$TMPDIR_BASE/.foreman/world.yaml'))" 2>/dev/null && \
        pass "T6: world.yaml is valid YAML" || fail "T6: world.yaml is valid YAML" "parse error"
}

# T7: settings.json has correct hook structure
test_settings_json_hooks() {
    local hooks_count
    hooks_count=$(jq '.hooks | keys | length' /home/agentdev/.claude/settings.json 2>/dev/null || printf '0')
    assert_eq "T7: settings.json has 2 hook types" "$hooks_count" "2"
}

# --- Run Tests ---

setup
test_sentinel_write
test_precompact_skeleton
test_sessionstart_compact
test_sessionstart_startup_noop
test_precompact_non_foreman
test_world_yaml_valid
test_settings_json_hooks
teardown

printf '\n\033[1mResults: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
