#!/usr/bin/env bash
# W1-5 Pending Decisions Register — automated test harness.
# Covers Steps 1, 2, 3, 4, 5, 6 of the W1-5 SPEC.
#
# The Foreman is a Claude Code agent and executes the pending-register
# operations as inline bash. These same stanzas are reproduced here
# (and documented in /mnt/c/SharedAssets/foreman/FOREMAN_BEHAVIOR.md §8)
# so they can be exercised in isolation.

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

warn() { printf '  \033[33mWARN\033[0m %s\n' "$*" >&2; }

# ------------------------------------------------------------------
# Isolated environment
# ------------------------------------------------------------------
TMPDIR_BASE="$(mktemp -d)"
export HOME="$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE/.foreman/continuity"

teardown() {
    [ -n "${TMPDIR_BASE:-}" ] && rm -rf "$TMPDIR_BASE"
}
trap teardown EXIT

setup() {
    rm -f "$HOME/.foreman/pending.json" "$HOME/.foreman/pending.json.tmp"
    rm -f "$HOME/.foreman/world.yaml" "$HOME/.foreman/world.yaml.tmp"
    cat > "$HOME/.foreman/continuity/forge_main_foreman.yaml" << 'YAML'
version: "1"
session_name: forge_main_foreman
session_type: foreman
authorization:
  approved: []
  pending_discussion: []
  deferred: []
YAML
}

# ------------------------------------------------------------------
# Inline implementations of the pending-register functions
# (mirror FOREMAN_BEHAVIOR.md §8 and W1-5 SPEC §4)
# ------------------------------------------------------------------

normalize_decision_type() {
    local raw="$1"
    case "$raw" in
        spec-approval)          printf 'approval_gate' ;;
        pi-dispatch)            printf 'dispatch_confirmation' ;;
        checkpoint)             printf 'pi_completion' ;;
        design-question)        printf 'error_escalation' ;;
        uncertainty_markers|spec_review|approval_gate|pi_completion|dispatch_confirmation|error_escalation)
            printf '%s' "$raw" ;;
        *) printf 'error_escalation' ;;
    esac
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

iso_plus_hours() {
    # $1 = hours
    date -u -d "+$1 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        python3 -c "from datetime import datetime,timedelta; print((datetime.utcnow()+timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

iso_minus_minutes() {
    # $1 = minutes
    date -u -d "-$1 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        python3 -c "from datetime import datetime,timedelta; print((datetime.utcnow()-timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

pending_write_empty() {
    local ts; ts=$(iso_now)
    jq -n --arg ts "$ts" '{version: 1, updated_at: $ts, decisions: {}}' \
        > "$HOME/.foreman/pending.json.tmp"
    mv "$HOME/.foreman/pending.json.tmp" "$HOME/.foreman/pending.json"
}

pending_read() {
    local pending_file="$HOME/.foreman/pending.json"
    if [ -f "$pending_file" ]; then
        local content
        content=$(cat "$pending_file") || content=""
        if printf '%s' "$content" | jq -e '.version and .decisions' >/dev/null 2>&1; then
            printf '%s' "$content"
            return 0
        fi
        warn "pending.json corrupt or invalid schema. Rebuilding empty register."
        pending_write_empty
    fi
    printf '{"version":1,"updated_at":"%s","decisions":{}}' "$(iso_now)"
}

pending_write() {
    local content="$1"
    local pending_file="$HOME/.foreman/pending.json"
    local tmp_file="$HOME/.foreman/pending.json.tmp"
    content=$(printf '%s' "$content" | jq --arg ts "$(iso_now)" '.updated_at = $ts')
    printf '%s\n' "$content" > "$tmp_file"
    mv "$tmp_file" "$pending_file"
}

pending_create() {
    # Args: $1=type $2=repo $3=issue $4=context_summary $5=options_json
    local raw_type="$1" repo="$2" issue="$3" summary="$4" options_json="$5"
    local type id ts expires_ts register base_id suffix=2

    type=$(normalize_decision_type "$raw_type")
    base_id="tg_$(date -u +%Y%m%d_%H%M%S)"
    id="$base_id"

    # Lazy-init register if missing
    if [ ! -f "$HOME/.foreman/pending.json" ]; then
        pending_write_empty
    fi
    register=$(pending_read)

    while printf '%s' "$register" | jq -e --arg k "$id" '.decisions[$k]' >/dev/null 2>&1; do
        id="${base_id}_${suffix}"
        suffix=$((suffix + 1))
    done

    ts=$(iso_now)
    expires_ts=$(iso_plus_hours 24)

    local issue_arg="null"
    if [ -n "$issue" ] && [ "$issue" != "null" ]; then
        issue_arg="$issue"
    fi

    local decision
    decision=$(jq -n \
        --arg id "$id" \
        --arg type "$type" \
        --arg repo "$repo" \
        --argjson issue "$issue_arg" \
        --arg ts "$ts" \
        --arg summary "$summary" \
        --argjson options "$options_json" \
        --arg expires "$expires_ts" \
        '{
            id: $id,
            type: $type,
            repo: $repo,
            issue: $issue,
            created_at: $ts,
            context_summary: $summary,
            options: $options,
            telegram_sent_at: null,
            telegram_message_count: 0,
            response_received: null,
            resolved_at: null,
            archived: false,
            expires_at: $expires
        }')

    register=$(printf '%s' "$register" | jq --arg id "$id" --argjson dec "$decision" '.decisions[$id] = $dec')
    pending_write "$register"
    printf '%s' "$id"
}

pending_resolve() {
    local id="$1" response="$2" ts register
    register=$(pending_read)
    ts=$(iso_now)
    register=$(printf '%s' "$register" | jq \
        --arg id "$id" --arg resp "$response" --arg ts "$ts" \
        '.decisions[$id].response_received = $resp
         | .decisions[$id].resolved_at = $ts
         | .decisions[$id].archived = true')
    pending_write "$register"
}

pending_expire_check() {
    local register now_epoch entry_expires expires_epoch id
    register=$(pending_read)
    now_epoch=$(date +%s)
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        entry_expires=$(printf '%s' "$register" | jq -r --arg k "$id" '.decisions[$k].expires_at')
        expires_epoch=$(date -d "$entry_expires" +%s 2>/dev/null || printf '0')
        if [ "$now_epoch" -gt "$expires_epoch" ]; then
            register=$(printf '%s' "$register" | jq \
                --arg id "$id" --arg ts "$(iso_now)" \
                '.decisions[$id].response_received = "expired"
                 | .decisions[$id].resolved_at = $ts
                 | .decisions[$id].archived = true')
        fi
    done < <(printf '%s' "$register" | jq -r '.decisions | to_entries[] | select(.value.archived == false) | .key')
    pending_write "$register"
}

# CONSTRAINT C2: Strategy 2 — recency match tiebreaker by created_at
# Among unresolved decisions with a non-null telegram_sent_at, pick the one
# with the latest telegram_sent_at; if multiple share the same telegram_sent_at,
# pick the most recently created.
pending_lookup_recency() {
    local register; register=$(pending_read)
    printf '%s' "$register" | jq -r '
        .decisions
        | to_entries
        | map(select(.value.archived == false and .value.telegram_sent_at != null))
        | sort_by(.value.telegram_sent_at, .value.created_at)
        | reverse
        | (.[0].key // "")
    '
}

# Resolution matching dispatcher. Priority: Direct ID > Context match > Recency match.
pending_lookup() {
    local reply="$1"
    local register id_match ctx_match recency
    register=$(pending_read)

    # Strategy 1: Direct ID match — reply contains a tg_YYYYMMDD_HHMMSS[_N] token
    id_match=$(printf '%s' "$reply" | grep -oE 'tg_[0-9]{8}_[0-9]{6}(_[0-9]+)?' | head -n1 || true)
    if [ -n "$id_match" ]; then
        if printf '%s' "$register" | jq -e --arg k "$id_match" '.decisions[$k]' >/dev/null 2>&1; then
            printf '%s' "$id_match"; return 0
        fi
    fi

    # Strategy 3: Context match — repo name and/or issue number
    local issue_num
    issue_num=$(printf '%s' "$reply" | grep -oE '#[0-9]+' | head -n1 | tr -d '#' || true)
    if [ -n "$issue_num" ]; then
        ctx_match=$(printf '%s' "$register" | jq -r --argjson n "$issue_num" '
            .decisions
            | to_entries
            | map(select(.value.archived == false and (.value.issue == $n)))
            | sort_by(.value.created_at)
            | reverse
            | (.[0].key // "")
        ')
        if [ -n "$ctx_match" ]; then
            printf '%s' "$ctx_match"; return 0
        fi
    fi

    # Strategy 2 (fallback): Recency match
    recency=$(pending_lookup_recency)
    printf '%s' "$recency"
}

# ------------------------------------------------------------------
# Continuity file helpers (Step 6)
# ------------------------------------------------------------------

continuity_append_pending() {
    local line="$1"
    local f="$HOME/.foreman/continuity/forge_main_foreman.yaml"
    if command -v yq >/dev/null 2>&1; then
        yq -i ".authorization.pending_discussion += [\"$line\"]" "$f" 2>/dev/null || true
    else
        python3 - "$f" "$line" << 'PY' || true
import sys, yaml
path, line = sys.argv[1], sys.argv[2]
with open(path) as fh: data = yaml.safe_load(fh) or {}
auth = data.setdefault("authorization", {})
lst = auth.setdefault("pending_discussion", []) or []
lst.append(line)
auth["pending_discussion"] = lst
with open(path, "w") as fh: yaml.safe_dump(data, fh, sort_keys=False)
PY
    fi
}

continuity_remove_pending() {
    local id_prefix="$1"
    local f="$HOME/.foreman/continuity/forge_main_foreman.yaml"
    python3 - "$f" "$id_prefix" << 'PY' || true
import sys, yaml
path, prefix = sys.argv[1], sys.argv[2]
with open(path) as fh: data = yaml.safe_load(fh) or {}
auth = data.setdefault("authorization", {})
lst = auth.get("pending_discussion", []) or []
lst = [x for x in lst if not str(x).startswith(prefix + ":")]
auth["pending_discussion"] = lst
with open(path, "w") as fh: yaml.safe_dump(data, fh, sort_keys=False)
PY
}

# ------------------------------------------------------------------
# Reconciliation (Step 3) — applies CONSTRAINT C1 field-level merge.
# pending.json is authoritative for: archived, resolved_at, response_received
# world.yaml is authoritative for: options, type, context_summary
# ------------------------------------------------------------------

reconcile_pending_with_world() {
    # Reads world.yaml.pending_decisions, merges with pending.json per C1.
    local world_file="$HOME/.foreman/world.yaml"
    local register; register=$(pending_read)

    # World doc as JSON (empty object if missing or no pending_decisions)
    local world_pd='{}'
    if [ -f "$world_file" ] && command -v yq >/dev/null 2>&1; then
        world_pd=$(yq -o=json '.pending_decisions // {}' "$world_file" 2>/dev/null || printf '{}')
    elif [ -f "$world_file" ]; then
        world_pd=$(python3 -c "
import sys, json, yaml
d = yaml.safe_load(open('$world_file')) or {}
print(json.dumps(d.get('pending_decisions') or {}))
" 2>/dev/null || printf '{}')
    fi

    # Field-level merge: start with pending.json as base, overlay world.yaml
    # operational fields (options, type, context_summary) only for entries
    # that exist in pending.json. NEVER un-archive.
    register=$(printf '%s' "$register" | jq --argjson w "$world_pd" '
        .decisions = (
            .decisions as $p
            | ($p | to_entries) as $pe
            | ($w | to_entries) as $we
            | (reduce $pe[] as $item (
                {};
                .[$item.key] = (
                    $item.value
                    + (
                        ($w[$item.key] // {})
                        | with_entries(select(.key == "options" or .key == "type" or .key == "context_summary"))
                    )
                )
              ))
            | . as $merged
            # Import world-only entries (not in pending.json) if they are unresolved
            | reduce ($we[]) as $wi (
                $merged;
                if (.[$wi.key] == null) then
                    .[$wi.key] = ($wi.value + {
                        id: $wi.key,
                        telegram_sent_at: ($wi.value.telegram_sent_at // null),
                        telegram_message_count: ($wi.value.telegram_message_count // 0),
                        response_received: null,
                        resolved_at: null,
                        archived: false
                    })
                else . end
              )
        )
    ')
    pending_write "$register"
}

# ------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------

run_t1() {
    setup
    printf '\n--- T1: Empty register creation ---\n'
    pending_write_empty
    [ -f "$HOME/.foreman/pending.json" ] && pass "T1.1 file exists" || fail "T1.1 file exists" "no file"
    assert_eq "T1.2 version" "$(jq -r '.version' "$HOME/.foreman/pending.json")" "1"
    assert_eq "T1.3 empty decisions" "$(jq '.decisions | length' "$HOME/.foreman/pending.json")" "0"
}

run_t2() {
    setup
    printf '\n--- T2: Create decision ---\n'
    pending_write_empty
    local id
    id=$(pending_create "spec-approval" "forge" "42" "Test spec ready" '{"1":"approve","cancel":"reject"}')
    assert_eq "T2.1 id prefix" "$(printf '%s' "$id" | cut -c1-3)" "tg_"
    assert_eq "T2.2 type normalized" "$(jq -r ".decisions[\"$id\"].type" "$HOME/.foreman/pending.json")" "approval_gate"
    assert_eq "T2.3 repo" "$(jq -r ".decisions[\"$id\"].repo" "$HOME/.foreman/pending.json")" "forge"
    assert_eq "T2.4 issue" "$(jq -r ".decisions[\"$id\"].issue" "$HOME/.foreman/pending.json")" "42"
    assert_eq "T2.5 archived" "$(jq -r ".decisions[\"$id\"].archived" "$HOME/.foreman/pending.json")" "false"
    assert_eq "T2.6 telegram_sent_at null" "$(jq -r ".decisions[\"$id\"].telegram_sent_at" "$HOME/.foreman/pending.json")" "null"
}

run_t3() {
    setup
    printf '\n--- T3: Type normalization ---\n'
    assert_eq "T3.1 spec-approval"       "$(normalize_decision_type 'spec-approval')"   "approval_gate"
    assert_eq "T3.2 pi-dispatch"         "$(normalize_decision_type 'pi-dispatch')"     "dispatch_confirmation"
    assert_eq "T3.3 checkpoint"          "$(normalize_decision_type 'checkpoint')"      "pi_completion"
    assert_eq "T3.4 design-question"     "$(normalize_decision_type 'design-question')" "error_escalation"
    assert_eq "T3.5 canonical passthrough" "$(normalize_decision_type 'spec_review')"   "spec_review"
    assert_eq "T3.6 unknown defaults"    "$(normalize_decision_type 'garbage')"         "error_escalation"
}

run_t4() {
    setup
    printf '\n--- T4: Resolution and archival ---\n'
    pending_write_empty
    local id
    id=$(pending_create "pi-dispatch" "forge" "25" "Dispatch Pi" '{"1":"go","cancel":"abort"}')
    pending_resolve "$id" "1"
    assert_eq "T4.1 archived"      "$(jq -r ".decisions[\"$id\"].archived" "$HOME/.foreman/pending.json")" "true"
    assert_eq "T4.2 response"      "$(jq -r ".decisions[\"$id\"].response_received" "$HOME/.foreman/pending.json")" "1"
    assert_eq "T4.3 resolved_at set" "$(jq -r ".decisions[\"$id\"].resolved_at" "$HOME/.foreman/pending.json" | cut -c1-4)" "2026"
    assert_eq "T4.4 entry not deleted" "$(jq '.decisions | length' "$HOME/.foreman/pending.json")" "1"
}

run_t5() {
    setup
    printf '\n--- T5: Corrupt file recovery ---\n'
    printf 'not valid json' > "$HOME/.foreman/pending.json"
    local result; result=$(pending_read 2>/dev/null)
    assert_eq "T5.1 returns valid json" "$(printf '%s' "$result" | jq -r '.version')" "1"
    assert_eq "T5.2 empty decisions"    "$(printf '%s' "$result" | jq '.decisions | length')" "0"
}

run_t6() {
    setup
    printf '\n--- T6: Collision avoidance ---\n'
    pending_write_empty
    local id1 id2 count
    id1=$(pending_create "checkpoint" "forge" "10" "First"  '{"1":"ok"}')
    id2=$(pending_create "checkpoint" "forge" "11" "Second" '{"1":"ok"}')
    count=$(jq '.decisions | length' "$HOME/.foreman/pending.json")
    assert_eq "T6.1 two entries" "$count" "2"
    [ "$id1" != "$id2" ] && pass "T6.2 distinct ids" || fail "T6.2 distinct ids" "$id1 == $id2"
}

run_t7() {
    setup
    printf '\n--- T7: Auto-expiry ---\n'
    pending_write_empty
    local id
    id=$(pending_create "checkpoint" "forge" "99" "Expiring entry" '{"1":"ok"}')
    # Force expiry into the past
    local reg past; past=$(iso_minus_minutes 60)
    reg=$(pending_read | jq --arg id "$id" --arg past "$past" '.decisions[$id].expires_at = $past')
    pending_write "$reg"
    pending_expire_check
    assert_eq "T7.1 archived after expiry"   "$(jq -r ".decisions[\"$id\"].archived" "$HOME/.foreman/pending.json")" "true"
    assert_eq "T7.2 response = expired"      "$(jq -r ".decisions[\"$id\"].response_received" "$HOME/.foreman/pending.json")" "expired"
}

run_t8() {
    setup
    printf '\n--- T8: Reconciliation field-level merge (CONSTRAINT C1) ---\n'
    pending_write_empty
    # Put an archived entry in pending.json
    local id="tg_20260101_120000"
    local reg
    reg=$(pending_read | jq --arg id "$id" '.decisions[$id] = {
        id: $id, type: "approval_gate", repo: "forge", issue: 42,
        created_at: "2026-01-01T12:00:00Z",
        context_summary: "persisted original",
        options: {"1":"approve","cancel":"reject"},
        telegram_sent_at: "2026-01-01T12:05:00Z",
        telegram_message_count: 1,
        response_received: "1",
        resolved_at: "2026-01-01T12:10:00Z",
        archived: true,
        expires_at: "2026-01-02T12:00:00Z"
    }')
    pending_write "$reg"

    # world.yaml has the SAME id but with archived=false and different context.
    # C1: archived/resolved must NOT be un-archived; operational fields (options/context_summary/type)
    # from world.yaml should overlay.
    cat > "$HOME/.foreman/world.yaml" << EOF
updated: null
pending_decisions:
  $id:
    type: approval_gate
    context_summary: "world.yaml fresher context"
    options:
      "1": "approve_as_is"
      "2": "answer_questions_first"
      "cancel": "reject"
EOF

    reconcile_pending_with_world

    assert_eq "T8.1 archived still true" \
        "$(jq -r ".decisions[\"$id\"].archived" "$HOME/.foreman/pending.json")" "true"
    assert_eq "T8.2 response_received preserved" \
        "$(jq -r ".decisions[\"$id\"].response_received" "$HOME/.foreman/pending.json")" "1"
    assert_eq "T8.3 resolved_at preserved" \
        "$(jq -r ".decisions[\"$id\"].resolved_at" "$HOME/.foreman/pending.json")" "2026-01-01T12:10:00Z"
    assert_eq "T8.4 context_summary overlaid" \
        "$(jq -r ".decisions[\"$id\"].context_summary" "$HOME/.foreman/pending.json")" "world.yaml fresher context"
    assert_eq "T8.5 options overlaid (count=3)" \
        "$(jq -r ".decisions[\"$id\"].options | length" "$HOME/.foreman/pending.json")" "3"
}

run_t9() {
    setup
    printf '\n--- T9: Reconciliation imports world-only entries ---\n'
    pending_write_empty
    local id="tg_20260301_140000"
    cat > "$HOME/.foreman/world.yaml" << EOF
updated: null
pending_decisions:
  $id:
    type: dispatch_confirmation
    context_summary: "world-only entry"
    options:
      "1": "go"
      "cancel": "abort"
EOF

    reconcile_pending_with_world

    assert_eq "T9.1 imported into pending.json" \
        "$(jq -r ".decisions[\"$id\"].context_summary" "$HOME/.foreman/pending.json")" "world-only entry"
    assert_eq "T9.2 archived=false for imported entry" \
        "$(jq -r ".decisions[\"$id\"].archived" "$HOME/.foreman/pending.json")" "false"
}

run_t10() {
    setup
    printf '\n--- T10: pending_lookup recency tiebreaker (CONSTRAINT C2) ---\n'
    pending_write_empty
    local ts_same="2026-04-14T20:00:00Z"
    local older_id="tg_20260414_100000"
    local newer_id="tg_20260414_195959"
    local reg
    reg=$(pending_read | jq \
        --arg o "$older_id" --arg n "$newer_id" --arg ts "$ts_same" '
        .decisions[$o] = {
            id: $o, type: "approval_gate", repo: "forge", issue: 10,
            created_at: "2026-04-14T10:00:00Z",
            context_summary: "older", options: {"1":"ok","cancel":"no"},
            telegram_sent_at: $ts, telegram_message_count: 1,
            response_received: null, resolved_at: null, archived: false,
            expires_at: "2026-04-15T10:00:00Z"
        }
        | .decisions[$n] = {
            id: $n, type: "approval_gate", repo: "forge", issue: 11,
            created_at: "2026-04-14T19:59:59Z",
            context_summary: "newer", options: {"1":"ok","cancel":"no"},
            telegram_sent_at: $ts, telegram_message_count: 1,
            response_received: null, resolved_at: null, archived: false,
            expires_at: "2026-04-15T19:59:59Z"
        }')
    pending_write "$reg"

    local hit; hit=$(pending_lookup_recency)
    assert_eq "T10.1 tiebreaker picks most recent created_at" "$hit" "$newer_id"

    # General dispatcher: a bare "1" should also land on the newer one.
    local hit2; hit2=$(pending_lookup "1")
    assert_eq "T10.2 dispatcher falls back to recency tiebreaker" "$hit2" "$newer_id"
}

run_t11() {
    setup
    printf '\n--- T11: pending_lookup direct ID match ---\n'
    pending_write_empty
    local id
    id=$(pending_create "spec-approval" "forge" "42" "lookup test" '{"1":"ok","cancel":"no"}')
    local hit; hit=$(pending_lookup "please resolve $id 1")
    assert_eq "T11.1 direct id match" "$hit" "$id"
}

run_t12() {
    setup
    printf '\n--- T12: Continuity file integration (Step 6) ---\n'
    pending_write_empty
    local id
    id=$(pending_create "pi-dispatch" "forge" "25" "Ready to dispatch Pi" '{"1":"go","cancel":"abort"}')
    continuity_append_pending "$id: dispatch_confirmation -- forge#25: Ready to dispatch Pi"
    grep -qF "$id:" "$HOME/.foreman/continuity/forge_main_foreman.yaml" \
        && pass "T12.1 continuity has new entry" \
        || fail "T12.1 continuity has new entry" "missing $id"

    pending_resolve "$id" "1"
    continuity_remove_pending "$id"
    if grep -qF "$id:" "$HOME/.foreman/continuity/forge_main_foreman.yaml"; then
        fail "T12.2 continuity entry removed on resolve" "still present"
    else
        pass "T12.2 continuity entry removed on resolve"
    fi
}

run_t13() {
    setup
    printf '\n--- T13: Re-presentation dedup window (Step 4) ---\n'
    pending_write_empty
    local fresh_id="tg_20260414_195500"
    local stale_id="tg_20260414_100000"
    local recent_ts old_ts old_created
    recent_ts=$(iso_minus_minutes 10)     # inside dedup window
    old_ts=$(iso_minus_minutes 45)        # outside dedup window
    old_created=$(iso_minus_minutes 120)  # > 5 min threshold

    local reg
    reg=$(pending_read | jq \
        --arg a "$fresh_id" --arg b "$stale_id" \
        --arg ra "$recent_ts" --arg rb "$old_ts" --arg oc "$old_created" '
        .decisions[$a] = {
            id: $a, type: "approval_gate", repo: "forge", issue: 1,
            created_at: $oc, context_summary: "fresh sent (dedup skip)",
            options: {"1":"ok","cancel":"no"},
            telegram_sent_at: $ra, telegram_message_count: 1,
            response_received: null, resolved_at: null, archived: false,
            expires_at: "2099-01-01T00:00:00Z"
        }
        | .decisions[$b] = {
            id: $b, type: "approval_gate", repo: "forge", issue: 2,
            created_at: $oc, context_summary: "stale sent (should re-present)",
            options: {"1":"ok","cancel":"no"},
            telegram_sent_at: $rb, telegram_message_count: 1,
            response_received: null, resolved_at: null, archived: false,
            expires_at: "2099-01-01T00:00:00Z"
        }')
    pending_write "$reg"

    # Compute the set of IDs that would be re-presented under the policy
    local repres
    repres=$(pending_read | jq -r '
        [ .decisions
          | to_entries[]
          | select(.value.archived == false)
          | select( (((now - (.value.created_at | fromdateiso8601)) / 60) >= 5) )
          | select(
              (.value.telegram_sent_at == null) or
              (((now - (.value.telegram_sent_at | fromdateiso8601)) / 60) >= 30)
            )
          | .key
        ] | sort | .[]
    ')

    printf '%s' "$repres" | grep -qF "$stale_id" \
        && pass "T13.1 stale entry re-presented" \
        || fail "T13.1 stale entry re-presented" "missing $stale_id"

    if printf '%s' "$repres" | grep -qF "$fresh_id"; then
        fail "T13.2 fresh entry dedup-skipped" "fresh id was re-presented"
    else
        pass "T13.2 fresh entry dedup-skipped"
    fi
}

run_t14() {
    printf '\n--- T14: FOREMAN_BEHAVIOR.md amendments (Step 7) ---\n'
    local f="/mnt/c/SharedAssets/foreman/FOREMAN_BEHAVIOR.md"
    [ -f "$f" ] && pass "T14.1 behavior doc exists" || { fail "T14.1 behavior doc exists" "missing $f"; return; }
    grep -qF "Pending Decisions Register" "$f" && pass "T14.2 §8 heading present" || fail "T14.2 §8 heading present" "missing heading"
    grep -qF "pending.json" "$f" && pass "T14.3 references pending.json" || fail "T14.3 references pending.json" "no mention of pending.json"
    grep -qF "30" "$f" && pass "T14.4 dedup window documented" || fail "T14.4 dedup window documented" "missing 30-min window"
    grep -qF "24h" "$f" || grep -qF "24 h" "$f" || grep -qF "24 hour" "$f" && pass "T14.5 TTL documented" || fail "T14.5 TTL documented" "missing 24h TTL"
}

run_t15() {
    printf '\n--- T15: Hook + CLAUDE.md amendments (Step 8) ---\n'
    grep -qF "pending.json" "/home/agentdev/.claude/hooks/foreman-session-start.sh" \
        && pass "T15.1 session-start hook mentions pending.json" \
        || fail "T15.1 session-start hook mentions pending.json" "missing"
    grep -qF "pending.json" "/home/agentdev/.foreman/CLAUDE.md" \
        && pass "T15.2 CLAUDE.md mentions pending.json" \
        || fail "T15.2 CLAUDE.md mentions pending.json" "missing"
}

# ------------------------------------------------------------------
# Run
# ------------------------------------------------------------------

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

printf '\n\033[1mResults: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
