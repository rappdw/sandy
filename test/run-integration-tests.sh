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

# The integration test harness runs sandy from directories that may legitimately
# carry privileged-tier keys in workspace .sandy/config (e.g. this repo's own
# ~/dev/sandy/.sandy/.secrets with GEMINI_API_KEY). Auto-approve them in-memory
# so the per-workspace prompt in _resolve_passive_privileged_approval() doesn't
# block the non-interactive test run. This env var is intentionally not on the
# passive config allowlist — a committed .sandy/config cannot set it.
export SANDY_AUTO_APPROVE_PRIVILEGED=1

# As of 1.0 the egress proxy is the default (SANDY_EGRESS_PROXY=1). The
# agent-functionality sections (§1-12) test builds / headless / credentials and
# must NOT be coupled to proxy correctness (a proxy bug would otherwise hang or
# fail every section, masking what they actually verify) — and they'd pay a
# proxy build + sidecar startup per launch. Pin them to legacy/no-proxy here;
# §13 sets SANDY_EGRESS_PROXY=1 explicitly to exercise the proxy end-to-end.
# Respect an explicit override so a maintainer can force the whole suite onto
# the proxy if they want.
export SANDY_EGRESS_PROXY="${SANDY_EGRESS_PROXY:-0}"

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
    # For every test workspace, also nuke sandy's per-workspace sandbox dir
    # and the sibling `<name>-<hash>.claude.json` sidecar file in
    # $SANDY_HOME/sandboxes/. Derive the sandbox name using the same formula
    # sandy uses at launch (basename + first 8 chars of sha256(phys_dir)).
    # This catches workspaces registered via setup_project AND throwaway
    # workspaces created by ensure_image_built that never called resolve_sandbox.
    for d in "${TEST_DIRS[@]+"${TEST_DIRS[@]}"}"; do
        if [ -n "$d" ] && [ -d "$d" ]; then
            local _phys _base _hash _sbname
            _phys="$(cd "$d" && pwd -P 2>/dev/null)" || _phys="$d"
            _base="$(basename "$_phys" | tr -cd 'a-zA-Z0-9._-')"
            _base="${_base:-project}"
            _hash="$(printf '%s' "$_phys" | shasum -a 256 2>/dev/null || printf '%s' "$_phys" | sha256sum)"
            _hash="${_hash%% *}"
            _sbname="${_base}-${_hash:0:8}"
            rm -rf "$SANDY_HOME/sandboxes/$_sbname" 2>/dev/null || true
            rm -f  "$SANDY_HOME/sandboxes/$_sbname.claude.json" 2>/dev/null || true
            rm -rf "$SANDY_HOME/sandboxes/.$_sbname.lock" 2>/dev/null || true
        fi
        rm -rf "$d" 2>/dev/null || true
    done
    for d in "${SANDBOX_DIRS[@]+"${SANDBOX_DIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
        rm -f "$d.claude.json" 2>/dev/null || true
        rm -rf "$(dirname "$d")/.$(basename "$d").lock" 2>/dev/null || true
    done
    # Tear down any leaked egress-proxy sidecars + per-instance networks so the
    # suite never leaves Docker state behind. With default egress=permissive,
    # every section that launches sandy creates these, and a SIGKILLed run leaks
    # them. (Function is defined later in the file but resolved at EXIT time.)
    sweep_leaked_sandy_networks 2>/dev/null || true
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

# Ensure a sandy image is built. Uses `sandy --build-only` which builds the
# image(s) for the given SANDY_AGENT and exits before any container runs — no
# credentials required. Returns 0 if the image exists (either already or after
# a successful build), 1 otherwise. Used by in-container check sections that
# only need the image, not a running session.
ensure_image_built() {
    local agent="$1" image="$2"
    if docker image inspect "$image" &>/dev/null; then
        return 0
    fi
    info "  Building $image on demand (no credentials needed)..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    TEST_DIRS+=("$tmp_dir")
    # --build-only exits right after docker build; run from a throwaway dir so
    # sandy's workspace-dependent logic (sandbox creation, trust entries, etc.)
    # doesn't touch anything real. Ignore failure — the image inspect below is
    # the authoritative check.
    (cd "$tmp_dir" && git init -q 2>/dev/null && \
        SANDY_AGENT="$agent" timeout "${SANDY_INTEG_TIMEOUT:-600}" \
        "$SANDY_SCRIPT" --build-only >/dev/null 2>&1) || true
    docker image inspect "$image" &>/dev/null
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
    # Feed sandy /dev/null on stdin: these are headless prompt-as-arg runs, and
    # an agent that reads stdin (codex exec) must see EOF, not block on an
    # inherited terminal. Makes the run identical from a terminal or in CI.
    if [ "$VERBOSE" -gt 0 ]; then
        if [ "${#env_args[@]}" -gt 0 ]; then
            timeout "$timeout_sec" env "${env_args[@]}" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" </dev/null 2>&1 | tee /dev/stderr || true
        else
            timeout "$timeout_sec" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" </dev/null 2>&1 | tee /dev/stderr || true
        fi
    else
        if [ "${#env_args[@]}" -gt 0 ]; then
            timeout "$timeout_sec" env "${env_args[@]}" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" </dev/null 2>&1 || true
        else
            timeout "$timeout_sec" "$SANDY_SCRIPT" $rebuild_flag $verbose_flag "${sandy_args[@]}" </dev/null 2>&1 || true
        fi
    fi
    # When `timeout` fires it SIGTERMs sandy, but sandy is blocked in its
    # foreground `docker run`, which doesn't receive the signal — so sandy's
    # cleanup trap can't run and the agent container is orphaned (a wedged
    # headless agent keeps running and pegs a CPU). Reap our test containers
    # (all named sandy-tmp.* — setup_project uses mktemp dirs). Force-removing
    # the container also makes the orphaned `docker run` exit, which unblocks
    # sandy so its own trap finally runs and tears down networks/sandboxes.
    reap_test_containers
}

# Force-remove any leftover sandy test containers (named sandy-tmp.*). Safe:
# the harness runs sections sequentially and owns every sandy-tmp.* container.
reap_test_containers() {
    local ids
    ids="$(docker ps -aq --filter 'name=sandy-tmp' 2>/dev/null)"
    [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 || true
    # Also reap leaked egress-proxy sidecars — but ONLY the test ones. The filter
    # MUST be scoped to `sandy-proxy-tmp` (test sandboxes use mktemp dirs named
    # tmp.*), NOT a bare `sandy-proxy-` substring. `docker --filter name=` is a
    # SUBSTRING match, so `sandy-proxy-` would also force-remove a developer's
    # REAL concurrent session proxy (`sandy-proxy-<project>-<hash>`), stranding
    # its agent on a routeless sidecar — every request FailedToOpenSocket until
    # that session is restarted. (This bug is exactly what made a real proxy
    # "disappear" while the suite ran; the agent's --restart policy can't save it
    # because the container is *removed*, not just stopped.)
    local pids
    pids="$(docker ps -aq --filter 'name=sandy-proxy-tmp' 2>/dev/null)"
    [ -n "$pids" ] && docker rm -f $pids >/dev/null 2>&1 || true
}

# Remove any leaked sandy per-instance networks (sandy_{net,sidecar,egress}_<pid>)
# AND the detached proxy sidecars that hold them open. Called before §13 (so a
# leftover from an earlier suite run can't pre-fail the leak assertion) and from
# the EXIT trap (so this suite never leaves leaks behind). NOT used to satisfy
# §13's assertion — that polls for sandy's own teardown.
#
# The egress proxy is launched with `docker run -d` (detached), so after a
# SIGKILLed run the sandy-proxy-<pid> container keeps RUNNING and stays attached
# to its sidecar network — `docker network rm` then fails with "active endpoints"
# until the container is gone. So: kill the proxy containers first, then
# force-disconnect any lingering endpoints, then remove the networks. (Avoid
# `xargs -r` — the -r/--no-run-if-empty flag is GNU-only, absent on macOS.)
sweep_leaked_sandy_networks() {
    # Scoped to test proxies only (sandy-proxy-tmp) — see reap_test_containers for
    # why a bare `sandy-proxy-` substring would nuke a real concurrent session.
    local pids
    pids="$(docker ps -aq --filter 'name=sandy-proxy-tmp' 2>/dev/null)"
    [ -n "$pids" ] && docker rm -f $pids >/dev/null 2>&1 || true
    local net cid attached real
    for net in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^sandy_(net|sidecar|egress)_' || true); do
        # Network names are PID-keyed and indistinguishable from a real session's,
        # so gate on the ATTACHED containers: if anything other than a test
        # container (sandy-tmp.* / sandy-proxy-tmp.*) is attached, this network
        # belongs to a real session — hands off (don't disconnect, don't remove).
        attached="$(docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
        real=0
        for cid in $attached; do
            case "$cid" in
                sandy-tmp.*|sandy-proxy-tmp.*) : ;;
                *) real=1 ;;
            esac
        done
        [ "$real" = 1 ] && continue
        # No real session attached (leaked or test-only): detach leftovers, remove.
        for cid in $attached; do
            docker network disconnect -f "$net" "$cid" >/dev/null 2>&1 || true
        done
        docker network rm "$net" >/dev/null 2>&1 || true
    done
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
HAS_OPENCODE_OAUTH=false

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
[ -f "$HOME/.local/share/opencode/auth.json" ] && HAS_OPENCODE_OAUTH=true
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
HAS_OPENCODE=false
[ "$HAS_OPENAI_API_KEY" = true ] || [ "$HAS_CODEX_OAUTH" = true ] && HAS_CODEX=true
[ "$HAS_GEMINI_API_KEY" = true ] || [ "$HAS_GEMINI_OAUTH" = true ] || [ "$HAS_GEMINI_ADC" = true ] && HAS_GEMINI=true
# OpenCode auth: either the OAuth file, or any provider API key the user has set
# (opencode reads ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY natively).
[ "$HAS_OPENCODE_OAUTH" = true ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ] && HAS_OPENCODE=true

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

echo "  Codex:    $(_label $HAS_CODEX)  $(_auth_detail "api-key=$HAS_OPENAI_API_KEY" "oauth=$HAS_CODEX_OAUTH")"
echo "  Gemini:   $(_label $HAS_GEMINI)  $(_auth_detail "api-key=$HAS_GEMINI_API_KEY" "oauth=$HAS_GEMINI_OAUTH" "adc=$HAS_GEMINI_ADC")"
echo "  Claude:   $(_label $HAS_CLAUDE)  $(_auth_detail "api-key=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo true || echo false)" "oauth-token=$([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo true || echo false)" "credentials-file=$([ -f "$HOME/.claude/.credentials.json" ] && echo true || echo false)")"
echo "  OpenCode: $(_label $HAS_OPENCODE)  $(_auth_detail "anthropic-key=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo true || echo false)" "openai-key=$HAS_OPENAI_API_KEY" "gemini-key=$HAS_GEMINI_API_KEY" "oauth=$HAS_OPENCODE_OAUTH")"
echo ""

_all_true=true
for _v in $HAS_CODEX $HAS_GEMINI $HAS_CLAUDE $HAS_OPENCODE; do
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
        if [ "$HAS_OPENCODE" = false ]; then
            echo "  OPENCODE (provider-agnostic — any of these works):"
            echo "    export ANTHROPIC_API_KEY=\"sk-ant-...\"   # opencode reads natively"
            echo "    export OPENAI_API_KEY=\"sk-...\""
            echo "    export GEMINI_API_KEY=\"AI...\""
            echo "    opencode auth login                     # OAuth → ~/.local/share/opencode/auth.json"
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

_out="$(SANDY_AGENT=claude,gemini "$SANDY_SCRIPT" --remote 2>&1 || true)"
if echo "$_out" | grep -q "only supported with SANDY_AGENT=claude"; then
    pass "--remote + claude,gemini rejected"
else
    fail "--remote + claude,gemini rejected"
fi

# The old `both` alias was removed in v0.12 — using it must error out with
# a pointer to the comma-separated syntax, not silently map to claude,gemini.
_out="$(SANDY_AGENT=both "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -q "SANDY_AGENT=both is no longer supported"; then
    pass "SANDY_AGENT=both errors with migration hint"
else
    fail "SANDY_AGENT=both errors with migration hint"
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

# OpenCode-specific guards (mirror codex)
_out="$(SANDY_AGENT=opencode SANDY_SKILL_PACKS=gstack "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -qi "SANDY_SKILL_PACKS requires claude"; then
    pass "SANDY_SKILL_PACKS + opencode rejected"
else
    fail "SANDY_SKILL_PACKS + opencode rejected"
fi
_out="$(SANDY_AGENT=opencode "$SANDY_SCRIPT" --remote 2>&1 || true)"
if echo "$_out" | grep -q "only supported with SANDY_AGENT=claude"; then
    pass "--remote + opencode rejected"
else
    fail "--remote + opencode rejected"
fi
_out="$(SANDY_AGENT=opencode SANDY_CHANNELS=discord "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -qi "discord.*only supported\|only supported.*claude"; then
    pass "discord channel + opencode rejected"
else
    fail "discord channel + opencode rejected"
fi

# SANDY_LOCAL_LLM_HOST validation: world-open / malformed values rejected.
_out="$(SANDY_LOCAL_LLM_HOST=0.0.0.0:11434 "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -q "world-open or empty"; then
    pass "SANDY_LOCAL_LLM_HOST=0.0.0.0:port rejected"
else
    fail "SANDY_LOCAL_LLM_HOST=0.0.0.0:port rejected"
fi
_out="$(SANDY_LOCAL_LLM_HOST=127.0.0.1 "$SANDY_SCRIPT" -p "test" 2>&1 || true)"
if echo "$_out" | grep -q "not in host:port format"; then
    pass "SANDY_LOCAL_LLM_HOST=bare-IP rejected"
else
    fail "SANDY_LOCAL_LLM_HOST=bare-IP rejected"
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

    # Positive check first: codex must have produced the requested word.
    # codex 0.139+ logs retryable ERROR lines on stderr — its experimental
    # Responses-websocket transport can 401 with a plain API key before
    # falling back to HTTPS and succeeding (openai/codex#19821, #15492) — so
    # matching bare "error" is a false positive when the session as a whole
    # works. Mirror the gemini treatment (§8): pass on the answer; a codex
    # *API* error (401/403/429/quota) means sandy did its job — it launched
    # codex and codex reached the API — so SKIP rather than FAIL. Empty
    # output or anything else is still sandy's responsibility → FAIL.
    # (strip the echoed prompt line — codex exec prints the prompt in its
    # transcript, which would otherwise satisfy the positive check)
    if [ -n "$_out" ] && echo "$_out" | grep -vi "reply with exactly one word" | grep -qi "pineapple"; then
        pass "codex headless responds without errors"
    elif [ -n "$_out" ] \
         && echo "$_out" | grep -qiE 'HTTP error: [45][0-9][0-9]|[45][0-9][0-9] (Unauthorized|Forbidden|Too Many Requests)|rate.?limit|insufficient.?quota'; then
        skip "codex headless responds without errors — codex API error, not a sandy fault ($(echo "$_out" | grep -oiE 'HTTP error: [45][0-9][0-9]|[45][0-9][0-9] (Unauthorized|Forbidden|Too Many Requests)|rate.?limit|insufficient.?quota' | head -1))"
    else
        fail "codex headless responds without errors"
        if [ -z "$_out" ]; then
            echo "    (empty output — codex produced nothing; sandy launch/credential issue)" >&2
        else
            echo "    (no 'pineapple' in output and no recognizable API error; tail: $(echo "$_out" | tail -4 | tr '\n' ' '))" >&2
        fi
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

if ensure_image_built codex sandy-codex; then
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
    fail "codex in-container checks (failed to build sandy-codex image)"
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

if ensure_image_built gemini sandy-gemini-cli; then
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
    fail "gemini in-container checks (failed to build sandy-gemini-cli image)"
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

if ensure_image_built claude sandy-claude-code; then
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
    fail "claude in-container checks (failed to build sandy-claude-code image)"
fi

# ============================================================
info "8. Cross-agent regression"
# ============================================================

# If we have both claude and codex keys, verify switching agents
# on the same project dir works without cross-contamination.
if [ "$HAS_CLAUDE" = true ] && [ "$HAS_OPENAI_API_KEY" = true ]; then
    setup_project codex "integ-switch"

    # Start as codex. Same positive-check-first logic as §2: codex 0.139+
    # logs retryable websocket-401 ERROR lines before its HTTPS fallback
    # succeeds, so bare "error" matching is a false positive; a real codex
    # API error is skipped (not sandy's fault), anything else fails.
    _out="$(run_sandy_headless "OPENAI_API_KEY=$OPENAI_API_KEY" -- -p "reply one word: first")"
    if [ -n "$_out" ] && echo "$_out" | grep -vi "reply one word" | grep -qi "first"; then
        pass "codex session works in switch test"
    elif [ -n "$_out" ] \
         && echo "$_out" | grep -qiE 'HTTP error: [45][0-9][0-9]|[45][0-9][0-9] (Unauthorized|Forbidden|Too Many Requests)|rate.?limit|insufficient.?quota'; then
        skip "codex session works in switch test — codex API error, not a sandy fault ($(echo "$_out" | grep -oiE 'HTTP error: [45][0-9][0-9]|[45][0-9][0-9] (Unauthorized|Forbidden|Too Many Requests)|rate.?limit|insufficient.?quota' | head -1))"
    else
        fail "codex session works in switch test"
        if [ -z "$_out" ]; then
            echo "    (empty output — codex produced nothing; sandy launch/credential issue)" >&2
        else
            echo "    (no 'first' in output and no recognizable API error; tail: $(echo "$_out" | tail -4 | tr '\n' ' '))" >&2
        fi
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
    # Positive check: model must have responded with the requested word.
    # Negative check: only sandy-level/flag-level failures, NOT bare "error" —
    # gemini-cli logs an _ApiError stack trace on transient 503s before its
    # own retry-with-backoff succeeds, and matching that as "error" here is a
    # false positive (the session as a whole still works).
    # A gemini *API* error (4xx/5xx, "critical error", 503/quota) means sandy did
    # its job — it launched gemini and gemini reached the API — and gemini's own
    # backend failed. That's not a sandy regression, so SKIP rather than FAIL
    # (a red suite on a transient Google API blip is a false alarm). A sandy-level
    # failure (empty output = didn't launch, or a flag-translation error) still
    # FAILS, because those are sandy's responsibility.
    if [ -n "$_out" ] \
       && echo "$_out" | grep -qi "first" \
       && ! echo "$_out" | grep -qi "unknown flag"; then
        pass "gemini session works in switch test"
    elif [ -n "$_out" ] \
         && ! echo "$_out" | grep -qi "unknown flag" \
         && echo "$_out" | grep -qiE 'status: *[45][0-9][0-9]|critical error|503|500|RESOURCE_EXHAUSTED|quota|UNAVAILABLE|rate.?limit'; then
        skip "gemini session works in switch test — gemini API error, not a sandy fault ($(echo "$_out" | grep -oiE 'status: *[0-9]+|critical error|RESOURCE_EXHAUSTED|quota|UNAVAILABLE|rate.?limit' | head -1))"
    else
        fail "gemini session works in switch test"
        if [ -z "$_out" ]; then
            echo "    (empty output — gemini produced nothing; sandy launch/credential issue)" >&2
        elif echo "$_out" | grep -qi "unknown flag"; then
            echo "    (flag-translation error — real sandy bug: $(echo "$_out" | grep -i 'unknown flag' | head -1))" >&2
        else
            echo "    (responded but without 'first' and no recognizable API error: $(echo "$_out" | tail -4 | tr '\n' ' '))" >&2
        fi
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

if [ "$HAS_GEMINI_OAUTH" = true ]; then
    setup_project gemini "integ-gemini-oauth"
    # Verify the OAuth path even when GEMINI_API_KEY is set in the harness env
    # (§5/§6 rely on it). Force the OAuth probe with SANDY_GEMINI_AUTH=oauth — which
    # makes load_gemini_credentials skip the api-key branch entirely — and empty the
    # key for this one invocation so it can't shadow OAuth in-container. This lets
    # BOTH gemini auth modes be verified in a single suite run.
    _out="$(run_sandy_headless "GEMINI_API_KEY=" "SANDY_GEMINI_AUTH=oauth" -- -p "reply one word: test")"

    if echo "$_out" | grep -q "Loaded Gemini OAuth"; then
        pass "gemini OAuth credentials detected from host (forced via SANDY_GEMINI_AUTH=oauth)"
    else
        if ! echo "$_out" | grep -qi "No Gemini credentials"; then
            pass "gemini session works with OAuth (no credential warning)"
        else
            fail "gemini OAuth credentials detected from host"
            echo "    (tail: $(echo "$_out" | tail -3 | tr '\n' ' '))" >&2
        fi
    fi

    resolve_sandbox
else
    skip "gemini OAuth (no ~/.gemini/oauth_creds.json or tokens.json)"
fi

# ============================================================
info "11. OpenCode — image build and headless response"
# ============================================================

if [ "$HAS_OPENCODE" = true ]; then
    setup_project opencode "integ-opencode"

    # Forward whichever provider keys the user has — opencode picks one up.
    _env_args=()
    [ -n "${ANTHROPIC_API_KEY:-}" ] && _env_args+=("ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    [ -n "${OPENAI_API_KEY:-}" ]    && _env_args+=("OPENAI_API_KEY=$OPENAI_API_KEY")
    [ -n "${GEMINI_API_KEY:-}" ]    && _env_args+=("GEMINI_API_KEY=$GEMINI_API_KEY")
    _out="$(run_sandy_headless "${_env_args[@]}" -- -p "reply with exactly one word: pineapple")"

    if docker image inspect sandy-opencode &>/dev/null; then
        pass "sandy-opencode image exists after build"
    else
        fail "sandy-opencode image exists after build"
    fi

    if [ -n "$_out" ] && ! echo "$_out" | grep -qi "error.*credential\|no provider configured"; then
        pass "opencode headless responds without errors"
    else
        fail "opencode headless responds without errors"
    fi

    resolve_sandbox

    if [ -n "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR" ]; then
        # Sandbox layout: config + share subdirs under opencode/
        if [ -d "$SANDBOX_DIR/opencode/config" ]; then
            pass "opencode/config dir exists in sandbox"
        else
            fail "opencode/config dir exists in sandbox"
        fi
        if [ -d "$SANDBOX_DIR/opencode/share" ]; then
            pass "opencode/share dir exists in sandbox"
        else
            fail "opencode/share dir exists in sandbox"
        fi
        # No cross-agent contamination
        if [ ! -d "$SANDBOX_DIR/claude" ] && [ ! -d "$SANDBOX_DIR/codex" ] && [ ! -d "$SANDBOX_DIR/gemini" ]; then
            pass "opencode sandbox has no claude/, codex/, or gemini/ subdirs"
        else
            fail "opencode sandbox has no claude/, codex/, or gemini/ subdirs"
        fi
    else
        fail "sandbox directory exists for opencode project"
    fi
else
    skip "opencode image build and headless (no provider key or OAuth file)"
fi

# ============================================================
info "12. OpenCode — in-container checks (sandy-opencode image)"
# ============================================================

if ensure_image_built opencode sandy-opencode; then
    _ver="$(docker run --rm --entrypoint bash sandy-opencode -c 'opencode --version 2>/dev/null || echo MISSING')"
    if [ "$_ver" != "MISSING" ] && [ -n "$_ver" ]; then
        pass "opencode binary on PATH in sandy-opencode image (v$_ver)"
    else
        fail "opencode binary on PATH in sandy-opencode image"
    fi

    _vfile="$(docker run --rm --entrypoint cat sandy-opencode /opt/opencode/.version 2>/dev/null || true)"
    if [ -n "$_vfile" ]; then
        pass "/opt/opencode/.version populated ($_vfile)"
    else
        fail "/opt/opencode/.version populated"
    fi

    _node="$(docker run --rm --entrypoint bash sandy-opencode -c 'node --version 2>/dev/null || echo MISSING')"
    if [ "$_node" != "MISSING" ]; then
        pass "node available in sandy-opencode image ($_node)"
    else
        fail "node available in sandy-opencode image"
    fi

    _sk="$(docker run --rm --entrypoint bash sandy-opencode -c 'command -v md2pdf && echo OK || echo MISSING')"
    if echo "$_sk" | grep -q OK; then
        pass "synthkit (md2pdf) available in sandy-opencode image"
    else
        fail "synthkit (md2pdf) available in sandy-opencode image"
    fi
else
    fail "opencode in-container checks (failed to build sandy-opencode image)"
fi

# ============================================================
info "13. Egress proxy (M2.7) — end-to-end through the sidecar"
# ============================================================
# Proves the agent reaches the model API THROUGH the proxy on the --internal
# two-network topology (the macOS F2 fix; identical on Linux). Requires Claude
# credentials. Until M2.7 merges to main, the proxy image builds from the
# current branch, so pin SANDY_PROXY_REF to it (a release pins its version tag).
# NOTE: the macOS-specific LAN-block behavior is covered by the manual checklist
# in TESTING_PLAN.md §6 (CI can't reach Docker Desktop's VM networking).
if [ "$HAS_CLAUDE" = true ]; then
    _PX_REF="$(git -C "$(dirname "$SANDY_SCRIPT")" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    setup_project claude "integ-proxy"

    # Clear any networks leaked by an earlier section / a previous suite run that
    # was SIGKILLed — otherwise the leak assertion below trips on someone else's
    # leftover, not this run's. (This is a clean-slate sweep, not the assertion.)
    sweep_leaked_sandy_networks

    # Snapshot the sandy networks that already exist (e.g. a developer's live
    # concurrent session, whose proxy/networks we must NOT disturb) so the leak
    # check below flags only networks THIS run created and failed to tear down —
    # not someone else's in-use session networks. Without this, running the suite
    # with a real session open false-fails: the global grep at the assertion sees
    # that session's sandy_* networks and reports them as "leaked".
    _pre_nets="$(docker network ls --format '{{.Name}}' | grep -E '^sandy_(sidecar|egress)_' || true)"

    # Permissive (=1): the agent must reach api.anthropic.com via the proxy.
    _out="$(run_sandy_headless "SANDY_EGRESS_PROXY=1" "SANDY_PROXY_REF=$_PX_REF" -- -p "reply with exactly one word: proxied")"

    if echo "$_out" | grep -q "Creating egress-proxy networks (mode=permissive)"; then
        pass "proxy mode 1 stands up the egress-proxy networks + sidecar"
    else
        fail "proxy mode 1 stands up the egress-proxy networks + sidecar"
        echo "    (output: $(echo "$_out" | head -6 | tr '\n' ' '))" >&2
    fi

    if echo "$_out" | grep -qi "proxied" && ! echo "$_out" | grep -qi "ECONNRESET\|Unable to connect to API"; then
        pass "agent reaches the model API through the proxy (no ECONNRESET)"
    else
        fail "agent reaches the model API through the proxy"
        echo "    (output: $(echo "$_out" | tail -6 | tr '\n' ' '))" >&2
    fi

    # Networks must be torn down on exit — a leak exhausts Docker's address pool.
    # Poll for up to ~5s: when the run is SIGTERM'd by `timeout`, the agent
    # container reap (in run_sandy_headless) unblocks sandy's cleanup trap, which
    # then removes the networks — but that teardown can lag the check by a beat.
    # Polling verifies SANDY's own teardown (not the reaper's) without racing it.
    _nets_cleared=false
    _leaked_nets=""
    for _i in $(seq 1 10); do
        # Leak = sandy networks present now that were NOT in the pre-run baseline
        # (so a concurrent real session's networks never count as this run's leak).
        _leaked_nets="$(docker network ls --format '{{.Name}}' | grep -E '^sandy_(sidecar|egress)_' | grep -vxF "$_pre_nets" | grep -E '^sandy_' || true)"
        if [ -z "$_leaked_nets" ]; then
            _nets_cleared=true; break
        fi
        sleep 0.5
    done
    if [ "$_nets_cleared" = true ]; then
        pass "proxy networks cleaned up after exit (no address-pool leak)"
    else
        fail "proxy networks cleaned up after exit (no address-pool leak)"
        echo "    (still leaked after ~5s: $(echo "$_leaked_nets" | tr '\n' ' '))" >&2
    fi

    # Opt-out (=0): no proxy path; the agent still works (legacy isolation).
    _out0="$(run_sandy_headless "SANDY_EGRESS_PROXY=0" -- -p "reply with exactly one word: direct")"
    if echo "$_out0" | grep -qi "direct" && ! echo "$_out0" | grep -q "egress-proxy networks"; then
        pass "SANDY_EGRESS_PROXY=0 opts out of the proxy path"
    else
        fail "SANDY_EGRESS_PROXY=0 opts out of the proxy path"
        echo "    (output: $(echo "$_out0" | tail -4 | tr '\n' ' '))" >&2
    fi
else
    skip "egress proxy end-to-end (no Claude credentials)"
fi

# ============================================================
info "13b. Egress proxy — non-TCP egress backstop (--internal drops UDP/QUIC)"
# ============================================================
# The proxy is TCP-only by design; --internal must drop all non-TCP egress (an L3
# FORWARD drop), or UDP/QUIC/HTTP-3 would bypass the SNI proxy and DNS could
# tunnel out. This is deterministic and needs no agent/creds — a throwaway alpine
# container on a fresh --internal network must NOT get a UDP DNS reply from a
# public resolver. (Linux coverage; the macOS spike covers Docker Desktop.)
_NTNET="sandy_nontcp_test_$$"
if docker network create --internal --driver bridge --ipv6=false "$_NTNET" >/dev/null 2>&1; then
    # nslookup uses UDP/53; a reply means UDP escaped the --internal bridge.
    if docker run --rm --network "$_NTNET" alpine:3.20 \
            sh -c "timeout 5 nslookup example.com 8.8.8.8 >/dev/null 2>&1"; then
        fail "non-TCP backstop: --internal allowed UDP DNS to 8.8.8.8 (egress leak)"
    else
        pass "non-TCP backstop: --internal blocks UDP egress (DNS to 8.8.8.8 failed)"
    fi
    docker network rm "$_NTNET" >/dev/null 2>&1 || true
else
    skip "non-TCP backstop (could not create --internal test network)"
fi

# ============================================================
info "14. Sandbox compatibility floor (M4 PR 4.2) — hard refuse below floor"
# ============================================================
# The 1.x forward-compat promise: a sandbox created below SANDY_SANDBOX_MIN_COMPAT
# is refused at launch (the launcher exits before docker run). Exercise the real
# launch path: create a sandbox, downgrade its marker below the floor, and assert
# sandy refuses; then restore an above-floor marker and assert it proceeds. The
# pure classifier is unit-tested in run-tests.sh §51; this covers the wiring.
if [ "$HAS_CLAUDE" = true ]; then
    setup_project claude "integ-compat"
    # First launch creates the sandbox authentically.
    run_sandy_headless -- -p "reply with exactly one word: floor" >/dev/null 2>&1
    resolve_sandbox
    if [ -n "$SANDBOX_DIR" ] && [ -d "$SANDBOX_DIR" ]; then
        _marker="$SANDBOX_DIR/.sandy_created_version"
        _orig_ver="$(cat "$_marker" 2>/dev/null || true)"

        # (a) Below-floor marker → sandy must refuse with the recreation hint.
        echo "0.5.0" > "$_marker"
        _out="$(run_sandy_headless -- -p "should not run")"
        if echo "$_out" | grep -q "below the" && echo "$_out" | grep -q "refuses to launch against it"; then
            pass "below-floor sandbox is hard-refused at launch"
        else
            fail "below-floor sandbox is hard-refused at launch"
            echo "    (output: $(echo "$_out" | head -4 | tr '\n' ' '))" >&2
        fi
        # The refusal must NOT have reached the container launch banner.
        if echo "$_out" | grep -qi "Launching .*sandbox"; then
            fail "below-floor refusal happens before container launch"
        else
            pass "below-floor refusal happens before container launch"
        fi

        # (b) Restore an above-floor marker → sandy proceeds (no refuse message).
        echo "${_orig_ver:-$("$SANDY_SCRIPT" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)}" > "$_marker"
        _out2="$(run_sandy_headless -- -p "reply with exactly one word: ok")"
        if echo "$_out2" | grep -q "refuses to launch against it"; then
            fail "above-floor sandbox launches without the floor refusal"
            echo "    (output: $(echo "$_out2" | head -4 | tr '\n' ' '))" >&2
        else
            pass "above-floor sandbox launches without the floor refusal"
        fi
    else
        fail "compat floor: sandbox dir resolved after first launch"
    fi
else
    skip "sandbox compatibility floor (needs Claude credentials)"
fi

# ============================================================
info "15. Failure-mode guards (M4 PR 4.4) — fail cleanly, not cryptically"
# ============================================================
# Sandy must exit non-zero with a SPECIFIC, actionable message on the common
# launch failures. Pure-script coverage (the credential validator + source-level
# message lock-in) is run-tests.sh §53; here we exercise the real launch path.
# Note: "Docker daemon down" can't be automated (we won't stop the host daemon) —
# it's a manual check; "missing image → rebuild" is covered by the build-on-demand
# behavior in §2/§5/§7/§11. (set -euo pipefail is active → capture rc with
# `&& rc=0 || rc=$?`.)

# 15a. Read-only SANDY_HOME → clean "not writable" error, exits before any
# container (fires at preflight; needs only a running daemon, which §0 confirmed).
_ro_home="$(mktemp -d)"
chmod 0555 "$_ro_home"
_fm_out="$(SANDY_HOME="$_ro_home" timeout 90 "$SANDY_SCRIPT" -p "noop" 2>&1)" && _fm_rc=0 || _fm_rc=$?
chmod 0755 "$_ro_home" 2>/dev/null || true; rm -rf "$_ro_home"
if [ "${_fm_rc:-0}" -ne 0 ] && echo "$_fm_out" | grep -q "is not writable"; then
    pass "read-only SANDY_HOME → clean error + non-zero exit"
else
    fail "read-only SANDY_HOME → clean error + non-zero exit"
    echo "    (rc=$_fm_rc; tail: $(echo "$_fm_out" | tail -3 | tr '\n' ' '))" >&2
fi

# 15b. Corrupt ~/.claude/.credentials.json with no token → clean re-login error.
# Override HOME to a throwaway dir holding a corrupt creds file; gate on a built
# claude image (the guard fires after the cached build). CLAUDE_CODE_OAUTH_TOKEN
# emptied so the hard-error branch (not the token-fallback branch) is exercised.
if [ "$HAS_CLAUDE" = true ]; then
    _bad_home="$(mktemp -d)"; mkdir -p "$_bad_home/.claude"
    printf '{ this is not valid json' > "$_bad_home/.claude/.credentials.json"
    _bad_sbx="$(mktemp -d)"
    setup_project claude "integ-corrupt-creds"
    _fm_out2="$(HOME="$_bad_home" SANDY_HOME="$_bad_sbx" CLAUDE_CODE_OAUTH_TOKEN="" \
        timeout 300 "$SANDY_SCRIPT" -p "noop" 2>&1)" && _fm_rc2=0 || _fm_rc2=$?
    rm -rf "$_bad_home" "$_bad_sbx"
    if [ "${_fm_rc2:-0}" -ne 0 ] && echo "$_fm_out2" | grep -q "credentials are corrupt"; then
        pass "corrupt credentials (no token) → clean re-login error + non-zero exit"
    else
        fail "corrupt credentials (no token) → clean re-login error + non-zero exit"
        echo "    (rc=$_fm_rc2; tail: $(echo "$_fm_out2" | tail -4 | tr '\n' ' '))" >&2
    fi
else
    skip "corrupt-credentials guard (needs Claude image built)"
fi

# ============================================================
info "16. Multi-agent combo (M4 PR 4.3) — sandy-full + headless routes to first agent"
# ============================================================
# §8 covers *sequential* single-agent switching; this covers a genuine
# multi-agent *combo* session: SANDY_AGENT=<a>,<b> selects the sandy-full
# superset image and, in headless (-p) mode, routes the prompt to the FIRST
# agent only (sandy/2561). We pick a combo whose first agent we have creds for
# so the routed agent is the one we verify; the other agent only needs to be
# installed in the image (no creds, since its pane isn't created headless).
# Asserting sandy-full exists after the run proves the superset image — not a
# single-agent image — was the one built/used.
#
# Matrix cells NOT auto-tested here (documented per roadmap, not silently
# skipped): the multi-PANE interactive experience (claude+gemini dual-pane,
# the 3-/4-agent grids, per-pane channel routing) is manual-only — it requires
# a TTY to observe the panes — and lives in docs/TESTING_PLAN.md §4 / §4b.
_combo=""; _routed=""
if [ "$HAS_CLAUDE" = true ] && [ "$HAS_CODEX" = true ]; then
    _combo="claude,codex"; _routed="claude"
elif [ "$HAS_CLAUDE" = true ] && [ "$HAS_GEMINI" = true ]; then
    _combo="claude,gemini"; _routed="claude"
elif [ "$HAS_GEMINI" = true ] && [ "$HAS_CODEX" = true ]; then
    _combo="gemini,codex"; _routed="gemini"
fi

if [ -n "$_combo" ]; then
    setup_project "$_combo" "integ-combo"
    _combo_env=()
    [ -n "${GEMINI_API_KEY:-}" ] && _combo_env+=("GEMINI_API_KEY=$GEMINI_API_KEY")
    [ -n "${OPENAI_API_KEY:-}" ] && _combo_env+=("OPENAI_API_KEY=$OPENAI_API_KEY")
    _out="$(run_sandy_headless "${_combo_env[@]+"${_combo_env[@]}"}" -- -p "reply one word: alpha")"

    # Positive-first, matching §8: the routed agent must have answered. A routed
    # agent's own API blip (gemini 5xx, codex 401-then-fallback) is sandy doing
    # its job → SKIP, not FAIL; empty output (didn't launch) still FAILS.
    if [ -n "$_out" ] && echo "$_out" | grep -vi "reply one word" | grep -qi "alpha"; then
        pass "combo $_combo → headless routes to $_routed, which responds"
    elif [ -n "$_out" ] \
         && echo "$_out" | grep -qiE 'status: *[45][0-9][0-9]|critical error|503|500|RESOURCE_EXHAUSTED|quota|UNAVAILABLE|rate.?limit|HTTP error: [45][0-9][0-9]|[45][0-9][0-9] (Unauthorized|Forbidden|Too Many Requests)|insufficient.?quota'; then
        skip "combo $_combo → routed $_routed reached API but it errored, not a sandy fault ($(echo "$_out" | grep -oiE 'status: *[0-9]+|critical error|RESOURCE_EXHAUSTED|quota|HTTP error: [45][0-9][0-9]|[45][0-9][0-9] [A-Za-z]+' | head -1))"
    else
        fail "combo $_combo → headless routes to $_routed, which responds"
        if [ -z "$_out" ]; then
            echo "    (empty output — combo didn't launch; sandy multi-agent launch/credential issue)" >&2
        else
            echo "    (no 'alpha' and no recognizable API error; tail: $(echo "$_out" | tail -4 | tr '\n' ' '))" >&2
        fi
    fi

    # The combo must have built/used the sandy-full superset image, not a
    # single-agent one. (Build-on-demand in run_sandy_headless creates it.)
    if docker image inspect sandy-full >/dev/null 2>&1; then
        pass "combo $_combo uses the sandy-full superset image"
    else
        fail "combo $_combo uses the sandy-full superset image"
        echo "    (sandy-full not present after a multi-agent launch — image selection regressed)" >&2
    fi

    resolve_sandbox
else
    skip "multi-agent combo (need 2 of claude/gemini/codex credentials)"
fi

# ============================================================
info "17. Claude auth — OAuth-first suppresses ANTHROPIC_API_KEY when both are set"
# ============================================================
# Billing-correctness invariant: Claude Code resolves ANTHROPIC_API_KEY AHEAD of
# CLAUDE_CODE_OAUTH_TOKEN, so if sandy forwarded both, the API key would silently
# win and bill per-use — bypassing the OAuth/subscription path. With both set,
# sandy must (a) warn, and (b) forward ONLY the token. We exercise the real launch
# path with throwaway fake creds (the agent fails auth, but the forwarding decision
# is made + printed before that) and assert on the runtime warning + the -vvv
# RUN_FLAGS. Source-level structure is guarded by run-tests.sh §52(e).
#
# Needs only a built claude image (no real key) — gated on HAS_CLAUDE like §15b.
if [ "$HAS_CLAUDE" = true ] || docker image inspect sandy-claude-code &>/dev/null; then
    setup_project claude "integ-oauth-first"
    _OF_OUT="$(run_sandy_headless \
        "ANTHROPIC_API_KEY=sk-fake-test-key-do-not-use" \
        "CLAUDE_CODE_OAUTH_TOKEN=fake-oauth-token-do-not-use" \
        -- -vvv -p "noop")"

    # (a) the runtime suppression warning fires (proves the both-set branch ran).
    if echo "$_OF_OUT" | grep -q "not forwarding ANTHROPIC_API_KEY"; then
        pass "both creds set → OAuth-first suppression warning fires at launch"
    else
        fail "both creds set → OAuth-first suppression warning fires at launch"
        echo "    (tail: $(echo "$_OF_OUT" | tail -5 | tr '\n' ' '))" >&2
    fi

    # (b) the actual forwarded env (RUN_FLAGS, printed under -vvv): the OAuth
    # token flag is present, the ANTHROPIC_API_KEY flag is ABSENT ENTIRELY
    # (suppression drops the -e flag, so no ANTHROPIC_API_KEY= line at all).
    # Secret VALUES are redacted in the -vvv dump (they must never land in a
    # pasted trace), so assert on the key name, not the fake value — which is
    # also the definitive "the container won't get the key" check.
    _OF_FLAGS="$(echo "$_OF_OUT" | sed -n '/Docker run flags:/,/^$/p')"
    if echo "$_OF_FLAGS" | grep -q "CLAUDE_CODE_OAUTH_TOKEN=<redacted>" \
       && ! echo "$_OF_FLAGS" | grep -q "ANTHROPIC_API_KEY="; then
        pass "RUN_FLAGS forward the OAuth token but NOT ANTHROPIC_API_KEY"
    else
        fail "RUN_FLAGS forward the OAuth token but NOT ANTHROPIC_API_KEY"
        echo "    (flags seen: $(echo "$_OF_FLAGS" | tr '\n' ' ' | head -c 300))" >&2
    fi
    # And the raw fake secret values must NOT appear anywhere in the -vvv output.
    if echo "$_OF_OUT" | grep -q "fake-oauth-token-do-not-use\|sk-fake-test-key-do-not-use"; then
        fail "secret values redacted from -vvv trace"
        echo "    (a raw fake credential leaked into -vvv output)" >&2
    else
        pass "secret values redacted from -vvv trace"
    fi

    resolve_sandbox
else
    skip "OAuth-first credential suppression (needs the sandy-claude-code image)"
fi

# ============================================================
info "18. Introspection — --print-state full-mode docker-spawn budget (#25)"
# ============================================================
# #25 cut full-mode --print-state's FIXED cost from ~9 spawns to ~3 (ONE
# batched `docker image inspect` for the whole image inventory + one
# `docker ps` + one `docker network ls`). On top of that fixed cost, full mode
# does per-container work that legitimately SCALES with host state:
#   - image_stale (#41): one `docker inspect` per running sandy container,
#   - attached_clients (#17): one `docker exec` per DAEMON container,
#   - orphan_networks (#26): one `docker network inspect` per dead-owner
#     candidate network,
#   plus a few cached `docker image inspect`s for image_stale's refs.
# The old flat "<= 3" budget silently assumed an IDLE host (zero sessions,
# zero orphan networks) — true on clean CI, false on a dev box with live
# daemon sessions, where the real count runs into the dozens. So compute the
# expected ceiling from the ACTUAL host state (a separate, UN-counted
# print-state for the container/daemon counts + a `network ls` for the orphan
# candidate ceiling). This stays a real guard: the #25 regression it exists to
# catch — reverting the image inventory to one `docker image inspect` PER
# image (~6) instead of one batched call — still blows past the +slack on any
# host, idle or busy.
_sc_pstate="$("$SANDY_SCRIPT" --print-state 2>/dev/null || echo '{}')"
_sc_rc_ct="$(printf '%s' "$_sc_pstate" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
rc=d.get("running_containers") or []
print(len(rc))' 2>/dev/null || echo 0)"
_sc_dm_ct="$(printf '%s' "$_sc_pstate" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
rc=d.get("running_containers") or []
print(sum(1 for c in rc if c.get("daemon") is True))' 2>/dev/null || echo 0)"
_sc_net_ct="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cE '^sandy_(sidecar|egress|net)_' || echo 0)"
# 3 fixed + 1 inspect/sandy-container + 1 exec/daemon-container + 1 net-inspect
# per candidate + 6 slack (cached image-ref inspects, candidate-vs-orphan gap).
_sc_budget=$(( 3 + _sc_rc_ct + _sc_dm_ct + _sc_net_ct + 6 ))
_sc_shim="$(mktemp -d)"; _sc_log="$(mktemp)"; TEST_DIRS+=("$_sc_shim")
_sc_real="$(command -v docker)"
cat > "$_sc_shim/docker" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$_sc_log"
exec "$_sc_real" "\$@"
SH
chmod +x "$_sc_shim/docker"
PATH="$_sc_shim:$PATH" "$SANDY_SCRIPT" --print-state >/dev/null 2>&1 || true
_sc_n="$(grep -c . "$_sc_log" 2>/dev/null || echo 99)"
if [ "$_sc_n" -le "$_sc_budget" ]; then
    pass "full --print-state spawns within host-scaled budget [got $_sc_n, budget $_sc_budget: 3 fixed + ${_sc_rc_ct}c + ${_sc_dm_ct}d + ${_sc_net_ct}net + 6]"
else
    fail "full --print-state exceeded host-scaled budget [got $_sc_n, budget $_sc_budget]"
    sed 's/^/      /' "$_sc_log" >&2
fi
rm -f "$_sc_log"

# ============================================================
info "19. Daemon-mode lifecycle acceptance (#17) — test/acceptance-daemon.sh"
# ============================================================
# The daemon lifecycle (start → attach in a real PTY → abrupt kill -9 of the
# client → container/supervisor/agent-process survive → reattach with state
# intact → --stop full teardown) is a real-Docker end-to-end scenario. It lives
# in a standalone harness so it stays independently runnable as the release
# gate; invoked here so a full integration run always covers it. The harness
# self-cleans (its own EXIT trap + scratch workspaces), so it needs nothing
# from this suite's cleanup. SANDY is pinned to this suite's sandy; the harness
# inherits this suite's credential/auto-approve env for its --start.
_acc_daemon="$(dirname "$0")/acceptance-daemon.sh"
if [ -f "$_acc_daemon" ]; then
    _acc_out="$(mktemp)"
    set +e   # a failing harness exits non-zero; don't let set -e abort the suite
    SANDY="$SANDY_SCRIPT" bash "$_acc_daemon" 2>&1 | tee "$_acc_out"
    _acc_rc=${PIPESTATUS[0]}
    set -e
    _acc_res="$(grep -oE 'RESULT: [0-9]+ passed, [0-9]+ failed' "$_acc_out" | tail -1)"
    if [ "$_acc_rc" -eq 0 ]; then
        pass "daemon-mode acceptance (${_acc_res:-all assertions passed})"
    else
        fail "daemon-mode acceptance (${_acc_res:-exited $_acc_rc}) — see harness output above"
    fi
    rm -f "$_acc_out"
else
    skip "daemon-mode acceptance (acceptance-daemon.sh not found)"
fi

# ============================================================
info "20. Fleet-update acceptance (#41) — test/acceptance-update-sessions.sh"
# ============================================================
# Two real daemon sessions → --update-sessions --dry-run (no-op) → forced
# (--rebuild) and organic staleness → scoped rolling restart with new container
# ids + sandy.updated_at labels → image_stale:false after → --stop. Every
# --update-sessions call in the harness is --workspace-scoped, so it only ever
# touches its own scratch sessions — but note the harness's --rebuild step
# rebuilds the SHARED agent image, which will (correctly) mark any OTHER daemon
# sessions on this host as stale afterward; that is inherent to what it tests,
# not a side effect of running it here. Same invocation contract as §19.
_acc_upd="$(dirname "$0")/acceptance-update-sessions.sh"
if [ -f "$_acc_upd" ]; then
    _acc_out="$(mktemp)"
    set +e
    SANDY="$SANDY_SCRIPT" bash "$_acc_upd" 2>&1 | tee "$_acc_out"
    _acc_rc=${PIPESTATUS[0]}
    set -e
    _acc_res="$(grep -oE 'RESULT: [0-9]+ passed, [0-9]+ failed' "$_acc_out" | tail -1)"
    if [ "$_acc_rc" -eq 0 ]; then
        pass "fleet-update acceptance (${_acc_res:-all assertions passed})"
    else
        fail "fleet-update acceptance (${_acc_res:-exited $_acc_rc}) — see harness output above"
    fi
    rm -f "$_acc_out"
else
    skip "fleet-update acceptance (acceptance-update-sessions.sh not found)"
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
