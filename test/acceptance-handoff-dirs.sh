#!/usr/bin/env bash
# End-to-end handoff directories + relay acceptance (#132 slice 1, plus
# SANDY_HANDOFF_RELAY 1.10.0).
#
# ⚠️ RUN ON A HOST WITH DOCKER. This cannot run inside sandy (no Docker). It
# proves the real container-level behavior that the static run-tests.sh §86
# and §114 checks cannot: the actual bind-mount mode (relay rw) and the
# :ro), that EROFS wins even for files the container-uid already owns, that
# the whole handoff directories feature is a true zero-diff when the key is
# unset, and (phase E, 1.10.0) that the relay supervisor described in
# CLAUDE.md "Handoff relay" actually behaves that way against a real
# container: starts with it, restarts a killed relay, never runs twice, and
# survives an --update-sessions recreation.
#
# Phases A-D ship directory/mount substrate only — no skills, no turn
# initiation, no manifest, no archive/ (its mode is unsettled in #132). Since
# 2.2.0 the tree is ONE DIRECTORY: relay rw. inbox, outbox and peer were
# and SANDY_HANDOFF_DIRS=0 is the opt-out. Phase E covers the ONE mechanism that does move bytes today: the
# relay process itself, plus the crossSessionInbound pin that gates whether
# a peer message it forwards is delivered, held, or refused. Phase E does
# NOT drive an actual UDS handoff message end-to-end (that is Claude Code's
# own live gate, covered by the live probe recorded in
# docs/security/CROSS_SESSION_INBOUND.md, not by this harness) — it proves
# sandy's OWN mechanics: the supervisor lifecycle and the settings writes.
#
#   Usage:  bash test/acceptance-handoff-dirs.sh          # uses ./sandy
#           SANDY=/path/to/sandy bash test/acceptance-handoff-dirs.sh
#
# Phases:
#   A. Default — NO config anywhere: all four mounts present with the right
#      RW flag (relay true) and that the three removed lanes are absent — the
#      exact check a consumer runs.
#   A2. Opt-out/zero-diff — SANDY_HANDOFF_DIRS=0 via the WORKSPACE's
#      .sandy/config: no "handoff" anywhere in `docker inspect` (Mounts + Env
#      in one grep), the host handoff/ dirs still exist (inert), no
#      in-container ~/.handoff path.
#   B. Explicit on — key =1 via the WORKSPACE's .sandy/config (proves the
#      passive tier end-to-end: no approval prompt, works under the
#      non-interactive --start supervisor): host dirs exist, mount RW flags
#   B, C. REMOVED in 2.2.0 with the lanes they tested (#352); see the note
#      resists chmod from inside the container despite being agent-uid-owned
#      (EROFS beats ownership — the entire point of the :ro mount flag).
#      where they used to be.
#   D. The MARKER (.handoff-enabled) OVERRIDES an opt-out: with
#      SANDY_HANDOFF_DIRS=0 in the isolated HOST config and no workspace
#      config anywhere, pre-marker the tree is off; post-marker it is on,
#      repeating the EROFS-beats-ownership assertions on THAT path — phase B
#      only proves them for the SANDY_HANDOFF_DIRS=1 path.
#   E. SANDY_HANDOFF_RELAY (1.10.0, privileged, set via the isolated host's
#      OWN ~/.sandy/config so no approval prompt applies): the relay mount +
#      env forwarding, the supervisor actually running as a sibling of tmux
#      (not a pane, not a session child), singleton-via-flock, restart on
#      death with a fresh pid, survival of an --update-sessions recreation
#      (state persists), sandy-handoff-sessions producing a real socket path,
#      the crossSessionInbound pin landing in both measured-working files and
#      the workspace copy being genuinely :ro, and that headless (-p) runs
#      never start a relay.
#
# Prints PASS/FAIL per assertion; exits non-zero if any FAIL.
set -uo pipefail

SANDY="${SANDY:-./sandy}"
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"
# Deliberately NOT named "handoff": the phase-A zero-diff assertion greps the
# entire `docker inspect` blob, and the workspace name reaches the container
# name, the mount source, the sandy.workspace_path label and SANDY_WORKSPACE —
# so a "handoff" in the workspace name would make that assertion unpassable.
WS="$(mktemp -d)/mbx-accept-$$"
mkdir -p "$WS" && (cd "$WS" && git init -q)
# Canonicalize exactly like sandy does (pwd -P) — see acceptance-daemon.sh for
# why: sandy.workspace_path labels hold the canonical form, so an
# uncanonicalized $WS makes every cid() label-filter miss.
WS="$(cd "$WS" && pwd -P)"
PASS=0; FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1));
       else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
cid() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS" 2>/dev/null | head -1; }
# Phase D uses a SECOND workspace, because its whole point is that no workspace
# .sandy/config exists anywhere — reusing $WS would leave phase B config behind
# and the marker could not be shown to be what overrode the opt-out.
WS2="$(mktemp -d)/mbx-marker-$$"
mkdir -p "$WS2" && (cd "$WS2" && git init -q)
WS2="$(cd "$WS2" && pwd -P)"
# Phase E's workspace. Declared (empty) here, alongside WS/WS2, so cleanup_ws
# can reference it under `set -u` no matter how early the script exits —
# guarded on non-empty below since phase E assigns it much later in the file.
WS3=""
cleanup_ws() {
    "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true
    "$SANDY" --stop --workspace "$WS2" >/dev/null 2>&1 || true
    [ -n "$WS3" ] && { "$SANDY" --stop --workspace "$WS3" >/dev/null 2>&1 || true; rm -rf "$(dirname "$WS3")"; }
    rm -rf "$(dirname "$WS")" "$(dirname "$WS2")"
    _cleanup_sandy_home || true
}
# Redirect $SANDY_HOME at a throwaway dir BEFORE anything launches, so the
# fixture sandboxes this harness creates never land in the developer's real
# state (where they are indistinguishable from real sandboxes to every
# --print-state consumer). Override by exporting SANDY_TEST_NO_ISOLATE=1.
. "$(dirname "$0")/lib-isolated-home.sh"
[ "${SANDY_TEST_NO_ISOLATE:-0}" = "1" ] || _isolate_sandy_home
# Re-derive AFTER the switch. This harness resolves SANDY_HOME_DIR near the top
# of the file, which runs before isolation -- left stale it would point at the
# real home while sandy created sandboxes in the isolated one, so every
# assertion about sandbox contents would look for a directory that is not there.
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"

trap cleanup_ws EXIT
cid2() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS2" 2>/dev/null | head -1; }

command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the host"; exit 2; }

# Slice ONE sandbox object out of a `--print-state` document.
#
# NEVER anchor a JSON assertion on a field NEIGHBOURS. `"name":"X"[^}]*"relay":{`
# reads naturally and is a tripwire: the character class cannot cross the `}` of
# a nested object, so it fails against an emitter that is entirely correct the
# day one lands in between. That is exactly what happened here -- `handoff{}`
# was added between `name` and `relay` in 1.12.0, and this harness then reported
# `relay.state=started` FAILING while --print-state was emitting precisely that.
# Third time this pattern has cost a round; run-tests.sh §123 and §124(8) were
# the first two, and run-tests.sh now ratchets against it.
#
# index/substr only -- no regex, so there is no BRE-vs-ERE or brace-metachar
# question, and it is BWK-awk safe (no multi-character RS). Selection is exact
# because the trailing quote is part of the key, so the sandbox `mbx-x` is not
# matched by the container `sandy-mbx-x`.
_ps_obj() {   # _ps_obj <print-state-output-with-whitespace-stripped> <sandbox-name>
    # One line: see the note in run-tests.sh _s124_obj -- a multi-line
    # single-quoted program argument desynchronizes the portability lint.
    printf '%s' "$1" | awk -v key="\"name\":\"$2\"" '{ p = index($0, key); if (p == 0) exit 0; rest = substr($0, p); q = index(substr(rest, 2), "{\"name\":\""); if (q > 0) rest = substr(rest, 1, q); print rest }'
}

echo "== A. default (no config anywhere): the whole tree is mounted =="
ck "phase A workspace has NO .sandy/config (the premise)" "[ ! -e \"$WS/.sandy/config\" ]"
ck "isolated host config does not mention SANDY_HANDOFF_DIRS (the premise)" \
   "! grep -qs SANDY_HANDOFF_DIRS \"$SANDY_HOME_DIR/config\""
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS"; RC=$?
ck "--start exits 0" "[ $RC -eq 0 ]"
# ABORT HERE if the very first launch failed (#261). Everything after this point
# inspects a container that does not exist, so it produces ~40 assertion
# failures about mount flags and --stop exit codes whose real cause is this one
# line, hundreds of lines above. That is exactly what happened when an expired
# OAuth token hung the supervisor: the run reported a mount assertion failing
# for a container that was never created, and the diagnosis cost a full pass.
#
# Worse, a --start that dies holding the workspace lock poisons every LATER
# phase too ("Another sandy is already running"), so continuing does not even
# test the later phases -- it just manufactures noise.
if [ "$RC" -ne 0 ]; then
    echo ""
    echo "==================================================="
    echo "ABORTING: the first --start failed (exit $RC)."
    echo ""
    echo "Every later assertion in this harness inspects a container that does"
    echo "not exist, and a --start that died holding the workspace lock will"
    echo "fail the remaining phases for an unrelated reason. Fix this first."
    echo ""
    echo "Most common causes:"
    echo "  - the host OAuth token expired  -> run 'claude auth login' on the host"
    echo "  - a stale workspace lock        -> sandy --doctor --fix"
    echo "  - Docker not reachable         -> docker ps"
    echo "==================================================="
    printf 'RESULT: %d passed, %d failed (aborted early)\n' "$PASS" "$FAIL"
    exit 1
fi
C="$(cid)"
ck "daemon container is running" "[ -n \"$C\" ]"
SESS="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS\" ]"
_m0="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C" 2>/dev/null)"
echo "  mounts:"; printf '%s\n' "$_m0" | grep -i handoff | sed 's/^/    /'
# This is the exact mount table a consumer verifies against -- four rows, no
# more: relay rw, and nothing else under ~/.handoff/.
ck "default: relay mount is RW=true (the only lane left since 2.2.0, #352)" \
   "printf '%s\n' \"\$_m0\" | grep -qE '^/home/sandy/.handoff/relay true\$'"
ck "default: relay mount is RW=true" \
   "printf '%s\n' \"\$_m0\" | grep -qE '^/home/sandy/.handoff/relay true\$'"
ck "default: exactly ONE ~/.handoff/* mount (relay; the three lanes were removed in 2.2.0, #352)" \
   "[ \"\$(printf '%s\n' \"\$_m0\" | grep -c '^/home/sandy/.handoff/')\" = 4 ]"
# The in-container half of the consumer check.
ck "default: in-container ~/.handoff/relay exists, and the three removed lanes do NOT (#352)" \
   "docker exec $C sh -c '[ -d ~/.handoff/relay ] && [ ! -e ~/.handoff/inbox ] && [ ! -e ~/.handoff/outbox ] && [ ! -e ~/.handoff/peer ]'"
   "! docker inspect -f '{{range .Config.Env}}{{.}}{{\"\n\"}}{{end}}' \"$C\" | grep -q '^SANDY_HANDOFF_RELAY='"
"$SANDY" --stop --workspace "$WS"; ck "--stop (phase A) exits 0" "[ $? -eq 0 ]"
# Idempotence: a second launch of the same sandbox must produce the same table
# (mkdir -p + the same -v lines), not fail on directories that now exist.
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS"; RC=$?
ck "default: a SECOND launch exits 0 (idempotent)" "[ $RC -eq 0 ]"
C="$(cid)"
ck "default: second launch has the same single ~/.handoff/* mount" \
   "[ \"\$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{\"\n\"}}{{end}}' \"$C\" | grep -c '^/home/sandy/.handoff/')\" = 4 ]"
"$SANDY" --stop --workspace "$WS"; ck "--stop (phase A, second) exits 0" "[ $? -eq 0 ]"

echo "== A2. opt-out (SANDY_HANDOFF_DIRS=0 via workspace .sandy/config): dirs exist, nothing is mounted =="
# The opt-out from a WORKSPACE source: it tightens, so the passive tier must
# take it with no prompt (env -u below keeps that claim honest, see phase B).
mkdir -p "$WS/.sandy"
echo "SANDY_HANDOFF_DIRS=0" > "$WS/.sandy/config"
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS"; RC=$?
ck "--start exits 0 under the opt-out" "[ $RC -eq 0 ]"
C="$(cid)"
ck "daemon container is running" "[ -n \"$C\" ]"
ck "docker inspect has NO mention of handoff anywhere (mounts, env, labels)" \
   "! docker inspect \"$C\" | grep -qi handoff"
# The host directories are created on EVERY launch (only the MOUNT is gated),
# so their presence proves nothing and is not asserted either way. What must
# hold under the opt-out is that nothing reaches the CONTAINER -- which the
# docker-inspect assertion above and the in-container check below cover.
ck "sandbox handoff/ dirs exist but are INERT (created always; presence means nothing)" \
   "[ -d \"$SANDY_HOME_DIR/sandboxes/$SESS/handoff/relay\" ]"
ck "in-container ~/.handoff does NOT exist" \
   "! docker exec -u \"\$(id -u)\" \"$C\" test -e /home/sandy/.handoff"
"$SANDY" --stop --workspace "$WS"; ck "--stop (phase A2) exits 0" "[ $? -eq 0 ]"

# Phases B and C were REMOVED in 2.2.0 (#352) along with the lanes they tested.
#
# B proved that inbox and peer really do return EROFS on a chmod, not merely
# that sandy writes ":ro" into the mount line -- the distinction §97(10) cannot
# make from the script text alone. C proved outbox content survived a
# stop/start. Both lanes are gone: a feature manifest names its own directories
# via `mounts`, and the fleet was measured empty before removal.
#
# The EROFS proof itself is NOT lost, and must not be. It moved to whatever
# exercises a manifest mount declared `mode: ro`, which is where a read-only
# guarantee now lives. If that coverage does not exist, this deletion traded a
# real runtime assertion for nothing -- which is the one way it could be wrong.

echo "== D. the MARKER overrides an opt-out, with no workspace config anywhere =="
# Closes acceptance criterion 4 for the MARKER path specifically. Phase B proves
# EROFS-beats-ownership when the tree is on by SANDY_HANDOFF_DIRS=1; that is
# NOT the same evidence. The marker resolves into the same variable before the
# gate, so both paths reach identical mount code — but "identical by
# construction" is an argument, not a test result, and criterion 4 exists
# precisely to reject that kind of reasoning.
#
# Since 1.10.0 the tree is on by default, so the marker is only observable
# against an opt-out. The opt-out here is HOST-level (the isolated
# $SANDY_HOME/config) with no workspace config at all -- the "off everywhere,
# on for these" fleet shape. The marker lives at the TOP level of the sandbox
# dir, whose slug is not known until a launch creates it. So: launch once
# (proving the host opt-out holds with no marker), stop, touch the marker,
# relaunch. That is exactly the order a provisioner works in.

ck "phase D workspace has NO .sandy/config (the premise)" "[ ! -e \"$WS2/.sandy/config\" ]"
echo "SANDY_HANDOFF_DIRS=0" >> "$SANDY_HOME_DIR/config"
ck "host-level opt-out is in place (the premise)" "grep -qx SANDY_HANDOFF_DIRS=0 \"$SANDY_HOME_DIR/config\""

env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS2"; RC=$?
ck "--start (D, pre-enrolment) exits 0" "[ $RC -eq 0 ]"
C2="$(cid2)"
ck "daemon container is running" "[ -n \"$C2\" ]"
SESS2="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C2" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS2\" ]"
# Marker absent + host opt-out => the tree must be OFF. Without this the phase
# could pass on a sandbox that had the tree for some unrelated reason (the
# default, for one).
ck "NEGATIVE: no marker + host opt-out => in-container ~/.handoff does NOT exist" \
   "! docker exec -u \"\$(id -u)\" \"$C2\" test -e /home/sandy/.handoff"

"$SANDY" --stop --workspace "$WS2" >/dev/null 2>&1
SBX2="$SANDY_HOME_DIR/sandboxes/$SESS2"
touch "$SBX2/.handoff-enabled"
ck "marker created at the sandbox top level" "[ -f \"$SBX2/.handoff-enabled\" ]"
ck "marker is EMPTY (contents are ignored; touch is how a provisioner makes it)" \
   "[ ! -s \"$SBX2/.handoff-enabled\" ]"

env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS2"; RC=$?
ck "--start (D, enrolled by marker) exits 0" "[ $RC -eq 0 ]"
C2="$(cid2)"
ck "daemon container is running after enrolment" "[ -n \"$C2\" ]"
ck "still NO workspace .sandy/config — the marker alone overrode the host opt-out" "[ ! -e \"$WS2/.sandy/config\" ]"
ck "the host opt-out is STILL in place (the marker won over it, it did not remove it)" "grep -qx SANDY_HANDOFF_DIRS=0 \"$SANDY_HOME_DIR/config\""

_m2="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C2" 2>/dev/null)"
echo "  mounts:"; printf '%s\n' "$_m2" | grep -i handoff | sed 's/^/    /'
ck "relay mount is RW=true (marker path) — the one lane left since 2.2.0, #352" \
   "printf '%s\n' \"\$_m2\" | grep -qE '^/home/sandy/.handoff/relay true\$'"
ck "the three removed lanes are NOT mounted on the marker path either" \
   "! printf '%s\n' \"\$_m2\" | grep -qE '^/home/sandy/.handoff/(inbox|outbox|peer) '"
ck "write to relay SUCCEEDS (marker path) — the supervisor writes .state and supervisor.log here" \
   "docker exec -u \"\$(id -u)\" \"$C2\" sh -c 'echo hi > /home/sandy/.handoff/relay/probe.txt'"

# --- criterion 5: the agent has no path to the marker ---
# Not "we did not mount it" as a claim, but: no mount SOURCE is the sandbox top
# level, so nothing inside the container resolves to the marker file.
ck "NEGATIVE: no bind mount sources the sandbox top level (agent cannot self-enrol)" \
   "! docker inspect -f '{{range .Mounts}}{{.Source}}{{\"\n\"}}{{end}}' \"$C2\" 2>/dev/null | grep -qx \"$SBX2\""
ck "NEGATIVE: the marker is not visible anywhere inside the container" \
   "! docker exec -u \"\$(id -u)\" \"$C2\" sh -c 'test -e /home/sandy/.handoff-enabled -o -e /home/sandy/.claude/.handoff-enabled' 2>/dev/null"

# --- introspection agrees with reality ---
ck "--print-state reports handoff_enabled=true for the enrolled sandbox" \
   "\"$SANDY\" --print-state light 2>/dev/null | grep -q '\"handoff_enabled\":true'"

"$SANDY" --stop --workspace "$WS2"; ck "--stop (D, final) exits 0" "[ $? -eq 0 ]"
# Remove the host-level opt-out so phase E runs against the default. Portable
# rewrite (no sed -i: BSD sed needs a suffix argument, GNU does not).
grep -vx 'SANDY_HANDOFF_DIRS=0' "$SANDY_HOME_DIR/config" > "$SANDY_HOME_DIR/config.tmp" || true
mv "$SANDY_HOME_DIR/config.tmp" "$SANDY_HOME_DIR/config"
ck "host-level opt-out removed before phase E" "! grep -qs SANDY_HANDOFF_DIRS \"$SANDY_HOME_DIR/config\""

echo "== E. handoff relay (SANDY_HANDOFF_RELAY, 1.10.0) =="
# Fresh workspace: relay fixtures shouldn't share state with A-D.
WS3="$(mktemp -d)/mbx-relay-$$"
mkdir -p "$WS3/.sandy" && (cd "$WS3" && git init -q)
WS3="$(cd "$WS3" && pwd -P)"
cid3() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS3" 2>/dev/null | head -1; }

cat > "$WS3/.sandy/relay.sh" <<'RELAYFIX'
#!/bin/sh
# Fixture relay for phase E: records its own pid + the env contract on each
# (re)start, then blocks. Deliberately NOT `exec sleep` -- pgrep -f below
# matches on this script's own path, and `exec` would replace this process's
# argv with "sleep 3600", losing that match the instant it ran.
echo "$$ $SANDY_HANDOFF_INBOX $SANDY_HANDOFF_OUTBOX $SANDY_HANDOFF_RELAY_STATE" >> "$SANDY_HANDOFF_RELAY_STATE/seen"
sleep 3600
RELAYFIX
chmod +x "$WS3/.sandy/relay.sh"

# SANDY_HANDOFF_RELAY is PRIVILEGED tier. Setting it via the isolated HOST's
# own ~/.sandy/config (a privileged SOURCE) needs no approval prompt at all --
# unlike phases B/D above (which prove the PASSIVE tier from a WORKSPACE
# source), a privileged source may set a privileged key freely. `env -u
# SANDY_AUTO_APPROVE_PRIVILEGED` is kept anyway, for the same "prove it, don't
# assume it" discipline as the rest of this file: this phase must pass
# without that escape hatch, because it isn't the thing being exercised here.
echo "SANDY_HANDOFF_RELAY=.sandy/relay.sh" >> "$SANDY_HOME_DIR/config"

env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS3"; RC=$?
ck "--start exits 0 with the relay configured" "[ $RC -eq 0 ]"
C3="$(cid3)"
ck "daemon container is running" "[ -n \"$C3\" ]"
SESS3="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C3" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS3\" ]"
SBX3="$SANDY_HOME_DIR/sandboxes/$SESS3"

echo "-- E1. mount + env forwarding --"
_m3="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C3" 2>/dev/null)"
echo "  mounts:"; printf '%s\n' "$_m3" | grep -i handoff | sed 's/^/    /'
ck "relay mount is RW=true" \
   "printf '%s\n' \"\$_m3\" | grep -qE '^/home/sandy/.handoff/relay true\$'"
ck "no removed lane is mounted alongside the relay (#352)" \
   "! printf '%s\n' \"\$_m3\" | grep -qE '^/home/sandy/.handoff/(inbox|outbox|peer) '"
# Never dump the whole env -- it carries CLAUDE_CODE_OAUTH_TOKEN and friends.
# Count occurrences of the one var under test instead of printing anything.
_envcount="$(docker inspect -f '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$C3" 2>/dev/null | grep -c '^SANDY_HANDOFF_RELAY=\.sandy/relay\.sh$')"
ck "SANDY_HANDOFF_RELAY forwarded into the container exactly once" "[ \"$_envcount\" = 1 ]"

echo "-- E2. relay is running, as a sibling of tmux (not a pane, not a session child) --"
# The subshell that runs _sandy_start_handoff_relay's loop is backgrounded
# (&) before tmux new-session runs, so --start's own readiness gate (which
# only waits on the inner tmux session) can return before the relay has
# actually flock'd and written its first log line. Poll rather than assert
# immediately.
_pid1=""
for _i in 1 2 3 4 5 6; do
    _pid1="$(docker exec -u "$(id -u)" "$C3" pgrep -f '\.sandy/relay\.sh' 2>/dev/null | head -1)"
    [ -n "$_pid1" ] && break
    sleep 1
done
ck "relay process is running in the container" "[ -n \"$_pid1\" ]"
ck "exactly one relay process" \
   "[ \"\$(docker exec -u \"\$(id -u)\" \"$C3\" pgrep -c -f '\.sandy/relay\.sh' 2>/dev/null)\" = 1 ]"
# Two /proc/<pid>/status hops: relay's parent is the supervisor loop shell;
# the loop shell's parent must be PID 1 (tail -f /dev/null in daemon mode,
# which the loop was backgrounded under BEFORE PID 1 exec'd into tail --
# exec preserves the pid, so children reparent to nothing across it).
_ppid1="$(docker exec -u "$(id -u)" "$C3" sh -c "awk '/^PPid:/{print \$2}' /proc/$_pid1/status" 2>/dev/null)"
ck "relay's immediate parent resolved (the supervisor loop shell)" "[ -n \"$_ppid1\" ]"
_ppid2="$(docker exec -u "$(id -u)" "$C3" sh -c "awk '/^PPid:/{print \$2}' /proc/$_ppid1/status" 2>/dev/null)"
ck "the supervisor loop's parent is PID 1 -- sibling of tmux, not a pane, not a session child" \
   "[ \"$_ppid2\" = 1 ]"

echo "-- E3. restart on death --"
_pid_before="$_pid1"
docker exec -u "$(id -u)" "$C3" kill "$_pid_before" >/dev/null 2>&1
_pid_after=""
for _i in 1 2 3 4 5 6 7 8; do
    sleep 1
    _pid_after="$(docker exec -u "$(id -u)" "$C3" pgrep -f '\.sandy/relay\.sh' 2>/dev/null | head -1)"
    [ -n "$_pid_after" ] && [ "$_pid_after" != "$_pid_before" ] && break
done
ck "relay came back with a NEW pid after being killed" \
   "[ -n \"$_pid_after\" ] && [ \"$_pid_after\" != \"$_pid_before\" ]"
_exits="$(docker exec -u "$(id -u)" "$C3" grep -c 'exit rc=' /home/sandy/.handoff/relay/supervisor.log 2>/dev/null || echo 0)"
ck "supervisor.log recorded the exit" "[ \"${_exits:-0}\" -ge 1 ]"
# The log line is "[sandy-relay] <ISO ts> start <path>", so the timestamp sits
# between the bracket and the word -- the old '\] start ' pattern required them
# adjacent and therefore never matched, making this check fail even on a
# perfectly working restart (which E3s own new-pid assertion had just proved).
_starts="$(docker exec -u "$(id -u)" "$C3" grep -c ' start /' /home/sandy/.handoff/relay/supervisor.log 2>/dev/null || echo 0)"
ck "supervisor.log shows at least 2 starts (initial + restart)" "[ \"${_starts:-0}\" -ge 2 ]"

echo "-- E4. never started twice --"
ck "the supervisor lock is HELD (a second flock -n attempt fails)" \
   "! docker exec -u \"\$(id -u)\" \"$C3\" flock -n /home/sandy/.sandy-handoff-relay.lock true"
ck "still exactly one relay process (no second supervisor was spawned)" \
   "[ \"\$(docker exec -u \"\$(id -u)\" \"$C3\" pgrep -c -f '\.sandy/relay\.sh' 2>/dev/null)\" = 1 ]"

echo "-- E5. sandy-handoff-sessions --"
_hs=""
for _i in 1 2 3 4 5 6; do
    _hs="$(docker exec -u "$(id -u)" "$C3" sandy-handoff-sessions 2>/dev/null)"
    printf '%s\n' "$_hs" | awk -F'\t' '$1=="claude"{f=1} END{exit !f}' && break
    sleep 5
done
ck "sandy-handoff-sessions lists a claude row" \
   "printf '%s\n' \"\$_hs\" | awk -F'\t' '\$1==\"claude\"{f=1} END{exit !f}'"
_sock="$(printf '%s\n' "$_hs" | awk -F'\t' '$1=="claude"{print $5; exit}')"
ck "the listed socket path is a real socket in the container" \
   "[ -n \"$_sock\" ] && [ \"$_sock\" != \"-\" ] && docker exec -u \"\$(id -u)\" \"$C3\" test -S \"$_sock\""

echo "-- E6. crossSessionInbound pin lands in both measured-working files --"
_marker="$(docker exec -u "$(id -u)" "$C3" cat /etc/sandy-session.json 2>/dev/null)"
ck "session marker reports handoff_relay=true" \
   "printf '%s' \"\$_marker\" | grep -q '\"handoff_relay\": true'"
ck "session marker reports cross_session_inbound=\"accept\" (default: relay configured)" \
   "printf '%s' \"\$_marker\" | grep -q '\"cross_session_inbound\": \"accept\"'"
ck "userSettings (sandbox claude/settings.json, RW) carries the accept pin" \
   "grep -q '\"crossSessionInbound\": *\"accept\"' \"$SBX3/claude/settings.json\""
ck "workspace .claude/settings.local.json ALSO carries the pin (harmless no-op there, clears staleness)" \
   "grep -q '\"crossSessionInbound\": *\"accept\"' \"$WS3/.claude/settings.local.json\""
# WS3 is under /tmp, outside $HOME, so sandy's workspace-mount fallback mounts
# it at its own real host path verbatim -- the container path equals $WS3.
ck "the workspace settings.local.json is genuinely :ro in-container" \
   "! docker exec -u \"\$(id -u)\" \"$C3\" sh -c 'echo x >> \"$WS3/.claude/settings.local.json\"' 2>/dev/null"

echo "-- E7. survives container recreation --"
# WHY THIS IS NOT `--update-sessions` ALONE: that command only restarts
# sessions whose running image id differs from the current image id. In an
# isolated $SANDY_HOME with a freshly built image nothing is stale, so it
# correctly does nothing and exits 0 -- and the old "container id changed"
# assertion, which assumed a restart always happens, failed on a perfectly
# healthy fleet. Worse, its two follow-on checks then passed VACUOUSLY against
# the very same container: "relay is running again" was just the original relay
# never having died, and the seen-file count was still E3s kill/restart pair.
# So: run --update-sessions for its own contract (exit 0, restart-or-no-op),
# then force a real recreation deterministically and assert the relay property
# against that.
_cid_before="$C3"
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --update-sessions --yes --workspace "$WS3" >/dev/null 2>&1; RC=$?
ck "--update-sessions exits 0 (whether it restarted a stale session or correctly no-opped)" "[ $RC -eq 0 ]"

_seen_before="$(wc -l < "$SBX3/handoff/relay/seen" 2>/dev/null | tr -d ' ')"
_cid_before="$(cid3)"
"$SANDY" --stop --workspace "$WS3" >/dev/null 2>&1
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS3" >/dev/null 2>&1; RC=$?
ck "--start after --stop exits 0 (deterministic recreation)" "[ $RC -eq 0 ]"
C3="$(cid3)"
ck "container id changed (a real recreation happened)" \
   "[ -n \"$C3\" ] && [ \"$C3\" != \"$_cid_before\" ]"
_pid_new=""
for _i in 1 2 3 4 5 6 7 8; do
    _pid_new="$(docker exec -u "$(id -u)" "$C3" pgrep -f '\.sandy/relay\.sh' 2>/dev/null | head -1)"
    [ -n "$_pid_new" ] && break
    sleep 1
done
ck "relay is running again in the NEW container" "[ -n \"$_pid_new\" ]"
# Asserted as GROWTH against the pre-recreation count, not a bare ">= 2":
# the sandbox dir survives recreation, so a fixed threshold would be satisfied
# by lines an earlier phase wrote and would prove nothing about this step.
_seen_after="$(wc -l < "$SBX3/handoff/relay/seen" 2>/dev/null | tr -d ' ')"
ck "relay state persisted across recreation AND the new instance appended to it" \
   "[ \"${_seen_after:-0}\" -gt \"${_seen_before:-0}\" ]"

echo "-- E8. headless (-p) never starts a relay --"
# Stop the daemon first -- a headless launch against a workspace whose daemon
# is still live would just be refused by the workspace mutex, proving nothing
# about the relay gate specifically.
"$SANDY" --stop --workspace "$WS3" >/dev/null 2>&1
_lines_before="$(wc -l < "$SBX3/handoff/relay/supervisor.log" 2>/dev/null | tr -d ' ')"
# `timeout` is GNU coreutils and is NOT present on a stock macOS (homebrew
# installs it as `gtimeout`). Invoking it unconditionally made the -p launch
# exit 127, which this phase then reported as "the launch did not succeed" --
# a SKIP with a misleading reason that hid a portability bug rather than
# naming it. Resolve a real binary, and skip honestly if there is none.
_e8_to=""
if command -v timeout >/dev/null 2>&1; then _e8_to="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then _e8_to="gtimeout 120"
fi
_e8_rc=0
_e8_out="$(mktemp)"
if [ -z "$_e8_to" ]; then
    printf '  \033[33mSKIP\033[0m %s\n' "E8 headless relay gate (no timeout/gtimeout on this host; refusing to run an unbounded -p launch inside an acceptance harness)"
    _e8_rc=127
else
    env -u SANDY_AUTO_APPROVE_PRIVILEGED $_e8_to "$SANDY" -p "reply with the single word pong" --workspace "$WS3" > "$_e8_out" 2>&1 || _e8_rc=$?
fi
if [ "$_e8_rc" -ne 0 ]; then
    # A failed headless launch (missing credentials, image not built, mutex,
    # timeout) proves nothing about the relay gate -- an unchanged log count
    # would be trivially true either way, so don't let this pass vacuously.
    # No `skip` counter exists in this harness (only PASS/FAIL) -- print and
    # move on without touching either, rather than counting it as a pass.
    [ -n "$_e8_to" ] && printf '  \033[33mSKIP\033[0m %s\n' "E8 headless relay gate (the -p launch itself did not succeed, rc=$_e8_rc -- cannot conclude anything about the relay gate from it)"
else
    _lines_after="$(wc -l < "$SBX3/handoff/relay/supervisor.log" 2>/dev/null | tr -d ' ')"
    ck "supervisor.log line count unchanged after a successful headless run (no relay was started)" \
       "[ \"${_lines_before:-0}\" = \"${_lines_after:-0}\" ]"
    # Acceptance criterion 8: the skip is announced, and the announcement names
    # the consequence for the receive surface -- a silent skip would leave the
    # operator unable to tell "no relay because headless" from "relay died".
    ck "headless launch prints the criterion-8 skip line naming the refuse consequence" \
       "grep -q 'SANDY_HANDOFF_RELAY not started (headless run); crossSessionInbound will default to refuse' \"$_e8_out\""
fi
rm -f "$_e8_out"

echo "-- E10. criterion 7: a configured relay that CANNOT start fails the launch --"
# The whole point of the fail-the-launch rule: the crossSessionInbound default
# resolves to `accept` on the strength of the key alone, so a configured relay
# that never starts would leave that surface open with nothing delivering.
# Host-side detection (the path is workspace-relative, so sandy can resolve it
# back to the host and refuse before `docker run` ever happens).
"$SANDY" --stop --workspace "$WS3" >/dev/null 2>&1
sed -i.bak 's|^SANDY_HANDOFF_RELAY=.*|SANDY_HANDOFF_RELAY=.sandy/does-not-exist.sh|' "$SANDY_HOME_DIR/config"
_e10_out="$(mktemp)"
_e10_rc=0
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS3" > "$_e10_out" 2>&1 || _e10_rc=$?
ck "--start refuses (nonzero) when the configured relay is not an executable file" "[ $_e10_rc -ne 0 ]"
ck "...and says so, naming the fail-the-launch rule" \
   "grep -q 'A configured relay that cannot start fails the launch' \"$_e10_out\""
ck "...and no daemon container was left behind" "[ -z \"$(cid3)\" ]"
rm -f "$_e10_out"
# Restore the working relay so anything added after this phase is unaffected.
mv "$SANDY_HOME_DIR/config.bak" "$SANDY_HOME_DIR/config" 2>/dev/null || \
    sed -i.bak2 's|^SANDY_HANDOFF_RELAY=.*|SANDY_HANDOFF_RELAY=.sandy/relay.sh|' "$SANDY_HOME_DIR/config"
rm -f "$SANDY_HOME_DIR/config.bak2"

# E9 (zero-diff regression) is phase A, which already ran with the relay
# entirely unset and asserted no "handoff" string anywhere in `docker
# inspect` -- not repeated here.

echo
echo "== F. the relay SLOT (SANDY_RELAY + relay-bin/, 1.11.0, #258) =="
# WHY THIS PHASE NEEDS DOCKER, when run-tests.sh §123 already covers the logic:
# §123 can prove the `:ro` flag is on the right mount. It CANNOT prove the write
# actually fails, and that is the entire security claim of the slot. The agent
# runs as the HOST uid and OWNS $SANDBOX_DIR/relay-bin/relay, so permission bits
# bind nothing -- it could chmod and rewrite its own relay. Only a read-only
# MOUNT stops it, and only a real container can demonstrate EROFS rather than
# EACCES. An adapter can write files; it cannot create a mount.
#
# Runs on a fresh workspace with NO SANDY_HANDOFF_RELAY anywhere, because the
# deprecated key wins over the slot and would mask everything below.
WS4="$(mktemp -d)/mbx-slot-$$"
mkdir -p "$WS4/.sandy" && (cd "$WS4" && git init -q)
WS4="$(cd "$WS4" && pwd -P)"
cid4() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS4" 2>/dev/null | head -1; }
# Drop the privileged relay key for this phase, then restore it afterwards.
cp "$SANDY_HOME_DIR/config" "$SANDY_HOME_DIR/config.f.bak"
grep -v '^SANDY_HANDOFF_RELAY=' "$SANDY_HOME_DIR/config" > "$SANDY_HOME_DIR/config.f.tmp" || true
mv "$SANDY_HOME_DIR/config.f.tmp" "$SANDY_HOME_DIR/config"

echo "-- F1. an EMPTY slot launches normally (this is what lets SANDY_RELAY default to 1) --"
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS4"; RC=$?
ck "--start exits 0 with no relay installed" "[ $RC -eq 0 ]"
C4="$(cid4)"
ck "daemon container is running" "[ -n \"$C4\" ]"
SESS4="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C4" 2>/dev/null)"
# PREMISE, not decoration. The first cut of this phase escaped the Go template
# ({{index .Config.Labels \"sandy.session\"}}), docker returned nothing, SBX4
# became ".../sandboxes/" and every write below landed nowhere -- while the
# NEGATIVE checks ("nothing is mounted", "the write fails") all reported PASS,
# because an empty inspect satisfies them. A premise that can silently go empty
# has to be asserted before anything is concluded from it.
ck "session label resolved (premise: every path below is built from it)" "[ -n \"$SESS4\" ]"
SBX4="$SANDY_HOME_DIR/sandboxes/$SESS4"
ck "the slot directory was created host-side (presence carries no information, by construction)" \
   "[ -d \"$SBX4/relay-bin\" ]"
_m4="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C4" 2>/dev/null)"
ck "docker inspect returned mount rows (premise: the negative below is vacuous against empty output)" \
   "printf '%s' \"$_m4\" | grep -q '/home/sandy'"
ck "...and NOTHING is mounted at /opt/sandy/relay when the slot is empty" \
   "! printf '%s' \"$_m4\" | grep -q '/opt/sandy/relay'"
"$SANDY" --stop --workspace "$WS4" >/dev/null 2>&1

echo "-- F2. an installed relay runs, and its slot is mounted READ-ONLY --"
cat > "$SBX4/relay-bin/relay" <<'SLOTFIX'
#!/bin/sh
echo "$$ $SANDY_HANDOFF_INBOX $SANDY_HANDOFF_OUTBOX $SANDY_HANDOFF_RELAY_STATE" >> "$SANDY_HANDOFF_RELAY_STATE/slot-seen"
sleep 3600
SLOTFIX
chmod +x "$SBX4/relay-bin/relay"
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS4"; RC=$?
ck "--start exits 0 with a relay installed in the slot" "[ $RC -eq 0 ]"
C4="$(cid4)"
_m4="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C4" 2>/dev/null)"
ck "the slot is mounted at /opt/sandy/relay" \
   "printf '%s' \"$_m4\" | grep -q '/opt/sandy/relay'"
ck "...and docker reports it READ-ONLY (RW=false)" \
   "printf '%s' \"$_m4\" | grep -q '^/opt/sandy/relay false'"
ck "the relay from the slot actually ran (it wrote the env contract)" \
   "docker exec \"$C4\" test -s /home/sandy/.handoff/relay/slot-seen"
ck "...as a container-level process, not inside any tmux pane" \
   "docker exec \"$C4\" pgrep -f /opt/sandy/relay/relay >/dev/null"

echo "-- F3. THE claim: the agent cannot replace its own relay (EROFS, not EACCES) --"
# Run as the workspace uid, which is the uid that OWNS the file on the host --
# the case permission bits cannot defend against.
# PREMISE: without this, "the write fails" passes for the wrong reason -- the
# first run of this phase failed with "Directory nonexistent" (the slot was
# never mounted) and the check reported PASS. EROFS is only meaningful once the
# path exists.
ck "the slot entry EXISTS in the container (premise: a missing path fails a write for the wrong reason)" \
   "docker exec \"$C4\" test -f /opt/sandy/relay/relay"
_f3_uid="$(docker exec "$C4" id -u 2>/dev/null || echo 0)"
_f3_err="$(docker exec "$C4" sh -c 'echo pwned > /opt/sandy/relay/relay' 2>&1 || true)"
ck "a write to the installed relay FAILS from inside the container" \
   "! docker exec \"$C4\" sh -c 'echo pwned > /opt/sandy/relay/relay' 2>/dev/null"
ck "...and fails with a READ-ONLY FILE SYSTEM error, not a permission error -- proving the MOUNT is the boundary, not the bits (got: $_f3_err)" \
   "printf '%s' \"$_f3_err\" | grep -qi 'read-only'"
ck "...the file is still owned by the container user, so bits alone would NOT have stopped it (this is what makes the check above meaningful rather than incidental)" \
   "[ \"\$(docker exec \"$C4\" stat -c %u /opt/sandy/relay/relay 2>/dev/null)\" = \"$_f3_uid\" ]"
ck "creating a NEW file in the slot also fails (the whole directory is :ro, not just the entry)" \
   "! docker exec \"$C4\" sh -c 'touch /opt/sandy/relay/evil' 2>/dev/null"
ck "the relay is unchanged on the host after the attempt" \
   "grep -q 'slot-seen' \"$SBX4/relay-bin/relay\""

echo "-- F4. --print-state reports the live state, and the marker reports only intent --"
# NOTE the `\$` in every pattern below: the variable must expand when ck EVALs
# the string, not when the string is built. These hold JSON, so interpolating
# them at write time embeds raw `"` characters into the command and destroys its
# quoting -- which is what made the first run of this phase report four
# failures against a feature that was working. Phase E6 gets this right; this
# did not.
_f4_ps="$("$SANDY" --print-state 2>/dev/null | tr -d ' \n')"
_f4_marker="$(docker exec "$C4" cat /etc/sandy-session.json 2>/dev/null | tr -d ' \n')"
# PREMISES. Without these the NEGATIVE below ("does not claim started") passes
# against an empty read, which is exactly how it passed while telling us
# nothing -- twice in this phase now.
ck "the marker was read and is JSON (premise: the negative below is vacuous against an empty read)" \
   "printf '%s' \"\$_f4_marker\" | grep -q '\"schema\":1'"
ck "--print-state produced output naming this sandbox (premise)" \
   "printf '%s' \"\$_f4_ps\" | grep -q '\"name\":\"$SESS4\"'"
_f4_obj="$(_ps_obj "$_f4_ps" "$SESS4")"
ck "the sandbox object was sliced out of --print-state (premise: the assertion below is vacuous against an empty slice)" \
   "printf '%s' \"\$_f4_obj\" | grep -q '\"name\":\"$SESS4\"'"
ck "--print-state reports relay.state=started for this sandbox" \
   "printf '%s' \"\$_f4_obj\" | grep -q '\"relay\":{\"state\":\"started\"'"
ck "the session marker reports relay.slot=present (launch intent)" \
   "printf '%s' \"\$_f4_marker\" | grep -q '\"relay\":{\"slot\":\"present\"'"
ck "...and the marker does NOT claim the relay started -- it is written before docker run and cannot know" \
   "! printf '%s' \"\$_f4_marker\" | grep -q 'started'"
ck "crossSessionInbound still defaults to accept on the strength of a slot relay" \
   "printf '%s' \"\$_f4_marker\" | grep -q '\"cross_session_inbound\":\"accept\"'"

echo "-- F5. SANDY_RELAY=0 suppresses it, and names who --"
"$SANDY" --stop --workspace "$WS4" >/dev/null 2>&1
# mkdir first: sandy reaps empty protected stub dirs at launch ("Cleaned up 1
# empty stub dir(s) ... .sandy"), so the directory this phase created at the top
# is gone by now and the redirect would fail.
mkdir -p "$WS4/.sandy"
echo "SANDY_RELAY=0" > "$WS4/.sandy/config"
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS4"; RC=$?
ck "--start exits 0 with the capability off (SANDY_RELAY=0 is passive-safe: it only tightens)" "[ $RC -eq 0 ]"
C4="$(cid4)"
_m4="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C4" 2>/dev/null)"
ck "docker inspect returned mount rows (premise for the negative below)" \
   "printf '%s' \"$_m4\" | grep -q '/home/sandy'"
ck "nothing is mounted at /opt/sandy/relay" \
   "! printf '%s' \"$_m4\" | grep -q '/opt/sandy/relay'"
ck "no relay process is running" \
   "! docker exec \"$C4\" pgrep -f /opt/sandy/relay/relay >/dev/null 2>&1"
_f5_marker="$(docker exec "$C4" cat /etc/sandy-session.json 2>/dev/null | tr -d ' \n')"
ck "the marker was read and is JSON (premise)" \
   "printf '%s' \"\$_f5_marker\" | grep -q '\"schema\":1'"
ck "the marker records slot=disabled and NAMES the workspace as the source, so a cloned repo cannot silently un-enrol a fleet sandbox" \
   "printf '%s' \"\$_f5_marker\" | grep -q '\"slot\":\"disabled\",\"path\":null,\"disabled_by\":\"workspace\"'"
ck "...and crossSessionInbound falls back to refuse, leaving no open receive surface with nothing delivering" \
   "printf '%s' \"\$_f5_marker\" | grep -q '\"cross_session_inbound\":\"refuse\"'"

echo "-- F6. --reset-sandbox preserves the installed relay --"
"$SANDY" --stop --workspace "$WS4" >/dev/null 2>&1
rm -f "$WS4/.sandy/config"
"$SANDY" --reset-sandbox --workspace "$WS4" --yes >/dev/null 2>&1
ck "relay-bin/relay survives a --reset-sandbox (operator state; destroying it would silently un-enrol the sandbox)" \
   "[ -x \"$SBX4/relay-bin/relay\" ]"
ck "...while the rest of the sandbox really was reset (handoff/ is gone)" \
   "[ ! -d \"$SBX4/handoff/relay\" ] || [ -z \"\$(ls -A \"$SBX4/handoff/relay\" 2>/dev/null)\" ]"

echo "-- F7. an installed-but-not-executable entry FAILS the launch (never silently 'absent') --"
chmod -x "$SBX4/relay-bin/relay"
_f7_out="$(mktemp)"; _f7_rc=0
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS4" > "$_f7_out" 2>&1 || _f7_rc=$?
ck "--start refuses (nonzero) when the slot entry is not executable" "[ $_f7_rc -ne 0 ]"
ck "...and says so, naming the remedy" \
   "grep -q 'is not an executable file' \"$_f7_out\""
ck "...and no daemon container was left behind" "[ -z \"$(cid4)\" ]"
rm -f "$_f7_out"

echo "-- F8. a relay that dies at startup FAILS the launch (the 35-hour crash loop) --"
printf '#!/bin/sh\nexit 3\n' > "$SBX4/relay-bin/relay"; chmod +x "$SBX4/relay-bin/relay"
_f8_out="$(mktemp)"; _f8_rc=0
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS4" > "$_f8_out" 2>&1 || _f8_rc=$?
ck "--start refuses (nonzero) for a relay that execs and immediately exits non-zero" "[ $_f8_rc -ne 0 ]"
ck "...the supervisor log records the failing exit code host-side, where an operator can actually find it" \
   "grep -q 'rc=3' \"$SBX4/handoff/relay/supervisor.log\""
rm -f "$_f8_out"
"$SANDY" --stop --workspace "$WS4" >/dev/null 2>&1 || true
mv "$SANDY_HOME_DIR/config.f.bak" "$SANDY_HOME_DIR/config"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
