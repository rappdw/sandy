#!/bin/bash
# Focused debug harness for the two failing tests in run-tests.sh.
#
# Usage: bash test/run-failing-tests.sh
#
# This script reproduces tests 13 (protected .bashrc read) and 37 (world-open
# LAN allowlist) in isolation with EXTENSIVE diagnostic output so we can figure
# out WHY they fail. Intentionally does NOT use `set -e` — we want to see every
# failure, not abort on the first one.

set -uo pipefail

IMAGE_NAME="sandy-claude-code"
SANDY_HOME="${SANDY_HOME:-$HOME/.sandy}"

cd "$(dirname "$0")/.."
SANDY_BIN="$(pwd)/sandy"

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Error: $IMAGE_NAME image not found. Run sandy once to build it." >&2
    exit 1
fi

# --- Pretty-print helpers ---

C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_CYAN=$'\033[0;36m'
C_YELLOW=$'\033[0;33m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

log()  { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
hdr()  { printf '\n%s%s=== %s ===%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }
pass() { printf '%s  PASS %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
fail() { printf '%s  FAIL %s%s\n' "$C_RED" "$*" "$C_RESET"; }
warn() { printf '%s  WARN %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

# --- Sandbox setup ---

SANDBOX_DIR="$(mktemp -d)"
mkdir -p "$SANDBOX_DIR"/{pip,uv,npm-global,go,cargo}
echo '{}' > "$SANDBOX_DIR/settings.json"

TEST_PROJECT=""
_cleanup() {
    rm -rf "$SANDBOX_DIR" 2>/dev/null || true
    [ -n "${TEST_PROJECT:-}" ] && rm -rf "$TEST_PROJECT" 2>/dev/null || true
}
trap _cleanup EXIT

fresh_project() {
    [ -n "${TEST_PROJECT:-}" ] && rm -rf "$TEST_PROJECT"
    TEST_PROJECT="$(mktemp -d)"
    log "  TEST_PROJECT=$TEST_PROJECT"
}

log "Setup:"
log "  SANDBOX_DIR=$SANDBOX_DIR"
log "  IMAGE_NAME=$IMAGE_NAME"
log "  SANDY_BIN=$SANDY_BIN"
log "  uname=$(uname -a)"
log "  docker server version: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
log "  docker server os type: $(docker version --format '{{.Server.Os}}' 2>/dev/null || echo '?')"
log "  docker info storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null || echo '?')"

# --- Host-side file describe ---

md5_host() {
    if command -v md5sum &>/dev/null; then
        md5sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v md5 &>/dev/null; then
        md5 -q "$1" 2>/dev/null
    else
        echo '?'
    fi
}

host_describe() {
    local f="$1"
    printf '    host path:     %s\n' "$f"
    if [ -e "$f" ]; then
        printf '    host exists:   yes\n'
        printf '    host size:     %s bytes\n' "$(wc -c < "$f" | tr -d ' ')"
        printf '    host inode:    %s\n' "$(ls -i "$f" 2>/dev/null | awk '{print $1}')"
        local _mtime
        _mtime="$(stat -f '%Sm' "$f" 2>/dev/null || stat -c '%y' "$f" 2>/dev/null || echo '?')"
        printf '    host mtime:    %s\n' "$_mtime"
        printf '    host md5:      %s\n' "$(md5_host "$f")"
        printf '    host content:  '
        cat "$f" | tr '\n' ' ' | head -c 80
        printf '\n'
    else
        printf '    host exists:   NO\n'
    fi
}

# --- Container-side diagnostic runner ---
#
# Mirrors sandy_run's mount layout with the SAME --print-protected-paths
# overlay loop. Takes three args:
#   $1 description (for logging)
#   $2 pre_create: "yes" = create empty stubs for missing files, "no" = skip
#   $3 inline command to run inside container
debug_container_run() {
    local _desc="$1" _precreate="$2" _cmd="$3"
    local _ro_mounts=()

    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        local _kind="${_line%%:*}" _p="${_line#*:}"
        case "$_kind" in
            file)
                if [ ! -e "$TEST_PROJECT/$_p" ]; then
                    if [ "$_precreate" = "yes" ]; then
                        mkdir -p "$(dirname "$TEST_PROJECT/$_p")"
                        : > "$TEST_PROJECT/$_p"
                    else
                        continue
                    fi
                fi
                _ro_mounts+=(-v "$TEST_PROJECT/$_p:/workspace/$_p:ro")
                ;;
            gitfile)
                [ -f "$TEST_PROJECT/$_p" ] && _ro_mounts+=(-v "$TEST_PROJECT/$_p:/workspace/$_p:ro")
                ;;
            dir)
                if [ ! -d "$TEST_PROJECT/$_p" ]; then
                    if [ "$_precreate" = "yes" ]; then
                        mkdir -p "$TEST_PROJECT/$_p"
                    else
                        continue
                    fi
                fi
                _ro_mounts+=(-v "$TEST_PROJECT/$_p:/workspace/$_p:ro")
                ;;
        esac
    done < <(SANDY_ALLOW_WORKFLOW_EDIT=0 "$SANDY_BIN" --print-protected-paths 2>/dev/null)

    docker run --rm \
        --read-only \
        --tmpfs /tmp:exec,size=64M \
        --tmpfs /home/claude:exec,size=64M,uid=1001,gid=1001 \
        -v "$SANDBOX_DIR:/home/claude/.claude" \
        -v "$SANDBOX_DIR/pip:/home/claude/.pip-packages" \
        -v "$SANDBOX_DIR/uv:/home/claude/.local/share/uv" \
        -v "$SANDBOX_DIR/npm-global:/home/claude/.npm-global" \
        -v "$SANDBOX_DIR/go:/home/claude/go" \
        -v "$SANDBOX_DIR/cargo:/home/claude/.cargo" \
        -v "$TEST_PROJECT:/workspace" \
        ${_ro_mounts[@]+"${_ro_mounts[@]}"} \
        -w /workspace \
        -e SANDY_WORKSPACE=/workspace \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -e DEBUG_CMD="$_cmd" \
        --entrypoint bash \
        "$IMAGE_NAME" \
        -c '
            RUN_UID=${HOST_UID:-1001}
            RUN_GID=${HOST_GID:-1001}
            chown "$RUN_UID:$RUN_GID" /home/claude 2>/dev/null || true
            exec gosu "$RUN_UID:$RUN_GID" bash -c "
                export HOME=/home/claude
                eval \"\$DEBUG_CMD\"
            "
        ' 2>&1
}

# Shared container-side probe command — a heredoc stored in a variable so all
# variants run the same diagnostic code.
read -r -d '' PROBE <<'PROBESH' || true
echo "--- ls -la /workspace/.bashrc ---"
ls -la /workspace/.bashrc 2>&1
echo "--- stat /workspace/.bashrc ---"
stat /workspace/.bashrc 2>&1
echo "--- wc -c ---"
wc -c /workspace/.bashrc 2>&1
echo "--- md5sum ---"
md5sum /workspace/.bashrc 2>&1
echo "--- od -c (first 200 bytes) ---"
od -c /workspace/.bashrc 2>&1 | head -20
echo "--- cat ---"
cat /workspace/.bashrc 2>&1
echo ""
echo "--- grep test ---"
if cat /workspace/.bashrc | grep -q "host bashrc"; then
    echo "GREP_RESULT=PASS"
else
    echo "GREP_RESULT=FAIL"
fi
echo "--- mount | grep workspace ---"
mount 2>&1 | grep workspace || echo "(no matches)"
PROBESH

# ============================================================
hdr "TEST 13 DEBUG — read protected .bashrc"
# ============================================================

# ====================================================================
# Variant A: fresh project, write .bashrc, container reads it.
# This is the CONTROL — no prior container activity against this dir.
# If this fails, the problem is NOT a cache issue — it's something
# fundamental with the mount or the read.
# ====================================================================
hdr "Variant A — CONTROL: fresh project, no prior container activity"
fresh_project
echo "# host bashrc" > "$TEST_PROJECT/.bashrc"

log "Host state after echo >:"
host_describe "$TEST_PROJECT/.bashrc"

log "Container reads (pre_create=yes, same as sandy_run):"
debug_container_run "variantA" "yes" "$PROBE" | sed 's/^/    /'

# ====================================================================
# Variant B: simulates run-tests.sh flow — pre-create empty stub,
# prime the cache with a container read, then plain echo > over it.
# ====================================================================
hdr "Variant B — pre-create stub, prime cache, plain echo >"
fresh_project
: > "$TEST_PROJECT/.bashrc"
log "Primed empty stub:"
host_describe "$TEST_PROJECT/.bashrc"

log "Priming container read (should see empty):"
debug_container_run "prime-B" "yes" 'wc -c /workspace/.bashrc; cat /workspace/.bashrc | od -c | head -5' | sed 's/^/    /'

log "Now echo > .bashrc on host:"
echo "# host bashrc" > "$TEST_PROJECT/.bashrc"
host_describe "$TEST_PROJECT/.bashrc"

log "Second container read (test 13 behavior):"
debug_container_run "variantB" "yes" "$PROBE" | sed 's/^/    /'

# ====================================================================
# Variant C: prime, then rm -f + echo > (fresh inode via unlink-create)
# ====================================================================
hdr "Variant C — pre-create stub, prime, rm -f + echo >"
fresh_project
: > "$TEST_PROJECT/.bashrc"
debug_container_run "prime-C" "yes" 'wc -c /workspace/.bashrc' >/dev/null 2>&1 || true

rm -f "$TEST_PROJECT/.bashrc"
echo "# host bashrc" > "$TEST_PROJECT/.bashrc"
log "Host state after rm+echo:"
host_describe "$TEST_PROJECT/.bashrc"

log "Container read after rm+echo:"
debug_container_run "variantC" "yes" "$PROBE" | sed 's/^/    /'

# ====================================================================
# Variant D: prime, then echo > .new + mv (atomic rename — current run-tests.sh)
# ====================================================================
hdr "Variant D — pre-create stub, prime, echo > .new + mv (atomic rename)"
fresh_project
: > "$TEST_PROJECT/.bashrc"
debug_container_run "prime-D" "yes" 'wc -c /workspace/.bashrc' >/dev/null 2>&1 || true

echo "# host bashrc" > "$TEST_PROJECT/.bashrc.new"
mv "$TEST_PROJECT/.bashrc.new" "$TEST_PROJECT/.bashrc"
log "Host state after mv:"
host_describe "$TEST_PROJECT/.bashrc"

log "Container read after mv:"
debug_container_run "variantD" "yes" "$PROBE" | sed 's/^/    /'

# ====================================================================
# Variant E: don't pre-create at all — existence-gated mount only
# ====================================================================
hdr "Variant E — NO pre-create anywhere (existence-gated sandy_run)"
fresh_project
echo "# host bashrc" > "$TEST_PROJECT/.bashrc"
log "Host state:"
host_describe "$TEST_PROJECT/.bashrc"

log "Container read (pre_create=no):"
debug_container_run "variantE" "no" "$PROBE" | sed 's/^/    /'

# ====================================================================
# Variant F: fresh project mid-flight, skip pre-create to isolate
# ====================================================================
hdr "Variant F — prime in old project, switch to FRESH project with content"
fresh_project
: > "$TEST_PROJECT/.bashrc"
debug_container_run "prime-F" "yes" 'wc -c /workspace/.bashrc' >/dev/null 2>&1 || true
log "Primed old project: $TEST_PROJECT"

# New project — different inode, different path
OLD_PROJECT="$TEST_PROJECT"
fresh_project
log "Switched to: $TEST_PROJECT"
echo "# host bashrc" > "$TEST_PROJECT/.bashrc"
host_describe "$TEST_PROJECT/.bashrc"

log "Container read from fresh project:"
debug_container_run "variantF" "yes" "$PROBE" | sed 's/^/    /'
rm -rf "$OLD_PROJECT"

# ============================================================
hdr "TEST 37 DEBUG — world-open LAN allowlist rejected"
# ============================================================

_LOADER_SRC="$(mktemp)"
sed -n '/^_load_sandy_config() {/,/^}$/p' "$SANDY_BIN" > "$_LOADER_SRC"
log "Extracted _load_sandy_config to $_LOADER_SRC ($(wc -l < "$_LOADER_SRC") lines)"

_TMP_SANDY_HOME="$(mktemp -d)"
cat > "$_TMP_SANDY_HOME/config" <<'EOFCFG'
SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0
EOFCFG
log "Temp config written:"
cat "$_TMP_SANDY_HOME/config" | sed 's/^/    /'

log "Running test 37 subshell:"
_LAN_RESULT="$(
    set +e
    source "$_LOADER_SRC"
    warn() { :; }
    error() { echo "ERROR: $*" >&2; }
    _load_sandy_config "$_TMP_SANDY_HOME/config" privileged 2>/dev/null || true
    echo "DEBUG: loaded SANDY_ALLOW_LAN_HOSTS=${SANDY_ALLOW_LAN_HOSTS:-UNSET}" >&2
    if [ -n "${SANDY_ALLOW_LAN_HOSTS:-}" ]; then
        IFS=',' read -ra _sanity_hosts <<< "$SANDY_ALLOW_LAN_HOSTS"
        set +u
        for _h in "${_sanity_hosts[@]}"; do
            _h="$(echo "$_h" | tr -d "[:space:]")"
            [ -z "$_h" ] && continue
            if [ "x$_h" = "x0.0.0.0/0" ]; then
                echo "REJECTED:$_h"
                exit 0
            fi
            if [ "x$_h" = "x::/0" ]; then
                echo "REJECTED:$_h"
                exit 0
            fi
        done
        set -u
    fi
    echo "ACCEPTED"
)" || log "Subshell exit status: $?"
log "Result: '$_LAN_RESULT'"
if echo "$_LAN_RESULT" | grep -q "^REJECTED:0.0.0.0/0$"; then
    pass "test 37: world-open rejected"
else
    fail "test 37: world-open rejected (got: '$_LAN_RESULT')"
fi

rm -rf "$_TMP_SANDY_HOME"
rm -f "$_LOADER_SRC"

hdr "Done"
log "Inspect the Variant output above to see which cache-bust strategy works."
log "Look for 'GREP_RESULT=PASS' in each variant."
