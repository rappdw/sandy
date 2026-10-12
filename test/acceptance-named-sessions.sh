#!/usr/bin/env bash
# test/acceptance-named-sessions.sh -- HOST-RUN acceptance for named Claude
# sessions (.sandy/sessions/, decisions/2026-10-12-named-claude-sessions.md).
# RUN THIS ON THE HOST, never inside a sandy sandbox: it uses sandy
# --start/--stop and docker.
#
# run-tests.sh §204 proves each piece against stubs. This proves the thing a
# stub cannot: that against the Claude Code the image really ships, a relaunch
# RESUMES each session under the same id instead of starting a copy, which is
# the whole point of the feature and the failure that matters most.
#
#   A1  first --start: exit 0; both declared sessions are live background jobs
#       carrying their names; the status file reports both up
#   A2  the non-receiving session was created with the inline refuse pin and
#       the receiving one without it (respawnFlags)
#   A3  the claude pane is agent view (`claude agents`), not `claude --continue`
#   A4  --stop + --start: exit 0, both sessions come back under the SAME
#       session ids, the On resume text lands in the ORIGINAL transcript, and
#       no second transcript carries either name (no copy)
#   A5  a session: id that is not in the sandbox: --start exits 9, the
#       container is left running, and --print-state reports state missing
#
# Uses a cheap model for the few real turns (SANDY_MODEL, override with
# ACCEPT_MODEL). Prints PASS/FAIL per assertion; exits non-zero on any FAIL.
set -uo pipefail

SANDY="${SANDY:-./sandy}"
# shellcheck source=/dev/null
. "$(dirname "$0")/lib-isolated-home.sh"
[ "${SANDY_TEST_NO_ISOLATE:-0}" = "1" ] || _isolate_sandy_home
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"

export SANDY_AGENT=claude SANDY_AUTO_APPROVE_PRIVILEGED=1
export SANDY_MODEL="${ACCEPT_MODEL:-claude-haiku-4-5-20251001}"
unset SANDY_CLAUDE_SESSIONS SANDY_CHANNELS SANDY_CROSS_SESSION_INBOUND

PASS=0; FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1));
       else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

WS="$(cd "$(mktemp -d)" && pwd -P)/named-sess-$$"
mkdir -p "$WS/.sandy/sessions" && (cd "$WS" && git init -q)
cat > "$WS/.sandy/sessions/alpha.md" <<'EOF'
---
name: Accept Alpha
---
## On create
Reply with exactly the word: alpha-created

## On resume
Reply with exactly the word: alpha-resumed
EOF
cat > "$WS/.sandy/sessions/beta.md" <<'EOF'
---
name: Accept Beta
receives: [cross_session]
---
## On create
Reply with exactly the word: beta-created

## On resume
Reply with exactly the word: beta-resumed
EOF

finish() {
    "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true
    _cleanup_sandy_home 2>/dev/null || true
}
trap finish EXIT

X() { "$SANDY" --exec --workspace "$WS" -- bash -c "$1"; }
sbx() { for d in "$SANDY_HOME_DIR"/sandboxes/named-sess-*; do [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }; done; return 1; }
# "<sessionId> <pid-or-none>" for the background job named $1, read with the
# container's node from the workspace (mounted at the same path, outside $HOME).
cat > "$WS/.accept-sel.js" <<'JS'
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  let a = []; try { a = JSON.parse(s); } catch (e) { return; }
  const jobs = a.filter(e => e.kind === "background" && e.id && String(e.sessionId).startsWith(e.id) && e.name === process.argv[2]);
  for (const j of jobs) {
    const live = a.some(e => e.pid && e.id === j.id);
    console.log(j.sessionId + " " + (live ? "live" : "stopped"));
  }
});
JS
job() { X "claude agents --json --all 2>/dev/null | node $(printf %q "$WS/.accept-sel.js") $(printf %q "$1")" 2>/dev/null; }
start() {
    "$SANDY" --start --workspace "$WS" > "$WS.start.$1.log" 2>&1
    echo $?
}

say "A1: first --start creates both sessions"
RC1="$(start 1)"
ck "A1 --start exited 0 (got $RC1)" '[ "$RC1" = 0 ]'
[ "$RC1" = 0 ] || tail -30 "$WS.start.1.log"
SB="$(sbx)"
A1="$(job 'Accept Alpha')"; B1="$(job 'Accept Beta')"
echo "  alpha: $A1"; echo "  beta:  $B1"
ck "A1 'Accept Alpha' is exactly one live background job" '[ "$(printf "%s\n" "$A1" | grep -c " live$")" = 1 ] && [ "$(printf "%s\n" "$A1" | grep -c .)" = 1 ]'
ck "A1 'Accept Beta' is exactly one live background job" '[ "$(printf "%s\n" "$B1" | grep -c " live$")" = 1 ] && [ "$(printf "%s\n" "$B1" | grep -c .)" = 1 ]'
ck "A1 the status file reports both up for this launch" '[ "$(grep -c "	up	" "$SB/claude/.sandy-sessions.tsv")" = 2 ]'
AID="${A1%% *}"; BID="${B1%% *}"

say "A2: the inbound pin is a creation flag, on the non-receiver only"
ck "A2 alpha (no receives) was created with --settings {crossSessionInbound: refuse}" 'grep -q "crossSessionInbound" "$SB/claude/jobs/${AID:0:8}/state.json"'
ck "A2 beta (receives cross_session) was created without it" '! grep -q "crossSessionInbound" "$SB/claude/jobs/${BID:0:8}/state.json"'
ck "A2 the shared settings say accept, source session:beta" 'grep -q "\"cross_session_inbound_source\": \"session:beta\"" "$SB/sandy-session.json"'

say "A3: the claude pane is agent view"
PANE="$(X 'tmux list-panes -t sandy -F "#{pane_start_command}"' 2>/dev/null)"
echo "  pane: $PANE"
ck "A3 the pane runs claude agents" 'printf "%s" "$PANE" | grep -q "claude agents"'
ck "A3 ...and never claude --continue" '! printf "%s" "$PANE" | grep -q -- "--continue"'

say "A4: relaunch resumes the same sessions, no copies"
"$SANDY" --stop --workspace "$WS" > /dev/null 2>&1 || true
RC2="$(start 2)"
ck "A4 the second --start exited 0 (got $RC2)" '[ "$RC2" = 0 ]'
[ "$RC2" = 0 ] || tail -30 "$WS.start.2.log"
A2="$(job 'Accept Alpha')"; B2="$(job 'Accept Beta')"
echo "  alpha: $A2"; echo "  beta:  $B2"
ck "A4 alpha is back under the SAME session id ($AID), live" '[ "$A2" = "$AID live" ]'
ck "A4 beta is back under the SAME session id ($BID), live" '[ "$B2" = "$BID live" ]'
for _ in $(seq 1 30); do
    grep -q "alpha-resumed" "$SB/claude/projects/"*"/$AID.jsonl" 2>/dev/null && break
    sleep 3
done
ck "A4 the On resume text reached alpha's ORIGINAL transcript" 'grep -q "alpha-resumed" "$SB/claude/projects/"*"/$AID.jsonl"'
ck "A4 no second transcript carries either name (no copy was made)" '[ "$(grep -l -e "\"customTitle\":\"Accept Alpha\"" -e "\"customTitle\":\"Accept Beta\"" "$SB/claude/projects/"*/*.jsonl | grep -c .)" = 2 ]'

say "A5: an unknown session: id -> exit 9, container left running"
"$SANDY" --stop --workspace "$WS" > /dev/null 2>&1 || true
cat > "$WS/.sandy/sessions/gamma.md" <<'EOF'
---
name: Accept Gamma
session: 00000000-0000-4000-8000-000000000000
---
EOF
RC3="$(start 3)"
ck "A5 --start exited 9 (got $RC3)" '[ "$RC3" = 9 ]'
ck "A5 ...naming gamma and why" 'grep -q "Accept Gamma.*not up: missing" "$WS.start.3.log"'
ck "A5 the container is still running" '[ -n "$(docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS")" ]'
ck "A5 --print-state reports gamma missing and alpha/beta up" '"$SANDY" --print-state 2>/dev/null | grep -q "\"slug\":\"gamma\",\"state\":\"missing\""'

echo ""
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
