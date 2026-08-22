#!/usr/bin/env bash
# Delete remote branches whose pull request is MERGED.
#
#   bash cleanup-remote-branches.sh            # dry run — lists, deletes nothing
#   bash cleanup-remote-branches.sh --yes      # actually delete
#   bash cleanup-remote-branches.sh --yes --include-release   # also release/*
#
# Safety model: a branch is deleted ONLY if GitHub reports a MERGED pull request
# whose head branch is exactly that name. That is the strongest available signal
# and the only one that works here — every PR in this repo is SQUASH-merged, so
# the branch tip is NOT an ancestor of main and `git branch --merged` /
# `--no-merged` would wrongly report all of them as unmerged.
#
# Branches with no merged PR (long-lived work, closed-without-merge PRs, old
# release branches) are listed for review and never touched. `main` is excluded
# unconditionally.
#
# Requires: git, gh (authenticated). bash 3.2 / BSD-userland safe.

set -uo pipefail

YES=false
INCLUDE_RELEASE=false
for a in "$@"; do
    case "$a" in
        --yes|-y) YES=true ;;
        --include-release) INCLUDE_RELEASE=true ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null 2>&1 || { echo "gh not found" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }

REMOTE="${REMOTE:-origin}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Querying $REMOTE and GitHub..."

# Live remote branches (authoritative — asks the remote, not stale local refs).
git ls-remote --heads "$REMOTE" 2>/dev/null \
    | sed 's|.*refs/heads/||' | sort -u > "$TMP/remote.txt"

# Head-branch names of MERGED PRs. --limit is generous; raise if this repo has
# more than 200 merged PRs and old branches are being missed.
gh pr list --state merged --limit 200 --json headRefName \
    --jq '.[].headRefName' 2>/dev/null | sort -u > "$TMP/merged.txt"

# Closed-but-not-merged, reported separately: the work may or may not have
# landed some other way, so it is a human call.
gh pr list --state closed --limit 200 --json headRefName,number,title \
    --jq '.[] | select(.headRefName != null) | .headRefName' 2>/dev/null \
    | sort -u > "$TMP/closed_all.txt"
comm -23 "$TMP/closed_all.txt" "$TMP/merged.txt" > "$TMP/closed.txt"

# Never touch these.
printf 'main\nmaster\nHEAD\n' | sort -u > "$TMP/protected.txt"

comm -12 "$TMP/remote.txt" "$TMP/merged.txt" | comm -23 - "$TMP/protected.txt" > "$TMP/merged_live.txt"
# Release branches: merged like any other, but a maintainer may keep them on
# purpose and the tags already pin those releases. Held back unless asked.
if [ "$INCLUDE_RELEASE" = true ]; then
    cp "$TMP/merged_live.txt" "$TMP/delete.txt"; : > "$TMP/keep_release.txt"
else
    grep -vE '^release[/-]' "$TMP/merged_live.txt" > "$TMP/delete.txt" || true
    grep -E  '^release[/-]' "$TMP/merged_live.txt" > "$TMP/keep_release.txt" || true
fi
comm -23 "$TMP/remote.txt" "$TMP/merged.txt" | comm -23 - "$TMP/protected.txt" > "$TMP/keep.txt"
comm -12 "$TMP/keep.txt" "$TMP/closed.txt" > "$TMP/keep_closed.txt"
comm -23 "$TMP/keep.txt" "$TMP/closed.txt" > "$TMP/keep_nopr.txt"

# `grep -c . f || echo 0` double-counts: grep prints 0 AND exits 1, so the
# fallback appends a second 0. awk has no exit-code coupling.
count() { awk 'END{print NR}' "$1"; }
n_del=$(count "$TMP/delete.txt")
n_cl=$(count "$TMP/keep_closed.txt")
n_no=$(count "$TMP/keep_nopr.txt")
n_rel=$(count "$TMP/keep_release.txt")

echo
echo "=== WILL DELETE — PR merged ($n_del) ==="
[ "$n_del" -gt 0 ] && sed 's/^/  /' "$TMP/delete.txt" || echo "  (none)"

echo
echo "=== KEEPING — release branches, merged ($n_rel) ==="
echo "    Held back by default; tags already pin these. Add --include-release to delete."
[ "$n_rel" -gt 0 ] && sed 's/^/  /' "$TMP/keep_release.txt" || echo "  (none)"

echo
echo "=== KEEPING — PR closed without merging ($n_cl) ==="
echo "    Review by hand: the work may have landed another way, or been abandoned."
[ "$n_cl" -gt 0 ] && sed 's/^/  /' "$TMP/keep_closed.txt" || echo "  (none)"

echo
echo "=== KEEPING — no PR found ($n_no) ==="
echo "    Long-lived branches, old release branches, or never-PR'd work."
[ "$n_no" -gt 0 ] && sed 's/^/  /' "$TMP/keep_nopr.txt" || echo "  (none)"

echo
if [ "$n_del" -eq 0 ]; then
    echo "Nothing to delete."
    exit 0
fi

if [ "$YES" != true ]; then
    echo "Dry run — nothing deleted. Re-run with --yes to delete the $n_del branch(es) above."
    exit 0
fi

echo "Deleting $n_del branch(es) from $REMOTE..."
ok=0; fail=0
while IFS= read -r b; do
    [ -n "$b" ] || continue
    if git push "$REMOTE" --delete "$b" >/dev/null 2>&1; then
        echo "  deleted  $b"; ok=$((ok + 1))
    else
        echo "  FAILED   $b" >&2; fail=$((fail + 1))
    fi
done < "$TMP/delete.txt"

echo
echo "Deleted $ok, failed $fail."
# Local refs tracking deleted remotes linger until pruned. Note rather than do:
# `git remote prune` mutates local state the caller may not expect.
echo "Tip: 'git remote prune $REMOTE' clears the stale local tracking refs."
[ "$fail" -eq 0 ]
