#!/usr/bin/env bash
# W1-4 Pi Completion Protocol — automated test harness.
# Exercises the DONE.md parse rules, checkpoint-variant selection, and
# defer/dedup logic documented in FOREMAN_BEHAVIOR.md §9.
#
# The Foreman is a Claude Code agent; it executes these stanzas inline during
# its event loop. The same stanzas are reproduced here so they can be run
# in isolation.
#
# Test coverage map (W1-4 SPEC §5):
#   T1  well-formed DONE.md                    — §5.2
#   T2  missing Test Results section           — §5.2
#   T3  missing Deferred Work section          — §5.2
#   T4  empty DONE.md                          — §5.2
#   T5  malformed pass/fail counts             — §5.2
#   T6  extra/unexpected sections              — §5.2
#   T7  detection helper (inline check)        — §5.3
#   T10 dead Pi without DONE.md                — §5.3
#   T15 no TASKS.md in worktree                — §5.4
#   T16 RC link missing                        — §5.4
#   C1  missing user_profile.experience_level  — CONSTRAINT C1 (advanced default)
#   C1b user_profile.experience_level=novice   — CONSTRAINT C1 (novice selected)
#   C2  defer handler sets deferred_remind_at  — CONSTRAINT C2
#   C2b re-present walker skips deferred       — CONSTRAINT C2
#   BH  FOREMAN_BEHAVIOR.md contains §9        — docs check
#   BH-R §9.4 and §9.8 contain ## Risk section — W2-7

set -euo pipefail
IFS=$'\n\t'

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
assert_eq() {
    local n="$1" a="$2" e="$3"
    [ "$a" = "$e" ] && pass "$n" || fail "$n" "expected '$e', got '$a'"
}
assert_contains() {
    local n="$1" haystack="$2" needle="$3"
    printf '%s' "$haystack" | grep -qF "$needle" && pass "$n" || fail "$n" "expected to contain '$needle'"
}
assert_file_exists() {
    local n="$1" f="$2"
    [ -f "$f" ] && pass "$n" || fail "$n" "file not found: $f"
}

TMPDIR_BASE="$(mktemp -d)"
teardown() { [ -n "${TMPDIR_BASE:-}" ] && rm -rf "$TMPDIR_BASE"; }
trap teardown EXIT

# ------------------------------------------------------------------
# Inline parse implementation -- mirrors FOREMAN_BEHAVIOR.md §9.1/§9.3
# ------------------------------------------------------------------

# Extract the summary: first non-empty paragraph under "## Summary".
parse_summary() {
    local f="$1"
    awk '
        /^## Summary[[:space:]]*$/ { in_sec=1; next }
        /^## / && in_sec { exit }
        in_sec && NF > 0 { print; exit }
    ' "$f" 2>/dev/null || true
}

# Extract integer following a header bullet inside "## Test Results".
# Args: file, "Pass" | "Fail" | "Skipped"
parse_test_count() {
    local f="$1" key="$2"
    awk -v key="$key" '
        /^## Test Results[[:space:]]*$/ { in_sec=1; next }
        /^## / && in_sec { exit }
        in_sec {
            if (match($0, "^- " key ":[[:space:]]*([0-9]+)", m)) {
                print m[1]; exit
            }
        }
    ' "$f" 2>/dev/null
    # default to 0 if nothing matched
}

# Count bullets under "## Files Changed".
parse_file_count() {
    local f="$1"
    awk '
        /^## Files Changed[[:space:]]*$/ { in_sec=1; next }
        /^## / && in_sec { exit }
        in_sec && /^- / { n++ }
        END { print n+0 }
    ' "$f" 2>/dev/null
}

# Lines under a named bullet section.
parse_bullets() {
    local f="$1" section="$2"
    awk -v sec="## $section" '
        $0 == sec { in_sec=1; next }
        /^## / && in_sec { exit }
        in_sec && /^- / { sub(/^- /, ""); print }
    ' "$f" 2>/dev/null
}

# Fallback-aware int (empty string -> "0")
int_default_zero() {
    local v="$1"
    [ -n "$v" ] && [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "0"
}

# Resolve DONE.md path with fallback. Echoes found path or empty string.
locate_done() {
    local repo="$1" wt="$2" slug="$3" root="$4"
    local primary="$root/$repo/$wt/.specs/$slug/DONE.md"
    local fallback="$root/$repo/$wt/DONE.md"
    if [ -f "$primary" ]; then echo "$primary"
    elif [ -f "$fallback" ]; then echo "$fallback"
    else echo ""
    fi
}

# ------------------------------------------------------------------
# Inline variant selector (CONSTRAINT C1)
# Reads world.yaml user_profile.experience_level; defaults to "advanced".
# ------------------------------------------------------------------
select_variant() {
    local world="$1"
    [ -f "$world" ] || { echo "advanced"; return; }
    local level
    level=$(python3 -c "
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    v = (d.get('user_profile') or {}).get('experience_level')
    print(v if v else '')
except Exception:
    print('')
" "$world" 2>/dev/null)
    case "$level" in
        novice) echo "novice" ;;
        *)      echo "advanced" ;;
    esac
}

# ------------------------------------------------------------------
# Inline defer handler (CONSTRAINT C2)
# Produces an updated decision JSON with fresh telegram_sent_at and
# deferred_remind_at = now + 12h. expires_at aligned with remind_at.
# ------------------------------------------------------------------
defer_decision() {
    local decision_json="$1"
    local now_iso
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local remind_iso
    remind_iso=$(date -u -d "+12 hours" +%Y-%m-%dT%H:%M:%SZ)
    jq -c \
      --arg now "$now_iso" \
      --arg remind "$remind_iso" \
      '. + {telegram_sent_at:$now, deferred_remind_at:$remind, expires_at:$remind, archived:false}' \
      <<< "$decision_json"
}

# Re-present walker gate (CONSTRAINT C2): returns 0 if the decision should be
# re-presented, 1 if it should be skipped.
should_represent() {
    local decision_json="$1"
    local now_iso
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    python3 - "$decision_json" "$now_iso" << 'PY'
import sys, json
from datetime import datetime, timezone

def parse(s):
    if not s or s in (None,"null"): return None
    return datetime.fromisoformat(s.replace("Z","+00:00"))

d = json.loads(sys.argv[1])
now = datetime.fromisoformat(sys.argv[2].replace("Z","+00:00"))

# Deferred override: skip until deferred_remind_at
dra = parse(d.get("deferred_remind_at"))
if dra and dra > now:
    sys.exit(1)

# Standard dedup: skip if telegram_sent_at < 30min ago
tsa = parse(d.get("telegram_sent_at"))
if tsa and (now - tsa).total_seconds() < 30*60:
    sys.exit(1)

# Skip if created < 5min ago
ca = parse(d.get("created_at"))
if ca and (now - ca).total_seconds() < 5*60:
    sys.exit(1)

sys.exit(0)
PY
}

# ------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------
mk_well_formed_done() {
    local f="$1"
    mkdir -p "$(dirname "$f")"
    cat > "$f" << 'DONE_EOF'
# DONE: Add widget validation

## Summary
Added input validation to the widget creation endpoint. All edge cases covered.

## Test Results
```
npm test
42 tests passed, 1 failed, 2 skipped
```
- Pass: 42
- Fail: 1
- Skipped: 2

## Files Changed
- `src/widgets/validate.ts` -- new validation module
- `src/widgets/create.ts` -- integrated validation call
- `test/widgets/validate.test.ts` -- new test file

## Commits
- `a1b2c3d` feat: add widget input validation
- `e4f5g6h` test: add validation test cases

## Deferred Work
- Performance optimization for bulk validation

## Risks
- Validation regex may be too strict for Unicode input
DONE_EOF
}

# ------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------
echo "== T1: well-formed DONE.md =="
DONE1="$TMPDIR_BASE/specs/widget/DONE.md"
mk_well_formed_done "$DONE1"
assert_eq "T1 summary" \
    "$(parse_summary "$DONE1")" \
    "Added input validation to the widget creation endpoint. All edge cases covered."
assert_eq "T1 pass_count" "$(int_default_zero "$(parse_test_count "$DONE1" Pass)")" "42"
assert_eq "T1 fail_count" "$(int_default_zero "$(parse_test_count "$DONE1" Fail)")" "1"
assert_eq "T1 file_count" "$(parse_file_count "$DONE1")" "3"
deferred_items=$(parse_bullets "$DONE1" "Deferred Work")
assert_eq "T1 deferred_items count" "$(printf '%s\n' "$deferred_items" | wc -l | tr -d ' ')" "1"
assert_contains "T1 deferred_items content" "$deferred_items" "Performance optimization for bulk validation"
risks=$(parse_bullets "$DONE1" "Risks")
assert_contains "T1 risks content" "$risks" "Validation regex"
commits=$(parse_bullets "$DONE1" "Commits")
assert_eq "T1 commits count" "$(printf '%s\n' "$commits" | wc -l | tr -d ' ')" "2"

echo
echo "== T2: missing Test Results section =="
DONE2="$TMPDIR_BASE/specs/t2/DONE.md"
mkdir -p "$(dirname "$DONE2")"
cat > "$DONE2" << 'EOF'
# DONE: T2

## Summary
Changes with no test block.

## Files Changed
- `a.ts` -- tweak
EOF
assert_eq "T2 pass_count defaults to 0" "$(int_default_zero "$(parse_test_count "$DONE2" Pass)")" "0"
assert_eq "T2 fail_count defaults to 0" "$(int_default_zero "$(parse_test_count "$DONE2" Fail)")" "0"
assert_eq "T2 file_count" "$(parse_file_count "$DONE2")" "1"

echo
echo "== T3: missing Deferred Work section =="
DONE3="$TMPDIR_BASE/specs/t3/DONE.md"
mkdir -p "$(dirname "$DONE3")"
cat > "$DONE3" << 'EOF'
# DONE: T3

## Summary
Complete.

## Test Results
```
ok
```
- Pass: 1
- Fail: 0

## Files Changed
- `x.ts` -- x
EOF
deferred=$(parse_bullets "$DONE3" "Deferred Work")
assert_eq "T3 deferred_items empty" "$deferred" ""

echo
echo "== T4: empty DONE.md =="
DONE4="$TMPDIR_BASE/specs/t4/DONE.md"
mkdir -p "$(dirname "$DONE4")"
: > "$DONE4"
assert_eq "T4 summary empty" "$(parse_summary "$DONE4")" ""
assert_eq "T4 pass_count default" "$(int_default_zero "$(parse_test_count "$DONE4" Pass)")" "0"
assert_eq "T4 fail_count default" "$(int_default_zero "$(parse_test_count "$DONE4" Fail)")" "0"
assert_eq "T4 file_count default" "$(parse_file_count "$DONE4")" "0"

echo
echo "== T5: malformed pass/fail counts =="
DONE5="$TMPDIR_BASE/specs/t5/DONE.md"
mkdir -p "$(dirname "$DONE5")"
cat > "$DONE5" << 'EOF'
# DONE: T5

## Summary
Weird numbers.

## Test Results
```
oops
```
- Pass: many
- Fail: none
EOF
# parse_test_count regex requires digits; output is empty -> int_default_zero returns 0
assert_eq "T5 malformed pass -> 0" "$(int_default_zero "$(parse_test_count "$DONE5" Pass)")" "0"
assert_eq "T5 malformed fail -> 0" "$(int_default_zero "$(parse_test_count "$DONE5" Fail)")" "0"

echo
echo "== T6: extra/unexpected sections are ignored =="
DONE6="$TMPDIR_BASE/specs/t6/DONE.md"
mkdir -p "$(dirname "$DONE6")"
cat > "$DONE6" << 'EOF'
# DONE: T6

## Summary
Extras.

## Notes
- should be ignored

## Test Results
- Pass: 5
- Fail: 0

## Files Changed
- `a.ts` -- a
- `b.ts` -- b
EOF
assert_eq "T6 pass_count" "$(int_default_zero "$(parse_test_count "$DONE6" Pass)")" "5"
assert_eq "T6 file_count" "$(parse_file_count "$DONE6")" "2"
notes=$(parse_bullets "$DONE6" "Notes")
assert_contains "T6 notes parseable but not used downstream" "$notes" "should be ignored"

echo
echo "== T7: detection helper with spec-dir and fallback locations =="
# Primary location
WT_ROOT="$TMPDIR_BASE/proj"
mkdir -p "$WT_ROOT/forge/feature-a/.specs/42-slug"
echo "# DONE" > "$WT_ROOT/forge/feature-a/.specs/42-slug/DONE.md"
assert_eq "T7 primary path located" \
    "$(locate_done forge feature-a 42-slug "$WT_ROOT")" \
    "$WT_ROOT/forge/feature-a/.specs/42-slug/DONE.md"
# Fallback location only
mkdir -p "$WT_ROOT/forge/feature-b"
echo "# DONE" > "$WT_ROOT/forge/feature-b/DONE.md"
assert_eq "T7 fallback path located" \
    "$(locate_done forge feature-b 99-slug "$WT_ROOT")" \
    "$WT_ROOT/forge/feature-b/DONE.md"
# Neither
assert_eq "T7 neither path -> empty" \
    "$(locate_done forge feature-c 11-slug "$WT_ROOT")" \
    ""

echo
echo "== T10: dead Pi without DONE.md -> detection skips gracefully =="
# locate_done returns empty; the caller treats this as a crash candidate.
res=$(locate_done forge feature-dead 77-slug "$WT_ROOT")
assert_eq "T10 no DONE.md for dead session" "$res" ""

echo
echo "== T15: no TASKS.md => total_tasks=1, remaining_tasks=0 =="
WT_T15="$WT_ROOT/forge/feature-a"
if [ -f "$WT_T15/TASKS.md" ]; then
    total=$(grep -c '^- ' "$WT_T15/TASKS.md" || echo 0)
else
    total=1
fi
task_number=1
remaining=$((total - task_number))
assert_eq "T15 total_tasks" "$total" "1"
assert_eq "T15 remaining_tasks" "$remaining" "0"

echo
echo "== T16: RC link missing => checkpoint omits transcript line =="
world_t16="$TMPDIR_BASE/world_t16.yaml"
cat > "$world_t16" << 'EOF'
active_pi_sessions:
  - session: forge_fa_pi
    repo: forge
    worktree: feature-a
    spec_slug: 42-slug
    rc_link: null
EOF
rc=$(python3 -c "
import yaml
d=yaml.safe_load(open('$world_t16'))
print(d['active_pi_sessions'][0].get('rc_link') or '')
")
assert_eq "T16 rc_link resolves empty" "$rc" ""
# Build the advanced variant checkpoint; verify no transcript line emitted
msg="✓ Pi done -- [forge#42] task 1/1
Tests: 5 pass, 0 fail. Files changed: 2."
if [ -n "$rc" ]; then
    msg="$msg
📋 Session transcript: $rc"
fi
msg="$msg
Reply: 1 review, 2 test first, 3 see DONE.md, 4 defer"
! printf '%s' "$msg" | grep -q 'Session transcript:' && pass "T16 transcript omitted" || fail "T16 transcript omitted" "transcript line present despite null rc_link"

echo
echo "== C1: missing user_profile.experience_level => advanced default =="
world_c1="$TMPDIR_BASE/world_c1.yaml"
cat > "$world_c1" << 'EOF'
active_pi_sessions: []
pending_decisions: {}
EOF
assert_eq "C1 no field -> advanced" "$(select_variant "$world_c1")" "advanced"
# Non-existent world file also safe
assert_eq "C1 missing file -> advanced" "$(select_variant "$TMPDIR_BASE/nosuch.yaml")" "advanced"
# Null value -> advanced
world_c1b="$TMPDIR_BASE/world_c1b.yaml"
cat > "$world_c1b" << 'EOF'
user_profile:
  experience_level: null
EOF
assert_eq "C1 null value -> advanced" "$(select_variant "$world_c1b")" "advanced"

echo
echo "== C1b: user_profile.experience_level=novice => novice variant =="
world_c1c="$TMPDIR_BASE/world_c1c.yaml"
cat > "$world_c1c" << 'EOF'
user_profile:
  experience_level: novice
EOF
assert_eq "C1b novice selected" "$(select_variant "$world_c1c")" "novice"

echo
echo "== C2: defer handler sets deferred_remind_at and fresh telegram_sent_at =="
base_dec='{"id":"tg_test","type":"pi_completion","repo":"forge","issue":24,"created_at":"2020-01-01T00:00:00Z","telegram_sent_at":"2020-01-01T00:00:00Z","archived":false}'
updated=$(defer_decision "$base_dec")
sent=$(jq -r '.telegram_sent_at' <<< "$updated")
remind=$(jq -r '.deferred_remind_at' <<< "$updated")
expires=$(jq -r '.expires_at' <<< "$updated")
arch=$(jq -r '.archived' <<< "$updated")
# telegram_sent_at refreshed (not the old 2020 timestamp)
[ "$sent" != "2020-01-01T00:00:00Z" ] && pass "C2 telegram_sent_at refreshed" || fail "C2 telegram_sent_at refreshed" "still '$sent'"
# deferred_remind_at present and after telegram_sent_at
[ -n "$remind" ] && [ "$remind" != "null" ] && pass "C2 deferred_remind_at set" || fail "C2 deferred_remind_at set" "got '$remind'"
# expires_at aligned with remind_at
assert_eq "C2 expires_at aligned with remind_at" "$expires" "$remind"
# Not archived
assert_eq "C2 not archived" "$arch" "false"
# Verify remind is ~12h ahead (within 5s tolerance)
diff_secs=$(python3 -c "
from datetime import datetime
a=datetime.fromisoformat('$sent'.replace('Z','+00:00'))
b=datetime.fromisoformat('$remind'.replace('Z','+00:00'))
print(int((b-a).total_seconds()))
")
[ "$diff_secs" -ge 43195 ] && [ "$diff_secs" -le 43205 ] && pass "C2 12h gap" || fail "C2 12h gap" "gap=${diff_secs}s"

echo
echo "== C2b: re-present walker skips deferred decisions =="
# Decision deferred 12h into future
deferred_dec=$(defer_decision "$base_dec")
if should_represent "$deferred_dec"; then
    fail "C2b walker skips deferred" "walker did not skip despite deferred_remind_at > now"
else
    pass "C2b walker skips deferred"
fi
# Once deferred_remind_at <= now, walker re-presents
past_remind=$(jq -c \
  --arg past "2020-01-01T00:00:00Z" \
  '. + {deferred_remind_at:$past, telegram_sent_at:$past, created_at:$past}' \
  <<< "$base_dec")
if should_represent "$past_remind"; then
    pass "C2b walker re-presents after remind_at elapsed"
else
    fail "C2b walker re-presents after remind_at elapsed" "walker skipped despite deferred_remind_at in the past"
fi
# Standard dedup still applies for non-deferred decisions
fresh_dec=$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id:"tg_fresh",archived:false,created_at:$now,telegram_sent_at:$now}' \
    <<< '{}')
if should_represent "$fresh_dec"; then
    fail "C2b standard dedup still fires" "walker re-presented a fresh decision"
else
    pass "C2b standard dedup still fires"
fi

echo
echo "== BH: FOREMAN_BEHAVIOR.md contains §9 Pi Completion Protocol =="
BH_FILE="/mnt/c/SharedAssets/foreman/FOREMAN_BEHAVIOR.md"
assert_file_exists "BH file exists" "$BH_FILE"
for header in \
    "## 9. Pi Completion Protocol" \
    "### 9.1 DONE.md Format" \
    "### 9.2 DONE.md Detection" \
    "### 9.3 DONE.md Parse Procedure" \
    "### 9.4 Checkpoint Message Formatting" \
    "### 9.5 Reply Handling for Pi Completion" \
    "### 9.6 Pi Session Cleanup Coordination" \
    "### 9.7 Startup Deduplication"
do
    if grep -qF "$header" "$BH_FILE"; then
        pass "BH contains '$header'"
    else
        fail "BH contains '$header'" "header missing"
    fi
done
# Constraint coverage in docs
if grep -qF "CONSTRAINT C1" "$BH_FILE"; then
    pass "BH documents CONSTRAINT C1"
else
    fail "BH documents CONSTRAINT C1" "not found"
fi
if grep -qF "CONSTRAINT C2" "$BH_FILE"; then
    pass "BH documents CONSTRAINT C2"
else
    fail "BH documents CONSTRAINT C2" "not found"
fi
if grep -qF "deferred_remind_at" "$BH_FILE"; then
    pass "BH documents deferred_remind_at field"
else
    fail "BH documents deferred_remind_at field" "not found"
fi

# W2-7: Risk section markers in checkpoint templates
echo
echo "== BH-R: §9.4 and §9.8 contain ## Risk section =="
risk_count=$(grep -cF "## Risk" "$BH_FILE" || true)
if [ "$risk_count" -ge 3 ]; then
    pass "BH-R §9.4+§9.8 contain >= 3 '## Risk' markers (got $risk_count)"
else
    fail "BH-R §9.4+§9.8 contain >= 3 '## Risk' markers" "expected >= 3, got $risk_count"
fi

# Verify spec-review checkpoint section exists
if grep -qF "### 9.8 Spec-Review Checkpoint Formatting" "$BH_FILE"; then
    pass "BH-R contains '### 9.8 Spec-Review Checkpoint Formatting'"
else
    fail "BH-R contains '### 9.8 Spec-Review Checkpoint Formatting'" "header missing"
fi

# Verify blast_radius template variable is present in checkpoint templates
if grep -qF "blast_radius" "$BH_FILE"; then
    pass "BH-R checkpoint templates reference blast_radius"
else
    fail "BH-R checkpoint templates reference blast_radius" "variable missing"
fi

# Verify live_surfacing template variable is present
if grep -qF "live_surfacing" "$BH_FILE"; then
    pass "BH-R checkpoint templates reference live_surfacing"
else
    fail "BH-R checkpoint templates reference live_surfacing" "variable missing"
fi

CLAUDE_MD="/home/agentdev/.foreman/CLAUDE.md"
assert_file_exists "CLAUDE.md exists" "$CLAUDE_MD"
if grep -qF "amended by W1-4" "$CLAUDE_MD"; then
    pass "CLAUDE.md Event Loop amended by W1-4"
else
    fail "CLAUDE.md Event Loop amended by W1-4" "marker missing"
fi
if grep -qF "amended by W2-7" "$CLAUDE_MD"; then
    pass "CLAUDE.md Behavioral Reference amended by W2-7"
else
    fail "CLAUDE.md Behavioral Reference amended by W2-7" "marker missing"
fi
if grep -qF "Every 60 ticks" "$CLAUDE_MD"; then
    pass "CLAUDE.md periodic-check table present"
else
    fail "CLAUDE.md periodic-check table present" "60-tick row missing"
fi

echo
echo "---"
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
