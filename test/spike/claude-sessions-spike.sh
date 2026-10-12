#!/usr/bin/env bash
# test/spike/claude-sessions-spike.sh -- HOST-RUN measurement for
# decisions/2026-10-12-named-claude-sessions.md. RUN THIS ON THE HOST, never
# inside a sandy sandbox: it uses sandy --start/--stop and docker.
#
# It answers three questions the named-sessions design rests on, against the
# Claude Code that the sandy image actually ships:
#
#   M1  How Claude Code records a session NAME (--name) in the transcript
#       .jsonl. Sandy's title lookup (decision 2) parses that record.
#   M2  Whether `claude --bg --resume <id>` in a NEW container (after a
#       --stop/--start relaunch) continues the session under the SAME id, or
#       "starts a copy" because records left by the previous container make
#       it look running. Plus a control: resuming a session that really is
#       running must report a copy, so we know what a copy looks like.
#   M3  Whether `claude agents --json` reports full session ids (readiness,
#       decision 5).
#
# The fourth unknown (a per-session --settings refuse beside a shared accept)
# is covered by test/measure-settings-inbound.sh Q1/Q2; re-run that too.
#
# It is a measurement, not a pass/fail suite: it prints raw evidence and a
# reading per question. Paste the whole output back. Uses a cheap model for
# the few real turns it runs (override with SPIKE_MODEL).
set -uo pipefail

SANDY="${SANDY:-./sandy}"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib-isolated-home.sh"
[ "${SANDY_TEST_NO_ISOLATE:-0}" = "1" ] || _isolate_sandy_home
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"

MODEL="${SPIKE_MODEL:-claude-haiku-4-5-20251001}"
NAME="Spike Alpha $$"
WS="$(cd "$(mktemp -d)" && pwd -P)/csess-$$"
mkdir -p "$WS" && (cd "$WS" && git init -q)
export SANDY_AGENT=claude SANDY_AUTO_APPROVE_PRIVILEGED=1

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
X()    { "$SANDY" --exec --workspace "$WS" -- bash -c "$1"; }
uuids() { grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort -u; }
sbx()  { for d in "$SANDY_HOME_DIR"/sandboxes/csess-*; do [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }; done; return 1; }
finish() {
    "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true
    _cleanup_sandy_home 2>/dev/null || true
}
trap finish EXIT

start() {
    say "sandy --start ($1)"
    if ! "$SANDY" --start --workspace "$WS" > "$WS.start.$1.log" 2>&1; then
        echo "FATAL: --start failed; its output:"; tail -40 "$WS.start.$1.log"; exit 2
    fi
    echo "started"
}
# Poll `claude agents --json` (up to ~60s) until NAME shows up; print the last JSON.
agents_wait() {
    local out=""
    for _ in $(seq 1 20); do
        out="$(X 'claude agents --json --all 2>&1' 2>/dev/null)"
        case "$out" in *"$NAME"*) break ;; esac
        sleep 3
    done
    printf '%s\n' "$out"
}

echo "claude-sessions spike: workspace $WS, model $MODEL, name '$NAME'"
start 1
say "Claude Code version in the container"
X 'claude --version'

say "M1/M3: create a named background session"
X "claude --bg --model $(printf %q "$MODEL") --permission-mode bypassPermissions --name $(printf %q "$NAME") 'Reply with exactly the word: ok'" 2>&1 | tee "$WS.create.out"
say "claude agents --json --all (after create)"
A1="$(agents_wait)"; printf '%s\n' "$A1" | head -c 4000; echo
SB="$(sbx)" || { echo "FATAL: no sandbox dir under $SANDY_HOME_DIR/sandboxes"; exit 2; }

say "M1: transcript records mentioning the name"
ID=""
while IFS= read -r f; do
    if grep -q "$NAME" "$f" 2>/dev/null; then
        ID="$(basename "$f" .jsonl)"
        echo "file: ${f#"$SB"/}"
        grep -n "$NAME" "$f" | cut -c1-600
    fi
done < <(find "$SB/claude/projects" -name '*.jsonl' 2>/dev/null)
echo "session id from transcript filename: ${ID:-<none found>}"

say "M3: ids in agents --json vs the transcript id"
printf '%s\n' "$A1" | uuids | sed 's/^/  agents --json uuid: /'
case "$A1" in
    *"$ID"*) [ -n "$ID" ] && echo "READING M3: agents --json carries the FULL id ($ID)" ;;
    *) echo "READING M3: agents --json does NOT carry the full transcript id; see the raw JSON above" ;;
esac

say "state dirs in the sandbox before relaunch"
ls -la "$SB/claude/sessions" "$SB/claude/jobs" 2>&1 | head -40

say "M2 control: resume the session while it is still registered in THIS container"
[ -n "$ID" ] && X "claude --bg --resume $ID --model $(printf %q "$MODEL") --permission-mode bypassPermissions 'Reply with exactly the word: ok-dup'" 2>&1 | tee "$WS.dup.out"

say "relaunch: --stop then --start (new container)"
"$SANDY" --stop --workspace "$WS" > /dev/null 2>&1 || true
start 2
say "state dirs in the sandbox after relaunch"
ls -la "$SB/claude/sessions" "$SB/claude/jobs" 2>&1 | head -40
say "claude agents --json --all in the new container, before resuming"
X 'claude agents --json --all 2>&1' | head -c 4000; echo

say "M2: resume the original id in the new container"
if [ -n "$ID" ]; then
    X "claude --bg --resume $ID --model $(printf %q "$MODEL") --permission-mode bypassPermissions 'Reply with exactly the word: ok-2'" 2>&1 | tee "$WS.resume.out"
    A2="$(agents_wait)"; printf '%s\n' "$A2" | head -c 4000; echo
    if grep -qi 'copy' "$WS.resume.out"; then
        echo "READING M2: COPY -- the resume reported starting a copy (see output above)"
    elif printf '%s\n' "$A2" | grep -q "$ID"; then
        echo "READING M2: RESUMED under the same id ($ID)"
    else
        echo "READING M2: UNCLEAR -- no 'copy' message, but $ID is not in agents --json; read the raw output"
    fi
    echo "transcripts now mentioning the name:"
    find "$SB/claude/projects" -name '*.jsonl' -exec grep -l "$NAME" {} + 2>/dev/null | sed "s|$SB/||"
else
    echo "SKIP M2: no session id was found in M1"
fi

say "Also re-run test/measure-settings-inbound.sh (per-session --settings refuse, decision 3)"
