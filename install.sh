#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sandy installer
#
# Usage: curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
#
# Installs the latest RELEASE. SANDY_CHANNEL=dev installs the head of main
# instead, pinned to its commit and recording it. SANDY_URL=<url> downloads
# exactly that file. LOCAL_INSTALL=./sandy installs a local copy.
# =============================================================================

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SANDY_URL="${SANDY_URL:-}"
SANDY_CHANNEL="${SANDY_CHANNEL:-release}"
SANDY_REPO_RAW="https://raw.githubusercontent.com/rappdw/sandy"
SANDY_API_URL="https://api.github.com/repos/rappdw/sandy/releases/latest"
SANDY_API_MAIN_URL="https://api.github.com/repos/rappdw/sandy/commits/main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[sandy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[sandy]${NC} $*"; }
error() { echo -e "${RED}[sandy]${NC} $*" >&2; }

# --- Check prerequisites ---
if ! command -v docker &>/dev/null; then
    warn "Docker is not installed. sandy requires Docker to run."
    warn "  Install: https://docs.docker.com/get-docker/"
fi

if ! command -v node &>/dev/null; then
    warn "Node.js is not installed. sandy uses Node.js for JSON config merging (optional)."
    warn "  Install: https://nodejs.org/"
fi

if ! command -v gh &>/dev/null; then
    warn "GitHub CLI (gh) is not installed. Required for default git auth (SANDY_SSH=token)."
    warn "  Install: https://cli.github.com"
    warn "  Then run: gh auth login"
elif ! gh auth token &>/dev/null; then
    warn "GitHub CLI is installed but not authenticated. Run: gh auth login"
fi

# --- Create install dir if needed ---
mkdir -p "$INSTALL_DIR"

# --- Download or copy sandy ---
# Record a commit in the installed script, so --version and --print-version
# tell builds of one -dev version apart. Rewrites through a temp file rather
# than `sed -i`, whose argument differs between BSD and GNU sed.
bake_commit() {
    sed "s/^SANDY_COMMIT=\"\"/SANDY_COMMIT=\"$1\"/" "$INSTALL_DIR/sandy" > "$INSTALL_DIR/sandy.tmp.$$" \
        && mv "$INSTALL_DIR/sandy.tmp.$$" "$INSTALL_DIR/sandy"
}
# fetch URL [HEADER] -> body on stdout, nonzero on failure.
fetch() {
    if command -v curl &>/dev/null; then
        if [ -n "${2:-}" ]; then curl -fsSL --max-time 20 -H "$2" "$1"; else curl -fsSL --max-time 20 "$1"; fi
    elif command -v wget &>/dev/null; then
        if [ -n "${2:-}" ]; then wget -qO- --timeout=20 --header="$2" "$1"; else wget -qO- --timeout=20 "$1"; fi
    else
        error "Neither curl nor wget found. Cannot download sandy."
        exit 1
    fi
}

if [ -n "${LOCAL_INSTALL:-}" ] && [ -f "$LOCAL_INSTALL" ]; then
    info "Installing sandy from local file: $LOCAL_INSTALL"
    cp "$LOCAL_INSTALL" "$INSTALL_DIR/sandy"
    # Bake in git commit hash if installing from a repo checkout
    local_dir="$(cd "$(dirname "$LOCAL_INSTALL")" && pwd)"
    commit_hash="$(git -C "$local_dir" rev-parse --short HEAD 2>/dev/null)" || true
    if [ -n "$commit_hash" ]; then
        bake_commit "$commit_hash"
    fi
else
    tag=""; sha=""
    if [ -n "$SANDY_URL" ]; then
        url="$SANDY_URL"
        info "Downloading sandy from $url..."
    elif [ "$SANDY_CHANNEL" = dev ]; then
        sha="$(fetch "$SANDY_API_MAIN_URL" "Accept: application/vnd.github.sha" 2>/dev/null)" || sha=""
        sha_re='^[0-9a-f]{40}$'
        if ! [[ $sha =~ $sha_re ]]; then
            error "Could not look up main's latest commit (GitHub API unreachable or rate-limited). Retry later."
            exit 1
        fi
        url="$SANDY_REPO_RAW/$sha/sandy"
        info "Downloading sandy from main (${sha:0:7})..."
    elif [ "$SANDY_CHANNEL" = release ]; then
        # GitHub pretty-prints this response ("tag_name": "v2.7.1"); match it
        # in bash rather than through a pipe a quitting grep would close.
        body="$(fetch "$SANDY_API_URL" 2>/dev/null)" || body=""
        tag_re='"tag_name"[[:space:]]*:[[:space:]]*"(v[0-9]+\.[0-9]+\.[0-9]+)"'
        if [[ $body =~ $tag_re ]]; then tag="${BASH_REMATCH[1]}"; fi
        if [ -z "$tag" ]; then
            error "Could not find the latest sandy release (GitHub API unreachable or rate-limited)."
            error "  Retry later, or install main with SANDY_CHANNEL=dev, or a file with SANDY_URL=<url>."
            exit 1
        fi
        url="$SANDY_REPO_RAW/$tag/sandy"
        info "Downloading sandy $tag..."
    else
        error "SANDY_CHANNEL must be 'release' or 'dev' (got: $SANDY_CHANNEL)."
        exit 1
    fi
    if ! fetch "$url" > "$INSTALL_DIR/sandy.tmp.$$"; then
        rm -f "$INSTALL_DIR/sandy.tmp.$$"
        error "Failed to download $url."
        exit 1
    fi
    new_ver="$(grep -m1 '^SANDY_VERSION=' "$INSTALL_DIR/sandy.tmp.$$" | cut -d'"' -f2)" || new_ver=""
    if [ -z "$new_ver" ] || { [ -n "$tag" ] && [ "$new_ver" != "${tag#v}" ]; }; then
        rm -f "$INSTALL_DIR/sandy.tmp.$$"
        error "The downloaded file does not look like sandy ${tag:-} (SANDY_VERSION=${new_ver:-none})."
        exit 1
    fi
    mv "$INSTALL_DIR/sandy.tmp.$$" "$INSTALL_DIR/sandy"
    if [ -n "$sha" ]; then bake_commit "${sha:0:7}"; fi
fi

chmod +x "$INSTALL_DIR/sandy"
info "Installed sandy to $INSTALL_DIR/sandy"

# --- Check PATH ---
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    warn ""
    warn "$INSTALL_DIR is not in your PATH. Add it with:"
    warn ""
    SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
    case "$SHELL_NAME" in
        zsh)  warn "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
        bash) warn "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
        fish) warn "  fish_add_path $INSTALL_DIR" ;;
        *)    warn "  export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
    esac
    warn ""
fi

echo ""
info "Done! Run 'sandy' from any project directory to start Claude in a sandbox."
info ""
info "  cd ~/my-project"
info "  sandy"
info "  sandy -p \"your prompt here\""
