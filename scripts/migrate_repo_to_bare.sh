#!/usr/bin/env bash
# migrate_repo_to_bare.sh — convert a regular clone at $PROJECTS_DIR/<repo>/main/
# into a bare+worktree layout ($PROJECTS_DIR/<repo>/.bare/ + main/ as a worktree)
# so the `dev` tool can manage it.
#
# Usage: bash migrate_repo_to_bare.sh <repo_name>
# Example: bash migrate_repo_to_bare.sh acorn
#
# Behavior:
#   - Idempotent: returns 0 if .bare/ already exists.
#   - Refuses to run on dirty trees or untracked files (operator must commit/stash first).
#   - Preserves history, all remotes (origin + upstream if present), and local
#     branch tracking config.
#   - Backs up the existing main/ to main.premigration-<ts> before mutating.
#   - Rolls back automatically (via ERR trap) if any of Steps 11..14 fail.
#   - Honors PROJECTS_DIR_OVERRIDE for tests.
#
# Spec: forge#153, plans/SPEC.md (Round 2).

set -euo pipefail
IFS=$'\n\t'

# ---- args ----
if [ "$#" -ne 1 ]; then
    echo "Usage: bash $(basename "$0") <repo_name>" >&2
    exit 1
fi
repo_name="$1"

# ---- helpers ----
warn() { echo "[WARN] $*" >&2; }

# ---- PROJECTS_DIR resolution (DS-3 fix: honor PROJECTS_DIR_OVERRIDE) ----
if [ -n "${PROJECTS_DIR_OVERRIDE:-}" ]; then
    PROJECTS_DIR="$PROJECTS_DIR_OVERRIDE"
else
    PROJECTS_DIR="$(realpath "$HOME/Projects/factory")"
fi

repo_dir="$PROJECTS_DIR/$repo_name"

# ---- idempotency ----
if [ -d "$repo_dir/.bare" ]; then
    echo "$repo_name already migrated (.bare exists)"
    exit 0
fi

# ---- existence ----
if [ ! -d "$repo_dir/main" ]; then
    echo "No $repo_dir/main directory found. Cannot migrate." >&2
    exit 1
fi

# ---- git-repo check ----
if [ ! -d "$repo_dir/main/.git" ] && [ ! -f "$repo_dir/main/.git" ]; then
    echo "$repo_dir/main is not a git repo" >&2
    exit 1
fi

# ---- clean-tree check (CM-2 fix: explicit if! for set -e) ----
cd "$repo_dir/main"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Uncommitted changes in $repo_dir/main. Commit or stash before migrating." >&2
    exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    echo "Working tree has untracked files in $repo_dir/main. Clean or commit before migrating." >&2
    exit 1
fi
cd - >/dev/null

# ---- capture remote + branch tracking config (CM-3 fix) ----
origin_url=$(git -C "$repo_dir/main" remote get-url origin 2>/dev/null || echo "")
upstream_url=$(git -C "$repo_dir/main" remote get-url upstream 2>/dev/null || echo "")
default_branch=$(git -C "$repo_dir/main" symbolic-ref --short HEAD 2>/dev/null || echo "main")
tracking_dump=$(git -C "$repo_dir/main" config --local --get-regexp '^branch\.' 2>/dev/null || true)

if [ -z "$origin_url" ]; then
    echo "No origin remote on $repo_dir/main; refusing to migrate without a known origin URL." >&2
    exit 1
fi

# ---- backup main/ (CM-1 fix: capture exact path, no glob) ----
backup_path="$repo_dir/main.premigration-$(date +%Y%m%d-%H%M%S)"
mv "$repo_dir/main" "$backup_path"
# Ensure the rename is fully visible before subsequent reads. On WSL2 with
# Windows-mounted filesystems (/mnt/c/, /mnt/e/), a fast mv-then-read sequence
# can race; sync forces metadata flush so `git clone --bare $backup_path/.git`
# sees a fully-populated .git directory.
sync
echo "Backup: $backup_path"

# ---- rollback helper (DS-2 fix: covers steps 11..14) ----
rollback() {
    echo "Migration failed; rolling back: removing partial $repo_dir/.bare and restoring main/" >&2
    rm -rf "$repo_dir/.bare"
    if [ -d "$backup_path" ] && [ ! -e "$repo_dir/main" ]; then
        mv "$backup_path" "$repo_dir/main"
    fi
}
trap 'rollback' ERR

# ---- Step 11: bare clone from exact backup path ----
if ! git clone --bare "$backup_path/.git" "$repo_dir/.bare"; then
    echo "git clone --bare failed" >&2
    exit 1
fi

# ---- Step 12: configure remotes on the bare clone ----
git -C "$repo_dir/.bare" remote remove origin 2>/dev/null || true
git -C "$repo_dir/.bare" remote add origin "$origin_url"
git -C "$repo_dir/.bare" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
if [ -n "$upstream_url" ]; then
    git -C "$repo_dir/.bare" remote add upstream "$upstream_url"
    git -C "$repo_dir/.bare" config remote.upstream.fetch "+refs/heads/*:refs/remotes/upstream/*"
fi
# Best-effort fetches (network may be flaky; upstream may be private).
git -C "$repo_dir/.bare" fetch origin || warn "fetch origin failed (continuing)"
if [ -n "$upstream_url" ]; then
    git -C "$repo_dir/.bare" fetch upstream || warn "fetch upstream failed (continuing)"
fi

# ---- Step 13: recreate main/ as a worktree ----
git --git-dir="$repo_dir/.bare" worktree add "$repo_dir/main" "$default_branch"

# ---- Step 13.5: restore local branch tracking config (CM-3) ----
if [ -n "$tracking_dump" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key="${line%% *}"
        value="${line#* }"
        git -C "$repo_dir/.bare" config "$key" "$value" || warn "Could not restore branch config: $key = $value"
    done <<< "$tracking_dump"
fi

# ---- Step 14: verify ----
[ -d "$repo_dir/.bare" ] || { echo "FAIL: .bare not created" >&2; exit 1; }
[ -f "$repo_dir/main/.git" ] || { echo "FAIL: main/.git is not a worktree pointer file" >&2; exit 1; }
grep -q "gitdir:" "$repo_dir/main/.git" || { echo "FAIL: main/.git missing gitdir pointer" >&2; exit 1; }
git -C "$repo_dir/main" rev-parse HEAD >/dev/null || { echo "FAIL: cannot resolve HEAD in new main worktree" >&2; exit 1; }

# All critical mutation steps succeeded — clear the rollback trap.
trap - ERR

# ---- Step 15: success message ----
cat <<EOF
Migrated $repo_name to bare+worktree structure.
Backup: $backup_path
Verify with: ls $repo_dir/  (expect .bare/ and main/)
Test with:   dev wt $repo_name <test-slug>
Once confirmed, remove backup: rm -rf $backup_path
EOF
