#!/usr/bin/env bash
# End-to-end fleet-update acceptance (#41, milestone 1.2.0) — the sandy-ui /
# cron target scenario for `sandy --update-sessions`.
#
# ⚠️ RUN ON A HOST WITH DOCKER. This cannot run inside sandy (no Docker). It is
# the release-readiness gate for the 1.2.0 fleet-update feature: run-tests.sh
# §71 covers structure/contract behind a stubbed docker, but ONLY this proves
# a real rolling restart works end to end — two real daemon sessions, a real
# `--rebuild`-forced image refresh, real `--stop` + `--start` child processes,
# new container IDs, and the sandy.updated_at label landing on the resurrected
# containers. Prints PASS/FAIL per assertion; exits non-zero if any FAIL.
#
#   Usage:  bash test/acceptance-update-sessions.sh          # uses ./sandy
#           SANDY=/path/to/sandy bash test/acceptance-update-sessions.sh
set -uo pipefail

SANDY="${SANDY:-./sandy}"
SANDY_HOME_DIR="${SANDY_HOME:-$HOME/.sandy}"
WSBASE="$(mktemp -d)/update-accept-$$"
WS1="$WSBASE/one"
WS2="$WSBASE/two"
mkdir -p "$WS1" "$WS2"
(cd "$WS1" && git init -q)
(cd "$WS2" && git init -q)
# Canonicalize exactly like sandy does (pwd -P) — see acceptance-daemon.sh
# for why this matters (macOS mktemp under a /var symlink).
WS1="$(cd "$WS1" && pwd -P)"
WS2="$(cd "$WS2" && pwd -P)"
PASS=0; FAIL=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1));
       else printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
cid_for() { docker ps -q --filter label=sandy.daemon=true --filter "label=sandy.workspace_path=$1" 2>/dev/null | head -1; }
cleanup_ws() {
    "$SANDY" --stop --workspace "$WS1" >/dev/null 2>&1 || true
    "$SANDY" --stop --workspace "$WS2" >/dev/null 2>&1 || true
    rm -rf "$WSBASE"
}
trap cleanup_ws EXIT

command -v docker >/dev/null 2>&1 || { echo "docker not found — run this on the host"; exit 2; }

echo "== 1. sandy --start two scratch-workspace sessions =="
"$SANDY" --start --workspace "$WS1"; ck "session 1 --start exits 0" "[ $? -eq 0 ]"
"$SANDY" --start --workspace "$WS2"; ck "session 2 --start exits 0" "[ $? -eq 0 ]"
C1="$(cid_for "$WS1")"
C2="$(cid_for "$WS2")"
ck "session 1 container is running" "[ -n \"$C1\" ]"
ck "session 2 container is running" "[ -n \"$C2\" ]"
ck "session 1 inner tmux session exists" "docker exec -u \"$(id -u)\" \"$C1\" tmux has-session -t sandy"
ck "session 2 inner tmux session exists" "docker exec -u \"$(id -u)\" \"$C2\" tmux has-session -t sandy"

# ⚠️ EVERY --update-sessions call below is SCOPED with --workspace. Unscoped,
# the command operates on EVERY daemon session on the host (that's its job) —
# an early version of this harness ran it unscoped and would have force-
# rebuilt and rolling-restarted the operator's real production sessions in
# step 3. Output is tee'd, not swallowed: per-workspace image refresh can
# legitimately take minutes (e.g. a project-image migration rebuild), and
# silence reads as a hang.
echo "== 2. scoped --update-sessions --dry-run per workspace — both current, no restarts =="
DRY_OUT="$(mktemp)"
"$SANDY" --update-sessions --dry-run --workspace "$WS1" 2>&1 | tee "$DRY_OUT"; DRY_RC=${PIPESTATUS[0]}
ck "ws1 --dry-run exits 0" "[ $DRY_RC -eq 0 ]"
ck "ws1 --dry-run scoped to exactly ONE session" "grep -q 'Found 1 daemon session(s) (scoped to' '$DRY_OUT'"
ck "ws1 --dry-run reports no restart candidates (just built, current)" \
    "grep -q 'no sessions restarted (0 restart candidate' '$DRY_OUT'"
"$SANDY" --update-sessions --dry-run --workspace "$WS2" 2>&1 | tee "$DRY_OUT"; DRY_RC=${PIPESTATUS[0]}
ck "ws2 --dry-run exits 0" "[ $DRY_RC -eq 0 ]"
ck "ws2 --dry-run reports no restart candidates" \
    "grep -q 'no sessions restarted (0 restart candidate' '$DRY_OUT'"
C1_AFTER_DRY="$(cid_for "$WS1")"
C2_AFTER_DRY="$(cid_for "$WS2")"
ck "session 1 container UNCHANGED by dry-run" "[ \"$C1\" = \"$C1_AFTER_DRY\" ]"
ck "session 2 container UNCHANGED by dry-run" "[ \"$C2\" = \"$C2_AFTER_DRY\" ]"
rm -f "$DRY_OUT"

echo "== 3. ws1: --rebuild --yes (forced staleness) → restart =="
UPD_OUT="$(mktemp)"
T0=$(date +%s)
"$SANDY" --update-sessions --rebuild --yes --workspace "$WS1" 2>&1 | tee "$UPD_OUT"; UPD_RC=${PIPESTATUS[0]}
T1=$(date +%s)
ck "ws1 --rebuild --yes exits 0" "[ $UPD_RC -eq 0 ]"
ck "ws1 plan showed it as a restart candidate (--rebuild forces staleness)" \
    "grep -q 'restart (stale)' '$UPD_OUT'"
ck "ws1 summary reports 1 restarted, 0 failed" \
    "grep -q '^Restarted: 1$' '$UPD_OUT' && grep -q '^Failed: 0$' '$UPD_OUT'"
echo "  (ws1 rebuild+restart took $((T1 - T0))s total)"

echo "== 3b. ws2: --yes with NO --rebuild — ORGANIC staleness (image moved under it in step 3) =="
T0=$(date +%s)
"$SANDY" --update-sessions --yes --workspace "$WS2" 2>&1 | tee "$UPD_OUT"; UPD_RC=${PIPESTATUS[0]}
T1=$(date +%s)
ck "ws2 --yes exits 0" "[ $UPD_RC -eq 0 ]"
ck "ws2 detected ORGANIC staleness (container predates ws1's rebuild of the shared image)" \
    "grep -q 'restart (stale)' '$UPD_OUT'"
ck "ws2 summary reports 1 restarted, 0 failed" \
    "grep -q '^Restarted: 1$' '$UPD_OUT' && grep -q '^Failed: 0$' '$UPD_OUT'"
echo "  (ws2 restart took $((T1 - T0))s total)"

C1_NEW="$(cid_for "$WS1")"
C2_NEW="$(cid_for "$WS2")"
ck "session 1 got a NEW container id (was $C1)" "[ -n \"$C1_NEW\" ] && [ \"$C1_NEW\" != \"$C1\" ]"
ck "session 2 got a NEW container id (was $C2)" "[ -n \"$C2_NEW\" ] && [ \"$C2_NEW\" != \"$C2\" ]"
ck "session 1 inner tmux session is up post-restart (exec -u)" \
    "docker exec -u \"$(id -u)\" \"$C1_NEW\" tmux has-session -t sandy"
ck "session 2 inner tmux session is up post-restart (exec -u)" \
    "docker exec -u \"$(id -u)\" \"$C2_NEW\" tmux has-session -t sandy"

echo "== 3c. DEC-U3 — sandy.updated_at label present on both restarted containers =="
L1="$(docker inspect -f '{{ index .Config.Labels "sandy.updated_at" }}' "$C1_NEW" 2>/dev/null)"
L2="$(docker inspect -f '{{ index .Config.Labels "sandy.updated_at" }}' "$C2_NEW" 2>/dev/null)"
ck "session 1 carries a non-empty sandy.updated_at label ($L1)" "[ -n \"$L1\" ]"
ck "session 2 carries a non-empty sandy.updated_at label ($L2)" "[ -n \"$L2\" ]"
rm -f "$UPD_OUT"

echo "== 4. --print-state full: both entries image_stale:false post-restart; join intact =="
STATE_JSON="$("$SANDY" --print-state)"
python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['schema_version'] == 1, d['schema_version']
rc = d['running_containers']
def find(cid):
    for c in rc:
        if c['id'].startswith(cid[:12]) or cid.startswith(c['id'][:12]):
            return c
    return None
c1 = find(sys.argv[2])
c2 = find(sys.argv[3])
assert c1 is not None, 'session 1 not in running_containers'
assert c2 is not None, 'session 2 not in running_containers'
assert c1['image_stale'] is False, ('session1 image_stale', c1)
assert c2['image_stale'] is False, ('session2 image_stale', c2)
assert c1['daemon'] is True and c2['daemon'] is True, (c1, c2)
" "$STATE_JSON" "$C1_NEW" "$C2_NEW" \
    && ck "print-state: image_stale:false + daemon:true for both post-restart sessions" "true" \
    || ck "print-state: image_stale:false + daemon:true for both post-restart sessions" "false"

echo "== 5. sandy --stop both — everything gone =="
"$SANDY" --stop --workspace "$WS1"; ck "session 1 --stop exits 0" "[ $? -eq 0 ]"
"$SANDY" --stop --workspace "$WS2"; ck "session 2 --stop exits 0" "[ $? -eq 0 ]"
sleep 2
ck "session 1 container is GONE" "[ -z \"$(cid_for "$WS1")\" ]"
ck "session 2 container is GONE" "[ -z \"$(cid_for "$WS2")\" ]"
ck "--stop again on session 1 → no-such-session exit 4" "\"$SANDY\" --stop --workspace \"$WS1\"; [ \$? -eq 4 ]"
ck "--stop again on session 2 → no-such-session exit 4" "\"$SANDY\" --stop --workspace \"$WS2\"; [ \$? -eq 4 ]"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
