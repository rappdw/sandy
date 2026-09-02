#!/usr/bin/env bash
# End-to-end handoff directories + relay acceptance (#132 slice 1, plus
# SANDY_HANDOFF_RELAY 1.10.0).
#
# ⚠️ RUN ON A HOST WITH DOCKER. This cannot run inside sandy (no Docker). It
# proves the real container-level behavior that the static run-tests.sh §86
# and §114 checks cannot: the actual bind-mount modes (outbox rw / inbox
# :ro), that EROFS wins even for files the container-uid already owns, that
# the whole handoff directories feature is a true zero-diff when the key is
# unset, and (phase E, 1.10.0) that the relay supervisor described in
# CLAUDE.md "Handoff relay" actually behaves that way against a real
# container: starts with it, restarts a killed relay, never runs twice, and
# survives an --update-sessions recreation.
#
# Phases A-D ship directory/mount substrate only — no skills, no turn
# initiation, no peers, no manifest, no archive/ (its mode is unsettled in
# #132). Phase E covers the ONE mechanism that does move bytes today: the
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
#   A. Negative/zero-diff — key unset: no "handoff" anywhere in `docker
#      inspect` (Mounts + Env in one grep), no sandbox handoff/ dir, no
#      in-container ~/.handoff path.
#   B. Positive — key set via the WORKSPACE's .sandy/config (proves the
#      passive tier end-to-end: no approval prompt, works under the
#      non-interactive --start supervisor): host dirs exist, mount RW flags
#      are outbox=true/inbox=false, outbox is writable, inbox is not (even
#      after chmod), and a host-placed file in inbox resists chmod from
#      inside the container despite being agent-uid-owned (EROFS beats
#      ownership — the entire point of the :ro mount flag).
#   C. Persistence — stop/start preserves the outbox content.
#   D. Enable by MARKER (.handoff-enabled) with no workspace config anywhere,
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
# and the marker could not be shown to be what enabled the pair.
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

echo "== A. negative (SANDY_HANDOFF_DIRS unset: dirs exist, nothing is mounted) =="
"$SANDY" --start --workspace "$WS"; RC=$?
ck "--start exits 0" "[ $RC -eq 0 ]"
C="$(cid)"
ck "daemon container is running" "[ -n \"$C\" ]"
SESS="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS\" ]"
ck "docker inspect has NO mention of handoff anywhere (mounts, env, labels)" \
   "! docker inspect \"$C\" | grep -qi handoff"
# The host directories are now created on EVERY launch (only the MOUNT is
# gated), so their presence proves nothing and is not asserted either way. What
# still must hold with handoff off is that nothing reaches the CONTAINER — which
# the docker-inspect assertion above and the in-container check below cover.
ck "sandbox handoff/ dirs exist but are INERT (created always; presence means nothing)" \
   "[ -d \"$SANDY_HOME_DIR/sandboxes/$SESS/handoff/inbox\" ]"
ck "in-container ~/.handoff does NOT exist" \
   "! docker exec -u \"\$(id -u)\" \"$C\" test -e /home/claude/.handoff"
"$SANDY" --stop --workspace "$WS"; ck "--stop (phase A) exits 0" "[ $? -eq 0 ]"

echo "== B. positive (SANDY_HANDOFF_DIRS=1 via workspace .sandy/config) =="
# Setting it here — not via env — proves the passive tier end-to-end: no
# approval prompt is needed, and it works under the non-interactive --start
# supervisor exactly like any other passive key.
#
# `env -u SANDY_AUTO_APPROVE_PRIVILEGED` is load-bearing for that claim. When
# this harness runs under run-integration-tests.sh it inherits that variable
# (the suite exports it because sandy's own repo carries privileged keys in
# .sandy/.secrets). With it set, a privileged key would be auto-approved and
# this phase would pass even if SANDY_HANDOFF_DIRS were retiered — i.e. the tier
# assertion would silently become vacuous. Unsetting it keeps the proof real
# whether the script runs standalone or as a suite section.
mkdir -p "$WS/.sandy"
echo "SANDY_HANDOFF_DIRS=1" >> "$WS/.sandy/config"
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS"; RC=$?
ck "--start exits 0 with the handoff directories enabled" "[ $RC -eq 0 ]"
C="$(cid)"
ck "daemon container is running" "[ -n \"$C\" ]"
SESS="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS\" ]"
ck "host outbox dir exists" "[ -d \"$SANDY_HOME_DIR/sandboxes/$SESS/handoff/outbox\" ]"
ck "host inbox dir exists" "[ -d \"$SANDY_HOME_DIR/sandboxes/$SESS/handoff/inbox\" ]"

_mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C" 2>/dev/null)"
echo "  mounts:"; printf '%s\n' "$_mounts" | grep -i handoff | sed 's/^/    /'
ck "outbox mount is RW=true" \
   "printf '%s\n' \"\$_mounts\" | grep -qE '^/home/claude/.handoff/outbox true\$'"
ck "inbox mount is RW=false" \
   "printf '%s\n' \"\$_mounts\" | grep -qE '^/home/claude/.handoff/inbox false\$'"

ck "write to outbox SUCCEEDS from inside the container" \
   "docker exec -u \"\$(id -u)\" \"$C\" sh -c 'echo hi > /home/claude/.handoff/outbox/probe.txt'"
ck "write to inbox FAILS from inside the container" \
   "! docker exec -u \"\$(id -u)\" \"$C\" sh -c 'echo hi > /home/claude/.handoff/inbox/probe.txt' 2>/dev/null"
ck "chmod u+w on the inbox dir itself FAILS (EROFS, not a mode problem)" \
   "! docker exec -u \"\$(id -u)\" \"$C\" chmod u+w /home/claude/.handoff/inbox 2>/dev/null"

# The EROFS-beats-ownership assertion — the entire point of the :ro mount
# flag. A file placed by the HOST into inbox is owned by the agent's
# in-container uid (same uid as the host user placing it, since sandy maps
# uid 1:1), so ownership alone would let the agent rewrite it — the mount
# flag is what actually stops it.
echo "host-placed-in-inbox" > "$SANDY_HOME_DIR/sandboxes/$SESS/handoff/inbox/from-host.txt"
ck "cat of the host-placed inbox file SUCCEEDS (read is fine)" \
   "docker exec -u \"\$(id -u)\" \"$C\" cat /home/claude/.handoff/inbox/from-host.txt"
# Prove the ownership premise BEFORE asserting chmod fails. Without this the
# chmod check passes for the wrong reason if the file is not actually owned by
# the agent uid — it would be testing permissions, not the mount flag.
ck "host-placed inbox file IS owned by the agent uid (the premise)" \
   "[ \"\$(docker exec -u \"\$(id -u)\" \"$C\" stat -c '%u' /home/claude/.handoff/inbox/from-host.txt 2>/dev/null)\" = \"\$(id -u)\" ]"
ck "chmod u+w on the agent-OWNED host-placed inbox file STILL FAILS" \
   "! docker exec -u \"\$(id -u)\" \"$C\" chmod u+w /home/claude/.handoff/inbox/from-host.txt 2>/dev/null"

# Informational only — not asserted, since the parent's on-host ownership
# depends on how the harness itself was invoked (sudo, CI runner uid, etc.).
_parent_stat="$(docker exec -u "$(id -u)" "$C" sh -c 'stat -c "%U:%G %a" /home/claude/.handoff 2>/dev/null || stat -f "%Su:%Sg %Lp" /home/claude/.handoff 2>/dev/null')" || _parent_stat="(stat unavailable)"
echo "  info: /home/claude/.handoff parent ownership/mode: $_parent_stat"

echo "== C. persistence across --stop / --start =="
"$SANDY" --stop --workspace "$WS"; ck "--stop (phase B) exits 0" "[ $? -eq 0 ]"
"$SANDY" --start --workspace "$WS"; ck "--start (phase C) exits 0" "[ $? -eq 0 ]"
C="$(cid)"
ck "outbox file from phase B still present after restart" \
   "docker exec -u \"\$(id -u)\" \"$C\" test -f /home/claude/.handoff/outbox/probe.txt"
"$SANDY" --stop --workspace "$WS"; ck "--stop (phase C, final) exits 0" "[ $? -eq 0 ]"

echo "== D. enable by MARKER, with no workspace config anywhere =="
# Closes acceptance criterion 4 for the MARKER path specifically. Phase B proves
# EROFS-beats-ownership when the pair is enabled by SANDY_HANDOFF_DIRS=1; that is
# NOT the same evidence. The marker resolves into the same variable before the
# gate, so both paths reach identical mount code — but "identical by
# construction" is an argument, not a test result, and criterion 4 exists
# precisely to reject that kind of reasoning.
#
# The marker lives at the TOP level of the sandbox dir, whose slug is not known
# until a launch creates it. So: launch once (also proving marker-absent means
# off), stop, enrol, relaunch. That is exactly the order a provisioner works in.

ck "phase D workspace has NO .sandy/config (the premise)" "[ ! -e \"$WS2/.sandy/config\" ]"

env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS2"; RC=$?
ck "--start (D, pre-enrolment) exits 0" "[ $RC -eq 0 ]"
C2="$(cid2)"
ck "daemon container is running" "[ -n \"$C2\" ]"
SESS2="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C2" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS2\" ]"
# Marker absent and no config => the pair must be OFF. Without this the phase
# could pass on a sandbox that had handoff enabled for some unrelated reason.
ck "NEGATIVE: no marker and no config => in-container ~/.handoff does NOT exist" \
   "! docker exec -u \"\$(id -u)\" \"$C2\" test -e /home/claude/.handoff"

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
ck "still NO workspace .sandy/config — the marker alone enabled it" "[ ! -e \"$WS2/.sandy/config\" ]"

_m2="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C2" 2>/dev/null)"
echo "  mounts:"; printf '%s\n' "$_m2" | grep -i handoff | sed 's/^/    /'
ck "outbox mount is RW=true (marker path)" \
   "printf '%s\n' \"\$_m2\" | grep -qE '^/home/claude/.handoff/outbox true\$'"
ck "inbox mount is RW=false (marker path)" \
   "printf '%s\n' \"\$_m2\" | grep -qE '^/home/claude/.handoff/inbox false\$'"

# --- criterion 4, under the marker path ---
ck "write to outbox SUCCEEDS (marker path)" \
   "docker exec -u \"\$(id -u)\" \"$C2\" sh -c 'echo hi > /home/claude/.handoff/outbox/probe.txt'"
ck "write to inbox FAILS (marker path)" \
   "! docker exec -u \"\$(id -u)\" \"$C2\" sh -c 'echo hi > /home/claude/.handoff/inbox/probe.txt' 2>/dev/null"
ck "chmod u+w on the inbox dir itself FAILS (EROFS, marker path)" \
   "! docker exec -u \"\$(id -u)\" \"$C2\" chmod u+w /home/claude/.handoff/inbox 2>/dev/null"
echo "host-placed-in-inbox" > "$SBX2/handoff/inbox/from-host.txt"
ck "host-placed inbox file IS owned by the agent uid (the premise, marker path)" \
   "[ \"\$(docker exec -u \"\$(id -u)\" \"$C2\" stat -c '%u' /home/claude/.handoff/inbox/from-host.txt 2>/dev/null)\" = \"\$(id -u)\" ]"
ck "chmod u+w on the agent-OWNED host-placed inbox file STILL FAILS (marker path)" \
   "! docker exec -u \"\$(id -u)\" \"$C2\" chmod u+w /home/claude/.handoff/inbox/from-host.txt 2>/dev/null"

# --- criterion 5: the agent has no path to the marker ---
# Not "we did not mount it" as a claim, but: no mount SOURCE is the sandbox top
# level, so nothing inside the container resolves to the marker file.
ck "NEGATIVE: no bind mount sources the sandbox top level (agent cannot self-enrol)" \
   "! docker inspect -f '{{range .Mounts}}{{.Source}}{{\"\n\"}}{{end}}' \"$C2\" 2>/dev/null | grep -qx \"$SBX2\""
ck "NEGATIVE: the marker is not visible anywhere inside the container" \
   "! docker exec -u \"\$(id -u)\" \"$C2\" sh -c 'test -e /home/claude/.handoff-enabled -o -e /home/claude/.claude/.handoff-enabled' 2>/dev/null"

# --- introspection agrees with reality ---
ck "--print-state reports handoff_enabled=true for the enrolled sandbox" \
   "\"$SANDY\" --print-state light 2>/dev/null | grep -q '\"handoff_enabled\":true'"

"$SANDY" --stop --workspace "$WS2"; ck "--stop (D, final) exits 0" "[ $? -eq 0 ]"

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
   "printf '%s\n' \"\$_m3\" | grep -qE '^/home/claude/.handoff/relay true\$'"
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
_exits="$(docker exec -u "$(id -u)" "$C3" grep -c 'exit rc=' /home/claude/.handoff/relay/supervisor.log 2>/dev/null || echo 0)"
ck "supervisor.log recorded the exit" "[ \"${_exits:-0}\" -ge 1 ]"
# The log line is "[sandy-relay] <ISO ts> start <path>", so the timestamp sits
# between the bracket and the word -- the old '\] start ' pattern required them
# adjacent and therefore never matched, making this check fail even on a
# perfectly working restart (which E3s own new-pid assertion had just proved).
_starts="$(docker exec -u "$(id -u)" "$C3" grep -c ' start /' /home/claude/.handoff/relay/supervisor.log 2>/dev/null || echo 0)"
ck "supervisor.log shows at least 2 starts (initial + restart)" "[ \"${_starts:-0}\" -ge 2 ]"

echo "-- E4. never started twice --"
ck "the supervisor lock is HELD (a second flock -n attempt fails)" \
   "! docker exec -u \"\$(id -u)\" \"$C3\" flock -n /home/claude/.sandy-handoff-relay.lock true"
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
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
