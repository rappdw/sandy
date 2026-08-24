#!/usr/bin/env bash
# End-to-end acceptance for `sandy --provision` (#177) — the fleet-provisioner
# target scenario: non-interactively materialize a workspace's sandbox by
# running the REAL launch path once, with no live session ever left behind
# and no live session ever silently torn down.
#
# ⚠️ RUN ON A HOST WITH DOCKER. This cannot run inside sandy (no Docker). It
# is the release-readiness gate for #177: run-tests.sh §102 covers
# --provision's own guard/TOCTOU/exit-code logic behind a stubbed docker and
# a fake $0 standing in for the daemon supervisor (see CLAUDE.md
# "sandy --provision") — ONLY this proves a real --start/--stop round trip
# actually materializes a sandbox end to end, and that a genuinely live
# session is left alone rather than bounced. Prints PASS/FAIL per assertion;
# exits non-zero if any FAIL.
#
#   Usage:  bash test/acceptance-provision.sh          # uses ./sandy
#           SANDY=/path/to/sandy bash test/acceptance-provision.sh
set -uo pipefail

SANDY="${SANDY:-./sandy}"
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"
WS="$(mktemp -d)/provision-accept-$$"
mkdir -p "$WS" && (cd "$WS" && git init -q)
# Canonicalize exactly like sandy does (pwd -P) — see acceptance-daemon.sh for
# why this matters (macOS mktemp under a /var symlink).
WS="$(cd "$WS" && pwd -P)"
PASS=0; FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1));
       else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
cid() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$WS" 2>/dev/null | head -1; }
cleanup_ws() { "$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true; rm -rf "$(dirname "$WS")"; _cleanup_sandy_home || true; }
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

command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the host"; exit 2; }

# Sandbox directory name resolution, mirrored from --reset-sandbox/sandy
# itself, so the harness can find the same sandbox --provision materializes.
_hash="$(printf '%s' "$WS" | { shasum -a 256 2>/dev/null || sha256sum; })"; _hash="${_hash%% *}"; _hash="${_hash:0:8}"
_base="$(basename "$WS" | tr -cd 'a-zA-Z0-9._-')"; _base="${_base:-project}"
SBXNAME="${_base}-${_hash}"
SBXDIR="$SANDY_HOME_DIR/sandboxes/$SBXNAME"

echo "== 1. no sandbox exists yet for a fresh workspace =="
ck "sandbox directory does not exist before --provision" "[ ! -d \"$SBXDIR\" ]"

echo "== 2. sandy --provision --yes: runs the real launch path once =="
"$SANDY" --provision --workspace "$WS" --yes; RC=$?
ck "--provision exits 0" "[ $RC -eq 0 ]"
ck "sandbox directory now exists (the real launch path materialized it)" "[ -d \"$SBXDIR\" ]"
ck "WORKSPACE.json was written (a real launch, not a fabricated marker)" "[ -f \"$SBXDIR/WORKSPACE.json\" ]"
ck "sandbox version marker was written (.sandy_created_version)" "[ -f \"$SBXDIR/.sandy_created_version\" ]"
ck "no daemon container is left running (--stop actually tore it down)" "[ -z \"$(cid)\" ]"
LOCK="$SANDY_HOME_DIR/sandboxes/.$SBXNAME.lock"
ck "workspace lock is released" "[ ! -d \"$LOCK\" ]"

echo "== 3. --provision is safely re-runnable (directory presence is not a skip condition) =="
"$SANDY" --provision --workspace "$WS" --yes; RC3=$?
ck "second --provision (no live session) exits 0 and runs the real path again" "[ $RC3 -eq 0 ]"
ck "still no daemon container left running afterward" "[ -z \"$(cid)\" ]"

echo "== 4. --provision against a LIVE session is a safe no-op, not a bounce =="
"$SANDY" --start --workspace "$WS" >/dev/null 2>&1
LIVE_C="$(cid)"
ck "setup: a real daemon session is now up" "[ -n \"$LIVE_C\" ]"
"$SANDY" --provision --workspace "$WS" --yes >/tmp/provision-accept-noop-$$.log 2>&1; RC4=$?
ck "--provision against a live session exits 0" "[ $RC4 -eq 0 ]"
ck "--provision printed a 'nothing to do' / already-live message, not a launch" "grep -qiE 'already has a (live session|running daemon container)' /tmp/provision-accept-noop-$$.log"
AFTER_C="$(cid)"
ck "the SAME container is still running — the live session was never touched" "[ -n \"$AFTER_C\" ] && [ \"$AFTER_C\" = \"$LIVE_C\" ]"
ck "the inner tmux session is still alive" "docker exec -u \"$(id -u)\" \"$AFTER_C\" tmux has-session -t sandy"
rm -f /tmp/provision-accept-noop-$$.log

echo "== 5. cleanup: stop the live session left over from step 4 =="
"$SANDY" --stop --workspace "$WS"; RC5=$?
ck "--stop exits 0" "[ $RC5 -eq 0 ]"
ck "container is gone" "[ -z \"$(cid)\" ]"

echo "== 6. --dry-run never launches anything (against a fresh, session-less workspace) =="
"$SANDY" --provision --workspace "$WS" --dry-run >/tmp/provision-accept-dry-$$.log 2>&1; RC6=$?
ck "--dry-run exits 0" "[ $RC6 -eq 0 ]"
ck "--dry-run prints its own 'nothing started' line" "grep -q -- '--dry-run: nothing started' /tmp/provision-accept-dry-$$.log"
ck "--dry-run started no container" "[ -z \"$(cid)\" ]"
rm -f /tmp/provision-accept-dry-$$.log

echo "== 7. non-TTY without --yes refuses rather than launching unattended =="
"$SANDY" --provision --workspace "$WS" </dev/null >/tmp/provision-accept-noyes-$$.log 2>&1; RC7=$?
ck "non-TTY without --yes exits 1" "[ $RC7 -eq 1 ]"
ck "non-TTY without --yes names the fix ('pass --yes')" "grep -q -- 'pass --yes' /tmp/provision-accept-noyes-$$.log"
ck "non-TTY without --yes started no container" "[ -z \"$(cid)\" ]"
rm -f /tmp/provision-accept-noyes-$$.log

echo "== 6. the supervisor stamps sandy.provision_id with the id it was handed =="
# This is the one half of the ownership model a unit fixture structurally cannot
# reach: run-tests.sh 102 fakes --start with a wrapper, so sandy's real
# supervisor branch never executes there (verified -- removing the stamping line
# does not fail 102). Only a real daemon launch exercises it, so it is asserted
# here. Drive --start directly with a KNOWN id rather than going through
# --provision, which starts and stops in one shot and leaves nothing to inspect.
_PROV_ID="acceptance-$$-$(date -u +%s)"
SANDY_PROVISION=1 SANDY_PROVISION_ID="$_PROV_ID" \
    "$SANDY" --start --workspace "$WS" >/dev/null 2>&1 || true
_PC="$(cid)"
ck "a provisioned --start produced a container" "[ -n \"$_PC\" ]"
if [ -n "$_PC" ]; then
    _GOT="$(docker inspect -f '{{ index .Config.Labels "sandy.provision_id" }}' "$_PC" 2>/dev/null || true)"
    _AT="$(docker inspect -f '{{ index .Config.Labels "sandy.provisioned_at" }}' "$_PC" 2>/dev/null || true)"
    ck "sandy.provision_id equals the id passed in (ownership, not just presence)" \
        "[ \"$_GOT\" = \"$_PROV_ID\" ]"
    # provisioned_at stays a PURE ISO timestamp -- identity lives in its own
    # label precisely so this one never has to carry two meanings.
    ck "sandy.provisioned_at is still a plain ISO-8601 timestamp" \
        "printf '%s' \"$_AT\" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'"
fi
"$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true

echo "== 7. a plain --start (no SANDY_PROVISION) carries NO provision_id =="
"$SANDY" --start --workspace "$WS" >/dev/null 2>&1 || true
_PC2="$(cid)"
if [ -n "$_PC2" ]; then
    _GOT2="$(docker inspect -f '{{ index .Config.Labels "sandy.provision_id" }}' "$_PC2" 2>/dev/null || true)"
    ck "an unprovisioned session has an empty sandy.provision_id" "[ -z \"$_GOT2\" ]"
fi
"$SANDY" --stop --workspace "$WS" >/dev/null 2>&1 || true

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
