#!/usr/bin/env bash
# test/lib-isolated-home.sh — give an acceptance harness its own $SANDY_HOME,
# so real container runs never write fixture sandboxes into the developer's
# state. Sourced, not executed.
#
# WHY. The acceptance harnesses launch real containers through the real sandy,
# which materializes a sandbox under $SANDY_HOME/sandboxes/. They name their
# workspaces with $$, so every run leaves a fresh set behind, and the workspace
# is a temp dir that is gone by the time anyone looks. A fleet consumer read
# 48 sandboxes where 14 were theirs: 34 were fixtures from ten separate runs.
#
# That matters beyond disk. --print-state IS the fleet API, and a fixture is
# indistinguishable from a real sandbox to every consumer of it: nothing marks
# it as a test artifact, so an operator scanning for the sandbox they mean
# reads past three dozen that do not exist any more, and a policy with a
# catch-all auto-enroll profile would enroll all of them.
#
# Teardown is the weaker fix and is why this exists instead: a killed run
# leaks, which is exactly how ten runs' worth accumulated. An isolated home
# means nothing lands in the developer's state in the first place, so there is
# no window in which a fleet tool can see a fixture and no dependence on
# cleanup actually running.
#
# WHY THE BUILD CACHE IS SEEDED. The image build gate reads
#
#     if [ ! -f "$HASH_FILE" ] || [ "$(cat "$HASH_FILE")" != "$HASH" ] || ! docker image inspect ...
#
# and the MISSING-FILE test comes first, so a bare `mktemp -d` home rebuilds
# every image — `--no-cache --pull` on the base — on every single run, even
# when the image already exists and is current. Seeding the Dockerfiles and
# hash files keeps the isolation free: sandy compares a matching hash against
# an existing image and reports "up to date". Only the STATEFUL parts
# (sandboxes/, approvals/) are left behind, which are the parts that leak.

# Redirect $SANDY_HOME at a fresh temp dir seeded with the real one's build
# cache. Sets _ISOLATED_SANDY_HOME for the matching cleanup.
_isolate_sandy_home() {
    local _real="${SANDY_HOME:-$HOME/.sandy}" _f
    _ISOLATED_SANDY_HOME="$(mktemp -d "${TMPDIR:-/tmp}/sandy-test-home.XXXXXX")" || return 1
    if [ -d "$_real" ]; then
        # Build cache only. Deliberately NOT sandboxes/ or approvals/: copying
        # those would reintroduce the developer's state into the run, and an
        # approval copied in would let a fixture inherit a decision made for a
        # real workspace.
        for _f in "$_real"/Dockerfile* "$_real"/.base_build_hash "$_real"/.build_hash* \
                  "$_real"/.skills_build_hash "$_real"/.skills_base_build_hash \
                  "$_real"/.skill_version_*; do
            [ -f "$_f" ] && cp -p "$_f" "$_ISOLATED_SANDY_HOME/" 2>/dev/null
        done
    fi
    export SANDY_HOME="$_ISOLATED_SANDY_HOME"
    printf '[isolated-home] SANDY_HOME=%s (build cache seeded from %s)\n' \
        "$_ISOLATED_SANDY_HOME" "$_real" >&2
}

# Remove the isolated home. Call from the harness's existing EXIT trap.
_cleanup_sandy_home() {
    [ -n "${_ISOLATED_SANDY_HOME:-}" ] || return 0
    # Containment assert at the point of use, not just where the path was
    # built: this is an rm -rf, and the check belongs where the damage would
    # happen. Refuse anything that is not a sandy-test-home.* temp directory.
    case "$(basename "$_ISOLATED_SANDY_HOME")" in
        sandy-test-home.*) ;;
        *) printf '[isolated-home] REFUSING to remove unexpected path: %s\n' \
               "$_ISOLATED_SANDY_HOME" >&2; return 1 ;;
    esac
    [ -d "$_ISOLATED_SANDY_HOME" ] || return 0
    rm -rf "$_ISOLATED_SANDY_HOME"
    unset _ISOLATED_SANDY_HOME
}
