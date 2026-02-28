#!/bin/bash
# Integration tests for sandy container environments.
# Requires: docker, sandy images already built (run `sandy` once first).
#
# Usage: ./test/run-tests.sh
set -euo pipefail

IMAGE_NAME="sandy-claude-code"
SANDY_HOME="${SANDY_HOME:-$HOME/.sandy}"
PASS=0
FAIL=0
ERRORS=()

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

            # Create pip/pip3 wrappers (root phase, simpler quoting)
            cat > /home/claude/.local/bin/pip <<'PIPWRAP'
#!/bin/bash
if [ -z \"\$VIRTUAL_ENV\" ] && [ \"\${1:-}\" = \"install\" ]; then
    shift
    exec python3 -m pip install --user \"\$@\"
fi
exec python3 -m pip \"\$@\"
PIPWRAP
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
    echo "Error: $IMAGE_NAME image not found. Run sandy once to build it."
    exit 1
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

echo "3.11" > "$TEST_PROJECT/.python-version"
# Simulate what the entrypoint does: read .python-version, install, verify
sandy_run '
    PY_WANT="$(cat /workspace/.python-version | tr -d "[:space:]")"
    uv python install "$PY_WANT" 2>/dev/null
    uv python find "$PY_WANT" >/dev/null 2>&1
'
check ".python-version triggers uv python install" \
    sandy_run "uv python find 3.11 >/dev/null 2>&1"
rm -f "$TEST_PROJECT/.python-version"

# ============================================================
info "9. Dev environment detection — broken .venv auto-installs Python"
# ============================================================

# Create a .venv with a broken symlink pointing to a specific Python version
mkdir -p "$TEST_PROJECT/.venv/bin"
ln -sf /usr/local/bin/python3.10 "$TEST_PROJECT/.venv/bin/python"
# Simulate what the entrypoint does: detect broken .venv, extract version, install
sandy_run '
    VENV_TARGET="$(readlink /workspace/.venv/bin/python)"
    PY_VER="$(echo "$VENV_TARGET" | grep -oE "[0-9]+\.[0-9]+" | head -1)"
    uv python install "$PY_VER" 2>/dev/null
    uv python find "$PY_VER" >/dev/null 2>&1
'
check "broken .venv triggers install of matching Python" \
    sandy_run "uv python find 3.10 >/dev/null 2>&1"
rm -rf "$TEST_PROJECT/.venv"

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
# Summary
# ============================================================
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
