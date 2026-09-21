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

# Phases A, A2, B, C and D were REMOVED in 2.2.0 with the mechanisms they
# tested: the ~/.handoff tree (#352, #353), the SANDY_HANDOFF_DIRS opt-out and
# the .handoff-enabled operator marker (#355).
#
# THE ONE THING THAT MUST NOT BE LOST WITH THEM is the EROFS-beats-ownership
# proof: that a :ro mount really returns EROFS for a file the container uid
# OWNS, which permission bits could never guarantee and which no script-text
# check can establish. It lived in phase B (inbox), moved to F3 (the relay
# slot) when #352 removed the lanes, and #354 then removed the slot.
#
# It now lives in phase G, against a feature manifest mount declared `mode:
# ro` -- the only :ro mount sandy still makes. run-tests.sh §97(16) is the
# tripwire that fails if it ever has no runtime home at all.

echo "== E. handoff relay (SANDY_HANDOFF_RELAY, 1.10.0) =="
# Fresh workspace: relay fixtures shouldn't share state with A-D.
WS3="$(mktemp -d)/mbx-relay-$$"
mkdir -p "$WS3/.sandy" && (cd "$WS3" && git init -q)
WS3="$(cd "$WS3" && pwd -P)"
cid3() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS3" 2>/dev/null | head -1; }

# The relay is installed as a feature manifest ENTRY (2.2.0). It used to be
# installed by setting SANDY_HANDOFF_RELAY in the isolated host config, which
# #354 made a HARD ERROR -- so a harness that still did that would refuse the
# launch and report the supervisor as broken, when what is broken is the
# harness. That happened; this is the fix.
_E_FEAT="$SANDY_HOME_DIR/features/acc-relay"
mkdir -p "$_E_FEAT/payload"
cat > "$_E_FEAT/payload/relay" <<'RELAYFIX'
#!/bin/sh
# Fixture relay for phase E: records its own pid + the env contract on each
# (re)start, then blocks. Deliberately NOT `exec sleep` -- pgrep -f below
# matches on this script's own path, and `exec` would replace this process's
# argv with "sleep 3600", losing that match the instant it ran.
echo "$$ $SANDY_RELAY_STATE" >> "$SANDY_RELAY_STATE/seen"
sleep 3600
RELAYFIX
chmod +x "$_E_FEAT/payload/relay"
cat > "$_E_FEAT/feature.json" <<'E_MANIFEST'
{ "sandboxes": {"include": ["*"]}, "agents": {"include": ["*"]},
  "mounts": [ { "name": "payload", "from": "payload" } ],
  "entry": "payload/relay" }
E_MANIFEST

# No config key is involved any more: a manifest under $SANDY_HOME is
# privileged by construction of WHERE IT LIVES, so there is nothing to approve.
# `env -u SANDY_AUTO_APPROVE_PRIVILEGED` is kept anyway, to prove that.
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS3"; RC=$?
ck "--start exits 0 with the relay configured" "[ $RC -eq 0 ]"
C3="$(cid3)"
ck "daemon container is running" "[ -n \"$C3\" ]"
SESS3="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C3" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS3\" ]"
SBX3="$SANDY_HOME_DIR/sandboxes/$SESS3"

echo "-- E1. mount + env forwarding --"
_m3="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{.RW}}{{"\n"}}{{end}}' "$C3" 2>/dev/null)"
echo "  mounts:"; printf '%s\n' "$_m3" | grep -iE 'handoff|relay-state' | sed 's/^/    /'
ck "relay STATE mount is RW=true at its 2.2.0 path (#353)" \
   "printf '%s\n' \"\$_m3\" | grep -qE '^/opt/sandy/relay-state true\$'"
ck "no removed lane is mounted alongside the relay (#352)" \
   "! printf '%s\n' \"\$_m3\" | grep -qE '^/home/sandy/.handoff/(inbox|outbox|peer) '"
# Never dump the whole env -- it carries CLAUDE_CODE_OAUTH_TOKEN and friends.
# Count occurrences of the one var under test instead of printing anything.
_envcount="$(docker inspect -f '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$C3" 2>/dev/null | grep -c '^SANDY_HANDOFF_RELAY=\.sandy/relay\.sh$')"
ck "the resolved entry is forwarded into the container exactly once (SANDY_HANDOFF_RELAY survives as the INTERNAL channel a manifest entry travels through -- only the config key was removed)" "[ \"$_envcount\" = 1 ]"

echo "-- E2. relay is running, as a sibling of tmux (not a pane, not a session child) --"
# The subshell that runs _sandy_start_handoff_relay's loop is backgrounded
# (&) before tmux new-session runs, so --start's own readiness gate (which
# only waits on the inner tmux session) can return before the relay has
# actually flock'd and written its first log line. Poll rather than assert
# immediately.
_pid1=""
for _i in 1 2 3 4 5 6; do
    _pid1="$(docker exec -u "$(id -u)" "$C3" pgrep -f 'acc-relay/relay' 2>/dev/null | head -1)"
    [ -n "$_pid1" ] && break
    sleep 1
done
ck "relay process is running in the container" "[ -n \"$_pid1\" ]"
ck "exactly one relay process" \
   "[ \"\$(docker exec -u \"\$(id -u)\" \"$C3\" pgrep -c -f 'acc-relay/relay' 2>/dev/null)\" = 1 ]"
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
    _pid_after="$(docker exec -u "$(id -u)" "$C3" pgrep -f 'acc-relay/relay' 2>/dev/null | head -1)"
    [ -n "$_pid_after" ] && [ "$_pid_after" != "$_pid_before" ] && break
done
ck "relay came back with a NEW pid after being killed" \
   "[ -n \"$_pid_after\" ] && [ \"$_pid_after\" != \"$_pid_before\" ]"
_exits="$(docker exec -u "$(id -u)" "$C3" grep -c 'exit rc=' /opt/sandy/relay-state/supervisor.log 2>/dev/null || echo 0)"
ck "supervisor.log recorded the exit" "[ \"${_exits:-0}\" -ge 1 ]"
# The log line is "[sandy-relay] <ISO ts> start <path>", so the timestamp sits
# between the bracket and the word -- the old '\] start ' pattern required them
# adjacent and therefore never matched, making this check fail even on a
# perfectly working restart (which E3s own new-pid assertion had just proved).
_starts="$(docker exec -u "$(id -u)" "$C3" grep -c ' start /' /opt/sandy/relay-state/supervisor.log 2>/dev/null || echo 0)"
ck "supervisor.log shows at least 2 starts (initial + restart)" "[ \"${_starts:-0}\" -ge 2 ]"

echo "-- E4. never started twice --"
ck "the supervisor lock is HELD (a second flock -n attempt fails)" \
   "! docker exec -u \"\$(id -u)\" \"$C3\" flock -n /home/sandy/.sandy-handoff-relay.lock true"
ck "still exactly one relay process (no second supervisor was spawned)" \
   "[ \"\$(docker exec -u \"\$(id -u)\" \"$C3\" pgrep -c -f 'acc-relay/relay' 2>/dev/null)\" = 1 ]"

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
ck "session marker reports relay.source=manifest -- handoff_relay was REMOVED in #355 and relay.source replaced it, so asserting the old field would be asserting a mechanism that no longer exists" \
   "docker exec \"$C3\" grep -q '\"source\": \"manifest\"' /etc/sandy-session.json"
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

_seen_before="$(wc -l < "$SBX3/relay-state/seen" 2>/dev/null | tr -d ' ')"
_cid_before="$(cid3)"
"$SANDY" --stop --workspace "$WS3" >/dev/null 2>&1
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS3" >/dev/null 2>&1; RC=$?
ck "--start after --stop exits 0 (deterministic recreation)" "[ $RC -eq 0 ]"
C3="$(cid3)"
ck "container id changed (a real recreation happened)" \
   "[ -n \"$C3\" ] && [ \"$C3\" != \"$_cid_before\" ]"
_pid_new=""
for _i in 1 2 3 4 5 6 7 8; do
    _pid_new="$(docker exec -u "$(id -u)" "$C3" pgrep -f 'acc-relay/relay' 2>/dev/null | head -1)"
    [ -n "$_pid_new" ] && break
    sleep 1
done
ck "relay is running again in the NEW container" "[ -n \"$_pid_new\" ]"
# Asserted as GROWTH against the pre-recreation count, not a bare ">= 2":
# the sandbox dir survives recreation, so a fixed threshold would be satisfied
# by lines an earlier phase wrote and would prove nothing about this step.
_seen_after="$(wc -l < "$SBX3/relay-state/seen" 2>/dev/null | tr -d ' ')"
ck "relay state persisted across recreation AND the new instance appended to it" \
   "[ \"${_seen_after:-0}\" -gt \"${_seen_before:-0}\" ]"

echo "-- E8. headless (-p) never starts a relay --"
# Stop the daemon first -- a headless launch against a workspace whose daemon
# is still live would just be refused by the workspace mutex, proving nothing
# about the relay gate specifically.
"$SANDY" --stop --workspace "$WS3" >/dev/null 2>&1
_lines_before="$(wc -l < "$SBX3/relay-state/supervisor.log" 2>/dev/null | tr -d ' ')"
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
    _lines_after="$(wc -l < "$SBX3/relay-state/supervisor.log" 2>/dev/null | tr -d ' ')"
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
# Break the ENTRY, not a config key: point the manifest at a path that is not
# executable. The refusal is in-container now (user-setup.sh exits 1 and the
# container dies), because a manifest entry resolves to an image-only path the
# host cannot stat -- which is the branch the host-side check was never
# covering anyway.
cp "$_E_FEAT/feature.json" "$_E_FEAT/feature.json.bak"
cat > "$_E_FEAT/feature.json" <<'E10_MANIFEST'
{ "sandboxes": {"include": ["*"]}, "agents": {"include": ["*"]},
  "mounts": [ { "name": "payload", "from": "payload" } ],
  "entry": "payload/not-executable" }
E10_MANIFEST
printf 'not executable\n' > "$_E_FEAT/payload/not-executable"   # deliberately no chmod +x
_e10_out="$(mktemp)"
_e10_rc=0
env -u SANDY_AUTO_APPROVE_PRIVILEGED "$SANDY" --start --workspace "$WS3" > "$_e10_out" 2>&1 || _e10_rc=$?
ck "--start refuses (nonzero) when the declared entry is not an executable file" "[ $_e10_rc -ne 0 ]"
ck "...and says so, naming the fail-the-launch rule" \
   "grep -q 'A configured relay that cannot start fails the session' \"$_e10_out\" || grep -q 'cannot start fails the' \"$_e10_out\""
ck "...and no daemon container was left behind" "[ -z \"$(cid3)\" ]"
rm -f "$_e10_out"
# Restore the working entry so anything added after this phase is unaffected.
mv "$_E_FEAT/feature.json.bak" "$_E_FEAT/feature.json"
rm -f "$_E_FEAT/payload/not-executable"

# Remove phase E's feature before anything else runs: its manifest selects
# every sandbox, so leaving it installed would enrol it in phase G too and
# start a relay there for no reason.
"$SANDY" --stop --workspace "$WS3" >/dev/null 2>&1 || true
rm -rf "$_E_FEAT"

# E9 (zero-diff regression) is phase A, which already ran with the relay
# entirely unset and asserted no "handoff" string anywhere in `docker
# inspect` -- not repeated here.

echo
echo "== G. THE claim: a :ro manifest mount returns EROFS, not EACCES =="
# Phase F tested the relay-bin slot, removed in 2.2.0 (#354). This is the same
# claim re-homed onto the mechanism that replaced it: a feature payload the
# manifest mounts read-only.
#
# Run as the uid that OWNS the file on the host -- the case permission bits
# cannot defend against, and the whole reason the MOUNT is the boundary.
#
# PREMISE FIRST, because without it "the write fails" passes for the wrong
# reason: the first run of the phase this replaces failed with "Directory
# nonexistent" (the mount was never made) and reported PASS. EROFS is only
# meaningful once the path exists.
_G_FEAT="$SANDY_HOME_DIR/features/acc-erofs"
mkdir -p "$_G_FEAT/payload"
printf 'payload-seen\n' > "$_G_FEAT/payload/thing"
cat > "$_G_FEAT/feature.json" <<'G_MANIFEST'
{ "sandboxes": {"include": ["*"]}, "agents": {"include": ["*"]},
  "mounts": [ { "name": "payload", "from": "payload", "mode": "ro" } ] }
G_MANIFEST

"$SANDY" --start --workspace "$WS" >/dev/null 2>&1; RC=$?
ck "--start exits 0 with the feature enrolled" "[ $RC -eq 0 ]"
CG="$(docker ps -q --filter "label=sandy.workspace_path=$WS" | head -1)"
ck "container is running" "[ -n \"$CG\" ]"
ck "the payload EXISTS in the container (premise: a missing path fails a write for the wrong reason)" \
   "docker exec \"$CG\" test -f /opt/sandy/features/acc-erofs/thing"
# EVERY check below is gated on a non-empty $CG. Without that gate a missing
# container makes `docker exec "" ...` fail, and "the write FAILED" then passes
# for the wrong reason -- three of these reported PASS against an empty id on
# the first real run of this phase, while the premise check correctly failed.
# A phase whose premise is red must not report green assertions beneath it.
_g_uid="$(docker exec "$CG" id -u 2>/dev/null || echo 0)"
_g_err="$([ -n "$CG" ] && docker exec "$CG" sh -c 'echo pwned > /opt/sandy/features/acc-erofs/thing' 2>&1 || echo "NO-CONTAINER")"
ck "a write to the :ro payload FAILS from inside the container" \
   "[ -n \"$CG\" ] && ! docker exec \"$CG\" sh -c 'echo pwned > /opt/sandy/features/acc-erofs/thing' 2>/dev/null"
ck "...and fails with a READ-ONLY FILE SYSTEM error, not a permission error -- proving the MOUNT is the boundary, not the bits (got: $_g_err)" \
   "[ -n \"$CG\" ] && printf '%s' \"$_g_err\" | grep -qi 'read-only'"
ck "...the file is still owned by the container user, so bits alone would NOT have stopped it (this is what makes the check above meaningful)" \
   "[ -n \"$CG\" ] && [ \"\$(docker exec \"$CG\" stat -c %u /opt/sandy/features/acc-erofs/thing 2>/dev/null)\" = \"$_g_uid\" ]"
ck "creating a NEW file in the payload also fails (the whole directory is :ro, not just the file)" \
   "[ -n \"$CG\" ] && ! docker exec \"$CG\" sh -c 'touch /opt/sandy/features/acc-erofs/evil' 2>/dev/null"
ck "the payload is unchanged on the host after the attempt" \
   "[ -n \"$CG\" ] && grep -q 'payload-seen' \"$_G_FEAT/payload/thing\""
"$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true
rm -rf "$_G_FEAT"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
