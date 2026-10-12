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
# RESULTS, run 5 (2026-10-12, Claude Code 2.1.296, macOS host):
#   M1  The name is in jobs/<short>/state.json (`name`, `nameSource: user`,
#       `sessionId`, `respawnFlags`) and in the transcript as
#       {"type":"custom-title","customTitle":...} + {"type":"agent-name",...}.
#   M2  After a relaunch, `claude --bg --resume <full id> '<prompt>'` with NO
#       flags wakes the session "with its saved options" and the prompt lands
#       in the SAME transcript. Any flag makes a copy ("keeps its own saved
#       options"), and so does resuming a session that is live (including one
#       the pane's `claude --continue` reopened). Flags are frozen at creation.
#       A flag-less resume with no prompt wakes it idle. `respawn` wakes it
#       too, but a prompted resume after that is a copy (it is live by then).
#   M3  agents --json carries sessionId and name. A woken process's own
#       entry shows a TRANSIENT sessionId until it takes a prompt, so key
#       readiness on the job `id` plus a pid, not on that entry's sessionId.
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
    # --new: the pane must NOT `claude --continue`. Run 3 showed it reopening
    # the background session's transcript (the newest one in the workspace),
    # which then made every resume start a copy. The real feature runs
    # `claude agents` in the pane instead.
    if ! "$SANDY" --start --new --workspace "$WS" > "$WS.start.$1.log" 2>&1; then
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
    console.log([j.sessionId, j.id || "-", j.kind || "-", j.state || j.status || "-", j.pid ? "pid=" + j.pid : "nopid"].join(" "));
});
JS
sel() { X "claude agents --json --all 2>/dev/null | node $(printf %q "$WS/.spike-sel.js") $(printf %q "$NAME")" 2>/dev/null; }
# Wait (up to ~120s) until the named job's own record (the entry whose short
# id is $SHORT, or the first one before $SHORT is known) has settled. Run 4
# showed this returning at once after a 5th field was added: match the state
# FIELD, never a line suffix.
settle() {
    local r="" st=""
    for _ in $(seq 1 40); do
        r="$(sel)"
        st="$(printf '%s\n' "$r" | awk -v s="${SHORT:-}" '(s == "" || $2 == s) && $3 == "background" {print $4; exit}')"
        case "$st" in working|starting|running|"") sleep 3 ;; *) break ;; esac
    done
    printf '%s\n' "$r"
}
# Which transcripts contain WORD (a prompt marker). The proof that a prompted
# resume continued the SAME conversation: the marker lands in $ID.jsonl only.
marker_in() {
    find "$SB/claude/projects" -name '*.jsonl' -exec grep -l "$1" {} + 2>/dev/null | sed "s|.*/||"
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
    echo "claude/ top level, sessions/ and jobs/ in the new container, before anything:"
    ls -la "$SB/claude" "$SB/claude/sessions" 2>&1 | head -50
    find "$SB/claude/jobs" -type f 2>/dev/null | sed "s|$SB/||"
    echo "raw agents --json --all:"; X 'claude agents --json --all 2>&1' | head -c 4000; echo
}
# Reading: same id and running = RESUMED; a second entry or a "copy" message = COPY.
reading() {  # $1 label, $2 output file
    local r; r="$(settle)"
    echo "named jobs after $1:"; printf '%s\n' "$r"
    echo "raw agents --json --all:"; X 'claude agents --json --all 2>&1' | head -c 4000; echo
    echo "jobs/$SHORT/state.json now:"; head -c 1500 "$SB/claude/jobs/$SHORT/state.json" 2>&1; echo
    # Judged on LIVE processes (entries with a pid) carrying the name: every
    # one must be running $ID. A live one on another sessionId is a copy.
    local live other
    live="$(printf '%s\n' "$r" | grep ' pid=' || true)"
    other="$(printf '%s\n' "$live" | grep -v "^$ID " | grep . || true)"
    if grep -qi 'copy' "$2"; then echo "READING $1: COPY (it said so)"
    elif grep -qi "can.t open\|another terminal\|open in another" "$2"; then echo "READING $1: BLOCKED (thinks the session is open elsewhere)"
    elif [ -n "$other" ]; then echo "READING $1: COPY (a live process carries the name on another session id: $other)"
    elif [ -n "$live" ]; then echo "READING $1: SAME ID ($ID) and live"
    else echo "READING $1: NOT LIVE (no process is running $ID; read the raw output)"; fi
}

# Run 2 (2026-10-12, 2.1.296): a resume WITH flags always starts a copy
# ("keeps its own saved options"); respawn was blocked by an "interactive"
# entry left over from the previous container. So: resume with NO flags.
relaunch 2
say "M2c: claude --bg --resume <full id>, NO flags, NO prompt"
X "claude --bg --resume $ID" > "$WS.m2c.out" 2>&1; cat "$WS.m2c.out"
reading M2c "$WS.m2c.out"

relaunch 3
say "M2d: claude --bg --resume <full id> 'prompt', NO flags (the On resume text)"
X "claude --bg --resume $ID 'Reply with exactly the word: resumed-m2d'" > "$WS.m2d.out" 2>&1; cat "$WS.m2d.out"
reading M2d "$WS.m2d.out"
echo "transcripts containing the M2d prompt (want exactly $ID.jsonl):"; marker_in 'resumed-m2d'
case "$(marker_in 'resumed-m2d' | tr '\n' ' ')" in
    "$ID.jsonl ") echo "READING M2d-transcript: SAME CONVERSATION" ;;
    *) echo "READING M2d-transcript: NOT the same conversation (see list above)" ;;
esac
echo "last lines of the transcript (did the prompt land in the SAME conversation?):"
tail -n 4 "$(find "$SB/claude/projects" -name "$ID.jsonl" | head -1)" 2>/dev/null | cut -c1-400

relaunch 4
say "M2b: claude respawn <short id>"
X "claude respawn $SHORT" > "$WS.m2b.out" 2>&1; cat "$WS.m2b.out"
reading M2b "$WS.m2b.out"
say "M2e: after respawn, a prompted resume of the same id (does respawn keep the conversation?)"
X "claude --bg --resume $ID 'Reply with exactly the word: resumed-m2e'" > "$WS.m2e.out" 2>&1; cat "$WS.m2e.out"
reading M2e "$WS.m2e.out"
echo "transcripts containing the M2e prompt (want exactly $ID.jsonl):"; marker_in 'resumed-m2e'
case "$(marker_in 'resumed-m2e' | tr '\n' ' ')" in
    "$ID.jsonl ") echo "READING M2e-transcript: SAME CONVERSATION" ;;
    *) echo "READING M2e-transcript: NOT the same conversation (see list above)" ;;
esac

say "transcripts mentioning the name at the end (one = no copies were made)"
find "$SB/claude/projects" -name '*.jsonl' -exec grep -l "$NAME" {} + 2>/dev/null | sed "s|$SB/||"

say "Also re-run test/measure-settings-inbound.sh (per-session --settings refuse, decision 3)"
