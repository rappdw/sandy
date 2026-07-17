#!/usr/bin/env bash
# End-to-end daemon-mode acceptance (#17) — the sandy-ui target scenario.
#
# ⚠️ RUN ON A HOST WITH DOCKER. This cannot run inside sandy (no Docker). It is
# the release-readiness gate for the 1.1.0 daemon-mode feature: the unit/verify
# passes cover structure/contract, but ONLY this proves the container actually
# survives client death, helpers reparent, and --stop fully tears down.
#
#   Usage:  bash test/acceptance-daemon.sh          # uses ./sandy
#           SANDY=/path/to/sandy bash test/acceptance-daemon.sh
#
# Exercises: --start → session up + attachable + supervisor alive → --print-state
# reports it (daemon:true, join key, attached_clients) → record state markers
# (agent pane PID + a tmux server buffer) → attach in a real PTY and kill -9 it
# abruptly (VSCode-crash sim) → container/supervisor/tmux SURVIVE and the agent
# process PID + buffer are UNCHANGED (in-memory state preserved by construction)
# → idempotent second --start → --stop → container, supervisor, networks,
# lock ALL gone. Prints PASS/FAIL per assertion; exits non-zero if any FAIL.
set -uo pipefail

SANDY="${SANDY:-./sandy}"
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"
WS="$(mktemp -d)/daemon-accept-$$"
mkdir -p "$WS" && (cd "$WS" && git init -q)
# Canonicalize exactly like sandy does (pwd -P): on macOS mktemp returns
# /var/folders/... but /var is a symlink to /private/var, and sandy's
# sandy.workspace_path label holds the canonical form — an uncanonicalized
# $WS makes every cid() label-filter miss and fails the whole harness
# vacuously while the session itself is healthy.
WS="$(cd "$WS" && pwd -P)"
PASS=0; FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1));
       else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
cid() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS" 2>/dev/null | head -1; }
cleanup_ws() { "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true; rm -rf "$(dirname "$WS")"; }
trap cleanup_ws EXIT

command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the host"; exit 2; }
MARK="SANDY_ACCEPT_MARKER_$$"

echo "== 1. sandy --start =="
"$SANDY" --start --workspace "$WS"; RC=$?
ck "--start exits 0" "[ $RC -eq 0 ]"
C="$(cid)"
ck "daemon container is running" "[ -n \"$C\" ]"
ck "inner tmux session exists" "docker exec -u \"$(id -u)\" \"$C\" tmux has-session -t sandy"
DPID="$(docker inspect -f '{{index .Config.Labels "sandy.daemon_pid"}}' "$C" 2>/dev/null)"
SESS="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C" 2>/dev/null)"
ck "supervisor process is alive (pid $DPID)" "[ -n \"$DPID\" ] && kill -0 \"$DPID\""
LOCK="$SANDY_HOME_DIR/sandboxes/.$SESS.lock"
ck "workspace lock is held" "[ -d \"$LOCK\" ]"

echo "== 2. --print-state reports the daemon session =="
"$SANDY" --print-state | python3 -c "
import json,sys
d=json.load(sys.stdin)
rc=[c for c in (d.get('running_containers') or []) if c.get('sandbox')=='$SESS']
assert rc, 'session not in running_containers'
c=rc[0]
assert c['daemon'] is True, ('daemon', c.get('daemon'))
assert isinstance(c.get('attached_clients'), (int,type(None))), c.get('attached_clients')
" && ck "print-state: daemon:true + join + attached_clients" "true" || ck "print-state: daemon:true + join + attached_clients" "false"

echo "== 3. record state markers (agent pane PID + tmux server buffer) =="
# Deliberately NO TUI interaction: the agent's first-run modals swallow typed
# text (and an earlier probe's Enter accidentally ANSWERED an onboarding
# dialog) — any screen-scrape couples the harness to the agent version's
# onboarding state machine. Assert state preservation directly instead:
#  - pane PID: if step 5 sees the SAME pid, the agent process never
#    restarted, so all its in-memory state (conversation, half-typed
#    composer, whatever was on screen) survived by construction — strictly
#    stronger than any screen grep;
#  - a tmux paste buffer: server-side state proving the tmux SERVER itself
#    wasn't respawned across the client kill.
PID3="$(docker exec -u "$(id -u)" "$C" tmux display -p -t sandy '#{pane_pid}' 2>/dev/null)" || PID3=""
docker exec -u "$(id -u)" "$C" tmux set-buffer -b sandy_accept "$MARK" 2>&1 | sed 's/^/  set-buffer: /'
ck "agent pane has a live process (pid ${PID3:-?})" "[ -n \"$PID3\" ]"
ck "agent TUI is rendering (pane has content)" "docker exec -u \"$(id -u)\" \"$C\" tmux capture-pane -p -t sandy | grep -q ."

echo "== 4. attach in a real PTY, then kill -9 the client (VSCode-crash sim) =="
python3 -c "import pty,sys; pty.spawn(['$SANDY','--attach','--workspace','$WS'])" >/dev/null 2>&1 &
APID=$!
sleep 4
kill -9 "$APID" 2>/dev/null || true
pkill -9 -P "$APID" 2>/dev/null || true
sleep 2
ck "container SURVIVES the abrupt client kill" "[ -n \"$(cid)\" ]"
ck "supervisor SURVIVES the client kill" "kill -0 \"$DPID\""
ck "inner tmux session survives" "docker exec -u \"$(id -u)\" \"$C\" tmux has-session -t sandy"

echo "== 5. re-attach: prior state intact =="
PID5="$(docker exec -u "$(id -u)" "$C" tmux display -p -t sandy '#{pane_pid}' 2>/dev/null)" || PID5=""
ck "agent process UNCHANGED across client kill (pid ${PID3:-?} -> ${PID5:-?})" "[ -n \"$PID3\" ] && [ \"$PID3\" = \"$PID5\" ]"
BUF5="$(docker exec -u "$(id -u)" "$C" tmux show-buffer -b sandy_accept 2>/dev/null)" || BUF5=""
ck "tmux server-side buffer marker survived" "[ \"\$BUF5\" = \"$MARK\" ]"
if [ "$BUF5" != "$MARK" ] || [ "$PID3" != "$PID5" ]; then
    echo "  --- diag: pid3='$PID3' pid5='$PID5' buf5='$BUF5' ---"
fi

echo "== 6. idempotent second --start =="
"$SANDY" --start --workspace "$WS"; ck "second --start is a no-op, exit 0" "[ $? -eq 0 ]"
ck "still exactly one daemon container" "[ \$(docker ps -q --filter label=sandy.daemon=true --filter label=sandy.workspace_path=$WS | wc -l | tr -d ' ') -eq 1 ]"

echo "== 6.5 zombie recovery: --start reaps a session-less container, restarts fresh =="
# Reproduce the observed failure: the agent exits but the container stays up
# (supervisor missed it, or a restart raced the #47 teardown window) → a zombie
# (container alive, inner session dead). A restart must NOT read it as "already
# running" and block — it must probe the session, find it dead, reap the
# container, and start a fresh one.
Z="$(cid)"
docker exec -u "$(id -u)" "$Z" tmux kill-server >/dev/null 2>&1 || true
sleep 1
ck "zombie: container still up but session gone" \
   "[ -n \"$Z\" ] && [ \"\$(cid)\" = \"$Z\" ] && ! docker exec -u \"$(id -u)\" \"$Z\" tmux has-session -t sandy 2>/dev/null"
"$SANDY" --start --workspace "$WS"; RCZ=$?
ck "--start over a zombie exits 0 (recovered, not blocked)" "[ $RCZ -eq 0 ]"
Z2="$(cid)"
ck "a FRESH container replaced the zombie (different id)" "[ -n \"$Z2\" ] && [ \"$Z2\" != \"$Z\" ]"
ck "the fresh session is live" "docker exec -u \"$(id -u)\" \"$Z2\" tmux has-session -t sandy"
# Re-point the teardown markers at the fresh session so §7 stops the NEW one.
C="$Z2"
DPID="$(docker inspect -f '{{index .Config.Labels "sandy.daemon_pid"}}' "$C" 2>/dev/null)"
SESS="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C" 2>/dev/null)"
LOCK="$SANDY_HOME_DIR/sandboxes/.$SESS.lock"

echo "== 7. sandy --stop — full teardown =="
"$SANDY" --stop --workspace "$WS"; ck "--stop exits 0" "[ $? -eq 0 ]"
sleep 2
ck "container is GONE" "[ -z \"$(cid)\" ]"
ck "supervisor is GONE" "! kill -0 \"$DPID\" 2>/dev/null"
ck "no leftover sandy networks for this supervisor" "[ -z \"\$(docker network ls --format '{{.Name}}' | grep -E 'sandy_(net|sidecar|egress)_$DPID\$')\" ]"
ck "workspace lock is released" "[ ! -d \"$LOCK\" ]"
ck "--stop again → no-such-session exit 4" "\"$SANDY\" --stop --workspace \"$WS\"; [ \$? -eq 4 ]"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
