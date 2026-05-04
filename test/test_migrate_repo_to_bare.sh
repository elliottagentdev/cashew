#!/usr/bin/env bash
# test_migrate_repo_to_bare.sh — unit tests for scripts/migrate_repo_to_bare.sh
# Spec: forge#153, plans/SPEC.md §4 (T1–T7).

set -uo pipefail
IFS=$'\n\t'

SCRIPT_UNDER_TEST="$(cd "$(dirname "$0")"/../scripts && pwd)/migrate_repo_to_bare.sh"
[ -f "$SCRIPT_UNDER_TEST" ] || { echo "SCRIPT_UNDER_TEST not found: $SCRIPT_UNDER_TEST" >&2; exit 1; }

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
assert_eq()       { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
assert_contains() { printf '%s' "$2" | grep -qF -- "$3" && pass "$1" || fail "$1" "expected to contain '$3'"; }
assert_dir()      { [ -d "$2" ] && pass "$1" || fail "$1" "expected directory $2"; }
assert_file()     { [ -f "$2" ] && pass "$1" || fail "$1" "expected file $2"; }

TMPDIR_BASE="$(mktemp -d)"
teardown() { [ -n "${TMPDIR_BASE:-}" ] && rm -rf "$TMPDIR_BASE"; }
trap teardown EXIT

# T1 — Usage error when no args
out=$(bash "$SCRIPT_UNDER_TEST" 2>&1 || true)
assert_contains "T1 usage error" "$out" "Usage:"

# T2 — Errors when repo dir does not exist
export PROJECTS_DIR_OVERRIDE="$TMPDIR_BASE/projects"
mkdir -p "$PROJECTS_DIR_OVERRIDE"
out=$(bash "$SCRIPT_UNDER_TEST" missingrepo 2>&1 || true)
assert_contains "T2 missing repo" "$out" "No"

# T3 — Idempotency: returns success when .bare already exists
mkdir -p "$PROJECTS_DIR_OVERRIDE/already/.bare"
mkdir -p "$PROJECTS_DIR_OVERRIDE/already/main"
out=$(bash "$SCRIPT_UNDER_TEST" already 2>&1)
assert_contains "T3 idempotent" "$out" "already migrated"

# T4 — Happy path: migrates a fresh local repo
REPO="$PROJECTS_DIR_OVERRIDE/synrepo"
mkdir -p "$REPO/main"
git -C "$REPO/main" init -q -b main
git -C "$REPO/main" remote add origin "https://example.com/synrepo.git"
echo "hello" > "$REPO/main/README.md"
git -C "$REPO/main" add README.md
git -C "$REPO/main" -c user.email=a@b -c user.name=t commit -q -m "init"

out=$(bash "$SCRIPT_UNDER_TEST" synrepo 2>&1)
assert_contains "T4 success message"   "$out" "Migrated synrepo"
assert_dir      "T4 .bare exists"      "$REPO/.bare"
assert_file     "T4 main/.git is file" "$REPO/main/.git"
gitdir_line=$(cat "$REPO/main/.git")
assert_contains "T4 main/.git has gitdir" "$gitdir_line" "gitdir:"
assert_contains "T4 main/.git points to .bare/worktrees/main" "$gitdir_line" ".bare/worktrees/main"
head_after=$(git -C "$REPO/main" log -1 --pretty=%s)
assert_eq "T4 history preserved" "$head_after" "init"
remote_url=$(git --git-dir="$REPO/.bare" remote get-url origin)
assert_eq "T4 origin remote preserved" "$remote_url" "https://example.com/synrepo.git"
backup_count=$(ls -d "$REPO"/main.premigration-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T4 backup created" "$backup_count" "1"

# T5 — Refuses to run on a dirty tree
REPO2="$PROJECTS_DIR_OVERRIDE/dirty"
mkdir -p "$REPO2/main"
git -C "$REPO2/main" init -q -b main
git -C "$REPO2/main" remote add origin "https://example.com/dirty.git"
echo "v1" > "$REPO2/main/file.txt"
git -C "$REPO2/main" add file.txt
git -C "$REPO2/main" -c user.email=a@b -c user.name=t commit -q -m "v1"
echo "v2" > "$REPO2/main/file.txt"   # uncommitted change

out=$(bash "$SCRIPT_UNDER_TEST" dirty 2>&1 || true)
assert_contains "T5 refuses dirty tree" "$out" "Uncommitted"
assert_dir      "T5 main untouched"     "$REPO2/main"

# T6 — Preserves a second remote (upstream)
REPO3="$PROJECTS_DIR_OVERRIDE/forkrepo"
mkdir -p "$REPO3/main"
git -C "$REPO3/main" init -q -b main
git -C "$REPO3/main" remote add origin   "https://example.com/forkrepo.git"
git -C "$REPO3/main" remote add upstream "https://example.com/upstream.git"
echo "x" > "$REPO3/main/x"
git -C "$REPO3/main" add x
git -C "$REPO3/main" -c user.email=a@b -c user.name=t commit -q -m "init"

# upstream fetch will fail (DNS) but the script should tolerate that
bash "$SCRIPT_UNDER_TEST" forkrepo >/dev/null 2>&1 || true

origin_url=$(git --git-dir="$REPO3/.bare" remote get-url origin 2>/dev/null || echo "")
upstream_url=$(git --git-dir="$REPO3/.bare" remote get-url upstream 2>/dev/null || echo "")
assert_eq "T6 origin preserved"   "$origin_url"   "https://example.com/forkrepo.git"
assert_eq "T6 upstream preserved" "$upstream_url" "https://example.com/upstream.git"

# T7 — Final summary
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
