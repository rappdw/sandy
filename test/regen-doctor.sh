#!/usr/bin/env bash
# Extract the `_sandy_doctor_host()` heredoc body from the sandy script into
# the repo-root doctor.sh. One-way sync — the sandy script's embedded heredoc
# remains the source of truth (single-file install + `sandy --upgrade`
# preserves the current shape, and `sandy --doctor` runs the heredoc body
# directly via a child `bash`, never this file); doctor.sh is a generated,
# committed mirror kept curl-able (`curl -fsSL .../doctor.sh | bash`) and
# byte-runnable standalone, exactly the templates/user-setup.sh.tmpl pattern
# (CLAUDE.md: a heredoc string literal is unshellcheckable, so the mirror
# exists for lint/review and for users who haven't installed sandy yet).
#
# Run after editing the heredoc body in sandy. test/run-tests.sh has a drift
# check that fails if the two diverge.
#
# Usage:
#   test/regen-doctor.sh           # rewrite doctor.sh in place
#   test/regen-doctor.sh --check   # exit 1 if a rewrite would change anything
#                                  # (used by test/run-tests.sh)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDY="$REPO_ROOT/sandy"
DOCTOR="$REPO_ROOT/doctor.sh"

MODE="write"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
fi

# Find heredoc boundaries. The opener is `bash <<'SANDY_DOCTOR_HOST'`; the
# closer is a bare `SANDY_DOCTOR_HOST` line. awk gives us the line ranges; we
# then strip the delimiter lines themselves with sed. The body's own first
# line is doctor.sh's shebang (`#!/usr/bin/env bash`) — bash treats it as an
# ordinary comment when the heredoc is piped to a child `bash`, so the body
# is copied out verbatim with no shebang re-insertion needed here.
_open_line="$(awk '/^    bash <<'"'"'SANDY_DOCTOR_HOST'"'"'$/ {print NR; exit}' "$SANDY")"
_close_line="$(awk -v start="$_open_line" 'NR > start && /^SANDY_DOCTOR_HOST$/ {print NR; exit}' "$SANDY")"

if [ -z "$_open_line" ] || [ -z "$_close_line" ]; then
    echo "[regen-doctor] ERROR: could not locate SANDY_DOCTOR_HOST heredoc bounds in $SANDY" >&2
    exit 1
fi

_body_start=$((_open_line + 1))
_body_end=$((_close_line - 1))

_generated="$(mktemp)"
trap 'rm -f "$_generated"' EXIT
sed -n "${_body_start},${_body_end}p" "$SANDY" > "$_generated"

if [ "$MODE" = "check" ]; then
    if [ ! -f "$DOCTOR" ]; then
        echo "[regen-doctor] DRIFT: $DOCTOR does not exist" >&2
        echo "[regen-doctor] run \`test/regen-doctor.sh\` to create it" >&2
        exit 1
    fi
    if ! diff -q "$_generated" "$DOCTOR" >/dev/null; then
        echo "[regen-doctor] DRIFT: heredoc body in sandy differs from $DOCTOR" >&2
        echo "[regen-doctor] run \`test/regen-doctor.sh\` to update" >&2
        diff "$DOCTOR" "$_generated" | head -20 >&2
        exit 1
    fi
    echo "[regen-doctor] doctor.sh up to date"
else
    if [ -f "$DOCTOR" ] && diff -q "$_generated" "$DOCTOR" >/dev/null; then
        echo "[regen-doctor] doctor.sh up to date (no rewrite needed)"
    else
        cp "$_generated" "$DOCTOR"
        chmod +x "$DOCTOR"
        echo "[regen-doctor] wrote $DOCTOR ($(wc -l < "$DOCTOR") lines)"
    fi
fi
