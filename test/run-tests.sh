#!/bin/bash
# Integration tests for sandy container environments.
# Requires: docker, sandy images already built (run `sandy` once first).
#
# Usage: ./test/run-tests.sh
set -euo pipefail

# Auto-approve passive privileged keys (e.g. a workspace .sandy/.secrets
# with GEMINI_API_KEY) so the per-workspace approval prompt doesn't block
# non-interactive test runs. Env-only knob — a committed .sandy/config
# cannot set it. See _resolve_passive_privileged_approval() in sandy.
export SANDY_AUTO_APPROVE_PRIVILEGED=1

IMAGE_NAME="sandy-claude-code"
SANDY_HOME="${SANDY_HOME:-$HOME/.sandy}"
PASS=0
FAIL=0
ERRORS=()
COMPLETED=false

# Guarantee we always print a summary, even if `set -euo pipefail` aborts the
# script mid-run (e.g. a bare pipeline with a failing grep). Without this, an
# early-terminating test would exit silently and the user would have no idea
# how far the suite got. The trap is overwritten by setup_sandbox to also
# clean up temp dirs; that wrapper also calls this function.
_emit_summary() {
    local code=$?
    # Reset terminal keypad to numeric mode (DECKPNM). Something in the suite
    # — likely a `docker run` that transiently drops a tmux/claude TUI into
    # application mode (DECKPAM, ESC =) — can leave the host terminal in a
    # state where up-arrow sends SS3 (ESC O A) instead of CSI (ESC [ A). If
    # zsh's ESC-timeout eats the lead byte, literal "OA" lands on the prompt
    # and the user sees `command not found: OA` on their next keystroke.
    # Unconditionally resetting here is cheap and safe.
    printf '\033>' 2>/dev/null || true
    command -v tput >/dev/null 2>&1 && tput rmkx 2>/dev/null || true
    # Only fire the abort banner when the script died mid-suite, i.e. at
    # least one test has already run. Legitimate early exits (preflight
    # "image not found", --help, etc.) leave PASS+FAIL at 0 and print their
    # own error — we must not drown them in a misleading banner.
    if [ "$COMPLETED" = false ] && [ "$((PASS + FAIL))" -gt 0 ]; then
        echo ""
        printf "\033[0;31m✗ test suite aborted early (exit=%d)\033[0m\n" "$code" >&2
        printf "\033[0;33mPartial results: %d passed, %d failed (of %d run so far)\033[0m\n" \
            "$PASS" "$FAIL" "$((PASS + FAIL))" >&2
        if [ "${#ERRORS[@]}" -gt 0 ]; then
            printf "\033[0;31mRecorded failures:\033[0m\n" >&2
            for e in "${ERRORS[@]}"; do
                printf "  \033[0;31m- %s\033[0m\n" "$e" >&2
            done
        fi
        printf "\033[0;33mHint: a command likely exited non-zero under 'set -euo pipefail'. Check just above the last printed test for an unguarded pipeline or missing '|| true'.\033[0m\n" >&2
    fi
}
trap _emit_summary EXIT

# When `set -e` aborts the script, bash fires an ERR pseudo-signal on the
# failing command. We use this to print the line number and the command that
# tripped the abort. Without this, an early exit leaves only the abort banner
# and the user has to bisect by hand. The trap is a one-liner that re-enters
# bash semantics: $LINENO is the failing line, $BASH_COMMAND is the command.
_err_trap() {
    local code=$?
    printf "\033[0;31m[err-trap] line %d: '%s' exited %d\033[0m\n" \
        "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" "$code" >&2
}
trap _err_trap ERR
# errtrace: make the ERR trap fire inside shell functions too. Without this,
# a failing command inside sandy_run() would just propagate out as a non-zero
# return and set -e would abort with no location info.
set -E

# --- Helpers ---

info()  { printf "\033[0;36m%s\033[0m\n" "$*"; }
pass()  { PASS=$((PASS + 1)); printf "  \033[0;32m✓ %s\033[0m\n" "$*"; }
fail()  { FAIL=$((FAIL + 1)); ERRORS+=("$*"); printf "  \033[0;31m✗ %s\033[0m\n" "$*"; }
check() {
    # check "description" <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# Create a temp sandbox with persistent mount dirs
setup_sandbox() {
    SANDBOX_DIR="$(mktemp -d)"
    mkdir -p "$SANDBOX_DIR"/{pip,uv,npm-global,go,cargo}
    # Minimal sandbox — needs a settings.json for claude to not error
    echo '{}' > "$SANDBOX_DIR/settings.json"
    trap cleanup EXIT
}

cleanup() {
    _emit_summary
    rm -rf "$SANDBOX_DIR" "$TEST_PROJECT" 2>/dev/null || true
}

# Create a temp project directory to mount as workspace
setup_project() {
    TEST_PROJECT="$(mktemp -d)"
}

# Run a command inside the sandy container with the test sandbox.
# The entrypoint runs as root, drops to user, sets up PATH/envs, then
# execs our command instead of launching claude.
sandy_run() {
    # Build protected-path overlays using sandy's shared-source helper
    # (--print-protected-paths), so the test harness never drifts from the
    # real launcher.
    #
    # File mounts are existence-gated — matching sandy's production behavior.
    # An earlier always-mount-with-empty-fixture policy caused Docker to create
    # 0-byte stubs on the host for every missing protected file (Docker auto-
    # creates bind-mount targets, and the target lives inside the rw workspace
    # bind). That broke direnv and polluted `git status`; see the comment block
    # in sandy where the protected-files loop runs. Tests assert the agent can
    # still write absent files — the mitigation is host-side visibility in
    # `git status`, not prevention.
    local _ro_mounts=()
    local _sandy_bin
    _sandy_bin="$(cd "$(dirname "$0")/.." && pwd)/sandy"
    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        local _kind="${_line%%:*}" _p="${_line#*:}"
        case "$_kind" in
            file)
                # Existence-gated in production sandy; same here — no pre-create.
                [ -e "$TEST_PROJECT/$_p" ] && _ro_mounts+=(-v "$TEST_PROJECT/$_p:/workspace/$_p:ro")
                ;;
            gitfile)
                # Existence-gated in production sandy; same here — no pre-create.
                [ -f "$TEST_PROJECT/$_p" ] && _ro_mounts+=(-v "$TEST_PROJECT/$_p:/workspace/$_p:ro")
                ;;
            dir)
                if [ ! -d "$TEST_PROJECT/$_p" ]; then
                    mkdir -p "$TEST_PROJECT/$_p"
                fi
                _ro_mounts+=(-v "$TEST_PROJECT/$_p:/workspace/$_p:ro")
                ;;
        esac
    done < <(SANDY_ALLOW_WORKFLOW_EDIT="${SANDY_ALLOW_WORKFLOW_EDIT:-0}" \
                "$_sandy_bin" --print-protected-paths 2>/dev/null)
    # Mirror _protect_submodule_gitdirs from the sandy launcher: for every
    # $TEST_PROJECT/.git/modules/<sub>/config sentinel, mount config/hooks/info
    # ro at the matching container path. Only runs if .git/modules exists —
    # test 34 creates a fake submodule gitdir layout to exercise this.
    if [ -d "$TEST_PROJECT/.git/modules" ]; then
        while IFS= read -r -d '' _cfg; do
            local _sub_dir _rel
            _sub_dir="$(dirname "$_cfg")"
            _rel="${_sub_dir#$TEST_PROJECT/.git/modules}"
            _ro_mounts+=(-v "$_sub_dir/config:/workspace/.git/modules${_rel}/config:ro")
            if [ -d "$_sub_dir/hooks" ]; then
                _ro_mounts+=(-v "$_sub_dir/hooks:/workspace/.git/modules${_rel}/hooks:ro")
            fi
            if [ -d "$_sub_dir/info" ]; then
                _ro_mounts+=(-v "$_sub_dir/info:/workspace/.git/modules${_rel}/info:ro")
            fi
        done < <(find "$TEST_PROJECT/.git/modules" -mindepth 1 -maxdepth 6 -type f -name config -print0 2>/dev/null)
    fi
    # Mount sandbox copies of commands, agents, and plugins over workspace
    for _sd in commands agents plugins; do
        if [ -d "$TEST_PROJECT/.claude/$_sd" ] || [ -d "$SANDBOX_DIR/workspace-$_sd" ]; then
            mkdir -p "$SANDBOX_DIR/workspace-$_sd"
            _ro_mounts+=(-v "$SANDBOX_DIR/workspace-$_sd:/workspace/.claude/$_sd")
        fi
    done
    docker run --rm \
        --read-only \
        --tmpfs /tmp:exec,size=256M \
        --tmpfs /home/claude:exec,size=256M,uid=1001,gid=1001 \
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
        -e SANDY_TEST_CMD="$1" \
        --entrypoint bash \
        "$IMAGE_NAME" \
        -c "
            # Replicate the essential entrypoint setup (root phase)
            RUN_UID=\${HOST_UID:-1001}
            RUN_GID=\${HOST_GID:-1001}
            chown \"\$RUN_UID:\$RUN_GID\" /home/claude
            for d in /home/claude/.pip-packages /home/claude/.local/share/uv \
                     /home/claude/.npm-global /home/claude/go /home/claude/.cargo; do
                chown \"\$RUN_UID:\$RUN_GID\" \"\$d\" 2>/dev/null || true
            done
            mkdir -p /home/claude/.local/bin /home/claude/.local/share
            ln -sf /usr/local/bin/claude /home/claude/.local/bin/claude
            ln -sf /opt/claude-code /home/claude/.local/share/claude
            chown \"\$RUN_UID:\$RUN_GID\" /home/claude/.local /home/claude/.local/bin \
                /home/claude/.local/share /home/claude/.local/share/claude 2>/dev/null || true

            # Create pip/pip3 wrappers (base64-encoded to avoid quoting hell)
            echo IyEvYmluL2Jhc2gKaWYgWyAteiAiJFZJUlRVQUxfRU5WIiBdICYmIFsgIiR7MTotfSIgPSAiaW5zdGFsbCIgXTsgdGhlbgogICAgc2hpZnQKICAgIGV4ZWMgcHl0aG9uMyAtbSBwaXAgaW5zdGFsbCAtLXVzZXIgIiRAIgpmaQpleGVjIHB5dGhvbjMgLW0gcGlwICIkQCIK | base64 -d > /home/claude/.local/bin/pip
            cp /home/claude/.local/bin/pip /home/claude/.local/bin/pip3
            chmod +x /home/claude/.local/bin/pip /home/claude/.local/bin/pip3
            chown \"\$RUN_UID:\$RUN_GID\" /home/claude/.local/bin/pip /home/claude/.local/bin/pip3

            # Drop to user and run the test command (passed via env var to
            # avoid quoting issues with nested bash -c single-quoted strings)
            exec gosu \"\$RUN_UID:\$RUN_GID\" bash -c '
                export HOME=/home/claude
                export CARGO_HOME=\"\$HOME/.cargo\"
                mkdir -p \"\$CARGO_HOME/bin\"
                for bin in /usr/local/cargo/bin/*; do
                    ln -sf \"\$bin\" \"\$CARGO_HOME/bin/\$(basename \"\$bin\")\"
                done
                export GOPATH=\"\$HOME/go\"
                mkdir -p \"\$GOPATH/bin\"
                export NPM_CONFIG_PREFIX=\"\$HOME/.npm-global\"
                mkdir -p \"\$NPM_CONFIG_PREFIX/bin\"
                export PIP_BREAK_SYSTEM_PACKAGES=1
                export PYTHONUSERBASE=\"\$HOME/.pip-packages\"
                mkdir -p \"\$PYTHONUSERBASE/bin\"
                export PATH=\"\$HOME/.local/bin:\$PYTHONUSERBASE/bin:\$NPM_CONFIG_PREFIX/bin:\$GOPATH/bin:\$CARGO_HOME/bin:\$PATH\"
                eval \"\$SANDY_TEST_CMD\"
            '
        "
}

# Variant: run two sequential sessions (first writes, second reads)
sandy_run_persist() {
    sandy_run "$1"
    sandy_run "$2"
}

# --- Preflight ---

if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    _sandy_bin="$(cd "$(dirname "$0")/.." && pwd)/sandy"
    echo "Info: $IMAGE_NAME image not found. Building via '$_sandy_bin --build-only'..."
    if ! "$_sandy_bin" --build-only; then
        echo "Error: failed to build $IMAGE_NAME. Run '$_sandy_bin --rebuild' manually to diagnose."
        exit 1
    fi
    if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "Error: $IMAGE_NAME still missing after build. Check '$_sandy_bin --build-only' output."
        exit 1
    fi
fi

setup_sandbox
setup_project

# ============================================================
info "1. Base toolchain availability"
# ============================================================

check "python3 is available"        sandy_run "python3 --version"
check "node is available"           sandy_run "node --version"
check "go is available"             sandy_run "go version"
check "rustc is available"          sandy_run "rustc --version"
check "cargo is available"          sandy_run "cargo --version"
check "uv is available"             sandy_run "uv --version"
check "gcc is available"            sandy_run "gcc --version"
check "git is available"            sandy_run "git --version"

# ============================================================
info "2. Persistent pip installs"
# ============================================================

sandy_run "pip install --quiet cowsay"
check "pip package persists across sessions" \
    sandy_run "python3 -c 'import cowsay; cowsay.cow(\"moo\")'"

# ============================================================
info "3. Persistent npm global installs"
# ============================================================

sandy_run "npm install -g --silent cowsay 2>&1"
check "npm -g package persists across sessions" \
    sandy_run "which cowsay"

# ============================================================
info "4. Persistent go install"
# ============================================================

sandy_run "go install golang.org/x/tools/cmd/goimports@latest 2>&1"
check "go install binary persists across sessions" \
    sandy_run "which goimports"

# ============================================================
info "5. pip installs to venv (not --user) when venv is active"
# ============================================================

check "pip inside venv installs to venv, not --user" \
    sandy_run "
        python3 -m venv /workspace/.venv
        source /workspace/.venv/bin/activate
        pip install --quiet pyjokes
        # Verify it's in the venv, not in PYTHONUSERBASE
        VENV_PKG=\$(find /workspace/.venv -name 'pyjokes' -type d 2>/dev/null | head -1)
        USER_PKG=\$(find \$PYTHONUSERBASE -name 'pyjokes' -type d 2>/dev/null | head -1)
        if [ -n \"\$VENV_PKG\" ] && [ -z \"\$USER_PKG\" ]; then
            exit 0
        else
            echo 'FAIL: pyjokes found in PYTHONUSERBASE or not in venv'
            exit 1
        fi
    "
rm -rf "$TEST_PROJECT/.venv"

# ============================================================
info "6. PATH order"
# ============================================================

ACTUAL_FIRST="$(sandy_run 'echo $PATH' | tr ':' '\n' | head -1)"
check "~/.local/bin is first on PATH" \
    test "$ACTUAL_FIRST" = "/home/claude/.local/bin"

# ============================================================
info "7. Read-only root filesystem"
# ============================================================

sandy_run "touch /usr/test 2>/dev/null" >/dev/null 2>&1 && WRITE_USR=yes || WRITE_USR=no
check "cannot write to /usr" \
    test "$WRITE_USR" = "no"
check "can write to /tmp" \
    sandy_run "touch /tmp/test"
check "can write to home" \
    sandy_run "touch /home/claude/test"

# ============================================================
info "8. Dev environment detection — .python-version auto-install"
# ============================================================

# rm-before-write for the same sshfs stale-inode reason as test 13: earlier
# sandy_run calls may have pre-created an empty .python-version stub and
# cached it in sshfs. `rm -f` + create gives a fresh inode so the container
# reads the new content via `uv python install`.
rm -f "$TEST_PROJECT/.python-version"
echo "3.11" > "$TEST_PROJECT/.python-version"
# Simulate what the entrypoint does: read .python-version, install, verify.
# Guarded with `|| true` because this priming sandy_run runs under `set -e`
# and any non-zero exit (a uv install hiccup, a network flake, a sshfs cache
# issue) would abort the whole suite before the real `check` below gets to
# run. The `check` is the actual gate — if install truly failed, the check
# below will report it cleanly as a test failure, not an abort.
sandy_run '
    PY_WANT="$(cat /workspace/.python-version | tr -d "[:space:]")"
    uv python install "$PY_WANT" 2>/dev/null || true
    uv python find "$PY_WANT" >/dev/null 2>&1 || true
    exit 0
' || true
check ".python-version triggers uv python install" \
    sandy_run "uv python find 3.11 >/dev/null 2>&1"
rm -f "$TEST_PROJECT/.python-version"

# ============================================================
info "9. Workspace .venv overlay — detection and materialization"
# ============================================================

# 9a. Allowlist accepts SANDY_VENV_OVERLAY in .sandy/config.
# v0.12+: the loader depends on SANDY_{PRIVILEGED,PASSIVE,ENV_ONLY}_KEYS arrays
# plus _key_in_list() — source all of them together before invoking the loader.
TMPCFG="$(mktemp -d)"
mkdir -p "$TMPCFG/.sandy"
echo 'SANDY_VENV_OVERLAY=0' > "$TMPCFG/.sandy/config"
_SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"
ALLOWLIST_RESULT="$(bash -c "
    $(sed -n '/^SANDY_PRIVILEGED_KEYS=(/,/^}$/p' "$_SANDY_SCRIPT_PATH")
    $(sed -n '/^_load_sandy_config()/,/^}$/p' "$_SANDY_SCRIPT_PATH")
    _load_sandy_config '$TMPCFG/.sandy/config'
    echo \"\${SANDY_VENV_OVERLAY:-unset}\"
")"
check "SANDY_VENV_OVERLAY in config allowlist" \
    test "$ALLOWLIST_RESULT" = "0"
rm -rf "$TMPCFG"

# 9b. pyvenv.cfg parsing — extract major.minor from `version = X.Y.Z`
VENV_FIXTURE="$(mktemp -d)"
cat > "$VENV_FIXTURE/pyvenv.cfg" <<'EOF'
home = /Users/drapp/.local/share/uv/python/cpython-3.10.16-macos-aarch64-none/bin
implementation = CPython
uv = 0.5.11
version_info = 3.10.16.final.0
include-system-site-packages = false
prompt = myproject
EOF
PARSED_VER="$(grep -E '^version(_info)?[[:space:]]*=' "$VENV_FIXTURE/pyvenv.cfg" \
    | head -1 | sed -E 's/.*=[[:space:]]*//' | cut -d. -f1-2 | tr -d '[:space:]')"
check "pyvenv.cfg version_info parsed as major.minor" \
    test "$PARSED_VER" = "3.10"
rm -rf "$VENV_FIXTURE"

# 9c. pyvenv.cfg parsing — `version = X.Y.Z` form (older virtualenv)
VENV_FIXTURE2="$(mktemp -d)"
cat > "$VENV_FIXTURE2/pyvenv.cfg" <<'EOF'
home = /usr/bin
include-system-site-packages = false
version = 3.11.5
EOF
PARSED_VER2="$(grep -E '^version(_info)?[[:space:]]*=' "$VENV_FIXTURE2/pyvenv.cfg" \
    | head -1 | sed -E 's/.*=[[:space:]]*//' | cut -d. -f1-2 | tr -d '[:space:]')"
check "pyvenv.cfg version parsed as major.minor" \
    test "$PARSED_VER2" = "3.11"
rm -rf "$VENV_FIXTURE2"

# 9d. Malformed pyvenv.cfg → empty version (falls back to default in container)
VENV_FIXTURE3="$(mktemp -d)"
cat > "$VENV_FIXTURE3/pyvenv.cfg" <<'EOF'
home = /usr/bin
include-system-site-packages = false
EOF
PARSED_VER3="$( { grep -E '^version(_info)?[[:space:]]*=' "$VENV_FIXTURE3/pyvenv.cfg" \
    | head -1 | sed -E 's/.*=[[:space:]]*//' | cut -d. -f1-2 | tr -d '[:space:]'; } || true )"
check "malformed pyvenv.cfg yields empty version" \
    test -z "$PARSED_VER3"
rm -rf "$VENV_FIXTURE3"

# 9e. Symlinked .venv is skipped (potential sandbox escape)
SYM_FIXTURE="$(mktemp -d)"
SYM_TARGET="$(mktemp -d)"
mkdir -p "$SYM_TARGET/bin"
ln -s "$SYM_TARGET" "$SYM_FIXTURE/.venv"
# The host-side detection uses [ -d DIR ] && [ ! -L DIR ] — should skip symlinks.
SKIP_RESULT="no"
if [ -d "$SYM_FIXTURE/.venv" ] && [ ! -L "$SYM_FIXTURE/.venv" ]; then
    SKIP_RESULT="no"
else
    SKIP_RESULT="yes"
fi
check "symlinked .venv is skipped by overlay detection" \
    test "$SKIP_RESULT" = "yes"
rm -rf "$SYM_FIXTURE" "$SYM_TARGET"

# 9f. Opt-out via SANDY_VENV_OVERLAY=0 disables detection even when .venv exists
OPTOUT_FIXTURE="$(mktemp -d)"
mkdir -p "$OPTOUT_FIXTURE/.venv"
OPTOUT_ACTIVE=false
SANDY_VENV_OVERLAY=0
if [ "${SANDY_VENV_OVERLAY:-1}" != "0" ] \
   && [ -d "$OPTOUT_FIXTURE/.venv" ] \
   && [ ! -L "$OPTOUT_FIXTURE/.venv" ]; then
    OPTOUT_ACTIVE=true
fi
check "SANDY_VENV_OVERLAY=0 disables overlay detection" \
    test "$OPTOUT_ACTIVE" = "false"
unset SANDY_VENV_OVERLAY
rm -rf "$OPTOUT_FIXTURE"

# 9g. Default (unset) enables detection when .venv exists
DEFAULT_FIXTURE="$(mktemp -d)"
mkdir -p "$DEFAULT_FIXTURE/.venv"
unset SANDY_VENV_OVERLAY
DEFAULT_ACTIVE=false
if [ "${SANDY_VENV_OVERLAY:-1}" != "0" ] \
   && [ -d "$DEFAULT_FIXTURE/.venv" ] \
   && [ ! -L "$DEFAULT_FIXTURE/.venv" ]; then
    DEFAULT_ACTIVE=true
fi
check "overlay default-on when .venv exists" \
    test "$DEFAULT_ACTIVE" = "true"
rm -rf "$DEFAULT_FIXTURE"

# 9h. PR 2.1: .python-version takes precedence over pyvenv.cfg
# Mirror the host-side precedence block: .python-version wins when both present.
PV_FIXTURE="$(mktemp -d)"
mkdir -p "$PV_FIXTURE/.venv"
cat > "$PV_FIXTURE/.venv/pyvenv.cfg" <<'EOF'
version_info = 3.10.16.final.0
EOF
echo "3.12" > "$PV_FIXTURE/.python-version"
# Emulate the same precedence logic from sandy (2213-2224)
if [ -f "$PV_FIXTURE/.python-version" ]; then
    PV_RESULT="$(tr -d '[:space:]' < "$PV_FIXTURE/.python-version" | cut -d. -f1-2)"
elif [ -f "$PV_FIXTURE/.venv/pyvenv.cfg" ]; then
    PV_RESULT="$(grep -E '^version(_info)?[[:space:]]*=' "$PV_FIXTURE/.venv/pyvenv.cfg" \
        | head -1 | sed -E 's/.*=[[:space:]]*//' | cut -d. -f1-2 | tr -d '[:space:]')"
fi
check ".python-version takes precedence over pyvenv.cfg" \
    test "$PV_RESULT" = "3.12"
rm -rf "$PV_FIXTURE"

# 9i. PR 2.1: garbage SANDY_VENV_PYTHON_VERSION rejected by major.minor regex
# Hostside block at sandy:2225-2229 drops non-major.minor values. Simulate it.
VALIDATE() {
    local v="$1"
    if [ -n "$v" ] && [[ ! "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo ""
    else
        echo "$v"
    fi
}
check "validator accepts 3.11" test "$(VALIDATE 3.11)" = "3.11"
check "validator accepts 3.12" test "$(VALIDATE 3.12)" = "3.12"
check "validator rejects 3.10.16"    test -z "$(VALIDATE 3.10.16)"
check "validator rejects 3.10.16.final.0" test -z "$(VALIDATE 3.10.16.final.0)"
check "validator rejects empty" test -z "$(VALIDATE '')"
check "validator rejects shell injection" test -z "$(VALIDATE '3.11; echo pwned')"

# 9j. PR 2.1: symlinked .venv triggers info-message branch (not silent skip)
# The hostside now has an elif that fires info() on symlinked .venv.
# Simulate the branch condition to confirm it would fire.
SYM_INFO_FIXTURE="$(mktemp -d)"
SYM_INFO_TARGET="$(mktemp -d)"
mkdir -p "$SYM_INFO_TARGET"
ln -s "$SYM_INFO_TARGET" "$SYM_INFO_FIXTURE/.venv"
WOULD_FIRE_INFO="no"
if [ "${SANDY_VENV_OVERLAY:-1}" != "0" ] && [ -L "$SYM_INFO_FIXTURE/.venv" ]; then
    WOULD_FIRE_INFO="yes"
fi
check "symlinked .venv fires info message branch" \
    test "$WOULD_FIRE_INFO" = "yes"
# And with opt-out, even symlinked .venv doesn't trigger the info branch.
SANDY_VENV_OVERLAY=0
WOULD_FIRE_INFO_OPTOUT="no"
if [ "${SANDY_VENV_OVERLAY:-1}" != "0" ] && [ -L "$SYM_INFO_FIXTURE/.venv" ]; then
    WOULD_FIRE_INFO_OPTOUT="yes"
fi
check "opt-out suppresses symlink info branch" \
    test "$WOULD_FIRE_INFO_OPTOUT" = "no"
unset SANDY_VENV_OVERLAY
rm -rf "$SYM_INFO_FIXTURE" "$SYM_INFO_TARGET"

# 9k. PR 2.1: materialization block uses uv venv --clear
# The overlay's target is a bind mount (dir always exists), so uv venv
# must be invoked with --clear. Without it, uv refuses with "A directory
# already exists at: .venv" and no venv is ever created.
MATERIALIZE_BLOCK_FILE="$(mktemp)"
awk '/Workspace \.venv overlay\. When SANDY_VENV_OVERLAY_ACTIVE/,/^elif \[ -L "\$WORKSPACE\/\.venv\/bin\/python" \]/' \
    "$_SANDY_SCRIPT_PATH" > "$MATERIALIZE_BLOCK_FILE"
check "materialization uses uv venv --clear" \
    grep -q 'uv venv --clear' "$MATERIALIZE_BLOCK_FILE"
rm -f "$MATERIALIZE_BLOCK_FILE"

# 9l. PR 2.1: workspace mutex prevents concurrent sandy instances
# Only one sandy may run against a given workspace at a time. The lock
# is a `mkdir`-based mutex (atomic, portable, no flock dependency).
# Previously we tried PID-suffixed container names + flock; that was
# significantly more complex and still had macOS caveats.
check "workspace mutex uses mkdir for atomicity" \
    grep -q 'mkdir "\$SANDY_WORKSPACE_LOCK"' "$_SANDY_SCRIPT_PATH"
check "workspace mutex errors when held" \
    grep -q 'Another sandy is already running in this workspace' "$_SANDY_SCRIPT_PATH"
check "workspace mutex is released in cleanup trap" \
    bash -c "awk '/^cleanup\(\)/,/^}$/' '$_SANDY_SCRIPT_PATH' | grep -q 'SANDY_WORKSPACE_LOCK'"
check "CONTAINER_NAME is deterministic (no PID suffix)" \
    grep -q 'CONTAINER_NAME="sandy-\${SANDBOX_NAME}"' "$_SANDY_SCRIPT_PATH"
# Regression: old flock-based approach must be gone
check "no leftover flock-based setup lock" \
    bash -c "! grep -q '_SANDY_HAVE_FLOCK' '$_SANDY_SCRIPT_PATH'"

# ============================================================
info "9z. PR 1.1 regression tests — resume fallback + codex grep-F"
# ============================================================

# Guard against regression of the `cmd || cmd_base` fallback pattern in
# build_claude_cmd. Earlier versions appended `|| $cmd_base` after the
# command so that `claude --continue` failures (including Ctrl-C) silently
# relaunched a fresh session. The session-detect guarantees we only add
# --continue when a session exists, so the fallback is both unnecessary
# and actively harmful. This test asserts it stays removed.
_SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"
BUILD_CLAUDE_BODY="$(awk '/^build_claude_cmd\(\)/,/^}$/' "$_SANDY_SCRIPT_PATH")"
FALLBACK_PRESENT="no"
if echo "$BUILD_CLAUDE_BODY" | grep -qE 'cmd="\$cmd \|\| \$cmd_base"'; then
    FALLBACK_PRESENT="yes"
fi
check "build_claude_cmd has no cmd||cmd_base fallback (PR 1.1 blocker #1)" \
    test "$FALLBACK_PRESENT" = "no"

# Also assert that cmd_base is not referenced at all — it's the marker
# variable for the fallback pattern, and its absence is the cleanest
# signal that the pattern is gone.
CMD_BASE_REFS="$(echo "$BUILD_CLAUDE_BODY" | grep -c 'cmd_base' || true)"
check "build_claude_cmd no longer references cmd_base" \
    test "$CMD_BASE_REFS" = "0"

# Guard against regression of the codex trust-entry grep-regex injection.
# The workspace path is interpolated into the grep pattern and contains
# '/' and '.' characters that are regex metacharacters in BRE mode. Using
# grep -F forces fixed-string matching. This test asserts the -F flag is
# present and the old unsafe form is gone.
CODEX_GREP_LINE="$(grep -n 'projects\.\\\"' "$_SANDY_SCRIPT_PATH" | grep -v '^\s*#' | grep 'grep' | head -1 || true)"
check "codex trust-entry check uses grep -F (PR 1.1 blocker #2)" \
    bash -c "echo '$CODEX_GREP_LINE' | grep -q 'grep -qF'"

# ============================================================
info "10. Dev environment detection — foreign native modules"
# ============================================================

mkdir -p "$TEST_PROJECT/node_modules/fake-addon"
# Create a Mach-O stub (magic bytes: 0xFEEDFACF = 64-bit Mach-O)
printf '\xfe\xed\xfa\xcf' > "$TEST_PROJECT/node_modules/fake-addon/binding.node"
# Check that the .node file's magic bytes are NOT ELF (7f 45 4c 46)
OUTPUT="$(sandy_run "od -A n -t x1 -N4 /workspace/node_modules/fake-addon/binding.node | tr -d ' '" 2>&1)"
check "detects non-ELF native addon" \
    bash -c '! echo "$1" | grep -qi "^7f454c46"' -- "$OUTPUT"
rm -rf "$TEST_PROJECT/node_modules"

# ============================================================
info "11. Sandbox isolation between projects"
# ============================================================

SANDBOX_DIR2="$(mktemp -d)"
mkdir -p "$SANDBOX_DIR2"/{pip,uv,npm-global,go,cargo}
echo '{}' > "$SANDBOX_DIR2/settings.json"

# pip package from test 2 should NOT be in the second sandbox
OUTPUT="$(
    docker run --rm \
        --read-only \
        --tmpfs /tmp:exec,size=256M \
        --tmpfs /home/claude:exec,size=256M,uid=1001,gid=1001 \
        -v "$SANDBOX_DIR2:/home/claude/.claude" \
        -v "$SANDBOX_DIR2/pip:/home/claude/.pip-packages" \
        -v "$SANDBOX_DIR2/uv:/home/claude/.local/share/uv" \
        -v "$SANDBOX_DIR2/npm-global:/home/claude/.npm-global" \
        -v "$SANDBOX_DIR2/go:/home/claude/go" \
        -v "$SANDBOX_DIR2/cargo:/home/claude/.cargo" \
        -v "$TEST_PROJECT:/workspace" \
        -w /workspace \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        --entrypoint bash \
        "$IMAGE_NAME" \
        -c "
            RUN_UID=\${HOST_UID:-1001}; RUN_GID=\${HOST_GID:-1001}
            chown \"\$RUN_UID:\$RUN_GID\" /home/claude
            for d in /home/claude/.pip-packages /home/claude/.npm-global /home/claude/go /home/claude/.cargo; do
                chown \"\$RUN_UID:\$RUN_GID\" \"\$d\" 2>/dev/null || true
            done
            mkdir -p /home/claude/.local/bin /home/claude/.local/share
            chown \"\$RUN_UID:\$RUN_GID\" /home/claude/.local /home/claude/.local/bin /home/claude/.local/share 2>/dev/null || true
            exec gosu \"\$RUN_UID:\$RUN_GID\" bash -c '
                export HOME=/home/claude
                export PIP_BREAK_SYSTEM_PACKAGES=1
                export PYTHONUSERBASE=\"\$HOME/.pip-packages\"
                python3 -c \"import cowsay\" 2>&1 && echo LEAKED || echo ISOLATED
            '
        " 2>&1
)"
check "packages don't leak between project sandboxes" \
    bash -c 'echo "$1" | grep -q ISOLATED' -- "$OUTPUT"
rm -rf "$SANDBOX_DIR2"

# ============================================================
info "12. Variable ordering — WORK_DIR defined before Phase 3"
# ============================================================

# Phase 3 (per-project Dockerfile) references WORK_DIR and SANDBOX_NAME.
# Regression test: these must be defined before their first use.
SCRIPT="$(dirname "$0")/../sandy"
WORK_DIR_DEF="$(grep -n '^WORK_DIR=' "$SCRIPT" | head -1 | cut -d: -f1)"
SANDBOX_NAME_DEF="$(grep -n '^SANDBOX_NAME=' "$SCRIPT" | head -1 | cut -d: -f1)"
PHASE3_USE="$(grep -n 'Phase 3.*Per-project image' "$SCRIPT" | head -1 | cut -d: -f1)"
check "WORK_DIR defined before Phase 3" \
    test "$WORK_DIR_DEF" -lt "$PHASE3_USE"
check "SANDBOX_NAME defined before Phase 3" \
    test "$SANDBOX_NAME_DEF" -lt "$PHASE3_USE"

# ============================================================
info "13. Protected files are read-only inside container"
# ============================================================

# Switch to a fresh TEST_PROJECT before asserting host→container content.
#
# Why: tests 1-12 ran sandy_run many times against $TEST_PROJECT, and
# sandy_run's file: loop pre-created empty .bashrc/.zshrc stubs inside it so
# the ro bind mounts would resolve. Each container read of those empty stubs
# populates OrbStack's fuse.sshfs attribute cache at the *path* level, and
# that cache survives rm, echo-over-write, atomic mv-rename, and inode-change
# (verified empirically — see test/run-failing-tests.sh variants B/C/D, all
# of which write 14 bytes on host but read 0 bytes in container). The only
# thing that dodges the cache is a never-before-seen path: a fresh mktemp.
#
# Switching TEST_PROJECT here means tests 14+ inherit the new directory. All
# of them set up their own fixtures, so that's fine. The old project is
# removed immediately to avoid leaking tempdirs.
_OLD_TEST_PROJECT="$TEST_PROJECT"
TEST_PROJECT="$(mktemp -d)"
rm -rf "$_OLD_TEST_PROJECT"
unset _OLD_TEST_PROJECT

echo "# host bashrc" > "$TEST_PROJECT/.bashrc"
echo "# host zshrc" > "$TEST_PROJECT/.zshrc"
mkdir -p "$TEST_PROJECT/.git/hooks"
echo "#!/bin/sh" > "$TEST_PROJECT/.git/hooks/pre-commit"
echo "[core]" > "$TEST_PROJECT/.git/config"
echo "" > "$TEST_PROJECT/.gitmodules"
mkdir -p "$TEST_PROJECT/.claude/commands"
echo "test" > "$TEST_PROJECT/.claude/commands/test.md"
mkdir -p "$TEST_PROJECT/.claude/agents"
echo "test" > "$TEST_PROJECT/.claude/agents/test-agent.md"
mkdir -p "$TEST_PROJECT/.claude/plugins"
echo "test" > "$TEST_PROJECT/.claude/plugins/test-plugin.json"

# Verify writes to protected files fail
sandy_run "echo injected >> /workspace/.bashrc 2>/dev/null" >/dev/null 2>&1 && WRITE_BASHRC=yes || WRITE_BASHRC=no
check "cannot write to .bashrc" test "$WRITE_BASHRC" = "no"

sandy_run "echo injected >> /workspace/.zshrc 2>/dev/null" >/dev/null 2>&1 && WRITE_ZSHRC=yes || WRITE_ZSHRC=no
check "cannot write to .zshrc" test "$WRITE_ZSHRC" = "no"

sandy_run "echo injected > /workspace/.git/hooks/pre-commit 2>/dev/null" >/dev/null 2>&1 && WRITE_HOOK=yes || WRITE_HOOK=no
check "cannot write to .git/hooks/" test "$WRITE_HOOK" = "no"

sandy_run "echo injected >> /workspace/.git/config 2>/dev/null" >/dev/null 2>&1 && WRITE_GITCFG=yes || WRITE_GITCFG=no
check "cannot write to .git/config" test "$WRITE_GITCFG" = "no"

sandy_run "echo injected >> /workspace/.gitmodules 2>/dev/null" >/dev/null 2>&1 && WRITE_GITMOD=yes || WRITE_GITMOD=no
check "cannot write to .gitmodules" test "$WRITE_GITMOD" = "no"

# Verify sandbox-mounted dirs: host content is hidden, writes succeed, host is untouched
check "host .claude/commands/ is hidden" \
    sandy_run "test ! -e /workspace/.claude/commands/test.md"
check "can write to .claude/commands/" \
    sandy_run "echo new > /workspace/.claude/commands/new-cmd.md"
check "commands write persists in sandbox" \
    test -f "$SANDBOX_DIR/workspace-commands/new-cmd.md"
check "commands write does not touch host" \
    test ! -f "$TEST_PROJECT/.claude/commands/new-cmd.md"

check "host .claude/agents/ is hidden" \
    sandy_run "test ! -e /workspace/.claude/agents/test-agent.md"
check "can write to .claude/agents/" \
    sandy_run "echo new > /workspace/.claude/agents/new-agent.md"
check "agents write persists in sandbox" \
    test -f "$SANDBOX_DIR/workspace-agents/new-agent.md"
check "agents write does not touch host" \
    test ! -f "$TEST_PROJECT/.claude/agents/new-agent.md"

check "host .claude/plugins/ is hidden" \
    sandy_run "test ! -e /workspace/.claude/plugins/test-plugin.json"

# Verify reads still work
check "can read protected .bashrc" \
    sandy_run "cat /workspace/.bashrc | grep -q 'host bashrc'"

# Verify unprotected files are still writable
check "can write to unprotected files" \
    sandy_run "echo test > /workspace/test-file.txt"

rm -f "$TEST_PROJECT/.bashrc" "$TEST_PROJECT/.zshrc" "$TEST_PROJECT/test-file.txt" "$TEST_PROJECT/.gitmodules"
rm -rf "$TEST_PROJECT/.git" "$TEST_PROJECT/.claude"

# ============================================================
info "14. git-lfs is available"
# ============================================================

check "git-lfs is installed" sandy_run "git lfs version"

# ============================================================
info "15. LFS auto-detection sets up filters"
# ============================================================

# Create a .gitattributes with LFS filter
echo "*.bin filter=lfs diff=lfs merge=lfs -text" > "$TEST_PROJECT/.gitattributes"
# Simulate what the entrypoint does: find .gitattributes with filter=lfs, run git lfs install
OUTPUT="$(sandy_run '
    if find /workspace -name .gitattributes -maxdepth 3 -exec grep -ql "filter=lfs" {} + 2>/dev/null; then
        git lfs install 2>/dev/null
    fi
    git config --get filter.lfs.smudge
' 2>&1)"
check "LFS filters configured when .gitattributes has filter=lfs" \
    bash -c 'echo "$1" | grep -q "git-lfs smudge"' -- "$OUTPUT"
rm -f "$TEST_PROJECT/.gitattributes"

# ============================================================
info "16. Container runs as host UID"
# ============================================================

EXPECTED_UID="$(id -u)"
CONTAINER_UID="$(sandy_run 'id -u' 2>&1 | tr -d '[:space:]')"
check "container UID matches host UID" \
    test "$CONTAINER_UID" = "$EXPECTED_UID"

# Static analysis: verify passwd overlay logic exists for non-default UIDs
check "passwd overlay for non-default UID" \
    grep -q 'SANDY_PASSWD.*passwd' "$SCRIPT"

# ============================================================
info "17. Per-project config parsing"
# ============================================================

# Static analysis: verify .sandy/config loading happens before SSH relay setup
CONFIG_SOURCE="$(grep -n '\.sandy/config' "$SCRIPT" | head -1 | cut -d: -f1)"
SSH_RELAY="$(grep -n 'SANDY_SSH=.*token' "$SCRIPT" | tail -1 | cut -d: -f1)"
check ".sandy/config loaded before SSH relay setup" \
    test "$CONFIG_SOURCE" -lt "$SSH_RELAY"

# Verify config parser does NOT use source (prevents code injection from untrusted repos)
check "config parser does not use source" \
    bash -c '! grep -q "source.*\.sandy/config" "$1"' -- "$SCRIPT"

# Verify config parser uses allowlist. v0.12+: keys live in named arrays
# (SANDY_PRIVILEGED_KEYS, SANDY_PASSIVE_KEYS) instead of inline case-statement
# pipe-delimited patterns.
check "config parser uses variable allowlist (privileged array)" \
    grep -qE '^SANDY_PRIVILEGED_KEYS=\(' "$SCRIPT"
check "config parser uses variable allowlist (passive array)" \
    grep -qE '^SANDY_PASSIVE_KEYS=\(' "$SCRIPT"
check "privileged array contains SANDY_SSH" \
    bash -c 'awk "/^SANDY_PRIVILEGED_KEYS=\(/,/^\)$/" "$1" | grep -qE "^[[:space:]]+SANDY_SSH$"' \
    -- "$SCRIPT"
check "passive array contains SANDY_MODEL" \
    bash -c 'awk "/^SANDY_PASSIVE_KEYS=\(/,/^\)$/" "$1" | grep -qE "^[[:space:]]+SANDY_MODEL$"' \
    -- "$SCRIPT"

# ============================================================
info "18. Container naming"
# ============================================================

# Static analysis: verify --name flag is set in RUN_FLAGS
check "container name includes sandbox name" \
    grep -q -- '--name "$CONTAINER_NAME"' "$SCRIPT"

# ============================================================
info "19. pip wrapper created in root section (not inside bash -c)"
# ============================================================

# The pip wrapper heredoc must be in the root section of the entrypoint, NOT
# inside the 'exec gosu ... bash -c' single-quoted string, because <<'PIPWRAP'
# would break the outer quoting and expand variables at startup time.
GOSU_LINE="$(grep -n "exec gosu" "$SCRIPT" | head -1 | cut -d: -f1)"
PIP_WRAPPER_LINE="$(grep -n "cat > .*/pip <<" "$SCRIPT" | head -1 | cut -d: -f1)"
check "pip wrapper created before exec gosu (root section)" \
    test "$PIP_WRAPPER_LINE" -lt "$GOSU_LINE"

# Also verify the wrapper actually works (not just passes through empty args)
OUTPUT="$(sandy_run 'pip install --quiet cowsay 2>&1; echo EXIT:$?' 2>&1)"
check "pip install works (wrapper passes args correctly)" \
    bash -c 'echo "$1" | grep -q "EXIT:0"' -- "$OUTPUT"

# ============================================================
info "20. Symlink protection — detects escaping symlinks"
# ============================================================

# Extract the symlink check logic from sandy and test it directly
REAL_WORK_DIR="$(cd "$TEST_PROJECT" && pwd -P)"

# Create a symlink that escapes the workspace
ln -sf /etc/hostname "$TEST_PROJECT/escape-link"
DANGEROUS_SYMLINKS=()
while IFS= read -r -d '' link; do
    target="$(readlink -f "$link" 2>/dev/null || true)"
    [ -z "$target" ] && continue
    if [[ "$target" != "$REAL_WORK_DIR"* ]]; then
        link_rel="${link#$TEST_PROJECT/}"
        DANGEROUS_SYMLINKS+=("$link_rel -> $target")
    fi
done < <(find "$TEST_PROJECT" -maxdepth 5 -type l \
    -not -path '*/node_modules/*' \
    -not -path '*/.venv/*' \
    -not -path '*/.git/*' \
    -print0 2>/dev/null)
check "detects symlink escaping workspace" \
    test ${#DANGEROUS_SYMLINKS[@]} -gt 0
rm -f "$TEST_PROJECT/escape-link"

# Create a safe relative symlink inside the workspace
mkdir -p "$TEST_PROJECT/subdir"
echo "target" > "$TEST_PROJECT/subdir/real-file"
ln -sf subdir/real-file "$TEST_PROJECT/safe-link"
DANGEROUS_SYMLINKS=()
while IFS= read -r -d '' link; do
    target="$(readlink -f "$link" 2>/dev/null || true)"
    [ -z "$target" ] && continue
    if [[ "$target" != "$REAL_WORK_DIR"* ]]; then
        link_rel="${link#$TEST_PROJECT/}"
        DANGEROUS_SYMLINKS+=("$link_rel -> $target")
    fi
done < <(find "$TEST_PROJECT" -maxdepth 5 -type l \
    -not -path '*/node_modules/*' \
    -not -path '*/.venv/*' \
    -not -path '*/.git/*' \
    -print0 2>/dev/null)
check "does not flag safe internal symlink" \
    test ${#DANGEROUS_SYMLINKS[@]} -eq 0
rm -f "$TEST_PROJECT/safe-link"
rm -rf "$TEST_PROJECT/subdir"

# Static analysis: verify symlink check exists in sandy before docker run
SYMLINK_CHECK="$(grep -n 'DANGEROUS_SYMLINKS' "$SCRIPT" | head -1 | cut -d: -f1)"
DOCKER_RUN="$(grep -n 'docker run.*RUN_FLAGS' "$SCRIPT" | head -1 | cut -d: -f1)"
check "symlink check runs before docker run" \
    test "$SYMLINK_CHECK" -lt "$DOCKER_RUN"

# ============================================================
info "21. Terminal notification passthrough"
# ============================================================

# Static analysis: verify tmux.conf has allow-passthrough on
check "tmux.conf enables allow-passthrough" \
    grep -q 'allow-passthrough on' "$SCRIPT"

# Static analysis: verify host hooks mount exists
check "host hooks mounted read-only" \
    grep -q '\.claude/hooks:/home/claude/\.claude/hooks:ro' "$SCRIPT"

# ============================================================
info "22. cmux auto-setup"
# ============================================================

# Static analysis: verify CMUX_WORKSPACE_ID detection exists
check "cmux detection checks CMUX_WORKSPACE_ID" \
    grep -q 'CMUX_WORKSPACE_ID' "$SCRIPT"

# Static analysis: verify hook script contains OSC 777
check "cmux hook template emits OSC 777" \
    grep -q '777;notify' "$SCRIPT"

# Static analysis: verify the Notification hook is registered in settings.json merge
check "cmux setup adds Notification hook to settings.json" \
    grep -q 'Notification' "$SCRIPT"

# Static analysis: verify idempotency check (cmux-notify dedup)
check "cmux hook dedup prevents duplicates" \
    grep -q 'cmux-notify' "$SCRIPT"

# Static analysis: verify cmux setup skipped when host hooks exist
check "cmux setup skipped when host hooks dir exists" \
    grep -q '! -d.*\.claude/hooks' "$SCRIPT"

# Functional test: run the cmux setup logic via a helper script
CMUX_SANDBOX="$(mktemp -d)"
mkdir -p "$CMUX_SANDBOX"
echo '{"teammateMode":"tmux"}' > "$CMUX_SANDBOX/settings.json"

# Extract and run the cmux auto-setup logic using a temp script (avoids quoting issues)
cat > "$CMUX_SANDBOX/test-cmux-setup.sh" <<'SETUP_SCRIPT'
#!/bin/bash
set -e
SANDBOX_DIR="$1"
mkdir -p "$SANDBOX_DIR/hooks"
cat > "$SANDBOX_DIR/hooks/cmux-notify.sh" <<'CMUXHOOK'
#!/bin/bash
INPUT=$(cat)
EVENT_TYPE=$(echo "$INPUT" | jq -r '.type // "unknown"')
case "$EVENT_TYPE" in
    permission_prompt)
        printf '\e]777;notify;Claude Code;Permission needed\a' ;;
    idle_prompt)
        printf '\e]777;notify;Claude Code;Waiting for input\a' ;;
esac
CMUXHOOK
chmod +x "$SANDBOX_DIR/hooks/cmux-notify.sh"
SETTINGS_FILE="$SANDBOX_DIR/settings.json"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"
HAS_CMUX=$(jq '[.hooks.Notification // [] | .[] | select(.hooks[]?.command? | contains("cmux-notify"))] | length' "$SETTINGS_FILE")
if [ "$HAS_CMUX" = "0" ]; then
    jq '.hooks //= {} | .hooks.Notification //= [] | .hooks.Notification += [{"matcher":"","hooks":[{"type":"command","command":"/home/claude/.claude/hooks/cmux-notify.sh"}]}]' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
fi
SETUP_SCRIPT
chmod +x "$CMUX_SANDBOX/test-cmux-setup.sh"

# Run setup once
bash "$CMUX_SANDBOX/test-cmux-setup.sh" "$CMUX_SANDBOX"

check "cmux hook script created and executable" \
    test -x "$CMUX_SANDBOX/hooks/cmux-notify.sh"
check "cmux hook script contains OSC 777" \
    grep -q '777;notify' "$CMUX_SANDBOX/hooks/cmux-notify.sh"
check "cmux hook registered in settings.json" \
    grep -q 'cmux-notify' "$CMUX_SANDBOX/settings.json"
check "existing settings preserved after cmux merge" \
    test "$(jq -r '.teammateMode' "$CMUX_SANDBOX/settings.json")" = "tmux"

# Run setup again — should NOT duplicate the hook
bash "$CMUX_SANDBOX/test-cmux-setup.sh" "$CMUX_SANDBOX"
HOOK_COUNT="$(jq '.hooks.Notification | length' "$CMUX_SANDBOX/settings.json")"
check "cmux hook not duplicated on second run" \
    test "$HOOK_COUNT" = "1"

rm -rf "$CMUX_SANDBOX"

# ============================================================
info "23. Container hardening flags"
# ============================================================

# Static analysis: verify pids-limit is set
check "pids-limit is configured" \
    grep -q 'pids-limit' "$SCRIPT"

# Static analysis: verify cap-drop ALL is set
check "cap-drop ALL is configured" \
    grep -q 'cap-drop ALL' "$SCRIPT"

# Static analysis: verify GPU passthrough support
check "SANDY_GPU config variable supported" \
    grep -q 'SANDY_GPU' "$SCRIPT"
check "GPU passthrough uses --gpus flag" \
    grep -q '\-\-gpus' "$SCRIPT"

# Static analysis: verify CLAUDE_CODE_OAUTH_TOKEN is blocked
check "CLAUDE_CODE_OAUTH_TOKEN blocked" \
    grep -q 'CLAUDE_CODE_OAUTH_TOKEN=' "$SCRIPT"

# ============================================================
info "24. CLAUDE_CODE_MAX_OUTPUT_TOKENS passed to container"
# ============================================================

# Static analysis: verify the env var is passed via docker -e
check "MAX_OUTPUT_TOKENS in docker -e flags" \
    grep -q 'CLAUDE_CODE_MAX_OUTPUT_TOKENS=.*128000' "$SCRIPT"

# ============================================================
info "25. Skill pack infrastructure"
# ============================================================

# Static analysis: verify skill pack registry exists
check "SKILL_PACK_NAMES array defined" \
    grep -q 'SKILL_PACK_NAMES=' "$SCRIPT"
check "SKILL_PACK_REPOS array defined" \
    grep -q 'SKILL_PACK_REPOS=' "$SCRIPT"
check "SKILL_PACK_VERSIONS array defined" \
    grep -q 'SKILL_PACK_VERSIONS=' "$SCRIPT"
check "SKILL_PACK_TAG_PREFIXES array defined" \
    grep -q 'SKILL_PACK_TAG_PREFIXES=' "$SCRIPT"
check "skill_pack_lookup function defined" \
    grep -q 'skill_pack_lookup()' "$SCRIPT"
check "skill_pack_latest_release function defined" \
    grep -q 'skill_pack_latest_release()' "$SCRIPT"
check "skill_pack_resolve_versions function defined" \
    grep -q 'skill_pack_resolve_versions()' "$SCRIPT"
check "gstack registered as skill pack" \
    grep -q 'gstack' "$SCRIPT"
check "gstack repo points to upstream garrytan" \
    grep -q 'garrytan/gstack' "$SCRIPT"

# Static analysis: verify SANDY_SKILL_PACKS is in config allowlist
check "SANDY_SKILL_PACKS in config allowlist" \
    grep -q 'SANDY_SKILL_PACKS' "$SCRIPT"

# Static analysis: verify generate_skill_pack_dockerfiles function exists
check "generate_skill_pack_dockerfiles function defined" \
    grep -q 'generate_skill_pack_dockerfiles()' "$SCRIPT"

# Static analysis: verify Phase 2.5 build block exists
check "Phase 2.5 skill pack build phase exists" \
    grep -q 'SKILLS_REBUILT' "$SCRIPT"

# Static analysis: verify skill pack auto-update check exists
check "skill pack versions resolved before Dockerfile generation" \
    grep -q 'skill_pack_resolve_versions' "$SCRIPT"

# Static analysis: verify --rebuild clears skills hash
check "--rebuild clears skill pack hash" \
    grep -q 'skills_build_hash' "$SCRIPT"

# Static analysis: verify runtime skill activation in user-setup
check "user-setup activates /opt/skills" \
    grep -q '/opt/skills' "$SCRIPT"
check "user-setup sets PLAYWRIGHT_BROWSERS_PATH" \
    grep -q 'PLAYWRIGHT_BROWSERS_PATH' "$SCRIPT"

# ============================================================
info "26. Skill pack Dockerfile generation"
# ============================================================

# Functional: generate the Dockerfile.skills and verify contents
SKILLS_TEST_DIR="$(mktemp -d)"
(
    # Source just the functions we need from the sandy script
    SANDY_HOME="$SKILLS_TEST_DIR"
    SKILL_PACK_NAMES=(gstack)
    SKILL_PACK_REPOS=("https://github.com/garrytan/gstack")
    SKILL_PACK_VERSIONS=("main")
    SKILL_PACK_TAG_PREFIXES=("")
    IMAGE_NAME="sandy-claude-code"

    skill_pack_lookup() {
        local pack="$1" field="$2" i
        for i in "${!SKILL_PACK_NAMES[@]}"; do
            if [ "${SKILL_PACK_NAMES[$i]}" = "$pack" ]; then
                case "$field" in
                    repo) echo "${SKILL_PACK_REPOS[$i]}" ;;
                    version) echo "${SKILL_PACK_VERSIONS[$i]}" ;;
                    tag_prefix) echo "${SKILL_PACK_TAG_PREFIXES[$i]}" ;;
                esac
                return 0
            fi
        done
        return 1
    }
    error() { echo "ERROR: $*" >&2; }

    # Extract the generator function from the script and source it
    eval "$(sed -n '/^generate_skill_pack_dockerfiles()/,/^}/p' "$SCRIPT")"

    generate_skill_pack_dockerfiles "gstack"
)

SKILLS_BASE_DF="$SKILLS_TEST_DIR/Dockerfile.skills-base.new"
SKILLS_DF="$SKILLS_TEST_DIR/Dockerfile.skills.new"

# Phase 2.5a: base image (Playwright + Chromium)
check "Dockerfile.skills-base generated" \
    test -f "$SKILLS_BASE_DF"
check "Dockerfile.skills-base starts FROM sandy-claude-code" \
    grep -q '^FROM sandy-claude-code' "$SKILLS_BASE_DF"
check "Dockerfile.skills-base installs Playwright deps" \
    grep -q 'playwright install-deps chromium' "$SKILLS_BASE_DF"
check "Dockerfile.skills-base installs Playwright browser" \
    grep -q 'playwright install chromium' "$SKILLS_BASE_DF"
check "Dockerfile.skills-base sets PLAYWRIGHT_BROWSERS_PATH" \
    grep -q 'PLAYWRIGHT_BROWSERS_PATH=/opt/skills/gstack/.browsers' "$SKILLS_BASE_DF"

# Phase 2.5b: code image (gstack source + bun build)
check "Dockerfile.skills generated" \
    test -f "$SKILLS_DF"
check "Dockerfile.skills starts FROM sandy-skills-base-gstack" \
    grep -q '^FROM sandy-skills-base-gstack' "$SKILLS_DF"
check "Dockerfile.skills downloads gstack tarball" \
    grep -q 'garrytan/gstack/archive' "$SKILLS_DF"
check "Dockerfile.skills installs to /opt/skills/gstack" \
    grep -q '/opt/skills/gstack' "$SKILLS_DF"
check "Dockerfile.skills runs bun build" \
    grep -q 'bun run build' "$SKILLS_DF"
check "Dockerfile.skills does not set USER (entrypoint handles privilege drop)" \
    bash -c "! grep -q '^USER' '$SKILLS_DF'"
check "Dockerfile.skills-base does not set USER" \
    bash -c "! grep -q '^USER' '$SKILLS_BASE_DF'"

rm -rf "$SKILLS_TEST_DIR"

# ============================================================
info "27. Project dir consolidation across path eras"
# ============================================================

# The container workspace path has changed across sandy versions:
#   /workspace → raw host path → $HOME-relative path
# Since each sandbox is per-project, all project dirs belong to the same project.
# The migration merges all non-current project dirs into the current one.
_MIGRATE_SNIPPET='
    _cur_proj="$HOME/.claude/projects/$(echo "$WORKSPACE" | tr "/" "-")"
    mkdir -p "$_cur_proj"
    for _old_proj in "$HOME/.claude/projects"/-*/; do
        [ -d "$_old_proj" ] || continue
        case "$_old_proj" in "$_cur_proj"/) continue ;; esac
        cp -an "$_old_proj". "$_cur_proj"/ 2>/dev/null || true
        rm -rf "$_old_proj"
    done
    if [ -f "$HOME/.claude/history.jsonl" ]; then
        sed -i "s|\"project\":\"[^\"]*\"|\"project\":\"$WORKSPACE\"|g" "$HOME/.claude/history.jsonl"
    fi
'

# Test 1: single old dir migrated to new path
mkdir -p "$SANDBOX_DIR/projects/-workspace"
echo "old-session" > "$SANDBOX_DIR/projects/-workspace/session.jsonl"
sandy_run "
    export WORKSPACE=/home/claude/dev/myproject
    $_MIGRATE_SNIPPET
"
check "old -workspace session migrated to new path" \
    test -f "$SANDBOX_DIR/projects/-home-claude-dev-myproject/session.jsonl"
check "old -workspace dir removed" \
    bash -c '! test -d "$1/projects/-workspace"' -- "$SANDBOX_DIR"
rm -rf "$SANDBOX_DIR/projects/-home-claude-dev-myproject"

# Test 2: multiple old dirs (all three eras) merged into current
mkdir -p "$SANDBOX_DIR/projects/-workspace"
echo "era1" > "$SANDBOX_DIR/projects/-workspace/era1.jsonl"
mkdir -p "$SANDBOX_DIR/projects/-Users-rappdw-dev-myproject"
echo "era2" > "$SANDBOX_DIR/projects/-Users-rappdw-dev-myproject/era2.jsonl"
mkdir -p "$SANDBOX_DIR/projects/-home-claude-dev-myproject"
echo "era3" > "$SANDBOX_DIR/projects/-home-claude-dev-myproject/era3.jsonl"
sandy_run "
    export WORKSPACE=/home/claude/dev/myproject
    $_MIGRATE_SNIPPET
"
check "era1 (/workspace) session merged" \
    test -f "$SANDBOX_DIR/projects/-home-claude-dev-myproject/era1.jsonl"
check "era2 (raw host path) session merged" \
    test -f "$SANDBOX_DIR/projects/-home-claude-dev-myproject/era2.jsonl"
check "era3 (current) session preserved" \
    test -f "$SANDBOX_DIR/projects/-home-claude-dev-myproject/era3.jsonl"
check "era1 dir removed" \
    bash -c '! test -d "$1/projects/-workspace"' -- "$SANDBOX_DIR"
check "era2 dir removed" \
    bash -c '! test -d "$1/projects/-Users-rappdw-dev-myproject"' -- "$SANDBOX_DIR"
rm -rf "$SANDBOX_DIR/projects/-home-claude-dev-myproject"

# Test 3: no-clobber — existing files in current dir not overwritten
mkdir -p "$SANDBOX_DIR/projects/-workspace"
echo "old-version" > "$SANDBOX_DIR/projects/-workspace/same.jsonl"
mkdir -p "$SANDBOX_DIR/projects/-home-claude-dev-myproject"
echo "new-version" > "$SANDBOX_DIR/projects/-home-claude-dev-myproject/same.jsonl"
sandy_run "
    export WORKSPACE=/home/claude/dev/myproject
    $_MIGRATE_SNIPPET
"
CONTENT="$(cat "$SANDBOX_DIR/projects/-home-claude-dev-myproject/same.jsonl")"
check "existing file not overwritten by old version" \
    test "$CONTENT" = "new-version"
rm -rf "$SANDBOX_DIR/projects/-workspace" "$SANDBOX_DIR/projects/-home-claude-dev-myproject"

# Test 4: subdirectory merge (memory/ dirs with different files)
mkdir -p "$SANDBOX_DIR/projects/-Users-rappdw-dev-myproject/memory"
echo "old-mem" > "$SANDBOX_DIR/projects/-Users-rappdw-dev-myproject/memory/context.md"
echo "shared" > "$SANDBOX_DIR/projects/-Users-rappdw-dev-myproject/memory/MEMORY.md"
mkdir -p "$SANDBOX_DIR/projects/-home-claude-dev-myproject/memory"
echo "new-mem" > "$SANDBOX_DIR/projects/-home-claude-dev-myproject/memory/MEMORY.md"
sandy_run "
    export WORKSPACE=/home/claude/dev/myproject
    $_MIGRATE_SNIPPET
"
check "old memory file merged into subdirectory" \
    test -f "$SANDBOX_DIR/projects/-home-claude-dev-myproject/memory/context.md"
MEM_CONTENT="$(cat "$SANDBOX_DIR/projects/-home-claude-dev-myproject/memory/MEMORY.md")"
check "existing memory file not overwritten" \
    test "$MEM_CONTENT" = "new-mem"
check "old project dir fully removed after subdir merge" \
    bash -c '! test -d "$1/projects/-Users-rappdw-dev-myproject"' -- "$SANDBOX_DIR"
rm -rf "$SANDBOX_DIR/projects/-home-claude-dev-myproject"

# Test 5: history.jsonl project paths rewritten to current workspace
mkdir -p "$SANDBOX_DIR/projects/-workspace"
echo "era1" > "$SANDBOX_DIR/projects/-workspace/session1.jsonl"
mkdir -p "$SANDBOX_DIR/projects/-Users-rappdw-dev-myproject"
echo "era2" > "$SANDBOX_DIR/projects/-Users-rappdw-dev-myproject/session2.jsonl"
cat > "$SANDBOX_DIR/history.jsonl" <<'HIST'
{"project":"/workspace","sessionId":"sess1"}
{"project":"/Users/rappdw/dev/myproject","sessionId":"sess2"}
HIST
sandy_run "
    export WORKSPACE=/home/claude/dev/myproject
    $_MIGRATE_SNIPPET
"
HIST_CONTENT="$(cat "$SANDBOX_DIR/history.jsonl")"
check "history.jsonl era1 project path rewritten" \
    bash -c 'echo "$1" | grep -q "\"project\":\"/home/claude/dev/myproject\".*sess1"' -- "$HIST_CONTENT"
check "history.jsonl era2 project path rewritten" \
    bash -c 'echo "$1" | grep -q "\"project\":\"/home/claude/dev/myproject\".*sess2"' -- "$HIST_CONTENT"
check "history.jsonl has no stale project paths" \
    bash -c '! echo "$1" | grep -q "\"project\":\"/workspace\""' -- "$HIST_CONTENT"
rm -rf "$SANDBOX_DIR/projects/-home-claude-dev-myproject" "$SANDBOX_DIR/history.jsonl"

# .claude.json migration snippet (runs inside container where node is available).
# Mirrors the node script from generate_user_setup() in sandy.
_CJ_MIGRATE_SNIPPET='
    CLAUDE_JSON="$1"
    WORKSPACE="$2"
    node -e "
        const fs = require(\"fs\");
        const f = process.argv[1];
        const ws = process.argv[2];
        let d;
        try { d = JSON.parse(fs.readFileSync(f, \"utf8\")); } catch { process.exit(0); }
        const p = d.projects;
        if (!p || typeof p !== \"object\") process.exit(0);
        const keys = Object.keys(p).filter(k => k !== ws);
        if (keys.length === 0) process.exit(0);
        let merged = p[ws] || {};
        for (const k of keys) {
            const old = p[k];
            if (old.hasTrustDialogAccepted) merged.hasTrustDialogAccepted = true;
            if (old.hasCompletedProjectOnboarding) merged.hasCompletedProjectOnboarding = true;
            if (old.allowedTools && old.allowedTools.length) {
                merged.allowedTools = [...new Set([...(merged.allowedTools || []), ...old.allowedTools])];
            }
            if (!p[ws]) { merged = { ...old, ...merged }; p[ws] = merged; }
            delete p[k];
        }
        p[ws] = merged;
        const tmp = f + \".tmp\";
        fs.writeFileSync(tmp, JSON.stringify(d, null, 2) + \"\\n\");
        fs.renameSync(tmp, f);
    " "$CLAUDE_JSON" "$WORKSPACE"
'

# Test 6: .claude.json trust state consolidated from multiple eras
# Reproduces the google sandbox scenario: /workspace had trust=true,
# /Users/.../google had trust=false, current workspace has no entry.
cat > "$SANDBOX_DIR/.claude.json.test" <<'CJ6'
{
  "numStartups": 5,
  "projects": {
    "/workspace": {
      "allowedTools": ["Read"],
      "hasTrustDialogAccepted": true,
      "lastSessionId": "sess1"
    },
    "/Users/rappdw/dev/genai/google": {
      "allowedTools": ["Edit"],
      "hasTrustDialogAccepted": false,
      "hasCompletedProjectOnboarding": true,
      "lastSessionId": "sess2"
    }
  }
}
CJ6
sandy_run "
    bash -c '$_CJ_MIGRATE_SNIPPET' -- /home/claude/.claude/.claude.json.test /home/claude/dev/genai/google
"
CJ6_RESULT="$(cat "$SANDBOX_DIR/.claude.json.test")"
check ".claude.json: trust=true inherited from /workspace era" \
    bash -c 'echo "$1" | grep -q "\"hasTrustDialogAccepted\": true"' -- "$CJ6_RESULT"
check ".claude.json: hasCompletedProjectOnboarding preserved" \
    bash -c 'echo "$1" | grep -q "\"hasCompletedProjectOnboarding\": true"' -- "$CJ6_RESULT"
check ".claude.json: allowedTools merged from both eras" \
    bash -c 'echo "$1" | grep -q "\"Read\"" && echo "$1" | grep -q "\"Edit\""' -- "$CJ6_RESULT"
check ".claude.json: old entries removed, only current workspace remains" \
    bash -c '! echo "$1" | grep -q "/workspace"' -- "$CJ6_RESULT"
check ".claude.json: non-project data preserved" \
    bash -c 'echo "$1" | grep -q "\"numStartups\": 5"' -- "$CJ6_RESULT"
rm -f "$SANDBOX_DIR/.claude.json.test"

# Test 7: .claude.json no-op when only current workspace entry exists
cat > "$SANDBOX_DIR/.claude.json.test" <<'CJ7'
{
  "projects": {
    "/home/claude/dev/myproject": {
      "hasTrustDialogAccepted": true,
      "lastCost": 1.23
    }
  }
}
CJ7
cp "$SANDBOX_DIR/.claude.json.test" "$SANDBOX_DIR/.claude.json.test.before"
sandy_run "
    bash -c '$_CJ_MIGRATE_SNIPPET' -- /home/claude/.claude/.claude.json.test /home/claude/dev/myproject
"
check ".claude.json: no-op when only current entry exists" \
    diff -q "$SANDBOX_DIR/.claude.json.test" "$SANDBOX_DIR/.claude.json.test.before"
rm -f "$SANDBOX_DIR/.claude.json.test" "$SANDBOX_DIR/.claude.json.test.before"

# Test 8: .claude.json graceful with malformed JSON
echo "not valid json" > "$SANDBOX_DIR/.claude.json.test"
sandy_run "
    bash -c '$_CJ_MIGRATE_SNIPPET' -- /home/claude/.claude/.claude.json.test /home/claude/dev/myproject
"
CJ8_CONTENT="$(cat "$SANDBOX_DIR/.claude.json.test")"
check ".claude.json: malformed JSON not corrupted" \
    test "$CJ8_CONTENT" = "not valid json"
rm -f "$SANDBOX_DIR/.claude.json.test"

# Test 9: .claude.json atomic write produces trailing newline
cat > "$SANDBOX_DIR/.claude.json.test" <<'CJ9'
{
  "projects": {
    "/workspace": { "hasTrustDialogAccepted": true },
    "/old": { "hasTrustDialogAccepted": false }
  }
}
CJ9
sandy_run "
    bash -c '$_CJ_MIGRATE_SNIPPET' -- /home/claude/.claude/.claude.json.test /home/claude/dev/myproject
"
check ".claude.json: file ends with newline" \
    bash -c 'test "$(tail -c 1 "$1/.claude.json.test" | xxd -p)" = "0a"' -- "$SANDBOX_DIR"
rm -f "$SANDBOX_DIR/.claude.json.test"

# ============================================================
info "28. Gemini CLI support — agent helpers and flag translation"
# ============================================================
# These tests extract helper functions directly from the sandy script via
# sed range matches and source them into a subshell. Purely script-level —
# no docker required. Tests will break if the function signatures in sandy
# move or are renamed; that's the intended early-warning contract.

SANDY_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/sandy"

# Pull the two one-line helpers and the build_gemini_cmd function body.
_HELPERS="$(grep -E '^_sandy_has_(claude|gemini|codex)\(\)' "$SANDY_SCRIPT")"
_BUILD_GEMINI="$(sed -n '/^build_gemini_cmd()/,/^}$/p' "$SANDY_SCRIPT")"

if [ -z "$_HELPERS" ] || [ -z "$_BUILD_GEMINI" ]; then
    fail "could not extract gemini helpers from sandy script (did they move?)"
else
    _gemini_script_test() {
        local desc="$1"; shift
        if bash -c "set -e; $_HELPERS
$_BUILD_GEMINI
$*" >/dev/null 2>&1; then
            pass "$desc"
        else
            fail "$desc"
        fi
    }

    _gemini_script_test "_sandy_has_claude true for SANDY_AGENT=claude" \
        'SANDY_AGENT=claude _sandy_has_claude'
    _gemini_script_test "_sandy_has_claude true for SANDY_AGENT=claude,gemini" \
        'SANDY_AGENT=claude,gemini _sandy_has_claude'
    _gemini_script_test "_sandy_has_claude false for SANDY_AGENT=gemini" \
        '! SANDY_AGENT=gemini _sandy_has_claude'
    _gemini_script_test "_sandy_has_gemini true for SANDY_AGENT=gemini" \
        'SANDY_AGENT=gemini _sandy_has_gemini'
    _gemini_script_test "_sandy_has_gemini true for SANDY_AGENT=claude,gemini" \
        'SANDY_AGENT=claude,gemini _sandy_has_gemini'
    _gemini_script_test "_sandy_has_gemini false for SANDY_AGENT=claude" \
        '! SANDY_AGENT=claude _sandy_has_gemini'
    _gemini_script_test "_sandy_has_gemini true for SANDY_AGENT=gemini,codex" \
        'SANDY_AGENT=gemini,codex _sandy_has_gemini'

    _gemini_script_test "build_gemini_cmd translates -p to --prompt" \
        'out=$(build_gemini_cmd -p hello); echo "$out" | grep -q -- "--prompt" && ! echo "${out%%;*}" | grep -qE " -p( |$)"'
    _gemini_script_test "build_gemini_cmd translates --print to --prompt" \
        'out=$(build_gemini_cmd --print hello); echo "$out" | grep -q -- "--prompt"'
    _gemini_script_test "build_gemini_cmd passes --prompt through unchanged" \
        'out=$(build_gemini_cmd --prompt hello); echo "$out" | grep -q -- "--prompt"'
    _gemini_script_test "build_gemini_cmd drops --continue" \
        'out=$(build_gemini_cmd --continue); ! echo "$out" | grep -q -- "--continue"'
    _gemini_script_test "build_gemini_cmd drops -c" \
        'out=$(build_gemini_cmd -c); ! echo "$out" | grep -qE " -c( |$)"'
    _gemini_script_test "build_gemini_cmd passes --yolo by default" \
        'out=$(build_gemini_cmd); echo "$out" | grep -q -- "--yolo"'
    _gemini_script_test "build_gemini_cmd suppresses --yolo when SANDY_SKIP_PERMISSIONS=false" \
        'out=$(SANDY_SKIP_PERMISSIONS=false build_gemini_cmd); ! echo "$out" | grep -q -- "--yolo"'
    _gemini_script_test "build_gemini_cmd honors GEMINI_MODEL" \
        'out=$(GEMINI_MODEL=test-model-x build_gemini_cmd); echo "$out" | grep -q "test-model-x"'
    _gemini_script_test "build_gemini_cmd exports GEMINI_SANDBOX=false" \
        'build_gemini_cmd >/dev/null; [ "$GEMINI_SANDBOX" = "false" ]'
fi

# ============================================================
info "28b. Codex CLI support — agent helpers and flag translation"
# ============================================================
_BUILD_CODEX="$(sed -n '/^build_codex_cmd()/,/^}$/p' "$SANDY_SCRIPT")"

if [ -z "$_HELPERS" ] || [ -z "$_BUILD_CODEX" ]; then
    fail "could not extract codex helpers from sandy script (did they move?)"
else
    _codex_script_test() {
        local desc="$1"; shift
        if bash -c "set -e; $_HELPERS
$_BUILD_CODEX
$*" >/dev/null 2>&1; then
            pass "$desc"
        else
            fail "$desc"
        fi
    }

    _codex_script_test "_sandy_has_codex true for SANDY_AGENT=codex" \
        'SANDY_AGENT=codex _sandy_has_codex'
    _codex_script_test "_sandy_has_codex false for SANDY_AGENT=claude" \
        '! SANDY_AGENT=claude _sandy_has_codex'
    _codex_script_test "_sandy_has_codex false for SANDY_AGENT=gemini" \
        '! SANDY_AGENT=gemini _sandy_has_codex'
    _codex_script_test "_sandy_has_codex false for SANDY_AGENT=claude,gemini" \
        '! SANDY_AGENT=claude,gemini _sandy_has_codex'
    _codex_script_test "_sandy_has_codex true for SANDY_AGENT=claude,codex" \
        'SANDY_AGENT=claude,codex _sandy_has_codex'
    _codex_script_test "_sandy_has_codex true for SANDY_AGENT=claude,gemini,codex" \
        'SANDY_AGENT=claude,gemini,codex _sandy_has_codex'

    _codex_script_test "build_codex_cmd (no args) uses interactive codex" \
        'out=$(build_codex_cmd); echo "$out" | grep -qE "^codex --sandbox danger-full-access"'
    _codex_script_test "build_codex_cmd -p switches to codex exec" \
        'out=$(build_codex_cmd -p hello); echo "$out" | grep -qE "^codex exec --sandbox danger-full-access"'
    _codex_script_test "build_codex_cmd --print switches to codex exec" \
        'out=$(build_codex_cmd --print hello); echo "$out" | grep -qE "^codex exec "'
    _codex_script_test "build_codex_cmd --prompt switches to codex exec" \
        'out=$(build_codex_cmd --prompt hello); echo "$out" | grep -qE "^codex exec "'
    _codex_script_test "build_codex_cmd drops -p flag itself (positional arg remains)" \
        'out=$(build_codex_cmd -p hello); ! echo "${out%%;*}" | grep -qE " -p( |$)" && echo "$out" | grep -q hello'
    _codex_script_test "build_codex_cmd drops --continue" \
        'out=$(build_codex_cmd --continue); ! echo "$out" | grep -q -- "--continue"'
    _codex_script_test "build_codex_cmd drops -c" \
        'out=$(build_codex_cmd -c); ! echo "$out" | grep -qE " -c( |$)"'
    _codex_script_test "build_codex_cmd honors CODEX_MODEL" \
        'out=$(CODEX_MODEL=gpt-5.1 build_codex_cmd); echo "$out" | grep -q "gpt-5.1"'
    _codex_script_test "build_codex_cmd always sets --sandbox danger-full-access" \
        'out=$(build_codex_cmd); echo "$out" | grep -q -- "--sandbox danger-full-access"'
    _codex_script_test "build_codex_cmd verbose appends exit-code echo" \
        'out=$(SANDY_VERBOSE=1 build_codex_cmd); echo "$out" | grep -q "Codex CLI exited"'
fi

# ============================================================
info "28c. Codex config.toml seeding"
# ============================================================
_CODEX_SEED_BLOCK="$(awk '
    /^if _sandy_agent_has codex; then$/ && !seen {seen=1; printing=1}
    printing {print}
    printing && /^fi$/ {exit}
' "$SANDY_SCRIPT")"

if [ -z "$_CODEX_SEED_BLOCK" ]; then
    fail "could not extract codex sandbox seeding block from sandy"
else
    _CSEED_TMP="$(mktemp -d)"
    SANDBOX_DIR="$_CSEED_TMP" bash -c "
        info() { :; }
        _sandy_agent_has() { case \",\$SANDY_AGENT,\" in *,\"\$1\",*) return 0 ;; esac; return 1; }
        SANDY_AGENT=codex
        $_CODEX_SEED_BLOCK
    "

    if [ -f "$_CSEED_TMP/codex/config.toml" ]; then
        pass "codex/config.toml created on first run"
    else
        fail "codex/config.toml created on first run"
    fi

    if grep -q 'sandbox_mode = "danger-full-access"' "$_CSEED_TMP/codex/config.toml" 2>/dev/null; then
        pass "codex/config.toml sets sandbox_mode = danger-full-access"
    else
        fail "codex/config.toml sets sandbox_mode = danger-full-access"
    fi

    if grep -q 'model = "gpt-5.4"' "$_CSEED_TMP/codex/config.toml" 2>/dev/null; then
        pass "codex/config.toml sets default model = gpt-5.4"
    else
        fail "codex/config.toml sets default model = gpt-5.4"
    fi

    _notice_count=$(grep -cE '^(hide_|"hide)' "$_CSEED_TMP/codex/config.toml" 2>/dev/null || echo 0)
    if [ "$_notice_count" -ge 5 ]; then
        pass "codex/config.toml seeds all 5 [notice] hide_* keys"
    else
        fail "codex/config.toml seeds all 5 [notice] hide_* keys (found: $_notice_count)"
    fi

    # Idempotency: re-run must not overwrite user edits
    echo "# user edit" >> "$_CSEED_TMP/codex/config.toml"
    SANDBOX_DIR="$_CSEED_TMP" bash -c "
        info() { :; }
        _sandy_agent_has() { case \",\$SANDY_AGENT,\" in *,\"\$1\",*) return 0 ;; esac; return 1; }
        SANDY_AGENT=codex
        $_CODEX_SEED_BLOCK
    "
    if grep -q '^# user edit$' "$_CSEED_TMP/codex/config.toml"; then
        pass "codex/config.toml re-run preserves user edits (idempotent)"
    else
        fail "codex/config.toml re-run preserves user edits (idempotent)"
    fi

    rm -rf "$_CSEED_TMP"
fi

# ============================================================
info "28d. Codex config allowlist, dispatch, alias, update regex"
# ============================================================

# Allowlist must include the codex variables. v0.12+: these now live in the
# SANDY_PRIVILEGED_KEYS / SANDY_PASSIVE_KEYS arrays rather than an inline
# pipe-delimited case pattern, so check each key independently.
_CODEX_VARS_MISSING=""
for _k in OPENAI_API_KEY CODEX_MODEL SANDY_CODEX_AUTH CODEX_HOME; do
    if ! awk '/^SANDY_(PRIVILEGED|PASSIVE)_KEYS=\(/,/^\)$/' "$SANDY_SCRIPT" \
         | grep -qE "^[[:space:]]+${_k}$"; then
        _CODEX_VARS_MISSING="${_CODEX_VARS_MISSING} ${_k}"
    fi
done
if [ -z "$_CODEX_VARS_MISSING" ]; then
    pass "config allowlist includes OPENAI_API_KEY, CODEX_MODEL, SANDY_CODEX_AUTH, CODEX_HOME"
else
    fail "config allowlist missing codex variables:${_CODEX_VARS_MISSING}"
fi
unset _CODEX_VARS_MISSING _k

# Agent dispatch case-statement must map codex → sandy-codex.
if grep -qE 'codex\)[[:space:]]+IMAGE_NAME="sandy-codex"' "$SANDY_SCRIPT"; then
    pass "agent dispatch: codex → sandy-codex"
else
    fail "agent dispatch: codex → sandy-codex"
fi

# Invalid SANDY_AGENT values must be rejected with a clear error that lists
# the valid agent names. We match against the error string in the source
# rather than running sandy (which would need Docker).
if grep -qE "Invalid agent.*valid: claude.*gemini.*codex" "$SANDY_SCRIPT"; then
    pass "invalid agent error lists valid agent names"
else
    fail "invalid agent error lists valid agent names"
fi

# Dockerfile.codex generator: extract and run into a tempdir, verify content.
_DOCKERFILE_CODEX_FN="$(sed -n '/^generate_dockerfile_codex()/,/^}$/p' "$SANDY_SCRIPT")"

if [ -z "$_DOCKERFILE_CODEX_FN" ]; then
    fail "could not extract generate_dockerfile_codex function"
else
    _DF_TMP="$(mktemp -d)"
    bash -c "
        SANDY_HOME='$_DF_TMP'
        BASE_IMAGE_NAME='sandy-base'
        $_DOCKERFILE_CODEX_FN
        generate_dockerfile_codex
    " 2>/dev/null

    if [ -f "$_DF_TMP/Dockerfile.codex.new" ]; then
        pass "generate_dockerfile_codex writes Dockerfile.codex.new"
    else
        fail "generate_dockerfile_codex writes Dockerfile.codex.new"
    fi

    if grep -q "FROM sandy-base" "$_DF_TMP/Dockerfile.codex.new" 2>/dev/null; then
        pass "Dockerfile.codex derives from sandy-base"
    else
        fail "Dockerfile.codex derives from sandy-base"
    fi

    if grep -q "npm install -g @openai/codex" "$_DF_TMP/Dockerfile.codex.new" 2>/dev/null; then
        pass "Dockerfile.codex installs @openai/codex"
    else
        fail "Dockerfile.codex installs @openai/codex"
    fi

    if grep -q "/opt/codex/.version" "$_DF_TMP/Dockerfile.codex.new" 2>/dev/null; then
        pass "Dockerfile.codex caches version to /opt/codex/.version"
    else
        fail "Dockerfile.codex caches version to /opt/codex/.version"
    fi

    if grep -q "uv tool install.*synthkit" "$_DF_TMP/Dockerfile.codex.new" 2>/dev/null; then
        pass "Dockerfile.codex installs synthkit"
    else
        fail "Dockerfile.codex installs synthkit"
    fi

    rm -rf "$_DF_TMP"
fi

# Update check sed regex: feed it sample tag_name JSON fragments and verify
# the version is extracted correctly. This is the regex from _check_codex_update.
# The real callsite uses `|| true` to fail-soft on pipeline failures; we do the
# same here so empty/missing inputs don't trip `set -euo pipefail`.
_codex_parse_tag() {
    { echo "$1" \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' 2>/dev/null | head -1 \
        | sed -E 's/.*"rust-v?([0-9][^"]*)"$/\1/'; } || true
}

_r="$(_codex_parse_tag '{"tag_name":"rust-v0.119.0","name":"foo"}')"
if [ "$_r" = "0.119.0" ]; then
    pass "update check parses rust-v0.119.0 → 0.119.0"
else
    fail "update check parses rust-v0.119.0 (got: $_r)"
fi

_r="$(_codex_parse_tag '{"tag_name":"rust-v1.0.0-beta.3"}')"
if [ "$_r" = "1.0.0-beta.3" ]; then
    pass "update check parses rust-v1.0.0-beta.3 → 1.0.0-beta.3"
else
    fail "update check parses rust-v1.0.0-beta.3 (got: $_r)"
fi

_r="$(_codex_parse_tag '')"
if [ -z "$_r" ]; then
    pass "update check returns empty on empty input (fail-soft)"
else
    fail "update check returns empty on empty input (got: $_r)"
fi

_r="$(_codex_parse_tag '{"message":"Not Found"}')"
if [ -z "$_r" ]; then
    pass "update check returns empty when tag_name absent (fail-soft)"
else
    fail "update check returns empty when tag_name absent (got: $_r)"
fi

# Trust entry block: idempotent append on ~/.codex/config.toml.
_TRUST_BLOCK="$(awk '
    /^if _sandy_has_codex; then$/ && !seen {seen=1; printing=1}
    printing {print}
    printing && /^fi$/ {exit}
' "$SANDY_SCRIPT")"

if [ -z "$_TRUST_BLOCK" ]; then
    fail "could not extract codex trust-entry block"
else
    _TRUST_TMP="$(mktemp -d)"
    mkdir -p "$_TRUST_TMP/.codex"
    cat > "$_TRUST_TMP/.codex/config.toml" <<'TOML'
model = "gpt-5.4"
sandbox_mode = "danger-full-access"

[notice]
hide_full_access_warning = true
TOML

    HOME="$_TRUST_TMP" SANDY_WORKSPACE="/home/claude/myproj" SANDY_AGENT=codex \
        bash -c "
            _sandy_has_codex() { case \",\${SANDY_AGENT:-claude},\" in *,codex,*) return 0 ;; esac; return 1; }
            $_TRUST_BLOCK
        " 2>/dev/null

    if grep -q '^\[projects\."/home/claude/myproj"\]$' "$_TRUST_TMP/.codex/config.toml"; then
        pass "trust entry appended for SANDY_WORKSPACE"
    else
        fail "trust entry appended for SANDY_WORKSPACE"
    fi

    if grep -q '^trust_level = "trusted"$' "$_TRUST_TMP/.codex/config.toml"; then
        pass "trust entry includes trust_level = trusted"
    else
        fail "trust entry includes trust_level = trusted"
    fi

    # Idempotency: second run must not duplicate.
    HOME="$_TRUST_TMP" SANDY_WORKSPACE="/home/claude/myproj" SANDY_AGENT=codex \
        bash -c "
            _sandy_has_codex() { case \",\${SANDY_AGENT:-claude},\" in *,codex,*) return 0 ;; esac; return 1; }
            $_TRUST_BLOCK
        " 2>/dev/null

    _count=$(grep -c '^\[projects\."/home/claude/myproj"\]$' "$_TRUST_TMP/.codex/config.toml" 2>/dev/null || echo 0)
    if [ "$_count" = "1" ]; then
        pass "trust entry idempotent on repeat invocation"
    else
        fail "trust entry idempotent on repeat invocation (count: $_count)"
    fi

    # Non-codex agents must not touch the config.
    echo "# marker" > "$_TRUST_TMP/.codex/config.toml"
    HOME="$_TRUST_TMP" SANDY_WORKSPACE="/home/claude/myproj" SANDY_AGENT=claude \
        bash -c "
            _sandy_has_codex() { case \",\${SANDY_AGENT:-claude},\" in *,codex,*) return 0 ;; esac; return 1; }
            $_TRUST_BLOCK
        " 2>/dev/null

    if [ "$(cat "$_TRUST_TMP/.codex/config.toml")" = "# marker" ]; then
        pass "trust entry block is a no-op for non-codex agents"
    else
        fail "trust entry block is a no-op for non-codex agents"
    fi

    rm -rf "$_TRUST_TMP"
fi

# Feature guards: the SANDY_SKILL_PACKS guard must reject non-claude agents.
# Structure: `if ! _sandy_agent_has claude && [ -n "${SANDY_SKILL_PACKS:-}" ]; then ERROR ...`
check "SANDY_SKILL_PACKS guard rejects non-claude agents" \
    grep -q '! _sandy_agent_has claude.*SANDY_SKILL_PACKS' "$SANDY_SCRIPT"

# The --remote and SANDY_CHANNELS=discord guards should also catch codex.
# These use different structures, so match by pattern in the error text.
if grep -qE '\-\-remote is only supported with SANDY_AGENT=claude' "$SANDY_SCRIPT"; then
    pass "--remote guard error says claude-only"
else
    fail "--remote guard error says claude-only"
fi

# The --remote guard condition must reject ANY non-claude agent (including codex).
# Uses `! _sandy_agent_has claude || [ "$_SANDY_IS_MULTI" = true ]`.
check "--remote guard condition rejects non-claude and multi-agent" \
    grep -q '! _sandy_agent_has claude.*_SANDY_IS_MULTI.*true' "$SANDY_SCRIPT"

# Discord guard must reject non-claude agents (covers codex, gemini).
# The guard uses `$SANDY_AGENT != "claude"` with a case match on *,discord,*.
check "discord channel guard rejects non-claude agents" \
    grep -q 'SANDY_CHANNELS=discord is only supported with SANDY_AGENT=claude' "$SANDY_SCRIPT"

# ============================================================
info "28e. Codex infrastructure — mounts, env, credentials, cleanup"
# ============================================================

# Sandbox dir creation: codex block must create codex/ subdir.
check "sandbox layout creates codex/ subdir for SANDY_AGENT=codex" \
    grep -q 'mkdir -p "$SANDBOX_DIR/codex"' "$SANDY_SCRIPT"

# Mount block: codex sandbox mounted at ~/.codex.
check "codex sandbox mounted at /home/claude/.codex" \
    grep -q 'SANDBOX_DIR/codex:/home/claude/.codex' "$SANDY_SCRIPT"

# Auth.json mounted read-only.
check "codex auth.json mount is read-only (:ro)" \
    grep -q 'auth.json:/home/claude/.codex/auth.json:ro' "$SANDY_SCRIPT"

# Env passthrough: OPENAI_API_KEY forwarded to container (codex reads this).
check "OPENAI_API_KEY passed to container via -e" \
    grep -q 'RUN_FLAGS+=(-e "OPENAI_API_KEY=' "$SANDY_SCRIPT"

# Env passthrough: CODEX_MODEL forwarded to container.
check "CODEX_MODEL passed to container via -e" \
    grep -q 'RUN_FLAGS+=(-e "CODEX_MODEL=' "$SANDY_SCRIPT"

# Cleanup trap must clean CODEX_CRED_TMPDIR.
check "cleanup trap removes CODEX_CRED_TMPDIR" \
    grep -q 'rm -rf "$CODEX_CRED_TMPDIR"' "$SANDY_SCRIPT"

# Credential loader: load_codex_credentials function exists.
check "load_codex_credentials function exists" \
    grep -q '^load_codex_credentials()' "$SANDY_SCRIPT"

# Dockerfile path dispatch: codex maps to Dockerfile.codex.
check "DOCKERFILE_PATH dispatch includes codex → Dockerfile.codex" \
    grep -q 'DOCKERFILE_PATH="$SANDY_HOME/Dockerfile.codex"' "$SANDY_SCRIPT"

# Build hash file: codex gets its own .build_hash_codex.
check "BUILD_HASH_FILE_NAME dispatch includes codex → .build_hash_codex" \
    grep -q '.build_hash_codex' "$SANDY_SCRIPT"

# .claude.json seeding gate uses _sandy_agent_has (covers multi-agent combos).
check ".claude.json seeding gate uses _sandy_agent_has claude" \
    grep -q '_sandy_agent_has claude && .*CLAUDE_JSON' "$SANDY_SCRIPT"

# SANDY_GEMINI_AUTH is in the config allowlist.
check "config allowlist includes SANDY_GEMINI_AUTH" \
    grep -q 'SANDY_GEMINI_AUTH' "$SANDY_SCRIPT"

# Synthkit skills block for codex: creates SKILL.md files with YAML frontmatter.
check "codex synthkit seeds ~/.codex/skills/ with SKILL.md files" \
    grep -q '\.codex/skills/md2pdf/SKILL.md' "$SANDY_SCRIPT"

# ============================================================
info "28f. Script syntax and version"
# ============================================================

check "sandy script passes bash -n syntax check" \
    bash -n "$SANDY_SCRIPT"

# Version string is defined exactly once.
_ver_count="$(grep -c '^SANDY_VERSION=' "$SANDY_SCRIPT" || true)"
if [ "$_ver_count" = "1" ]; then
    pass "SANDY_VERSION defined exactly once"
else
    fail "SANDY_VERSION defined exactly once (found: $_ver_count)"
fi

# Version string contains expected major.minor.
if grep -q '^SANDY_VERSION="0\.12\.' "$SANDY_SCRIPT"; then
    pass "SANDY_VERSION is 0.12.x"
else
    fail "SANDY_VERSION is 0.12.x"
fi

# ============================================================
info "29. v1 → v1.5 sandbox layout migration"
# ============================================================
# Extract the migration block from sandy and exercise it against fake
# sandbox directories in a tempdir. The block references $SANDBOX_DIR and
# calls info() — we provide both.

_MIG_SNIPPET="$(sed -n '/^_v1_claude_entries=/,/^fi$/p' "$SANDY_SCRIPT")"

if [ -z "$_MIG_SNIPPET" ]; then
    fail "could not extract v1.5 migration block from sandy"
else
    _MIG_TMP="$(mktemp -d)"
    _run_migration() {
        # Provide stub info() (sandy uses it for user-visible log lines) and
        # point SANDBOX_DIR at the passed-in fixture.
        SANDBOX_DIR="$1" bash -c "
            info() { :; }
            $_MIG_SNIPPET
        "
    }

    # ---- Test A: clean v1 → v1.5 migration with expanded allowlist ----
    SB_A="$_MIG_TMP/sb_clean"
    mkdir -p "$SB_A"
    touch "$SB_A/settings.json"
    mkdir -p "$SB_A/projects" "$SB_A/cache" "$SB_A/sessions" \
             "$SB_A/plans" "$SB_A/telemetry" "$SB_A/file-history"
    _run_migration "$SB_A"

    check "migration: settings.json moved under claude/" \
        test -f "$SB_A/claude/settings.json"
    check "migration: projects/ moved under claude/" \
        test -d "$SB_A/claude/projects"
    check "migration: cache/ (expanded allowlist) moved under claude/" \
        test -d "$SB_A/claude/cache"
    check "migration: sessions/ moved under claude/" \
        test -d "$SB_A/claude/sessions"
    check "migration: plans/ (expanded allowlist) moved under claude/" \
        test -d "$SB_A/claude/plans"
    check "migration: telemetry/ (expanded allowlist) moved under claude/" \
        test -d "$SB_A/claude/telemetry"
    check "migration: file-history/ (expanded allowlist) moved under claude/" \
        test -d "$SB_A/claude/file-history"
    check "migration: top level cleared of claude entries" \
        bash -c '! ls "$1" 2>/dev/null | grep -qE "^(settings\.json|projects|cache|sessions|plans|telemetry|file-history)$"' -- "$SB_A"

    # ---- Test B: idempotent (second pass is a no-op) ----
    _run_migration "$SB_A"
    check "migration idempotent: no .v1-backup created on clean re-run" \
        test ! -d "$SB_A/.v1-backup"
    check "migration idempotent: claude/settings.json still present" \
        test -f "$SB_A/claude/settings.json"

    # ---- Test C: conflict quarantine (stale top-level + live claude/) ----
    SB_C="$_MIG_TMP/sb_conflict"
    mkdir -p "$SB_C/claude/commands"
    echo "authoritative" > "$SB_C/claude/commands/fresh.toml"
    mkdir -p "$SB_C/commands"
    echo "stale" > "$SB_C/commands/old.toml"
    _run_migration "$SB_C"

    check "conflict: stale commands/ quarantined to .v1-backup/" \
        bash -c 'ls "$1"/.v1-backup/commands.* >/dev/null 2>&1' -- "$SB_C"
    check "conflict: authoritative claude/commands/fresh.toml preserved" \
        test -f "$SB_C/claude/commands/fresh.toml"
    check "conflict: authoritative claude/commands/fresh.toml content preserved" \
        bash -c 'grep -q authoritative "$1/claude/commands/fresh.toml"' -- "$SB_C"
    check "conflict: stale top-level commands/ removed" \
        test ! -d "$SB_C/commands"
    check "conflict: quarantined file content preserved" \
        bash -c 'grep -rq stale "$1/.v1-backup/"' -- "$SB_C"

    # ---- Test D: no leftovers → no-op (doesn't create empty claude/) ----
    SB_D="$_MIG_TMP/sb_empty"
    mkdir -p "$SB_D"
    _run_migration "$SB_D"
    check "no leftovers: migration does not create empty claude/ dir" \
        test ! -d "$SB_D/claude"

    rm -rf "$_MIG_TMP"
fi

# ============================================================
info "30. Gemini CLI in-container (sandy-gemini-cli image)"
# ============================================================
# In-container smoke tests against the sandy-gemini-cli image. Skipped if
# the image hasn't been built (e.g. on hosts that only use Claude).

if docker image inspect sandy-gemini-cli &>/dev/null; then
    _gemini_in_container() {
        docker run --rm --read-only \
            --tmpfs /tmp:exec,size=64M \
            --tmpfs /home/claude:exec,size=64M,uid=1001,gid=1001 \
            --user 1001:1001 \
            -e HOME=/home/claude \
            --entrypoint bash \
            sandy-gemini-cli -c "$1" >/dev/null 2>&1
    }

    check "gemini binary on PATH" \
        _gemini_in_container "command -v gemini"
    check "gemini --version runs" \
        _gemini_in_container "gemini --version"
    check "node is available (required by gemini CLI)" \
        _gemini_in_container "node --version"

    # Sanity: the base Claude toolchain should still be present in the multi-agent image
    # (we're only checking gemini-cli here; sandy-full would be a separate check).
else
    printf "  \033[0;33m⊘ skipped — sandy-gemini-cli image not built\033[0m\n"
fi

# ============================================================
info "31. Sprint 1 — Absent protected dirs blocked by empty-ro fixtures"
# ============================================================
# F3 remediation (dirs): protected directories are always-mounted. If the host
# has no .vscode/, .idea/, .github/workflows/, etc., sandy overlays an empty
# read-only directory at that container path, so the agent cannot create files
# under those paths from inside the container. Empty dirs on the host are
# benign — git doesn't track them and no tool reacts to their mere presence.
#
# NOTE: Protected FILES are existence-gated, not always-mounted. See the
# comment block in sandy where the protected-files loop runs: Docker auto-
# creates bind-mount targets on the host inside the rw workspace bind, which
# stubbed .bashrc/.envrc/etc. as 0-byte files in every workspace — breaking
# direnv and polluting `git status`. The residual F3 gap for files is an
# agent creating them in-session; the new file then shows up in `git status`
# on the host, which is the review path.

# Clean slate — no host-side copies of any protected path.
rm -rf "$TEST_PROJECT/.bashrc" "$TEST_PROJECT/.vscode" "$TEST_PROJECT/.idea" \
       "$TEST_PROJECT/.envrc" "$TEST_PROJECT/.github" "$TEST_PROJECT/.devcontainer" \
       "$TEST_PROJECT/.git"

# Directories that didn't exist on host can't be created inside container
sandy_run "mkdir /workspace/.vscode 2>/dev/null && touch /workspace/.vscode/settings.json 2>/dev/null" \
    >/dev/null 2>&1 && MK_VSCODE=yes || MK_VSCODE=no
check "cannot create files under absent .vscode/" test "$MK_VSCODE" = "no"

sandy_run "mkdir /workspace/.idea 2>/dev/null && touch /workspace/.idea/workspace.xml 2>/dev/null" \
    >/dev/null 2>&1 && MK_IDEA=yes || MK_IDEA=no
check "cannot create files under absent .idea/" test "$MK_IDEA" = "no"

sandy_run "mkdir -p /workspace/.github/workflows 2>/dev/null && touch /workspace/.github/workflows/ci.yml 2>/dev/null" \
    >/dev/null 2>&1 && MK_WORKFLOWS=yes || MK_WORKFLOWS=no
check "cannot create files under absent .github/workflows/" test "$MK_WORKFLOWS" = "no"

# ============================================================
info "32. Sprint 1 — Expanded protected-files list"
# ============================================================
# F4 remediation: additional shell-sourced / tool-config files now protected.

for _f in .envrc .tool-versions .mise.toml .npmrc .yarnrc .yarnrc.yml .pypirc .netrc .pre-commit-config.yaml; do
    echo "# host $_f" > "$TEST_PROJECT/$_f"
done

for _f in .envrc .tool-versions .mise.toml .npmrc .yarnrc .yarnrc.yml .pypirc .netrc .pre-commit-config.yaml; do
    sandy_run "echo evil >> /workspace/$_f 2>/dev/null" >/dev/null 2>&1 && _WR=yes || _WR=no
    check "cannot write present $_f" test "$_WR" = "no"
done

# Cleanup
for _f in .envrc .tool-versions .mise.toml .npmrc .yarnrc .yarnrc.yml .pypirc .netrc .pre-commit-config.yaml; do
    rm -f "$TEST_PROJECT/$_f"
done

# ============================================================
info "33. Sprint 1 — .github/workflows opt-in via SANDY_ALLOW_WORKFLOW_EDIT"
# ============================================================
# When SANDY_ALLOW_WORKFLOW_EDIT=1 is exported, .github/workflows is not
# protected by sandy's launcher and the test harness should get the same
# list from --print-protected-paths.

# With default (opt-out not set): workflows listed as a protected dir
_SANDY_BIN="$(cd "$(dirname "$0")/.." && pwd)/sandy"
_PROTECTED_DEFAULT="$("$_SANDY_BIN" --print-protected-paths 2>/dev/null)"
check "default: .github/workflows in protected list" \
    bash -c 'echo "$1" | grep -q "^dir:.github/workflows$"' -- "$_PROTECTED_DEFAULT"

# With SANDY_ALLOW_WORKFLOW_EDIT=1: workflows absent from list
_PROTECTED_OPT_OUT="$(SANDY_ALLOW_WORKFLOW_EDIT=1 "$_SANDY_BIN" --print-protected-paths 2>/dev/null)"
check "opt-out: .github/workflows absent from protected list" \
    bash -c '! echo "$1" | grep -q "^dir:.github/workflows$"' -- "$_PROTECTED_OPT_OUT"

# ============================================================
info "34. Sprint 1 — Submodule gitdir protection"
# ============================================================
# F1 remediation: .git/modules/<sub>/hooks/ and config were fully writable.

# Fixture: a minimal repo layout with a submodule gitdir
mkdir -p "$TEST_PROJECT/.git/modules/fake-sub/hooks"
mkdir -p "$TEST_PROJECT/.git/modules/fake-sub/info"
echo "[core]" > "$TEST_PROJECT/.git/modules/fake-sub/config"
echo "#!/bin/sh" > "$TEST_PROJECT/.git/modules/fake-sub/hooks/pre-commit"
chmod +x "$TEST_PROJECT/.git/modules/fake-sub/hooks/pre-commit"
echo "" > "$TEST_PROJECT/.git/modules/fake-sub/info/attributes"

sandy_run "echo injected > /workspace/.git/modules/fake-sub/hooks/post-checkout 2>/dev/null" \
    >/dev/null 2>&1 && WR_SUBMODULE_HOOK=yes || WR_SUBMODULE_HOOK=no
check "cannot create submodule post-checkout hook" test "$WR_SUBMODULE_HOOK" = "no"

sandy_run "echo evil >> /workspace/.git/modules/fake-sub/config 2>/dev/null" \
    >/dev/null 2>&1 && WR_SUBMODULE_CFG=yes || WR_SUBMODULE_CFG=no
check "cannot modify submodule config" test "$WR_SUBMODULE_CFG" = "no"

sandy_run "echo '*.txt filter=evil' >> /workspace/.git/modules/fake-sub/info/attributes 2>/dev/null" \
    >/dev/null 2>&1 && WR_SUBMODULE_INFO=yes || WR_SUBMODULE_INFO=no
check "cannot modify submodule info/attributes" test "$WR_SUBMODULE_INFO" = "no"

# ============================================================
info "35. Sprint 1 — .git/info/ protection (filter-driver vector)"
# ============================================================
# F1 (top-level): .git/info/attributes registers filter drivers that run
# during checkout. Needs to be read-only.

mkdir -p "$TEST_PROJECT/.git/info"
echo "" > "$TEST_PROJECT/.git/info/attributes"

sandy_run "echo '*.txt filter=evil' >> /workspace/.git/info/attributes 2>/dev/null" \
    >/dev/null 2>&1 && WR_GITINFO=yes || WR_GITINFO=no
check "cannot modify .git/info/attributes" test "$WR_GITINFO" = "no"

# .git/HEAD and .git/packed-refs too
echo "ref: refs/heads/main" > "$TEST_PROJECT/.git/HEAD"
echo "# pack-refs" > "$TEST_PROJECT/.git/packed-refs"

sandy_run "echo 'ref: refs/heads/pwned' > /workspace/.git/HEAD 2>/dev/null" \
    >/dev/null 2>&1 && WR_HEAD=yes || WR_HEAD=no
check "cannot overwrite .git/HEAD" test "$WR_HEAD" = "no"

rm -rf "$TEST_PROJECT/.git"

# ============================================================
info "36. Sprint 1 — Tier-split config (privileged keys dropped from workspace)"
# ============================================================
# F5 remediation: _load_sandy_config now takes a tier argument. Privileged
# keys from passive (workspace) sources warn and drop. Pure bash test of the
# parser — no docker needed.

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"
TIER_TEST_FILE="$(mktemp)"
cat > "$TIER_TEST_FILE" <<'EOF'
SANDY_SKIP_PERMISSIONS=1
SANDY_ALLOW_NO_ISOLATION=1
SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0
SANDY_SSH=agent
ANTHROPIC_API_KEY=sk-attacker
SANDY_MODEL=claude-opus-4-6
SANDY_VERBOSE=1
EOF

# Extract the loader function from the live sandy script to a temp file so
# we can source it without nested process substitution (bash 3.2 on macOS
# does not reliably handle `source <(sed ...)` inside `$(...)`).
#
# v0.12+: the loader uses the SANDY_{PRIVILEGED,PASSIVE,ENV_ONLY}_KEYS arrays
# and the _key_in_list() helper — all defined at the top of the sandy script
# before the loader. Extract both blocks into the single source file.
_LOADER_SRC="$(mktemp)"
# Arrays + _key_in_list() — range ends at the first bare `}` (closing
# _key_in_list), which is also the last `}` before the loader definition.
sed -n '/^SANDY_PRIVILEGED_KEYS=(/,/^}$/p' "$SANDY_SCRIPT_PATH" > "$_LOADER_SRC"
printf '\n' >> "$_LOADER_SRC"
sed -n '/^_load_sandy_config() {/,/^}$/p' "$SANDY_SCRIPT_PATH" >> "$_LOADER_SRC"

# Extract + source _load_sandy_config, call with tier=passive, and verify
# privileged keys were not exported.
_TIER_RESULT="$(
    # shellcheck disable=SC1090
    source "$_LOADER_SRC"
    warn() { echo "warn:$*" >&2; }
    unset SANDY_SKIP_PERMISSIONS SANDY_ALLOW_NO_ISOLATION SANDY_ALLOW_LAN_HOSTS \
          SANDY_SSH ANTHROPIC_API_KEY SANDY_MODEL SANDY_VERBOSE
    _load_sandy_config "$TIER_TEST_FILE" passive 2>/dev/null || true
    # Passive keys should pass through
    echo "SANDY_MODEL=${SANDY_MODEL:-UNSET}"
    echo "SANDY_VERBOSE=${SANDY_VERBOSE:-UNSET}"
    # Privileged keys should be dropped
    echo "SANDY_SKIP_PERMISSIONS=${SANDY_SKIP_PERMISSIONS:-UNSET}"
    echo "SANDY_ALLOW_NO_ISOLATION=${SANDY_ALLOW_NO_ISOLATION:-UNSET}"
    echo "SANDY_ALLOW_LAN_HOSTS=${SANDY_ALLOW_LAN_HOSTS:-UNSET}"
    echo "SANDY_SSH=${SANDY_SSH:-UNSET}"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-UNSET}"
)"

check "passive tier: SANDY_MODEL honored" \
    bash -c 'echo "$1" | grep -q "^SANDY_MODEL=claude-opus-4-6$"' -- "$_TIER_RESULT"
check "passive tier: SANDY_VERBOSE honored" \
    bash -c 'echo "$1" | grep -q "^SANDY_VERBOSE=1$"' -- "$_TIER_RESULT"
check "passive tier: SANDY_SKIP_PERMISSIONS dropped" \
    bash -c 'echo "$1" | grep -q "^SANDY_SKIP_PERMISSIONS=UNSET$"' -- "$_TIER_RESULT"
check "passive tier: SANDY_ALLOW_NO_ISOLATION dropped" \
    bash -c 'echo "$1" | grep -q "^SANDY_ALLOW_NO_ISOLATION=UNSET$"' -- "$_TIER_RESULT"
check "passive tier: SANDY_ALLOW_LAN_HOSTS dropped" \
    bash -c 'echo "$1" | grep -q "^SANDY_ALLOW_LAN_HOSTS=UNSET$"' -- "$_TIER_RESULT"
check "passive tier: SANDY_SSH dropped" \
    bash -c 'echo "$1" | grep -q "^SANDY_SSH=UNSET$"' -- "$_TIER_RESULT"
check "passive tier: ANTHROPIC_API_KEY dropped" \
    bash -c 'echo "$1" | grep -q "^ANTHROPIC_API_KEY=UNSET$"' -- "$_TIER_RESULT"

# Privileged tier: all keys honored
_PRIV_RESULT="$(
    # shellcheck disable=SC1090
    source "$_LOADER_SRC"
    warn() { :; }
    unset SANDY_SKIP_PERMISSIONS ANTHROPIC_API_KEY SANDY_SSH
    _load_sandy_config "$TIER_TEST_FILE" privileged 2>/dev/null || true
    echo "SANDY_SKIP_PERMISSIONS=${SANDY_SKIP_PERMISSIONS:-UNSET}"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-UNSET}"
    echo "SANDY_SSH=${SANDY_SSH:-UNSET}"
)"
check "privileged tier: SANDY_SKIP_PERMISSIONS honored" \
    bash -c 'echo "$1" | grep -q "^SANDY_SKIP_PERMISSIONS=1$"' -- "$_PRIV_RESULT"
check "privileged tier: ANTHROPIC_API_KEY honored" \
    bash -c 'echo "$1" | grep -q "^ANTHROPIC_API_KEY=sk-attacker$"' -- "$_PRIV_RESULT"
check "privileged tier: SANDY_SSH honored" \
    bash -c 'echo "$1" | grep -q "^SANDY_SSH=agent$"' -- "$_PRIV_RESULT"

rm -f "$TIER_TEST_FILE"

# ============================================================
info "37. Sprint 1 — World-open LAN allowlist rejected"
# ============================================================
# F5 subfix: SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0 should hard-error even from a
# privileged source. Test by directly sourcing the loader + running the sanity
# block (use the temp-file loader source established for test 36, which is
# bash-3.2-safe — nested `source <(...)` inside `$(...)` breaks on macOS).

# Stand up a temp $SANDY_HOME so the check doesn't trip on real user config
_TMP_SANDY_HOME="$(mktemp -d)"
mkdir -p "$_TMP_SANDY_HOME"
cat > "$_TMP_SANDY_HOME/config" <<'EOF'
SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0
EOF

# NOTE on comments inside the subshell below: bash 3.2 (macOS default) has a
# parser bug where apostrophes inside # comments inside $(...) command
# substitution are treated as opening single quotes, causing the parser to
# scan forward past EOF looking for a matching close. ALL comments inside the
# subshell must be apostrophe-free. Use plain ASCII; rephrase contractions.
_LAN_RESULT="$(
    set +e
    # shellcheck disable=SC1090
    source "$_LOADER_SRC"
    warn() { :; }
    error() { echo "ERROR: $*" >&2; }
    _load_sandy_config "$_TMP_SANDY_HOME/config" privileged 2>/dev/null || true
    # Run the sanity check block inline.
    if [ -n "${SANDY_ALLOW_LAN_HOSTS:-}" ]; then
        IFS=',' read -ra _sanity_hosts <<< "$SANDY_ALLOW_LAN_HOSTS"
        set +u
        for _h in "${_sanity_hosts[@]}"; do
            _h="$(echo "$_h" | tr -d "[:space:]")"
            [ -z "$_h" ] && continue
            # Plain string tests because bash 3.2 on macOS misparses case
            # patterns containing slash inside nested command substitution.
            # exit 0 because the outer set -e trap will fire on a non-zero
            # _LAN_RESULT assignment; the outer check greps stdout instead.
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
)"
check "0.0.0.0/0 in SANDY_ALLOW_LAN_HOSTS rejected" \
    bash -c 'echo "$1" | grep -q "^REJECTED:0.0.0.0/0$"' -- "$_LAN_RESULT"

rm -rf "$_TMP_SANDY_HOME"
rm -f "$_LOADER_SRC"

# ============================================================
info "38. Sprint 1 — --print-protected-paths flag"
# ============================================================
# S1.8: test harness and sandy share the protected-path list via this flag.

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"
_PRINT_OUT="$("$SANDY_SCRIPT_PATH" --print-protected-paths 2>/dev/null)"

check "--print-protected-paths emits file: entries" \
    bash -c 'echo "$1" | grep -q "^file:.bashrc$"' -- "$_PRINT_OUT"
check "--print-protected-paths emits gitfile: entries" \
    bash -c 'echo "$1" | grep -q "^gitfile:.git/config$"' -- "$_PRINT_OUT"
check "--print-protected-paths emits dir: entries" \
    bash -c 'echo "$1" | grep -q "^dir:.vscode$"' -- "$_PRINT_OUT"
check "--print-protected-paths includes expanded .envrc" \
    bash -c 'echo "$1" | grep -q "^file:.envrc$"' -- "$_PRINT_OUT"
check "--print-protected-paths includes .git/info" \
    bash -c 'echo "$1" | grep -q "^dir:.git/info$"' -- "$_PRINT_OUT"

# ============================================================
info "39. Sprint 1 — Empty ro-fixtures exist in SANDY_HOME"
# ============================================================
# S1.0: ensure_build_files creates $SANDY_HOME/.empty-ro-file and .empty-ro-dir.
# Verify they exist and are empty.

check ".empty-ro-file exists" test -f "$SANDY_HOME/.empty-ro-file"
check ".empty-ro-file is empty" test ! -s "$SANDY_HOME/.empty-ro-file"
check ".empty-ro-dir exists" test -d "$SANDY_HOME/.empty-ro-dir"
check ".empty-ro-dir is empty" \
    bash -c '[ -z "$(ls -A "$1")" ]' -- "$SANDY_HOME/.empty-ro-dir"

# ============================================================
info "40. Sprint 1 — Credentials mounts"
# ============================================================
# Claude credentials are rw (needed for /ultrareview token refresh); Codex/Gemini
# stay :ro. All three use ephemeral tmpdirs cleaned up on exit.

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"
check "Claude credentials mount is rw (no :ro suffix)" \
    bash -c 'grep -q "CRED_TMPDIR/.credentials.json:/home/claude/.claude/.credentials.json\")" "$1" && ! grep -q "CRED_TMPDIR/.credentials.json:/home/claude/.claude/.credentials.json:ro" "$1"' -- "$SANDY_SCRIPT_PATH"
check "Codex credentials mount has :ro" \
    grep -q 'CODEX_CRED_TMPDIR/auth.json:/home/claude/.codex/auth.json:ro' "$SANDY_SCRIPT_PATH"
check "Gemini OAuth mount has :ro" \
    grep -q 'home/claude/.gemini/.*:ro' "$SANDY_SCRIPT_PATH"
check "cleanup trap includes QUIT ABRT" \
    grep -q 'trap cleanup EXIT INT TERM HUP QUIT ABRT' "$SANDY_SCRIPT_PATH"

# ============================================================
info "41. Sprint 1 — macOS --add-host nullification is conditional"
# ============================================================
# S1.6: host.docker.internal must NOT be nullified when SANDY_SSH=agent.
# Static code check (same pattern as test 40).

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"
check "gateway.docker.internal unconditionally nullified on non-Linux" \
    grep -q '"gateway.docker.internal:127.0.0.1"' "$SANDY_SCRIPT_PATH"
check "metadata.google.internal unconditionally nullified on non-Linux" \
    grep -q '"metadata.google.internal:127.0.0.1"' "$SANDY_SCRIPT_PATH"
check "host.docker.internal guarded by SANDY_SSH check" \
    bash -c 'awk "/SANDY_SSH.*!= \"agent\"/,/fi/" "$1" | grep -q "host.docker.internal:127.0.0.1"' \
    -- "$SANDY_SCRIPT_PATH"
check "macOS network warning banner present" \
    grep -q 'Network isolation is NOT active' "$SANDY_SCRIPT_PATH"

# ============================================================
info "42. Sprint 2 — settings.json re-seed every launch (S2.1, revised 0.11.3)"
# ============================================================
# Revised approach: the Claude settings.json lives inside the rw sandbox mount
# (not a :ro sidecar — that broke /plugin install with EROFS). It is
# regenerated on every launch from the host copy with merge-preserving
# semantics: host-side edits to $HOME/.claude/settings.json propagate into
# the sandbox, but `enabledPlugins` from the previous sandbox session is
# preserved so plugin installs survive across launches.

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"

check "SEED_SETTINGS points at sandbox-internal settings.json (rw)" \
    grep -q 'SEED_SETTINGS="\$SANDBOX_DIR/claude/settings\.json"' "$SANDY_SCRIPT_PATH"

# Seed block must NOT be gated on SANDBOX_IS_NEW=true.
_SEED_OPEN_LINE="$(grep -nB0 'SEED_SETTINGS="\$SANDBOX_DIR/claude/settings\.json"' "$SANDY_SCRIPT_PATH" | head -1 | cut -d: -f1)"
_SEED_GATE_LINE="$(awk -v n="$_SEED_OPEN_LINE" 'NR<n && /if _sandy_agent_has claude/ {last=NR} END {print last}' "$SANDY_SCRIPT_PATH")"
check "seed block opener does not gate on SANDBOX_IS_NEW" \
    bash -c 'sed -n "${2}p" "$1" | grep -qv SANDBOX_IS_NEW' \
    -- "$SANDY_SCRIPT_PATH" "$_SEED_GATE_LINE"

# No :ro child overlay on settings.json (that was the pre-0.11.3 approach).
check "no :ro overlay on settings.json" \
    bash -c '! grep -q "settings\.json:ro" "$1"' -- "$SANDY_SCRIPT_PATH"

# Seed block must preserve enabledPlugins from previous sandbox settings
# so /plugin install survives across launches.
check "seed preserves enabledPlugins across launches" \
    grep -q 'if (prev.enabledPlugins) s.enabledPlugins = prev.enabledPlugins' "$SANDY_SCRIPT_PATH"

# cmux hook merge must target $SEED_SETTINGS.
_CMUX_BLOCK="$(grep -A 50 'Merge notification hook into the sandbox' "$SANDY_SCRIPT_PATH" || true)"
check "cmux merge block references SEED_SETTINGS" \
    bash -c 'echo "$1" | grep -q "SEED_SETTINGS"' -- "$_CMUX_BLOCK"

# Functional test: simulate the node merge preserving enabledPlugins across
# two "launches" where the host content changes but plugin list was modified
# mid-session in the sandbox.
if command -v node &>/dev/null; then
    _S2_SANDBOX="$(mktemp -d)"
    mkdir -p "$_S2_SANDBOX/claude"
    _S2_HOST="$(mktemp)"

    # Launch 1: host settings = {"flavor":"A"}, no prior sandbox file
    echo '{"flavor":"A"}' > "$_S2_HOST"
    SEED_HOST_SRC="$_S2_HOST" node -e '
        const fs = require("fs");
        const dst = process.argv[1];
        const hostSrc = process.env.SEED_HOST_SRC || "";
        function readJson(p) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch(e) { return {}; } }
        let s = readJson(hostSrc);
        const prev = readJson(dst);
        if (prev.enabledPlugins) s.enabledPlugins = prev.enabledPlugins;
        fs.writeFileSync(dst, JSON.stringify(s));
    ' "$_S2_SANDBOX/claude/settings.json"
    _S2_FIRST="$(jq -r '.flavor' "$_S2_SANDBOX/claude/settings.json" 2>/dev/null)"

    # Mid-session: agent installs a plugin (writes enabledPlugins into the rw file)
    node -e '
        const fs = require("fs");
        const f = process.argv[1];
        const s = JSON.parse(fs.readFileSync(f, "utf8"));
        s.enabledPlugins = {"my-plugin": true};
        fs.writeFileSync(f, JSON.stringify(s));
    ' "$_S2_SANDBOX/claude/settings.json"

    # Launch 2: host changed flavor to B; enabledPlugins must survive.
    echo '{"flavor":"B"}' > "$_S2_HOST"
    SEED_HOST_SRC="$_S2_HOST" node -e '
        const fs = require("fs");
        const dst = process.argv[1];
        const hostSrc = process.env.SEED_HOST_SRC || "";
        function readJson(p) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch(e) { return {}; } }
        let s = readJson(hostSrc);
        const prev = readJson(dst);
        if (prev.enabledPlugins) s.enabledPlugins = prev.enabledPlugins;
        fs.writeFileSync(dst, JSON.stringify(s));
    ' "$_S2_SANDBOX/claude/settings.json"
    _S2_SECOND_FLAVOR="$(jq -r '.flavor' "$_S2_SANDBOX/claude/settings.json" 2>/dev/null)"
    _S2_SECOND_PLUGIN="$(jq -r '.enabledPlugins["my-plugin"]' "$_S2_SANDBOX/claude/settings.json" 2>/dev/null)"

    check "seed regeneration picks up host changes" \
        bash -c 'test "$1" = "A" && test "$2" = "B"' -- "$_S2_FIRST" "$_S2_SECOND_FLAVOR"
    check "seed regeneration preserves enabledPlugins across launches" \
        bash -c 'test "$1" = "true"' -- "$_S2_SECOND_PLUGIN"

    rm -rf "$_S2_SANDBOX"
    rm -f "$_S2_HOST"
fi

# ============================================================
info "43. Sprint 2 — Persistent symlink approval (S2.2)"
# ============================================================
# F8 fix: the set of "approved" dangerous symlinks is persisted to the sandbox.
# A new entry that wasn't in the approved set hard-errors the launch — no
# re-prompt, no "oops I'll click y again" trainability. Removed entries are
# pruned silently.

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"

check "persisted symlink approval list path declared" \
    grep -q '\.sandy-approved-symlinks\.list' "$SANDY_SCRIPT_PATH"
check "symlink approval uses comm -23 for new-entry detection" \
    grep -q 'comm -23.*_current_tmp.*_approved_tmp' "$SANDY_SCRIPT_PATH"
check "new symlink hard-errors with specific message" \
    grep -q "Symlink escape detected that wasn't present at previous approval" "$SANDY_SCRIPT_PATH"
check "persisted list refreshed to prune removed entries" \
    grep -q 'cp "\$_current_tmp" "\$_approved_list"' "$SANDY_SCRIPT_PATH"

# Functional test: exercise the core comm-based comparison logic with fixture
# files. Scenarios: identical → empty diff; added → listed as new; removed →
# empty diff (silently pruned).
_S2_APPROVED_TMP="$(mktemp)"
_S2_CURRENT_TMP="$(mktemp)"
_S2_NEW_TMP="$(mktemp)"

# Seed the approved list
printf 'link1 -> /Users/drapp/.ssh\nlink2 -> /tmp/foo\n' | sort -u > "$_S2_APPROVED_TMP"

# Scenario 1: current set identical to approved → no new entries
printf 'link1 -> /Users/drapp/.ssh\nlink2 -> /tmp/foo\n' | sort -u > "$_S2_CURRENT_TMP"
comm -23 "$_S2_CURRENT_TMP" "$_S2_APPROVED_TMP" > "$_S2_NEW_TMP"
check "identical symlink set → empty new-entry diff (silent proceed)" \
    test ! -s "$_S2_NEW_TMP"

# Scenario 2: new entry added → detected
printf 'link1 -> /Users/drapp/.ssh\nlink2 -> /tmp/foo\nevil-link -> /etc/shadow\n' \
    | sort -u > "$_S2_CURRENT_TMP"
comm -23 "$_S2_CURRENT_TMP" "$_S2_APPROVED_TMP" > "$_S2_NEW_TMP"
check "new symlink entry detected as unapproved" \
    bash -c 'grep -q "evil-link -> /etc/shadow" "$1"' -- "$_S2_NEW_TMP"

# Scenario 3: entry removed → no new entries (silent prune)
printf 'link1 -> /Users/drapp/.ssh\n' | sort -u > "$_S2_CURRENT_TMP"
comm -23 "$_S2_CURRENT_TMP" "$_S2_APPROVED_TMP" > "$_S2_NEW_TMP"
check "removed symlink entries yield empty new-entry diff (silent prune)" \
    test ! -s "$_S2_NEW_TMP"

rm -f "$_S2_APPROVED_TMP" "$_S2_CURRENT_TMP" "$_S2_NEW_TMP"

# ============================================================
info "44. Empty stub dir cleanup (post-session + pre-existing debris)"
# ============================================================
# Docker's bind-mount target auto-creation leaves empty stub dirs (.vscode/,
# .idea/, etc.) on the host when sandy mounts .empty-ro-dir over a missing
# protected path. Two cleanup mechanisms:
#   (a) Session-scoped: sandy records each stub it creates in
#       $SANDBOX_DIR/.session-created-stubs and rmdirs them in cleanup().
#       rmdir no-ops on populated dirs so legitimate writes survive.
#   (b) Pre-existing debris from prior sandy versions: auto-removed at
#       launch under a 4-condition safety gate (git repo + name match +
#       empty + not git-tracked).

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"

check "session-created-stubs file path declared" \
    grep -q '\.session-created-stubs' "$SANDY_SCRIPT_PATH"
check "stub recorded when empty-ro-dir fallback mount is used (dirs loop)" \
    bash -c 'awk "/Record session-created stubs/,/done < <\\(_sandy_protected_dirs\\)/" "$1" | grep -q "\\.session-created-stubs"' \
    -- "$SANDY_SCRIPT_PATH"
check "stub recorded when empty-ro-dir fallback mount is used (submodule hooks)" \
    bash -c 'awk "/_protect_submodule_gitdirs\\(\\)/,/^}/" "$1" | grep -q "\\.session-created-stubs"' \
    -- "$SANDY_SCRIPT_PATH"
check "cleanup() reads session-created-stubs and rmdirs entries" \
    bash -c 'awk "/^cleanup\\(\\) \\{/,/^}/" "$1" | grep -q "\\.session-created-stubs" \
             && awk "/^cleanup\\(\\) \\{/,/^}/" "$1" | grep -q "rmdir"' \
    -- "$SANDY_SCRIPT_PATH"
check "pre-existing cleanup uses rmdir (never rm -rf)" \
    bash -c 'awk "/Pre-existing-debris auto-cleanup/,/_cleaned_debris\\[@\\]/" "$1" | grep -q "rmdir" \
             && ! awk "/Pre-existing-debris auto-cleanup/,/_cleaned_debris\\[@\\]/" "$1" | grep -qE "rm[[:space:]]+-rf"' \
    -- "$SANDY_SCRIPT_PATH"
check "pre-existing cleanup gated on git repo" \
    bash -c 'awk "/Pre-existing-debris auto-cleanup/,/_cleaned_debris\\[@\\]/" "$1" | grep -q "git rev-parse"' \
    -- "$SANDY_SCRIPT_PATH"
check "pre-existing cleanup gated on untracked (git ls-files)" \
    bash -c 'awk "/Pre-existing-debris auto-cleanup/,/_cleaned_debris\\[@\\]/" "$1" | grep -q "git ls-files --error-unmatch"' \
    -- "$SANDY_SCRIPT_PATH"
check "pre-existing cleanup gated on emptiness (ls -A)" \
    bash -c 'awk "/Pre-existing-debris auto-cleanup/,/_cleaned_debris\\[@\\]/" "$1" | grep -q "ls -A"' \
    -- "$SANDY_SCRIPT_PATH"

# --- Functional tests: exercise the cleanup logic against fixture trees ---
_S44_TMP="$(mktemp -d)"

# Scenario A: session cleanup rmdirs an empty recorded stub.
mkdir -p "$_S44_TMP/a/.vscode"
printf '%s\n' "$_S44_TMP/a/.vscode" > "$_S44_TMP/a.stubs"
while IFS= read -r _stub; do
    [ -z "$_stub" ] && continue
    [ -d "$_stub" ] && [ -z "$(ls -A "$_stub" 2>/dev/null)" ] && rmdir "$_stub" 2>/dev/null || true
done < "$_S44_TMP/a.stubs"
check "A: session cleanup rmdirs empty recorded stub" \
    bash -c '[ ! -d "$1" ]' -- "$_S44_TMP/a/.vscode"

# Scenario B: session cleanup preserves a populated recorded stub.
mkdir -p "$_S44_TMP/b/.vscode"
echo '{}' > "$_S44_TMP/b/.vscode/settings.json"
printf '%s\n' "$_S44_TMP/b/.vscode" > "$_S44_TMP/b.stubs"
while IFS= read -r _stub; do
    [ -z "$_stub" ] && continue
    [ -d "$_stub" ] && [ -z "$(ls -A "$_stub" 2>/dev/null)" ] && rmdir "$_stub" 2>/dev/null || true
done < "$_S44_TMP/b.stubs"
check "B: session cleanup preserves populated dir (content intact)" \
    bash -c '[ -f "$1/settings.json" ]' -- "$_S44_TMP/b/.vscode"

# Scenario C: pre-existing cleanup auto-removes empty protected dirs in git repo.
mkdir -p "$_S44_TMP/c"
(cd "$_S44_TMP/c" && git init -q && git config user.email t@t && git config user.name t \
 && echo README > README.md && git add README.md && git commit -q -m init)
mkdir -p "$_S44_TMP/c/.vscode" "$_S44_TMP/c/.idea" "$_S44_TMP/c/.devcontainer"
# Simulate sandy's pre-existing cleanup loop against a fixed protected-dirs list.
_C_DIRS=(".vscode" ".idea" ".circleci" ".devcontainer" ".github/workflows")
if (cd "$_S44_TMP/c" && git rev-parse --git-dir >/dev/null 2>&1); then
    for _pd in "${_C_DIRS[@]}"; do
        _p="$_S44_TMP/c/$_pd"
        [ -d "$_p" ] || continue
        [ -z "$(ls -A "$_p" 2>/dev/null)" ] || continue
        if (cd "$_S44_TMP/c" && git ls-files --error-unmatch "$_pd" >/dev/null 2>&1); then continue; fi
        rmdir "$_p" 2>/dev/null || true
    done
fi
check "C: pre-existing cleanup removes empty .vscode in git repo" \
    bash -c '[ ! -d "$1" ]' -- "$_S44_TMP/c/.vscode"
check "C: pre-existing cleanup removes empty .idea in git repo" \
    bash -c '[ ! -d "$1" ]' -- "$_S44_TMP/c/.idea"
check "C: pre-existing cleanup removes empty .devcontainer in git repo" \
    bash -c '[ ! -d "$1" ]' -- "$_S44_TMP/c/.devcontainer"

# Scenario D: pre-existing cleanup preserves non-empty dir (safety: emptiness check).
mkdir -p "$_S44_TMP/d"
(cd "$_S44_TMP/d" && git init -q && git config user.email t@t && git config user.name t \
 && echo R > R.md && git add R.md && git commit -q -m init)
mkdir -p "$_S44_TMP/d/.vscode"
echo "keep" > "$_S44_TMP/d/.vscode/settings.json"
if (cd "$_S44_TMP/d" && git rev-parse --git-dir >/dev/null 2>&1); then
    for _pd in "${_C_DIRS[@]}"; do
        _p="$_S44_TMP/d/$_pd"
        [ -d "$_p" ] || continue
        [ -z "$(ls -A "$_p" 2>/dev/null)" ] || continue
        if (cd "$_S44_TMP/d" && git ls-files --error-unmatch "$_pd" >/dev/null 2>&1); then continue; fi
        rmdir "$_p" 2>/dev/null || true
    done
fi
check "D: pre-existing cleanup preserves non-empty .vscode (content intact)" \
    bash -c '[ -f "$1/settings.json" ]' -- "$_S44_TMP/d/.vscode"

# Scenario E: pre-existing cleanup skips non-git workspace (safety: git repo check).
mkdir -p "$_S44_TMP/e/.vscode"
# Intentionally no git init
if (cd "$_S44_TMP/e" && git rev-parse --git-dir >/dev/null 2>&1); then
    for _pd in "${_C_DIRS[@]}"; do
        _p="$_S44_TMP/e/$_pd"
        [ -d "$_p" ] || continue
        [ -z "$(ls -A "$_p" 2>/dev/null)" ] || continue
        if (cd "$_S44_TMP/e" && git ls-files --error-unmatch "$_pd" >/dev/null 2>&1); then continue; fi
        rmdir "$_p" 2>/dev/null || true
    done
fi
check "E: pre-existing cleanup skips non-git workspace" \
    bash -c '[ -d "$1" ]' -- "$_S44_TMP/e/.vscode"

rm -rf "$_S44_TMP"

# ============================================================
# SECTION 45: Introspection surface (SPEC_INTROSPECTION.md)
# ============================================================
# Purpose: lock down the JSON introspection flags --print-schema,
# --print-state, --validate-config. These are fast-path handlers
# that run without Docker, so they're cheap to exercise in CI.
info ""
info "=== Introspection surface ==="

SANDY_SCRIPT_PATH="$(cd "$(dirname "$0")/.." && pwd)/sandy"

_INTRO_TMP="$(mktemp -d)"
_SCHEMA_JSON="$_INTRO_TMP/schema.json"
_STATE_JSON="$_INTRO_TMP/state.json"

# --- --print-schema ---
_SCHEMA_RC=0
bash "$SANDY_SCRIPT_PATH" --print-schema > "$_SCHEMA_JSON" 2>/dev/null || _SCHEMA_RC=$?
check "--print-schema exits 0" test "$_SCHEMA_RC" -eq 0
check "--print-schema output is valid JSON" \
    python3 -m json.tool < "$_SCHEMA_JSON"
check "schema has schema_version=1" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"schema_version\"]==1" "$1"' \
    -- "$_SCHEMA_JSON"
check "schema has sandy.version" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"sandy\"][\"version\"]" "$1"' \
    -- "$_SCHEMA_JSON"
check "schema lists privileged_keys (non-empty)" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d[\"config\"][\"privileged_keys\"])>0" "$1"' \
    -- "$_SCHEMA_JSON"
check "schema lists passive_keys (non-empty)" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d[\"config\"][\"passive_keys\"])>0" "$1"' \
    -- "$_SCHEMA_JSON"
check "schema flags SANDY_SSH as privileged" \
    bash -c 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
names=[k[\"name\"] for k in d[\"config\"][\"privileged_keys\"]]
assert \"SANDY_SSH\" in names
" "$1"' -- "$_SCHEMA_JSON"
check "schema flags SANDY_MODEL as passive" \
    bash -c 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
names=[k[\"name\"] for k in d[\"config\"][\"passive_keys\"]]
assert \"SANDY_MODEL\" in names
" "$1"' -- "$_SCHEMA_JSON"
check "schema flags privileged keys with passive_approval_required" \
    bash -c 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for k in d[\"config\"][\"privileged_keys\"]:
    assert k.get(\"passive_approval_required\") is True, k[\"name\"]
" "$1"' -- "$_SCHEMA_JSON"
check "schema lists all three agents (claude,gemini,codex)" \
    bash -c 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
names=[a[\"name\"] for a in d[\"agents\"]]
assert set(names)=={\"claude\",\"gemini\",\"codex\"}
" "$1"' -- "$_SCHEMA_JSON"
check "schema cli_flags includes --print-schema" \
    bash -c 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
names=[f[\"name\"] for f in d[\"cli_flags\"]]
assert \"--print-schema\" in names
" "$1"' -- "$_SCHEMA_JSON"
check "schema protected_paths.files includes .envrc (S1.3 expansion)" \
    bash -c 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert \".envrc\" in d[\"protected_paths\"][\"files\"]
" "$1"' -- "$_SCHEMA_JSON"
check "schema compatibility.supported_schema_versions contains 1" \
    bash -c 'python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert 1 in d[\"compatibility\"][\"supported_schema_versions\"]
" "$1"' -- "$_SCHEMA_JSON"

# --- --print-state ---
# Capture stderr to a file so we can surface the ERR-trap diagnostic (see
# _sandy_introspect_err_trap in sandy) when the command fails. Without this,
# a `set -euo pipefail` abort inside _sandy_emit_state would just produce
# non-zero exit with silent partial stdout, giving no signal for debugging.
_STATE_RC=0
_STATE_ERR="$_INTRO_TMP/state.err"
bash "$SANDY_SCRIPT_PATH" --print-state > "$_STATE_JSON" 2>"$_STATE_ERR" || _STATE_RC=$?
if [ "$_STATE_RC" -ne 0 ] || [ ! -s "$_STATE_JSON" ]; then
    echo "  --- sandy --print-state diagnostic ---" >&2
    echo "  exit code: $_STATE_RC" >&2
    echo "  stdout bytes: $(wc -c < "$_STATE_JSON" 2>/dev/null || echo 0)" >&2
    if [ -s "$_STATE_ERR" ]; then
        sed 's/^/  stderr: /' "$_STATE_ERR" >&2
    else
        echo "  stderr: (empty)" >&2
    fi
    echo "  -------------------------------------" >&2
fi
check "--print-state exits 0 (even without docker)" test "$_STATE_RC" -eq 0
check "--print-state output is valid JSON" \
    python3 -m json.tool < "$_STATE_JSON"
check "state has schema_version" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert \"schema_version\" in d" "$1"' \
    -- "$_STATE_JSON"
check "state has sandy_home" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert \"sandy_home\" in d" "$1"' \
    -- "$_STATE_JSON"
check "state has sandboxes array" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d[\"sandboxes\"],list)" "$1"' \
    -- "$_STATE_JSON"
check "state has docker_reachable bool" \
    bash -c 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d[\"docker_reachable\"],bool)" "$1"' \
    -- "$_STATE_JSON"

# --- --validate-config ---
# `set -euo pipefail` is active — a command substitution whose child exits
# non-zero aborts the assignment unless guarded by `||`. Use
# `_VAR="$(cmd)" || _RC=$?` to capture both the output and the exit code.
# Case 1: passive-safe config — no errors, no pending approval.
cat > "$_INTRO_TMP/passive-ok.config" <<'EOF'
SANDY_MODEL=claude-opus-4-7
SANDY_VERBOSE=1
EOF
_VAL_RC=0
_VAL_OUT="$(bash "$SANDY_SCRIPT_PATH" --validate-config "$_INTRO_TMP/passive-ok.config" 2>/dev/null)" || _VAL_RC=$?
check "validate-config passive-safe exits 0" test "$_VAL_RC" -eq 0
check "validate-config passive-safe is valid JSON" \
    bash -c 'echo "$1" | python3 -m json.tool' -- "$_VAL_OUT"
check "validate-config passive-safe reports approval_status=none_required" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[\"approval_status\"]==\"none_required\", d[\"approval_status\"]
" "$1"' -- "$_VAL_OUT"
check "validate-config passive-safe has no unknown_keys" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[\"unknown_keys\"]==[], d[\"unknown_keys\"]
" "$1"' -- "$_VAL_OUT"
check "validate-config detects source_tier=passive outside SANDY_HOME" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[\"source_tier\"]==\"passive\", d[\"source_tier\"]
" "$1"' -- "$_VAL_OUT"

# Case 2: passive config with a privileged key — reports pending approval.
cat > "$_INTRO_TMP/passive-bad.config" <<'EOF'
SANDY_SSH=agent
SANDY_SKIP_PERMISSIONS=1
BOGUS_KEY=yes
EOF
_VAL_RC2=0
_VAL_OUT2="$(bash "$SANDY_SCRIPT_PATH" --validate-config "$_INTRO_TMP/passive-bad.config" 2>/dev/null)" || _VAL_RC2=$?
check "validate-config passive-privileged exits 0 (pending is not an error)" test "$_VAL_RC2" -eq 0
check "validate-config passive-privileged reports approval_status=pending" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[\"approval_status\"]==\"pending\", d[\"approval_status\"]
" "$1"' -- "$_VAL_OUT2"
check "validate-config passive-privileged lists SANDY_SSH in privileged_keys_requiring_approval" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert \"SANDY_SSH\" in d[\"privileged_keys_requiring_approval\"], d[\"privileged_keys_requiring_approval\"]
" "$1"' -- "$_VAL_OUT2"
check "validate-config passive-privileged lists BOGUS_KEY in unknown_keys" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert \"BOGUS_KEY\" in d[\"unknown_keys\"], d[\"unknown_keys\"]
" "$1"' -- "$_VAL_OUT2"
check "validate-config passive-privileged warns on each privileged key" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
keys=[w[\"key\"] for w in d[\"warnings\"]]
assert \"SANDY_SSH\" in keys and \"SANDY_SKIP_PERMISSIONS\" in keys, keys
" "$1"' -- "$_VAL_OUT2"
check "validate-config passive-privileged emits approval_file_path" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[\"approval_file_path\"] and \"approvals/passive-\" in d[\"approval_file_path\"], d[\"approval_file_path\"]
" "$1"' -- "$_VAL_OUT2"

# Case 3: non-existent file (expected exit 1 — `|| _VAL_RC3=$?` absorbs set -e).
# `trap - ERR` inside the subshell stops the harness-level ERR trap from
# printing a spurious red line when the intentionally-failing bash exits 1.
# `set -E` (errtrace) makes the trap inherit into command substitutions, so
# it would otherwise fire in the subshell before the outer `||` absorbs the
# exit code. The outer `||` still captures the exit code into _VAL_RC3.
_VAL_RC3=0
_VAL_OUT3="$(trap - ERR; bash "$SANDY_SCRIPT_PATH" --validate-config "$_INTRO_TMP/does-not-exist.config" 2>/dev/null)" || _VAL_RC3=$?
check "validate-config missing-file exits 1" test "$_VAL_RC3" -eq 1
check "validate-config missing-file reports file-does-not-exist error" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert any(\"does not exist\" in e for e in d[\"errors\"]), d[\"errors\"]
" "$1"' -- "$_VAL_OUT3"

# Case 4: no path argument (expected exit 1).
_VAL_RC4=0
bash "$SANDY_SCRIPT_PATH" --validate-config >/dev/null 2>&1 || _VAL_RC4=$?
check "validate-config with no argument exits 1" test "$_VAL_RC4" -eq 1

# Case 5: privileged source (under SANDY_HOME) has no approval prompt.
_FAKE_HOME="$_INTRO_TMP/fake-sandy-home"
mkdir -p "$_FAKE_HOME"
cat > "$_FAKE_HOME/config" <<'EOF'
SANDY_SSH=agent
SANDY_MODEL=claude-opus-4-7
EOF
_VAL_RC5=0
_VAL_OUT5="$(SANDY_HOME="$_FAKE_HOME" bash "$SANDY_SCRIPT_PATH" --validate-config "$_FAKE_HOME/config" 2>/dev/null)" || _VAL_RC5=$?
check "validate-config SANDY_HOME source exits 0" test "$_VAL_RC5" -eq 0
check "validate-config under SANDY_HOME is classified as privileged" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[\"source_tier\"]==\"privileged\", d[\"source_tier\"]
" "$1"' -- "$_VAL_OUT5"
check "validate-config privileged source reports approval_status=none_required" \
    bash -c 'python3 -c "
import json,sys
d=json.loads(sys.argv[1])
assert d[\"approval_status\"]==\"none_required\", d[\"approval_status\"]
" "$1"' -- "$_VAL_OUT5"

rm -rf "$_INTRO_TMP"

# ============================================================
# Summary
# ============================================================
COMPLETED=true   # suppress the early-abort message in the EXIT trap
echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    printf "\033[0;32mAll %d tests passed.\033[0m\n" "$TOTAL"
else
    printf "\033[0;31m%d/%d tests failed:\033[0m\n" "$FAIL" "$TOTAL"
    for e in "${ERRORS[@]}"; do
        printf "  \033[0;31m- %s\033[0m\n" "$e"
    done
    exit 1
fi
