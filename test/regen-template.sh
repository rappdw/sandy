#!/usr/bin/env bash
# Extract the `generate_user_setup()` heredoc body from the sandy script into
# templates/user-setup.sh.tmpl. One-way sync — the sandy script's embedded
# heredoc remains the source of truth (single-file install + `sandy --upgrade`
# preserves the current shape); the template file is a derivative used for
# shellcheck and review.
#
# Run after editing the heredoc body in sandy. test/run-tests.sh has a drift
# check that fails if the two diverge.
#
# Usage:
#   test/regen-template.sh           # rewrite templates/user-setup.sh.tmpl in place
#   test/regen-template.sh --check   # exit 1 if a rewrite would change anything
#                                    # (used by test/run-tests.sh)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDY="$REPO_ROOT/sandy"
TMPL="$REPO_ROOT/templates/user-setup.sh.tmpl"

MODE="write"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
fi

# Find heredoc boundaries. The opener is `cat > "$SANDY_HOME/user-setup.sh.new" <<'USERSETUP'`;
# the closer is a bare `USERSETUP` line. awk gives us the line ranges; we then
# strip the delimiter lines themselves with sed.
_open_line="$(awk '/cat > "\$SANDY_HOME\/user-setup\.sh\.new" <<'"'"'USERSETUP'"'"'$/ {print NR; exit}' "$SANDY")"
_close_line="$(awk -v start="$_open_line" 'NR > start && /^USERSETUP$/ {print NR; exit}' "$SANDY")"

if [ -z "$_open_line" ] || [ -z "$_close_line" ]; then
    echo "[regen-template] ERROR: could not locate USERSETUP heredoc bounds in $SANDY" >&2
    exit 1
fi

_body_start=$((_open_line + 1))
_body_end=$((_close_line - 1))

_generated="$(mktemp)"
trap 'rm -f "$_generated"' EXIT
sed -n "${_body_start},${_body_end}p" "$SANDY" > "$_generated"

mkdir -p "$(dirname "$TMPL")"

if [ "$MODE" = "check" ]; then
    if [ ! -f "$TMPL" ]; then
        echo "[regen-template] DRIFT: $TMPL does not exist" >&2
        echo "[regen-template] run \`test/regen-template.sh\` to create it" >&2
        exit 1
    fi
    if ! diff -q "$_generated" "$TMPL" >/dev/null; then
        echo "[regen-template] DRIFT: heredoc body in sandy differs from $TMPL" >&2
        echo "[regen-template] run \`test/regen-template.sh\` to update" >&2
        diff "$TMPL" "$_generated" | head -20 >&2
        exit 1
    fi
    echo "[regen-template] template up to date"
else
    if [ -f "$TMPL" ] && diff -q "$_generated" "$TMPL" >/dev/null; then
        echo "[regen-template] template up to date (no rewrite needed)"
    else
        cp "$_generated" "$TMPL"
        echo "[regen-template] wrote $TMPL ($(wc -l < "$TMPL") lines)"
    fi
fi
