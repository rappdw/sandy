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
#       decision 5). (Run 1, 2026-10-12, Claude Code 2.1.296: yes, sessionId
#       and name, and a job from a previous container stays listed as
#       state "failed" -- Claude Code keeps name->id in ~/.claude/jobs.)
#   M2b Whether `claude respawn <id>` is the native way to bring such a
#       failed job back in a new container, same id.
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

# The named job's fields, selected IN the container with its node (the host
# may have neither jq nor python3). Written to the workspace, which the
# container mounts at the same path (it is outside $HOME).
cat > "$WS/.spike-sel.js" <<'JS'
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  let a = [];
  try { a = JSON.parse(s); } catch (e) { console.log("UNPARSEABLE"); return; }
  for (const j of a) if (j.name === process.argv[2])
    console.log([j.sessionId, j.id || "-", j.kind || "-", j.state || j.status || "-"].join(" "));
});
JS
sel() { X "claude agents --json --all 2>/dev/null | node $(printf %q "$WS/.spike-sel.js") $(printf %q "$NAME")" 2>/dev/null; }
# Wait (up to ~90s) until the named job has left state "working".
settle() {
    local r=""
    for _ in $(seq 1 30); do
        r="$(sel)"
        case "$r" in *" working"|"") sleep 3 ;; *) break ;; esac
    done
    printf '%s\n' "$r"
}
bg_args="--model $(printf %q "$MODEL") --permission-mode bypassPermissions"

say "M1/M3: create a named background session"
X "claude --bg $bg_args --name $(printf %q "$NAME") 'Reply with exactly the word: ok'" 2>&1
say "named job after create (sessionId shortId kind state)"
S1="$(settle)"; printf '%s\n' "$S1"
ID="$(printf '%s\n' "$S1" | head -1 | cut -d' ' -f1)"
SHORT="$(printf '%s\n' "$S1" | head -1 | cut -d' ' -f2)"
SB="$(sbx)" || { echo "FATAL: no sandbox dir under $SANDY_HOME_DIR/sandboxes"; exit 2; }
[ -n "$ID" ] || { echo "FATAL: the named job is not in agents --json"; X 'claude agents --json --all' ; exit 2; }

say "M1: Claude Code's job record, claude/jobs/$SHORT"
find "$SB/claude/jobs/$SHORT" -type f 2>/dev/null | while IFS= read -r f; do
    echo "--- ${f#"$SB"/} ($(wc -c < "$f" | tr -d ' ') bytes)"; head -c 1500 "$f"; echo
done
say "M1: the transcript for $ID"
T="$(find "$SB/claude/projects" -name "$ID.jsonl" 2>/dev/null | head -1)"
if [ -n "$T" ]; then
    echo "file: ${T#"$SB"/}"
    echo "lines naming the session:"; grep -n "$NAME" "$T" | cut -c1-600
    echo "record types present:"; grep -oE '"type":"[a-z_-]+"' "$T" | sort | uniq -c
else
    echo "no $ID.jsonl yet; project dirs:"; ls "$SB/claude/projects" 2>&1
fi

say "M2 control: resume while the job is still live in THIS container"
X "claude --bg --resume $ID $bg_args 'Reply with exactly the word: ok-dup'" 2>&1
sleep 5; echo "named jobs now:"; sel

relaunch() {
    say "relaunch: --stop then --start ($1)"
    "$SANDY" --stop --workspace "$WS" > /dev/null 2>&1 || true
    start "$1"
    echo "named jobs in the new container, before anything:"; sel
}
# Reading: same id and running = RESUMED; a second entry or a "copy" message = COPY.
reading() {  # $1 label, $2 output file
    local r n; r="$(settle)"; n="$(printf '%s\n' "$r" | grep -c .)"
    echo "named jobs after $1:"; printf '%s\n' "$r"
    if grep -qi 'copy' "$2"; then echo "READING $1: COPY (it said so)"
    elif [ "$n" -gt 1 ]; then echo "READING $1: COPY ($n jobs carry the name)"
    elif printf '%s\n' "$r" | grep -q "^$ID "; then echo "READING $1: SAME ID ($ID), state $(printf '%s\n' "$r" | awk '{print $4}')"
    else echo "READING $1: UNCLEAR, read the raw output"; fi
}

relaunch 2
say "M2a: claude --bg --resume <full id> in the new container"
X "claude --bg --resume $ID $bg_args 'Reply with exactly the word: ok-2'" > "$WS.m2a.out" 2>&1; cat "$WS.m2a.out"
reading M2a "$WS.m2a.out"

relaunch 3
say "M2b: claude respawn <short id> in the new container"
X "claude respawn $SHORT" > "$WS.m2b.out" 2>&1; cat "$WS.m2b.out"
reading M2b "$WS.m2b.out"

say "transcripts mentioning the name at the end (one = no copies were made)"
find "$SB/claude/projects" -name '*.jsonl' -exec grep -l "$NAME" {} + 2>/dev/null | sed "s|$SB/||"

say "Also re-run test/measure-settings-inbound.sh (per-session --settings refuse, decision 3)"
