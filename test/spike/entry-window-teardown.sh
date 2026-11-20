#!/usr/bin/env bash
# test/spike/entry-window-teardown.sh -- HOST-RUN measurement for B5 (the
# feature-entry startup window runs alongside the agent). RUN THIS ON THE
# HOST, never inside a sandy sandbox: it uses sandy --start/--stop, docker
# and tmux.
#
# Since B5 the agent is already starting when a failing feature entry makes
# the window tear the session down (TERM to each pane's process group, up to
# 3s, then tmux kill-server). The design accepted two persistent risks on the
# condition that they are MEASURED, not argued:
#
#   R1  a credential or config file truncated by a kill in the middle of a
#       write: claude/.claude.json, claude/.credentials.json, codex/auth.json;
#   R2  a transcript created by the torn-down launch, which auto-continue
#       (claude --continue, codex resume --last) would then resume next time
#       instead of the user's real conversation.
#
# For each agent (claude, codex) it
#   1. starts a daemon session, sends one real prompt to the pane, and waits,
#      so a real conversation exists; records the newest transcript (claude:
#      claude/projects/<ws>/*.jsonl; codex: interactive rollout-*.jsonl);
#   2. installs a feature whose entry runs `sleep T; exit 3`, for T in
#      RIG_TIMES (default 0.5 1 2 3 4.5), RIG_REPS times each (default 10),
#      and launches: --start must exit 6, nothing may be left running, every
#      file in R1 must still parse, and the newest transcript must still be
#      the one from step 1 (R2);
#   3. removes the feature, starts again, sends a marker prompt, and checks
#      the marker landed in the step-1 transcript: the next launch resumed
#      the same conversation.
#
# RIG_MODE=pty runs step 2 as an INTERACTIVE launch on a pty instead (needs
# python3): exit 1, with the entry's message printed after tmux exits. The
# teardown is the same function in both modes; only where the window runs
# differs (the daemon's main process vs a watcher beside tmux attach).
#
# Prints PASS/FAIL per assertion plus raw evidence; exits non-zero on any
# FAIL. Paste the whole output back. Uses a cheap model where it can
# (RIG_CLAUDE_MODEL, RIG_CODEX_MODEL). RIG_AGENTS limits the agents.
# RIG_PTY_DEADLINE (default 180 s) bounds each pty launch; a launch that
# overruns is killed and counts as a FAIL ("timeout").
set -uo pipefail

SANDY="${SANDY:-$(cd "$(dirname "$0")/../.." && pwd)/sandy}"
# shellcheck source=/dev/null
. "$(dirname "$0")/../lib-isolated-home.sh"
[ "${SANDY_TEST_NO_ISOLATE:-0}" = "1" ] || _isolate_sandy_home
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"
export SANDY_AUTO_APPROVE_PRIVILEGED=1

RIG_TIMES="${RIG_TIMES:-0.5 1 2 3 4.5}"
RIG_REPS="${RIG_REPS:-10}"
RIG_MODE="${RIG_MODE:-start}"
RIG_AGENTS="${RIG_AGENTS:-claude codex}"
FEAT="$SANDY_HOME_DIR/features/rig-entry-window"
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
WS=""
finish() {
    [ -n "$WS" ] && "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1
    rm -rf "$FEAT"
    _cleanup_sandy_home 2>/dev/null || true
}
trap finish EXIT
command -v docker >/dev/null 2>&1 || { echo "docker not found -- run this on the host"; exit 2; }
[ -e /etc/sandy-session.json ] && { echo "refusing: this looks like a sandy container; run on the host"; exit 2; }
[ "$RIG_MODE" = start ] || command -v python3 >/dev/null 2>&1 || { echo "RIG_MODE=pty needs python3"; exit 2; }

cid() { docker ps -aq --filter "label=sandy.workspace_path=$WS" 2>/dev/null; }
sbx() {
    local d
    for d in "$SANDY_HOME_DIR"/sandboxes/"$(basename "$WS")"-*; do [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }; done
    return 1
}
# The newest transcript auto-continue would resume, as "<basename> <lines>".
newest() {   # $1 = agent, $2 = sandbox dir
    local f="" r h
    local -a c=()
    case "$1" in
        claude) f="$(ls -t "$2"/claude/projects/*/*.jsonl 2>/dev/null | head -n 1)" ;;
        codex)
            # Interactive rollouts for this workspace only, as codex resume --last.
            while IFS= read -r r; do
                h="$(head -n 1 "$r")"
                case "$h" in *'"source":"exec"'*) continue ;; esac
                case "$h" in *"\"cwd\":\"$WS\""*) c+=("$r") ;; esac
            done < <(find "$2/codex/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null)
            [ "${#c[@]}" -gt 0 ] && f="$(ls -t "${c[@]}" | head -n 1)" ;;
    esac
    [ -n "$f" ] || { echo "none 0"; return 0; }
    printf '%s %s\n' "$(basename "$f")" "$(wc -l < "$f" | tr -d ' ')"
}
count_transcripts() {   # $1 = agent, $2 = sandbox dir
    case "$1" in
        claude) find "$2/claude/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ' ;;
        codex)  find "$2/codex/sessions" -name 'rollout-*.jsonl' 2>/dev/null | wc -l | tr -d ' ' ;;
    esac
}
# R1: every credential/config file that exists must parse as JSON.
files_parse() {   # $1 = sandbox dir -> prints one line per file
    local f
    for f in "$1/claude/.claude.json" "$1/claude/.credentials.json" "$1/codex/auth.json"; do
        [ -s "$f" ] || continue
        if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
            echo "parses ${f#"$1"/}"
        else
            echo "BROKEN ${f#"$1"/}"
        fi
    done
}
prompt_pane() {   # $1 = text: type it into the daemon's pane, then Enter
    "$SANDY" --exec --workspace "$WS" -- tmux send-keys -t sandy -l "$1" >/dev/null 2>&1
    sleep 1
    "$SANDY" --exec --workspace "$WS" -- tmux send-keys -t sandy Enter >/dev/null 2>&1
}
install_entry() {   # $1 = seconds before the entry exits 3
    # A NEW file per entry time, never a rewrite: on macOS file sharing a
    # container reads a host-replaced file at its old length (#400, #549),
    # so a longer script came back cut short (`exit ` with no status, rc 0).
    local _e="payload/fail-$1" _t
    mkdir -p "$FEAT/payload"
    if [ ! -e "$FEAT/$_e" ]; then
        _t="$(mktemp "$FEAT/payload/.fail.XXXXXX")"
        printf '#!/bin/sh\nsleep %s\nexit 3\n' "$1" > "$_t"
        chmod +x "$_t" && mv "$_t" "$FEAT/$_e"
    fi
    _t="$(mktemp "$FEAT/.feature.XXXXXX")"
    printf '{ "sandboxes": {"include": ["*"]}, "agents": {"include": ["*"]},\n  "mounts": [ { "name": "payload", "from": "payload" } ],\n  "entry": "%s" }\n' "$_e" > "$_t"
    mv "$_t" "$FEAT/feature.json"
}
# One interactive launch on a pty; prints "<rc> <message seen after tmux>".
pty_launch() {
    python3 - "$SANDY" "$WS" <<'PY'
import os, pty, select, signal, subprocess, sys, time
sandy, ws = sys.argv[1], sys.argv[2]
master, slave = pty.openpty()
p = subprocess.Popen(["bash", sandy], stdin=slave, stdout=slave, stderr=slave, cwd=ws,
                     env={**os.environ, "TERM": "xterm"}, start_new_session=True)
os.close(slave)
# Overall deadline (#549): the per-read 120 s alone let a launch that kept
# printing, or never closed the pty, hang the rig.
deadline = time.monotonic() + float(os.environ.get("RIG_PTY_DEADLINE", "180"))
out = b""; timed_out = False
while True:
    left = deadline - time.monotonic()
    if left <= 0:
        timed_out = True; break
    r, _, _ = select.select([master], [], [], min(left, 120))
    if not r:
        timed_out = time.monotonic() >= deadline
        if not timed_out:
            continue
        break
    try:
        chunk = os.read(master, 65536)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
if timed_out:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
try:
    rc = p.wait(timeout=30)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); rc = p.wait()
if timed_out:
    print(rc, "timeout")
    sys.exit(0)
text = out.decode(errors="replace")
tail = text.rsplit("\x1b[?1049l", 1)[-1]
print(rc, "after-tmux" if "within 5s of starting" in tail else "message-missing-after-tmux")
PY
}

for AGENT in $RIG_AGENTS; do
    say "$AGENT: baseline conversation"
    WS="$(cd "$(mktemp -d)" && pwd -P)/ewrig-$AGENT-$$"
    mkdir -p "$WS" && (cd "$WS" && git init -q)
    export SANDY_AGENT="$AGENT"
    case "$AGENT" in
        claude) [ -n "${RIG_CLAUDE_MODEL:-}" ] && export SANDY_MODEL="$RIG_CLAUDE_MODEL" ;;
        codex)  [ -n "${RIG_CODEX_MODEL:-}" ] && export SANDY_MODEL="$RIG_CODEX_MODEL" ;;
    esac
    rm -rf "$FEAT"
    if ! "$SANDY" --start --workspace "$WS" > "$WS.base.log" 2>&1; then
        bad "$AGENT: baseline --start failed"; tail -30 "$WS.base.log"; continue
    fi
    sleep 8
    prompt_pane "Reply with exactly the word: baseline"
    sleep 30
    "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1
    SB="$(sbx)" || { bad "$AGENT: no sandbox dir"; continue; }
    BASE="$(newest "$AGENT" "$SB")"; BASE_ID="${BASE%% *}"
    BASE_N="$(count_transcripts "$AGENT" "$SB")"
    echo "  baseline transcript: $BASE (of $BASE_N)"
    [ "$BASE_ID" != none ] || { bad "$AGENT: the baseline turn left no transcript; cannot measure R2"; continue; }

    for T in $RIG_TIMES; do
        install_entry "$T"
        for REP in $(seq 1 "$RIG_REPS"); do
            t0=$(date +%s)
            if [ "$RIG_MODE" = pty ]; then
                res="$(pty_launch)"; rc="${res%% *}"; how="${res#* }"; want=1
            else
                "$SANDY" --start --workspace "$WS" > "$WS.fail.log" 2>&1; rc=$?; how="-"; want=6
            fi
            dt=$(( $(date +%s) - t0 ))
            i=0; while [ -n "$(cid)" ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
            left="$(cid)"
            now="$(newest "$AGENT" "$SB")"; n="$(count_transcripts "$AGENT" "$SB")"
            parse="$(files_parse "$SB" | tr '\n' ' ')"
            line="$AGENT T=${T}s rep=$REP rc=$rc (${dt}s) $how newest=$now transcripts=$n files: $parse"
            if [ "$rc" = "$want" ] && [ -z "$left" ] && [ "${now%% *}" = "$BASE_ID" ] \
               && ! printf '%s' "$parse" | grep -q BROKEN \
               && { [ "$how" = - ] || [ "$how" = after-tmux ]; }; then
                ok "$line"
            else
                bad "$line${left:+ LEFT RUNNING: $left}"
                [ "$RIG_MODE" = start ] && tail -15 "$WS.fail.log"
                [ -n "$left" ] && "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1
            fi
        done
    done
    rm -rf "$FEAT"

    say "$AGENT: the next launch resumes the baseline conversation"
    if "$SANDY" --start --workspace "$WS" > "$WS.resume.log" 2>&1; then
        sleep 8
        MARK="ewrig-marker-$$-$AGENT"
        prompt_pane "Reply with exactly the word: $MARK"
        sleep 30
        "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1
        hits="$(grep -rl "$MARK" "$SB/claude/projects" "$SB/codex/sessions" 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
        echo "  marker found in: ${hits:-nothing}"
        if [ "$AGENT" = claude ]; then
            case " $hits " in *" $BASE_ID "*) ok "$AGENT: the marker landed in the baseline transcript $BASE_ID" ;;
                              *) bad "$AGENT: the marker is not in the baseline transcript $BASE_ID" ;; esac
        else
            # GUESS (design B5 section 2): whether codex resume --last appends
            # to the same rollout file or writes a new one that references it.
            # Evidence only: read the lines above.
            echo "  codex: baseline rollout $BASE_ID; read the marker location above"
        fi
    else
        bad "$AGENT: the resume --start failed"; tail -30 "$WS.resume.log"
    fi
    rm -rf "$(dirname "$WS")" "$WS".*.log
    WS=""
done

echo
echo "entry-window teardown rig: $PASS passed, $FAIL failed (mode $RIG_MODE, times: $RIG_TIMES, reps: $RIG_REPS)"
[ "$FAIL" -eq 0 ]
