#!/usr/bin/env bash
# Diagnose the "gemini session works in switch test" integration-test failure.
# Reproduces the exact invocation the integration suite makes, captures the
# full captured output (no truncation), and reports what's tripping the
# `grep -qi "unknown flag\|error"` assertion.
#
# Usage:
#   bash test/diagnose-gemini-switch.sh
#
# Requires:
#   - $GEMINI_API_KEY in the env (or run with `GEMINI_API_KEY=... bash ...`)
#   - Docker running, sandy-gemini-cli image already built (re-uses cache)
set -uo pipefail

if [ -z "${GEMINI_API_KEY:-}" ]; then
    echo "ERROR: GEMINI_API_KEY not set in env. Run with:" >&2
    echo "  GEMINI_API_KEY=\$GEMINI_API_KEY bash $0" >&2
    exit 1
fi

SANDY_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/sandy"
[ -x "$SANDY_SCRIPT" ] || { echo "ERROR: sandy script not found at $SANDY_SCRIPT" >&2; exit 1; }

# macOS doesn't ship GNU timeout; the integration harness uses a perl fallback.
# Mirror that so this script is portable.
if ! command -v timeout >/dev/null 2>&1; then
    timeout() {
        local secs="$1"; shift
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    }
fi

_proj="$(mktemp -d)"
mkdir -p "$_proj/.sandy"
echo "SANDY_AGENT=gemini" > "$_proj/.sandy/config"

cd "$_proj"

echo "=== Reproducing integration test §8 'gemini session works in switch test' ==="
echo "Workspace:      $_proj"
echo "Sandy script:   $SANDY_SCRIPT"
echo ""

# The integration test wraps in `timeout 300` and uses `2>&1 | tee /dev/stderr`
# inside a $() capture. We replicate the exact capture here: combined stderr
# into stdout, captured into _out as a single string.
_out="$(timeout 300 env "GEMINI_API_KEY=$GEMINI_API_KEY" "$SANDY_SCRIPT" -p "reply one word: first" 2>&1)"
_rc=$?

echo "=== Exit code: $_rc ==="
echo ""
echo "=== Full captured output ($(echo -n "$_out" | wc -l) lines, $(echo -n "$_out" | wc -c) bytes) ==="
echo "$_out"
echo ""
echo "=== Lines matching 'error' (case-insensitive) — what the test grep sees ==="
if echo "$_out" | grep -in "error" >/dev/null 2>&1; then
    echo "$_out" | grep -in "error"
else
    echo "(no matches — the 'error' grep should NOT trip)"
fi
echo ""
echo "=== Lines matching 'unknown flag' (case-insensitive) ==="
if echo "$_out" | grep -in "unknown flag" >/dev/null 2>&1; then
    echo "$_out" | grep -in "unknown flag"
else
    echo "(no matches)"
fi
echo ""
echo "=== Test verdict ==="
if echo "$_out" | grep -qi "unknown flag\|error"; then
    echo "FAIL — the integration-test grep would fail this run."
    echo "       (the matching lines are listed above)"
else
    echo "PASS — the integration-test grep would NOT fail this run."
    echo "       (this run is clean; the failure must be transient/timing-related)"
fi

cd /
rm -rf "$_proj"
