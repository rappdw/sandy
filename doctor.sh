#!/usr/bin/env bash
# =============================================================================
# sandy doctor — check that the host has everything sandy needs.
#
# Usage:
#   bash doctor.sh                                         # from a clone
#   curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/doctor.sh | bash
#
# Exits 0 if all required checks pass, 1 otherwise. Recommended misses are
# warnings and never block. No sudo, no installs — advice only.
# =============================================================================

# Intentionally no `set -e -u`: we want every check to run to completion,
# and bash 3.2 (macOS default) + `set -u` + empty arrays is a trap.

# ---- colors ----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

# ---- state ----
REQUIRED_FAILS=0
RECOMMENDED_FAILS=0
HINTS=()

ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
fail()    { printf "  ${RED}✗${RESET} %s\n" "$1"; REQUIRED_FAILS=$((REQUIRED_FAILS+1)); [ -n "${2:-}" ] && HINTS+=("$2"); }
warn()    { printf "  ${YELLOW}!${RESET} %s\n" "$1"; RECOMMENDED_FAILS=$((RECOMMENDED_FAILS+1)); [ -n "${2:-}" ] && HINTS+=("$2"); }
section() { printf "\n${BOLD}%s${RESET}\n" "$1"; }

# ---- platform detection ----
case "$(uname -s 2>/dev/null)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      OS=unknown ;;
esac

DISTRO=unknown
if [ "$OS" = "linux" ] && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"
fi
ARCH="$(uname -m 2>/dev/null || echo unknown)"

# Platform-aware package install hint (single-package form).
pkg_hint() {
    local pkg="$1"
    case "$OS" in
        macos)
            if command -v brew >/dev/null 2>&1; then
                echo "brew install $pkg"
            else
                echo "Install Homebrew from https://brew.sh, then: brew install $pkg"
            fi
            ;;
        linux)
            case "$DISTRO" in
                debian|ubuntu|raspbian|pop|linuxmint) echo "sudo apt update && sudo apt install -y $pkg" ;;
                fedora|rhel|centos|rocky|almalinux)   echo "sudo dnf install -y $pkg" ;;
                arch|manjaro|endeavouros)             echo "sudo pacman -S --needed $pkg" ;;
                alpine)                               echo "sudo apk add $pkg" ;;
                opensuse*|sles)                       echo "sudo zypper install -y $pkg" ;;
                *)                                    echo "Install $pkg via your distro's package manager" ;;
            esac
            ;;
        *) echo "Install $pkg for your platform" ;;
    esac
}

# ---- banner ----
printf "${BOLD}sandy doctor${RESET}  —  host readiness check\n"
printf "  platform: %s" "$OS"
[ "$OS" = "linux" ] && printf " (%s)" "$DISTRO"
printf " / %s\n" "$ARCH"

# ---- required ----
section "Required"

# bash (we're already in it — just report)
ok "bash ${BASH_VERSION%%(*}"

# git
if command -v git >/dev/null 2>&1; then
    ok "git $(git --version 2>/dev/null | awk '{print $3}')"
else
    fail "git not found" "$(pkg_hint git)"
fi

# curl (used by install.sh and sandy's update check)
if command -v curl >/dev/null 2>&1; then
    ok "curl"
else
    fail "curl not found" "$(pkg_hint curl)"
fi

# docker runtime — must have the CLI AND a reachable daemon
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        _dver="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
        [ -z "$_dver" ] && _dver="unknown"
        ok "docker daemon reachable (server $_dver)"
    else
        fail "docker CLI found but 'docker info' failed — daemon not running?" \
             "Start your Docker runtime:
    - Rancher Desktop / Docker Desktop / OrbStack: open the app
    - Colima: colima start
    - Linux native: sudo systemctl start docker"
    fi
else
    case "$OS" in
        macos)
            fail "docker not found" \
                 "Install any Docker-compatible runtime (sandy works with all of these):
    - Rancher Desktop: https://rancherdesktop.io/    (free, open source)
    - OrbStack:        https://orbstack.dev/         (fast, macOS-native)
    - Colima:          brew install colima docker && colima start
    - Docker Desktop:  https://www.docker.com/products/docker-desktop/"
            ;;
        linux)
            fail "docker not found" \
                 "Install Docker Engine following the official guide for your distro:
    https://docs.docker.com/engine/install/
After install, add yourself to the docker group and re-login:
    sudo usermod -aG docker \$USER"
            ;;
        *)
            fail "docker not found" "Install a Docker-compatible runtime for your platform"
            ;;
    esac
fi

# ---- path ----
section "PATH"
case ":$PATH:" in
    *":$HOME/.local/bin:"*)
        ok "\$HOME/.local/bin is on PATH" ;;
    *)
        _shell="$(basename "${SHELL:-/bin/bash}")"
        case "$_shell" in
            zsh)  _rc="~/.zshrc" ;;
            bash) _rc="~/.bashrc (Linux) or ~/.bash_profile (macOS)" ;;
            fish) _rc="fish" ;;
            *)    _rc="your shell rc" ;;
        esac
        if [ "$_shell" = "fish" ]; then
            warn "\$HOME/.local/bin not on PATH (sandy installs here)" \
                 "Add to PATH (fish):
    fish_add_path \$HOME/.local/bin"
        else
            warn "\$HOME/.local/bin not on PATH (sandy installs here)" \
                 "Add to $_rc:
    export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
        ;;
esac

# ---- recommended ----
section "Recommended"

# gh CLI — default SANDY_SSH=token mode uses 'gh auth token' as the git credential helper
if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        ok "gh CLI authenticated (SANDY_SSH=token mode ready)"
    else
        warn "gh CLI installed but not authenticated" \
             "Sign in so sandy can use it as a git credential helper:
    gh auth login"
    fi
else
    warn "gh CLI not found (needed for default SANDY_SSH=token mode)" \
         "$(pkg_hint gh)
Then: gh auth login"
fi

# node or jq — sandy uses one of them to merge settings.json; falls back to printf-defaults otherwise
if command -v node >/dev/null 2>&1; then
    ok "node $(node --version 2>/dev/null) (used for settings.json merge)"
elif command -v jq >/dev/null 2>&1; then
    ok "jq (used as fallback for settings.json merge)"
else
    warn "neither node nor jq found (sandy will fall back to printf defaults for settings.json)" \
         "Install either one:
    $(pkg_hint node)
  or
    $(pkg_hint jq)"
fi

# socat (macOS only, for SANDY_SSH=agent mode)
if [ "$OS" = "macos" ]; then
    if command -v socat >/dev/null 2>&1; then
        ok "socat (for SANDY_SSH=agent mode on macOS)"
    else
        warn "socat not found (only needed if you want SANDY_SSH=agent on macOS)" \
             "$(pkg_hint socat)"
    fi
fi

# ---- credentials ----
section "Credentials (at least one is needed for Claude Code)"

_found_creds=0
if [ -f "$HOME/.claude/.credentials.json" ]; then
    ok "~/.claude/.credentials.json present (Claude Pro/Max OAuth — seeded fresh each launch)"
    _found_creds=1
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "ANTHROPIC_API_KEY is set in the environment"
    _found_creds=1
fi
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    ok "CLAUDE_CODE_OAUTH_TOKEN is set in the environment"
    _found_creds=1
fi
if [ -f "$HOME/.sandy/.secrets" ] && grep -qE '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=' "$HOME/.sandy/.secrets" 2>/dev/null; then
    ok "~/.sandy/.secrets contains a Claude credential"
    _found_creds=1
fi
if [ "$_found_creds" -eq 0 ]; then
    warn "No Claude credentials detected" \
         "Pick one:
    Claude Pro/Max (recommended — no key management):
        Install Claude Code on the host once, sign in, then run sandy.
        https://claude.ai/code
    Long-lived OAuth token (recommended for headless servers):
        claude setup-token            # on a machine with a browser
        Add to ~/.sandy/.secrets:  CLAUDE_CODE_OAUTH_TOKEN=sk-ant-...
    API key:
        export ANTHROPIC_API_KEY=sk-ant-..."
fi

# ---- sandy install status (informational) ----
section "Sandy"
if command -v sandy >/dev/null 2>&1; then
    _sver="$(sandy --version 2>/dev/null | head -1)"
    [ -z "$_sver" ] && _sver="(version unavailable)"
    ok "sandy installed at $(command -v sandy) — $_sver"
else
    warn "sandy is not installed yet" \
         "Install once the required checks are green:
    curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash"
fi

# ---- summary ----
section "Summary"
if [ "$REQUIRED_FAILS" -eq 0 ]; then
    printf "  ${GREEN}%s${RESET}\n" "All required checks passed."
    if [ "$RECOMMENDED_FAILS" -gt 0 ]; then
        printf "  ${YELLOW}%d recommended item(s) to address.${RESET}\n" "$RECOMMENDED_FAILS"
    fi
else
    printf "  ${RED}%d required check(s) failed.${RESET}" "$REQUIRED_FAILS"
    if [ "$RECOMMENDED_FAILS" -gt 0 ]; then
        printf " ${YELLOW}%d recommended.${RESET}" "$RECOMMENDED_FAILS"
    fi
    printf "\n"
fi

if [ "${#HINTS[@]}" -gt 0 ]; then
    if [ "$REQUIRED_FAILS" -gt 0 ]; then
        printf "\n${BOLD}Fix these first:${RESET}\n"
    else
        printf "\n${BOLD}Suggested actions:${RESET}\n"
    fi
    for h in "${HINTS[@]}"; do
        printf "\n%s\n" "$h"
    done
fi

if [ "$REQUIRED_FAILS" -eq 0 ] && ! command -v sandy >/dev/null 2>&1; then
    printf "\n${BLUE}Next:${RESET} install sandy\n"
    printf "    curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash\n"
fi

printf "\n"
[ "$REQUIRED_FAILS" -eq 0 ] && exit 0 || exit 1
