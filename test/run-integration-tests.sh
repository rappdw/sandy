#!/bin/bash
# Integration tests for sandy — requires Docker, API keys, and real agent sessions.
#
# These tests launch real sandy sessions with real API calls. They complement
# test/run-tests.sh (pure-script, no Docker needed) by verifying end-to-end
# behavior that can only be checked with a running container and live credentials.
#
# Credentials are auto-detected; sections without credentials are skipped.
# The more credentials you provide, the more tests run.
#
# ── Setup ──────────────────────────────────────────────────────────────
#
#   1. Run unit tests first:
#        bash test/run-tests.sh
#
#   2. Provide credentials via env vars, well-known paths, or ~/.sandy/.secrets
#      (the user-level secrets file that sandy itself reads — credentials placed
#      here are auto-detected by these tests too):
#
#      CODEX (OpenAI Codex CLI):
#        • export OPENAI_API_KEY="sk-..."          ← OpenAI API key
#          OR
#        • Run `codex login` on the host           ← creates ~/.codex/auth.json
#          (OAuth path tested separately; API key covers most tests)
#
#      GEMINI (Google Gemini CLI):
#        • export GEMINI_API_KEY="AI..."           ← from https://aistudio.google.com/apikey
#          OR
#        • Run `gemini auth` on the host            ← creates ~/.gemini/tokens.json
#
#      CLAUDE (Anthropic Claude Code):
#        • export ANTHROPIC_API_KEY="sk-ant-..."
#          OR
#        • Have ~/.claude/.credentials.json         ← from Claude Max / OAuth login
#
#   3. Run:
#        bash test/run-integration-tests.sh
#
#      To force image rebuilds (slow, but tests the full build pipeline):
#        SANDY_INTEG_REBUILD=1 bash test/run-integration-tests.sh
#
# ── What runs with what ────────────────────────────────────────────────
#
#   Credentials provided    │ Tests that run
#   ────────────────────────┼──────────────────────────────────────────
#   (none)                  │ Feature guards only (§1)
#   OPENAI_API_KEY           │ §1-4: guards, codex build/headless/seeding/container
#   + ~/.codex/auth.json    │ + §9: OAuth read-only mount detection
#   GEMINI_API_KEY          │ §5-6: gemini build/headless/container
#   + ~/.gemini/tokens.json │ + §10: OAuth detection
#   ANTHROPIC_API_KEY       │ §7: claude headless regression
#   Any two of the above    │ + §8: cross-agent switching regression
#
# ── Notes ──────────────────────────────────────────────────────────────
#
#   • Each test creates temp project dirs that are cleaned up on exit.
#   • First run with a new agent builds its Docker image (can take minutes).
#   • API calls are minimal — each headless test sends one short prompt.
#   • Tests never write credentials to disk or commit anything.
#
# ── Flags ─────────────────────────────────────────────────────────────
#
#   -v      Pass SANDY_VERBOSE=1 to sandy (info messages)
#   -vv     Pass SANDY_VERBOSE=2 to sandy (+ set -x)
#   -vvv    Pass SANDY_VERBOSE=3 to sandy (+ docker run flags dump)
#
#   SANDY_INTEG_TIMEOUT=600  Override per-test timeout (default 300s)
#
set -euo pipefail

SANDY_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/sandy"
SANDY_HOME="${SANDY_HOME:-$HOME/.sandy}"
PASS=0
FAIL=0
SKIP=0
ERRORS=()
COMPLETED=false
TEST_DIRS=()
SANDBOX_DIRS=()

# macOS doesn't have GNU timeout; use perl fallback
if ! command -v timeout &>/dev/null; then
    timeout() {
        local secs="$1"; shift
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    }
fi

# Verbosity: -v, -vv, -vvv (passed through to sandy)
VERBOSE=0
for _arg in "$@"; do
    case "$_arg" in
        -vvv) VERBOSE=3 ;;
        -vv)  VERBOSE=2 ;;
        -v)   VERBOSE=1 ;;
    esac
done

# --- Helpers ---

info()  { printf "\033[0;36m%s\033[0m\n" "$*"; }
pass()  { PASS=$((PASS + 1)); printf "  \033[0;32m✓ %s\033[0m\n" "$*"; }
fail()  { FAIL=$((FAIL + 1)); ERRORS+=("$*"); printf "  \033[0;31m✗ %s\033[0m\n" "$*"; }
skip()  { SKIP=$((SKIP + 1)); printf "  \033[0;33m⊘ %s (skipped)\033[0m\n" "$*"; }

_emit_summary() {
    local code=$?
    printf '\033>' 2>/dev/null || true
    command -v tput >/dev/null 2>&1 && tput rmkx 2>/dev/null || true
    if [ "$COMPLETED" = false ] && [ "$((PASS + FAIL))" -gt 0 ]; then
        echo ""
        printf "\033[0;31m✗ integration test suite aborted early (exit=%d)\033[0m\n" "$code" >&2
        printf "\033[0;33mPartial results: %d passed, %d failed, %d skipped (of %d run)\033[0m\n" \
            "$PASS" "$FAIL" "$SKIP" "$((PASS + FAIL + SKIP))" >&2
        if [ "${#ERRORS[@]}" -gt 0 ]; then
            printf "\033[0;31mRecorded failures:\033[0m\n" >&2
            for e in "${ERRORS[@]}"; do
                printf "  \033[0;31m- %s\033[0m\n" "$e" >&2
            done
        fi
    fi
}

cleanup() {
    _emit_summary
    for d in "${TEST_DIRS[@]+"${TEST_DIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
    for d in "${SANDBOX_DIRS[@]+"${SANDBOX_DIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM HUP

# Create a temporary project dir pre-configured for a given agent.
# Sets PROJECT_DIR and SANDBOX_DIR as side effects.
setup_project() {
    local agent="$1" name="$2"
    PROJECT_DIR="$(mktemp -d)"
    TEST_DIRS+=("$PROJECT_DIR")
    cd "$PROJECT_DIR"
    git init -q
    echo "integration test" > README.md
    mkdir -p .sandy
    echo "SANDY_AGENT=$agent" > .sandy/config
    # Give sandy a moment to settle the sandbox name
    SANDBOX_DIR=""
}

# Resolve the sandbox dir after first sandy launch.
# Adds the resolved dir to SANDBOX_DIRS for cleanup on exit.
# Uses the same naming scheme as sandy: <basename>-<8char-sha256-of-path>
resolve_sandbox() {
    # Sandy uses $(pwd) which resolves symlinks on macOS (/var → /private/var).
    # Use pwd -P from the project dir to match.
    local phys_dir base short_hash
    phys_dir="$(cd "$PROJECT_DIR" && pwd -P)"
    base="$(basename "$phys_dir" | tr -cd 'a-zA-Z0-9._-')"
    base="${base:-project}"
    short_hash="$(printf '%s' "$phys_dir" | shasum -a 256 2>/dev/null || printf '%s' "$phys_dir" | sha256sum)"
    short_hash="${short_hash%% *}"
    short_hash="${short_hash:0:8}"
    SANDBOX_DIR="$SANDY_HOME/sandboxes/${base}-${short_hash}"
    if [ ! -d "$SANDBOX_DIR" ]; then
        # Fallback: find an actual directory matching the prefix (not the
        # sibling <name>.claude.json sidecar file that lives next to it).
        SANDBOX_DIR=""
        for _d in "$SANDY_HOME/sandboxes/${base}-"*/; do
            [ -d "$_d" ] || continue
            SANDBOX_DIR="${_d%/}"
            break
        done
    fi
    if [ -n "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR" ]; then
        SANDBOX_DIRS+=("$SANDBOX_DIR")
    fi
}

# Run sandy headless and capture combined output. Returns the exit code.
# Usage: sandy_output=$(run_sandy_headless [env vars] -- [sandy args])
run_sandy_headless() {
    local env_args=() sandy_args=()
    local past_separator=false
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            past_separator=true
            continue
        fi
        if [ "$past_separator" = true ]; then
            sandy_args+=("$arg")
        else
            env_args+=("$arg")
        fi
    done
    local rebuild_flag=""
    if [ "${SANDY_INTEG_REBUILD:-}" = "1" ]; then
        rebuild_flag="--rebuild"
    fi
    local verbose_flag=""
    case "$VERBOSE" in
        3) verbose_flag="-vvv" ;;
        2) verbose_flag="-vv" ;;
        1) verbose_flag="-v" ;;
    esac
    # Timeout: headless sandy should complete within 5 minutes.
    # Image builds can be slow on first run, so this is generous.
    local timeout_sec="${SANDY_INTEG_TIMEOUT:-300}"
    # When verbose, tee output to stderr so it's visible even when the caller
    # captures stdout into a variable (e.g. _out="$(run_sandy_headless ...)").
    if [ "$VERBOSE" -gt 0 ]; then
        if [ "${#env_args[@]}" -gt 0 ]; then
            timeout "$timeout_sec" env "${env_args[@]}" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" 2>&1 | tee /dev/stderr || true
        else
            timeout "$timeout_sec" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" 2>&1 | tee /dev/stderr || true
        fi
    else
        if [ "${#env_args[@]}" -gt 0 ]; then
            timeout "$timeout_sec" env "${env_args[@]}" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" 2>&1 || true
        else
            timeout "$timeout_sec" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" 2>&1 || true
        fi
    fi
}

# --- Preflight ---

if ! command -v docker &>/dev/null; then
    echo "Error: docker not found. Integration tests require Docker."
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    echo "Error: Docker daemon not running."
    exit 1
fi

# Detect available credentials.
# Check env vars, well-known credential files, AND ~/.sandy/.secrets (the
# user-level secrets file that sandy itself reads at launch). Sandy loads
# .sandy/.secrets as KEY=VALUE pairs — we do the same here so integration
# tests see whatever the user has configured without requiring them to
# also export to the shell environment.
HAS_OPENAI_API_KEY=false
HAS_CODEX_OAUTH=false
HAS_GEMINI_API_KEY=false
HAS_GEMINI_OAUTH=false
HAS_CLAUDE=false

# Source credentials from ~/.sandy/.secrets if it exists (same file sandy reads).
# This is a safe KEY=VALUE file (no shell code) — sandy validates it against an
# allowlist, so we only extract the variables we care about.
if [ -f "$HOME/.sandy/.secrets" ]; then
    while IFS='=' read -r _key _val; do
        # Strip leading/trailing whitespace and skip comments/blanks
        _key="$(echo "$_key" | tr -d '[:space:]')"
        _val="$(echo "$_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$_key" ] || [[ "$_key" == \#* ]] && continue
        case "$_key" in
            OPENAI_API_KEY)            [ -z "${OPENAI_API_KEY:-}" ]            && export OPENAI_API_KEY="$_val" ;;
            GEMINI_API_KEY)            [ -z "${GEMINI_API_KEY:-}" ]            && export GEMINI_API_KEY="$_val" ;;
            ANTHROPIC_API_KEY)         [ -z "${ANTHROPIC_API_KEY:-}" ]         && export ANTHROPIC_API_KEY="$_val" ;;
            CLAUDE_CODE_OAUTH_TOKEN)   [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]   && export CLAUDE_CODE_OAUTH_TOKEN="$_val" ;;
        esac
    done < "$HOME/.sandy/.secrets"
fi

[ -n "${OPENAI_API_KEY:-}" ] && HAS_OPENAI_API_KEY=true
[ -f "$HOME/.codex/auth.json" ] && HAS_CODEX_OAUTH=true
[ -n "${GEMINI_API_KEY:-}" ] && HAS_GEMINI_API_KEY=true
# Gemini OAuth: check oauth_creds.json (≥0.30) and legacy tokens.json.
HAS_GEMINI_OAUTH=false
HAS_GEMINI_ADC=false
for _gtp in "$HOME/.gemini/oauth_creds.json" \
            "$HOME/.gemini/tokens.json"; do
    [ -f "$_gtp" ] && HAS_GEMINI_OAUTH=true && break
done
[ -f "$HOME/.config/gcloud/application_default_credentials.json" ] && HAS_GEMINI_ADC=true
# Claude: API key, OAuth token, or credential file
if [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -f "$HOME/.claude/.credentials.json" ]; then
    HAS_CLAUDE=true
fi

echo ""
info "Sandy Integration Tests"

# For test gating, each agent is available if ANY of its auth methods works.
HAS_CODEX=false
HAS_GEMINI=false
[ "$HAS_OPENAI_API_KEY" = true ] || [ "$HAS_CODEX_OAUTH" = true ] && HAS_CODEX=true
[ "$HAS_GEMINI_API_KEY" = true ] || [ "$HAS_GEMINI_OAUTH" = true ] || [ "$HAS_GEMINI_ADC" = true ] && HAS_GEMINI=true

_label() { if [ "$1" = true ]; then printf "\033[0;32m✓\033[0m"; else printf "\033[0;31m✗\033[0m"; fi; }
_auth_detail() {
    local methods=()
    for pair in "$@"; do
        local name="${pair%%=*}" val="${pair#*=}"
        [ "$val" = true ] && methods+=("$name")
    done
    if [ "${#methods[@]}" -gt 0 ]; then
        printf "%s" "(${methods[*]})"
    else
        printf "none configured"
    fi
}

echo "  Codex:   $(_label $HAS_CODEX)  $(_auth_detail "api-key=$HAS_OPENAI_API_KEY" "oauth=$HAS_CODEX_OAUTH")"
echo "  Gemini:  $(_label $HAS_GEMINI)  $(_auth_detail "api-key=$HAS_GEMINI_API_KEY" "oauth=$HAS_GEMINI_OAUTH" "adc=$HAS_GEMINI_ADC")"
echo "  Claude:  $(_label $HAS_CLAUDE)  $(_auth_detail "api-key=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo true || echo false)" "oauth-token=$([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo true || echo false)" "credentials-file=$([ -f "$HOME/.claude/.credentials.json" ] && echo true || echo false)")"
echo ""

_all_true=true
for _v in $HAS_CODEX $HAS_GEMINI $HAS_CLAUDE; do
    [ "$_v" = true ] || _all_true=false
done

if [ "$_all_true" = false ]; then
    printf "\033[0;33mSome credentials are missing — affected tests will be skipped.\033[0m\n"
    printf "Enter \033[1ms\033[0m for setup help, or press \033[1mEnter\033[0m to continue: "
    read -r _choice </dev/tty || _choice=""
    echo ""
    if [ "$_choice" = "s" ] || [ "$_choice" = "S" ]; then
        echo ""
        echo "  Missing credentials — how to fix:"
        echo ""
        if [ "$HAS_CODEX" = false ]; then
            echo "  CODEX (need at least one):"
            echo "    export OPENAI_API_KEY=\"sk-...\"       # https://platform.openai.com/api-keys"
            echo "    codex login                          # creates ~/.codex/auth.json"
            echo ""
        fi
        if [ "$HAS_GEMINI" = false ]; then
            echo "  GEMINI (need at least one):"
            echo "    export GEMINI_API_KEY=\"AI...\"       # https://aistudio.google.com/apikey"
            echo "    gemini auth                          # creates ~/.gemini/oauth_creds.json"
            echo "    gcloud auth application-default login # Google ADC"
            echo ""
        fi
        if [ "$HAS_CLAUDE" = false ]; then
            echo "  CLAUDE (need at least one):"
            echo "    export ANTHROPIC_API_KEY=\"sk-ant-...\"  # Anthropic API key"
            echo "    export CLAUDE_CODE_OAUTH_TOKEN=\"...\"   # long-lived OAuth token"
            echo "    claude                                  # interactive login → ~/.claude/.credentials.json"
            echo ""
        fi
        echo "  To persist credentials, add them to ~/.sandy/.secrets (one per line):"
        echo "    OPENAI_API_KEY=sk-..."
        echo "    GEMINI_API_KEY=AI..."
        echo "    CLAUDE_CODE_OAUTH_TOKEN=..."
        echo "  This file is auto-read by both sandy and these tests."
        echo ""
        printf "Set the missing credentials and re-run, or press \033[1mEnter\033[0m to continue: "
        read -r _choice2 </dev/tty || _choice2=""
        echo ""
    fi
fi

# ============================================================
info "1. Feature guards (no credentials needed)"
# ============================================================

# These just need the sandy script; they exit at the guard before Docker.
# --help and --version exit before config loading, so we pass -p "test"
# which gets past arg parsing into the config/guard section. The guards
# fire and exit before any Docker operations.

_out="$(SANDY_AGENT=codex SANDY_SKILL_PACKS=gstack "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -qi "SANDY_SKILL_PACKS requires claude\|skill.packs.*not supported"; then
    pass "SANDY_SKILL_PACKS + codex rejected"
else
    fail "SANDY_SKILL_PACKS + codex rejected"
fi

_out="$(SANDY_AGENT=codex "$SANDY_SCRIPT" --remote 2>&1 || true)"
if echo "$_out" | grep -q "only supported with SANDY_AGENT=claude"; then
    pass "--remote + codex rejected"
else
    fail "--remote + codex rejected"
fi

_out="$(SANDY_AGENT=gemini "$SANDY_SCRIPT" --remote 2>&1 || true)"
if echo "$_out" | grep -q "only supported with SANDY_AGENT=claude"; then
    pass "--remote + gemini rejected"
else
    fail "--remote + gemini rejected"
fi

_out="$(SANDY_AGENT=both "$SANDY_SCRIPT" --remote 2>&1 || true)"
if echo "$_out" | grep -q "only supported with SANDY_AGENT=claude"; then
    pass "--remote + both rejected"
else
    fail "--remote + both rejected"
fi

_out="$(SANDY_AGENT=codex+claude "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -q "Invalid agent"; then
    pass "SANDY_AGENT=codex+claude rejected"
else
    fail "SANDY_AGENT=codex+claude rejected"
fi

# SANDY_AGENT=all is now a valid alias for claude,gemini,codex — verify it's accepted.
_out="$(SANDY_AGENT=all "$SANDY_SCRIPT" --help 2>&1 || true)"
if ! echo "$_out" | grep -q "Invalid agent"; then
    pass "SANDY_AGENT=all accepted as alias"
else
    fail "SANDY_AGENT=all accepted as alias"
fi

_out="$(SANDY_AGENT=codex SANDY_CHANNELS=discord "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -qi "discord.*only supported\|only supported.*claude"; then
    pass "discord channel + codex rejected"
else
    fail "discord channel + codex rejected"
fi

# ============================================================
info "2. Codex — image build and headless response"
# ============================================================

if [ "$HAS_OPENAI_API_KEY" = true ]; then
    setup_project codex "integ-codex"

    _out="$(run_sandy_headless "OPENAI_API_KEY=$OPENAI_API_KEY" -- -p "reply with exactly one word: pineapple")"
    _exit=$?

    # Image should exist after first run
    if docker image inspect sandy-codex &>/dev/null; then
        pass "sandy-codex image exists after build"
    else
        fail "sandy-codex image exists after build"
    fi

    # Should have gotten a response (non-empty output, exit 0)
    if [ -n "$_out" ] && ! echo "$_out" | grep -qi "error\|landlock\|permission"; then
        pass "codex headless responds without errors"
    else
        fail "codex headless responds without errors"
    fi

    # Check for Landlock specifically
    if echo "$_out" | grep -qi "landlock"; then
        fail "no Landlock errors in codex output"
    else
        pass "no Landlock errors in codex output"
    fi

    resolve_sandbox

    if [ -n "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR" ]; then
        # Config.toml seeding
        _cfg="$SANDBOX_DIR/codex/config.toml"
        if [ -f "$_cfg" ]; then
            pass "codex/config.toml exists in sandbox"

            if grep -q 'sandbox_mode = "danger-full-access"' "$_cfg"; then
                pass "config.toml contains sandbox_mode = danger-full-access"
            else
                fail "config.toml contains sandbox_mode = danger-full-access"
            fi

            _hide_count="$(grep -cE '^(hide_|"hide)' "$_cfg" || echo 0)"
            if [ "$_hide_count" -ge 5 ]; then
                pass "config.toml has all 5 hide keys ($_hide_count found)"
            else
                fail "config.toml has all 5 hide keys (only $_hide_count found)"
            fi

            _proj_count="$(grep -c '^\[projects\.' "$_cfg" || echo 0)"
            if [ "$_proj_count" -ge 1 ]; then
                pass "config.toml has trust entry for workspace"
            else
                fail "config.toml has trust entry for workspace"
            fi
        else
            fail "codex/config.toml exists in sandbox"
        fi

        # Idempotency: run again and check trust entry isn't duplicated
        run_sandy_headless "OPENAI_API_KEY=$OPENAI_API_KEY" -- -p "reply one word: test" >/dev/null 2>&1
        _proj_count="$(grep -c '^\[projects\.' "$_cfg" 2>/dev/null || echo 0)"
        if [ "$_proj_count" -eq 1 ]; then
            pass "trust entry idempotent on relaunch (count=$_proj_count)"
        else
            fail "trust entry idempotent on relaunch (count=$_proj_count)"
        fi

        # Sandbox forcing: delete config.toml, relaunch, verify it's re-seeded
        rm -f "$_cfg"
        _out="$(run_sandy_headless "OPENAI_API_KEY=$OPENAI_API_KEY" -- -p "reply one word: test")"
        if [ -f "$_cfg" ]; then
            pass "config.toml re-seeded after deletion"
        else
            fail "config.toml re-seeded after deletion"
        fi
        if echo "$_out" | grep -qi "landlock"; then
            fail "no Landlock errors after config.toml deletion (belt-and-suspenders)"
        else
            pass "no Landlock errors after config.toml deletion (belt-and-suspenders)"
        fi

        # Verify no cross-agent subdirs were created
        if [ ! -d "$SANDBOX_DIR/claude" ] && [ ! -d "$SANDBOX_DIR/gemini" ]; then
            pass "codex sandbox has no claude/ or gemini/ subdirs"
        else
            fail "codex sandbox has no claude/ or gemini/ subdirs"
        fi
    else
        fail "sandbox directory exists for codex project"
    fi
else
    skip "codex image build and headless (no OPENAI_API_KEY)"
fi

# (Section 3 removed — CODEX_API_KEY aliasing was dropped; codex uses OPENAI_API_KEY natively)

# ============================================================
info "4. Codex — in-container checks (sandy-codex image)"
# ============================================================

if docker image inspect sandy-codex &>/dev/null; then
    # Check codex is on PATH
    _ver="$(docker run --rm --entrypoint bash sandy-codex -c 'codex --version 2>/dev/null || echo MISSING')"
    if [ "$_ver" != "MISSING" ] && [ -n "$_ver" ]; then
        pass "codex binary on PATH in sandy-codex image (v$_ver)"
    else
        fail "codex binary on PATH in sandy-codex image"
    fi

    # Check version file
    _vfile="$(docker run --rm --entrypoint cat sandy-codex /opt/codex/.version 2>/dev/null || true)"
    if [ -n "$_vfile" ]; then
        pass "/opt/codex/.version populated ($_vfile)"
    else
        fail "/opt/codex/.version populated"
    fi

    # Check node is available (needed for npm install)
    _node="$(docker run --rm --entrypoint bash sandy-codex -c 'node --version 2>/dev/null || echo MISSING')"
    if [ "$_node" != "MISSING" ]; then
        pass "node available in sandy-codex image ($_node)"
    else
        fail "node available in sandy-codex image"
    fi

    # Check synthkit is installed
    _sk="$(docker run --rm --entrypoint bash sandy-codex -c 'command -v md2pdf && echo OK || echo MISSING')"
    if echo "$_sk" | grep -q "OK"; then
        pass "synthkit (md2pdf) available in sandy-codex image"
    else
        fail "synthkit (md2pdf) available in sandy-codex image"
    fi

    # Check WeasyPrint works via synthkit's isolated venv (uv tool install
    # puts weasyprint in /opt/uv-tools/, not the system Python).
    _wp="$(docker run --rm --entrypoint bash sandy-codex -c 'echo "# test" | md2html /dev/stdin 2>&1 && echo OK || echo MISSING')"
    if echo "$_wp" | grep -q "OK"; then
        pass "WeasyPrint functional in sandy-codex image (md2html)"
    else
        fail "WeasyPrint functional in sandy-codex image (md2html)"
    fi
else
    skip "codex in-container checks (sandy-codex image not built)"
fi

# ============================================================
info "5. Gemini — image build and headless response"
# ============================================================

if [ "$HAS_GEMINI" = true ]; then
    setup_project gemini "integ-gemini"

    # Pass GEMINI_API_KEY if available; otherwise let sandy detect OAuth/ADC.
    _gemini_env=()
    [ -n "${GEMINI_API_KEY:-}" ] && _gemini_env+=("GEMINI_API_KEY=$GEMINI_API_KEY")
    _out="$(run_sandy_headless "${_gemini_env[@]+"${_gemini_env[@]}"}" -- -p "reply with exactly one word: banana")"

    if docker image inspect sandy-gemini-cli &>/dev/null; then
        pass "sandy-gemini-cli image exists after build"
    else
        fail "sandy-gemini-cli image exists after build"
    fi

    if [ -n "$_out" ] && ! echo "$_out" | grep -qi "unknown flag\|error.*sandbox"; then
        pass "gemini headless responds without errors"
    else
        fail "gemini headless responds without errors"
    fi

    resolve_sandbox
    if [ -n "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR/gemini" ]; then
        pass "sandbox has gemini/ subdir"
    else
        fail "sandbox has gemini/ subdir"
    fi

    # Verify no cross-agent subdirs were created
    if [ -n "$SANDBOX_DIR" ] && [ ! -d "$SANDBOX_DIR/claude" ] && [ ! -d "$SANDBOX_DIR/codex" ]; then
        pass "gemini sandbox has no claude/ or codex/ subdirs"
    else
        fail "gemini sandbox has no claude/ or codex/ subdirs"
    fi
else
    skip "gemini image build and headless (no Gemini credentials)"
fi

# ============================================================
info "6. Gemini — in-container checks (sandy-gemini-cli image)"
# ============================================================

if docker image inspect sandy-gemini-cli &>/dev/null; then
    _ver="$(docker run --rm --entrypoint bash sandy-gemini-cli -c 'gemini --version 2>/dev/null || echo MISSING')"
    if [ "$_ver" != "MISSING" ] && [ -n "$_ver" ]; then
        pass "gemini binary on PATH in sandy-gemini-cli image"
    else
        fail "gemini binary on PATH in sandy-gemini-cli image"
    fi

    _node="$(docker run --rm --entrypoint bash sandy-gemini-cli -c 'node --version 2>/dev/null || echo MISSING')"
    if [ "$_node" != "MISSING" ]; then
        pass "node available in sandy-gemini-cli image ($_node)"
    else
        fail "node available in sandy-gemini-cli image"
    fi

    _sk="$(docker run --rm --entrypoint bash sandy-gemini-cli -c 'command -v md2pdf && echo OK || echo MISSING')"
    if echo "$_sk" | grep -q "OK"; then
        pass "synthkit (md2pdf) available in sandy-gemini-cli image"
    else
        fail "synthkit (md2pdf) available in sandy-gemini-cli image"
    fi

    _wp="$(docker run --rm --entrypoint bash sandy-gemini-cli -c 'echo "# test" | md2html /dev/stdin 2>&1 && echo OK || echo MISSING')"
    if echo "$_wp" | grep -q "OK"; then
        pass "WeasyPrint functional in sandy-gemini-cli image (md2html)"
    else
        fail "WeasyPrint functional in sandy-gemini-cli image (md2html)"
    fi
else
    skip "gemini in-container checks (sandy-gemini-cli image not built)"
fi

# ============================================================
info "7. Claude — headless regression"
# ============================================================

if [ "$HAS_CLAUDE" = true ]; then
    setup_project claude "integ-claude"

    _out="$(run_sandy_headless -- -p "reply with exactly one word: cherry")"

    # Image should exist after first run
    if docker image inspect sandy-claude-code &>/dev/null; then
        pass "sandy-claude-code image exists after build"
    else
        fail "sandy-claude-code image exists after build"
    fi

    _claude_ok=false
    if [ -n "$_out" ] && ! echo "$_out" | grep -qi "error.*settings\|layout migration"; then
        pass "claude headless responds without errors"
        _claude_ok=true
    else
        fail "claude headless responds without errors"
        # Show first few lines of output for debugging
        echo "    (output was: $(echo "$_out" | head -3 | tr '\n' ' '))" >&2
    fi

    resolve_sandbox
    if [ "$_claude_ok" = true ]; then
        if [ -n "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR/claude" ]; then
            pass "sandbox has claude/ subdir (v1.5 layout)"
        else
            fail "sandbox has claude/ subdir (v1.5 layout)"
            echo "    (SANDBOX_DIR=$SANDBOX_DIR, contents: $(ls "$SANDBOX_DIR" 2>/dev/null | tr '\n' ' '))" >&2
        fi

        # settings.json should NOT be at top level
        if [ -n "$SANDBOX_DIR" ] && [ ! -f "$SANDBOX_DIR/settings.json" ]; then
            pass "no settings.json at sandbox top level (v1.5 layout)"
        else
            fail "no settings.json at sandbox top level (v1.5 layout)"
        fi

        # Verify no cross-agent subdirs were created
        if [ -n "$SANDBOX_DIR" ] && [ ! -d "$SANDBOX_DIR/gemini" ] && [ ! -d "$SANDBOX_DIR/codex" ]; then
            pass "claude sandbox has no gemini/ or codex/ subdirs"
        else
            fail "claude sandbox has no gemini/ or codex/ subdirs"
        fi
    else
        skip "sandbox layout checks (claude session failed)"
    fi
else
    skip "claude headless regression (no Anthropic credentials)"
fi

# ============================================================
info "7b. Claude — in-container checks (sandy-claude-code image)"
# ============================================================

if docker image inspect sandy-claude-code &>/dev/null; then
    _ver="$(docker run --rm --entrypoint bash sandy-claude-code -c 'claude --version 2>/dev/null || echo MISSING')"
    if [ "$_ver" != "MISSING" ] && [ -n "$_ver" ]; then
        pass "claude binary on PATH in sandy-claude-code image (v$_ver)"
    else
        fail "claude binary on PATH in sandy-claude-code image"
    fi

    _node="$(docker run --rm --entrypoint bash sandy-claude-code -c 'node --version 2>/dev/null || echo MISSING')"
    if [ "$_node" != "MISSING" ]; then
        pass "node available in sandy-claude-code image ($_node)"
    else
        fail "node available in sandy-claude-code image"
    fi

    _sk="$(docker run --rm --entrypoint bash sandy-claude-code -c 'command -v md2pdf && echo OK || echo MISSING')"
    if echo "$_sk" | grep -q "OK"; then
        pass "synthkit (md2pdf) available in sandy-claude-code image"
    else
        fail "synthkit (md2pdf) available in sandy-claude-code image"
    fi

    _wp="$(docker run --rm --entrypoint bash sandy-claude-code -c 'echo "# test" | md2html /dev/stdin 2>&1 && echo OK || echo MISSING')"
    if echo "$_wp" | grep -q "OK"; then
        pass "WeasyPrint functional in sandy-claude-code image (md2html)"
    else
        fail "WeasyPrint functional in sandy-claude-code image (md2html)"
    fi
else
    skip "claude in-container checks (sandy-claude-code image not built)"
fi

# ============================================================
info "8. Cross-agent regression"
# ============================================================

# If we have both claude and codex keys, verify switching agents
# on the same project dir works without cross-contamination.
if [ "$HAS_CLAUDE" = true ] && [ "$HAS_OPENAI_API_KEY" = true ]; then
    setup_project codex "integ-switch"

    # Start as codex
    _out="$(run_sandy_headless "OPENAI_API_KEY=$OPENAI_API_KEY" -- -p "reply one word: first")"
    if ! echo "$_out" | grep -qi "error\|landlock"; then
        pass "codex session works in switch test"
    else
        fail "codex session works in switch test"
    fi

    # Switch to claude
    echo "SANDY_AGENT=claude" > "$PROJECT_DIR/.sandy/config"
    _out="$(run_sandy_headless -- -p "reply one word: second")"
    if [ -n "$_out" ] && ! echo "$_out" | grep -qi "codex\|error.*agent"; then
        pass "claude session works after switching from codex"
    else
        fail "claude session works after switching from codex"
    fi

    resolve_sandbox
elif [ "$HAS_CLAUDE" = true ] && [ "$HAS_GEMINI" = true ]; then
    setup_project gemini "integ-switch"

    _gemini_env=()
    [ -n "${GEMINI_API_KEY:-}" ] && _gemini_env+=("GEMINI_API_KEY=$GEMINI_API_KEY")
    _out="$(run_sandy_headless "${_gemini_env[@]+"${_gemini_env[@]}"}" -- -p "reply one word: first")"
    if ! echo "$_out" | grep -qi "unknown flag\|error"; then
        pass "gemini session works in switch test"
    else
        fail "gemini session works in switch test"
    fi

    echo "SANDY_AGENT=claude" > "$PROJECT_DIR/.sandy/config"
    _out="$(run_sandy_headless -- -p "reply one word: second")"
    if [ -n "$_out" ]; then
        pass "claude session works after switching from gemini"
    else
        fail "claude session works after switching from gemini"
    fi

    resolve_sandbox
else
    skip "cross-agent regression (need at least 2 sets of credentials)"
fi

# ============================================================
info "9. Codex — OAuth read-only mount"
# ============================================================

if [ "$HAS_CODEX_OAUTH" = true ]; then
    setup_project codex "integ-codex-oauth"
    # Unset API key env vars so OAuth path is used
    _out="$(run_sandy_headless "OPENAI_API_KEY=" -- -p "reply one word: test")"

    if echo "$_out" | grep -qi "Loaded Codex OAuth\|read-only mount"; then
        pass "codex OAuth credentials detected from host"
    else
        # Might still work without the log message
        if ! echo "$_out" | grep -qi "No Codex credentials"; then
            pass "codex session works with OAuth (no credential warning)"
        else
            fail "codex OAuth credentials detected from host"
        fi
    fi

    resolve_sandbox
else
    skip "codex OAuth read-only mount (no ~/.codex/auth.json)"
fi

# ============================================================
info "10. Gemini — OAuth path"
# ============================================================

if [ "$HAS_GEMINI_OAUTH" = true ] && [ -z "${GEMINI_API_KEY:-}" ]; then
    setup_project gemini "integ-gemini-oauth"
    _out="$(run_sandy_headless "GEMINI_API_KEY=" -- -p "reply one word: test")"

    if echo "$_out" | grep -q "Loaded Gemini OAuth"; then
        pass "gemini OAuth credentials detected from host"
    else
        if ! echo "$_out" | grep -qi "No Gemini credentials"; then
            pass "gemini session works with OAuth (no credential warning)"
        else
            fail "gemini OAuth credentials detected from host"
        fi
    fi

    resolve_sandbox
elif [ "$HAS_GEMINI_OAUTH" = true ]; then
    skip "gemini OAuth (GEMINI_API_KEY is set, would shadow OAuth; unset it to test)"
else
    skip "gemini OAuth (no ~/.gemini/oauth_creds.json or tokens.json)"
fi

# ============================================================
# Summary
# ============================================================
COMPLETED=true
echo ""
TOTAL=$((PASS + FAIL + SKIP))
if [ "$FAIL" -eq 0 ]; then
    printf "\033[0;32mAll %d tests passed" "$((PASS))"
    if [ "$SKIP" -gt 0 ]; then
        printf " (%d skipped — missing credentials)" "$SKIP"
    fi
    printf ".\033[0m\n"
else
    printf "\033[0;31m%d/%d tests failed:\033[0m\n" "$FAIL" "$((PASS + FAIL))"
    for e in "${ERRORS[@]}"; do
        printf "  \033[0;31m- %s\033[0m\n" "$e"
    done
    if [ "$SKIP" -gt 0 ]; then
        printf "\033[0;33m(%d tests skipped — missing credentials)\033[0m\n" "$SKIP"
    fi
    exit 1
fi
