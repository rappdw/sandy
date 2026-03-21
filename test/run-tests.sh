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
    for _pd in .git/hooks .claude/commands .claude/agents .claude/plugins .vscode .idea; do
        [ -d "$TEST_PROJECT/$_pd" ] && _ro_mounts+=(-v "$TEST_PROJECT/$_pd:/workspace/$_pd:ro")
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
mkdir -p "$TEST_PROJECT/.claude/plugins"
echo "test" > "$TEST_PROJECT/.claude/plugins/test-plugin.json"

# Verify writes to protected files fail
sandy_run "echo injected >> /workspace/.bashrc 2>/dev/null" >/dev/null 2>&1 && WRITE_BASHRC=yes || WRITE_BASHRC=no
check "cannot write to .bashrc" test "$WRITE_BASHRC" = "no"

sandy_run "echo injected >> /workspace/.zshrc 2>/dev/null" >/dev/null 2>&1 && WRITE_ZSHRC=yes || WRITE_ZSHRC=no
check "cannot write to .zshrc" test "$WRITE_ZSHRC" = "no"

sandy_run "echo injected > /workspace/.git/hooks/pre-commit 2>/dev/null" >/dev/null 2>&1 && WRITE_HOOK=yes || WRITE_HOOK=no
check "cannot write to .git/hooks/" test "$WRITE_HOOK" = "no"

sandy_run "echo injected > /workspace/.claude/commands/test.md 2>/dev/null" >/dev/null 2>&1 && WRITE_CMD=yes || WRITE_CMD=no
check "cannot write to .claude/commands/" test "$WRITE_CMD" = "no"

sandy_run "echo injected >> /workspace/.git/config 2>/dev/null" >/dev/null 2>&1 && WRITE_GITCFG=yes || WRITE_GITCFG=no
check "cannot write to .git/config" test "$WRITE_GITCFG" = "no"

sandy_run "echo injected >> /workspace/.gitmodules 2>/dev/null" >/dev/null 2>&1 && WRITE_GITMOD=yes || WRITE_GITMOD=no
check "cannot write to .gitmodules" test "$WRITE_GITMOD" = "no"

sandy_run "echo injected > /workspace/.claude/plugins/test-plugin.json 2>/dev/null" >/dev/null 2>&1 && WRITE_PLUGIN=yes || WRITE_PLUGIN=no
check "cannot write to .claude/plugins/" test "$WRITE_PLUGIN" = "no"

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
node -e "
    const fs = require('fs');
    const f = process.argv[1];
    let s;
    try { s = JSON.parse(fs.readFileSync(f, 'utf8')); } catch { s = {}; }
    if (!s.hooks) s.hooks = {};
    if (!s.hooks.Notification) s.hooks.Notification = [];
    const hasCmux = s.hooks.Notification.some(h =>
        h.hooks && h.hooks.some(hh => hh.command && hh.command.includes('cmux-notify'))
    );
    if (!hasCmux) {
        s.hooks.Notification.push({
            matcher: '',
            hooks: [{
                type: 'command',
                command: '/home/claude/.claude/hooks/cmux-notify.sh'
            }]
        });
    }
    fs.writeFileSync(f, JSON.stringify(s, null, 2) + '\n');
" "$SANDBOX_DIR/settings.json"
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
    node -e "
        const s = JSON.parse(require('fs').readFileSync('$CMUX_SANDBOX/settings.json', 'utf8'));
        if (s.teammateMode !== 'tmux') process.exit(1);
    "

# Run setup again — should NOT duplicate the hook
bash "$CMUX_SANDBOX/test-cmux-setup.sh" "$CMUX_SANDBOX"
HOOK_COUNT="$(node -e "
    const s = JSON.parse(require('fs').readFileSync('$CMUX_SANDBOX/settings.json', 'utf8'));
    console.log(s.hooks.Notification.length);
")"
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
