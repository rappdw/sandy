#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sandy installer
#
# Usage: curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
# =============================================================================

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SANDY_URL="${SANDY_URL:-https://raw.githubusercontent.com/rappdw/sandy/main/sandy}"

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
    warn "Node.js is not installed. sandy requires Node.js for setup and SSH agent relay."
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
if [ -n "${LOCAL_INSTALL:-}" ] && [ -f "$LOCAL_INSTALL" ]; then
    info "Installing sandy from local file: $LOCAL_INSTALL"
    cp "$LOCAL_INSTALL" "$INSTALL_DIR/sandy"
else
    info "Downloading sandy..."
    if command -v curl &>/dev/null; then
        curl -fsSL "$SANDY_URL" -o "$INSTALL_DIR/sandy"
    elif command -v wget &>/dev/null; then
        wget -qO "$INSTALL_DIR/sandy" "$SANDY_URL"
    else
        error "Neither curl nor wget found. Cannot download sandy."
        exit 1
    fi
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
