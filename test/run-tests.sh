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
    local _ro_mounts=()
    for _pf in .bashrc .bash_profile .zshrc .zprofile .profile .gitconfig .ripgreprc .mcp.json; do
        [ -e "$TEST_PROJECT/$_pf" ] && _ro_mounts+=(-v "$TEST_PROJECT/$_pf:/workspace/$_pf:ro")
    done
    for _gpf in .git/config .gitmodules; do
        [ -f "$TEST_PROJECT/$_gpf" ] && _ro_mounts+=(-v "$TEST_PROJECT/$_gpf:/workspace/$_gpf:ro")
    done
    for _pd in .git/hooks .vscode .idea; do
        [ -d "$TEST_PROJECT/$_pd" ] && _ro_mounts+=(-v "$TEST_PROJECT/$_pd:/workspace/$_pd:ro")
    done
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
info "13. Protected files are read-only inside container"
# ============================================================

# Create protected files and dirs in the project
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
info "17. Per-project config is sourced"
# ============================================================

# Static analysis: verify .sandy/config loading happens before SSH relay setup
CONFIG_SOURCE="$(grep -n '\.sandy/config' "$SCRIPT" | head -1 | cut -d: -f1)"
SSH_RELAY="$(grep -n 'SANDY_SSH=.*token' "$SCRIPT" | tail -1 | cut -d: -f1)"
check ".sandy/config loaded before SSH relay setup" \
    test "$CONFIG_SOURCE" -lt "$SSH_RELAY"

# Verify config parser does NOT use source (prevents code injection from untrusted repos)
check "config parser does not use source" \
    bash -c '! grep -q "source.*\.sandy/config" "$1"' -- "$SCRIPT"

# Verify config parser uses allowlist
check "config parser uses variable allowlist" \
    grep -q 'SANDY_SSH|SANDY_MODEL' "$SCRIPT"

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
check "gstack repo points to rappdw fork" \
    grep -q 'rappdw/gstack' "$SCRIPT"

# Static analysis: verify SANDY_SKILL_PACKS is in config allowlist
check "SANDY_SKILL_PACKS in config allowlist" \
    grep -q 'SANDY_SKILL_PACKS' "$SCRIPT"

# Static analysis: verify generate_skill_pack_dockerfile function exists
check "generate_skill_pack_dockerfile function defined" \
    grep -q 'generate_skill_pack_dockerfile()' "$SCRIPT"

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
    SKILL_PACK_REPOS=("https://github.com/rappdw/gstack")
    SKILL_PACK_VERSIONS=("sandy/v0.11.19.0")
    SKILL_PACK_TAG_PREFIXES=("sandy/v")
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
    eval "$(sed -n '/^generate_skill_pack_dockerfile()/,/^}/p' "$SCRIPT")"

    generate_skill_pack_dockerfile "gstack"
)

SKILLS_DF="$SKILLS_TEST_DIR/Dockerfile.skills.new"
check "Dockerfile.skills generated" \
    test -f "$SKILLS_DF"
check "Dockerfile.skills starts FROM sandy-claude-code" \
    grep -q '^FROM sandy-claude-code' "$SKILLS_DF"
check "Dockerfile.skills downloads gstack tarball" \
    grep -q 'rappdw/gstack/archive' "$SKILLS_DF"
check "Dockerfile.skills installs to /opt/skills/gstack" \
    grep -q '/opt/skills/gstack' "$SKILLS_DF"
check "Dockerfile.skills runs bun build" \
    grep -q 'bun run build' "$SKILLS_DF"
check "Dockerfile.skills installs Playwright deps" \
    grep -q 'playwright install-deps chromium' "$SKILLS_DF"
check "Dockerfile.skills installs Playwright browser" \
    grep -q 'playwright install chromium' "$SKILLS_DF"
check "Dockerfile.skills sets PLAYWRIGHT_BROWSERS_PATH" \
    grep -q 'PLAYWRIGHT_BROWSERS_PATH=/opt/skills/gstack/.browsers' "$SKILLS_DF"
check "Dockerfile.skills does not set USER (entrypoint handles privilege drop)" \
    bash -c "! grep -q '^USER' '$SKILLS_DF'"

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
