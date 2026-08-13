#!/usr/bin/env bash
# End-to-end handoff-handoff directories acceptance (#132 slice 1: dirs + mounts only).
#
# ⚠️ RUN ON A HOST WITH DOCKER. This cannot run inside sandy (no Docker). It
# proves the real container-level behavior that the static run-tests.sh §86
# checks cannot: the actual bind-mount modes (outbox rw / inbox :ro), that
# EROFS wins even for files the container-uid already owns, and that the
# whole handoff directories is a true zero-diff when the key is unset.
#
# This slice ships directory/mount substrate ONLY — no relay, no helper, no
# skills, no turn initiation, no peers, no manifest, no archive/ (its mode is
# unsettled in #132). Nothing here ever moves a file between workspaces.
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
cleanup_ws() { "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true; rm -rf "$(dirname "$WS")"; }
trap cleanup_ws EXIT

command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the host"; exit 2; }

echo "== A. negative / zero-diff (SANDY_HANDOFF_DIRS unset) =="
"$SANDY" --start --workspace "$WS"; RC=$?
ck "--start exits 0" "[ $RC -eq 0 ]"
C="$(cid)"
ck "daemon container is running" "[ -n \"$C\" ]"
SESS="$(docker inspect -f '{{index .Config.Labels "sandy.session"}}' "$C" 2>/dev/null)"
ck "session label resolved" "[ -n \"$SESS\" ]"
ck "docker inspect has NO mention of handoff anywhere (mounts, env, labels)" \
   "! docker inspect \"$C\" | grep -qi handoff"
ck "sandbox handoff/ dir does NOT exist" "[ ! -e \"$SANDY_HOME_DIR/sandboxes/$SESS/handoff\" ]"
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

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
