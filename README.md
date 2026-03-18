[![License: MIT](https://img.shields.io/github/license/rappdw/sandy)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/rappdw/sandy)](https://github.com/rappdw/sandy/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()

# sandy — Claude's isolated sibling

Sandy was born from building [Proofpoint Satori](https://www.proofpoint.com/us/products/satori) — a platform that deploys AI agents to scale security operations. When you're giving AI agents real autonomy to write code, run tests, and modify systems, the environment needs OS-enforced boundaries, not permission prompts. Sandy is the tool we built to make that work.

Install it, run it. That's it.

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
cd /path/to/your/project
sandy
```

Sandy runs Claude Code in a Docker container with `--dangerously-skip-permissions` — so Claude works without interruption while your system stays protected:

- **Filesystem**: Read/write limited to the mounted working directory only
- **Network**: Public internet only — all LAN/private networks blocked
- **Resources**: Capped CPU and memory (auto-detected from host)
- **Security**: Non-root user, read-only root filesystem, no privilege escalation
- **Protected files**: Shell configs, git hooks, and Claude commands mounted read-only
- **Per-project sandboxes**: Isolated `~/.claude`, credentials, and package storage per project
- **Dev environments**: Python, Node.js, Go, Rust, and C/C++ with persistent package installs
- **Terminal notifications**: OSC passthrough enabled — works with [cmux](https://www.cmux.dev/), iTerm2, and other notification-aware terminals

No `ANTHROPIC_API_KEY` required if using a Claude paid account (Pro/Max) — credentials are seeded from the host on first run.

## Prerequisites

Sandy works with any Docker-compatible runtime:

- [Rancher Desktop](https://rancherdesktop.io/)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Colima](https://github.com/abiosoft/colima)
- [Lima](https://github.com/lima-vm/lima)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
```

Or install locally from a clone:

```bash
LOCAL_INSTALL=./sandy ./install.sh
```

## Usage

```bash
cd /path/to/your/project
sandy                                              # interactive session
sandy -p "Review the code in src/ for security issues"  # one-shot prompt
sandy --remote                                     # remote-control server mode
```

## Configuration

### Per-project config (`.sandy/config`)

Create a `.sandy/config` file in any project to set defaults for that project:

```bash
# .sandy/config — sourced on every sandy launch in this directory
SANDY_SSH=agent                          # use SSH agent instead of gh token
SANDY_MODEL=claude-sonnet-4-5-20250929   # override default model
SANDY_SKIP_PERMISSIONS=false             # keep Claude's permission prompts
```

Any environment variable can go here. It's sourced as a bash script before anything else runs.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SANDY_MODEL` | `claude-opus-4-6` | Claude model to use |
| `SANDY_SSH` | `token` | Git auth method: `token` (gh CLI + HTTPS) or `agent` (SSH agent forwarding) |
| `SANDY_SKIP_PERMISSIONS` | `true` | Set to `false` to keep Claude Code's permission system active |
| `SANDY_HOME` | `~/.sandy` | Sandy config/build/sandbox directory |
| `SANDY_ALLOW_NO_ISOLATION` | (unset) | Set to `1` to allow launch without iptables rules (Linux) |
| `ANTHROPIC_API_KEY` | (unset) | API key — not needed with Claude Pro/Max (OAuth) |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | Max output tokens per response (Claude Code default is 32K) |

### Flags

| Flag | Description |
|---|---|
| `--new` | Start a fresh session (default: resume last) |
| `--resume` | Open session picker |
| `--remote` | Start in [remote-control](https://code.claude.com/docs/en/remote-control) server mode (connect from browser/phone) |
| `--rebuild` | Force rebuild of the Docker image |
| `--build-only` | Build images and exit (for CI) |
| `-p "prompt"` | One-shot prompt (no interactive session) |

All other arguments are forwarded to `claude`.

## How Network Isolation Works

### macOS (Docker Desktop)
Docker Desktop runs containers inside a lightweight Linux VM. Containers **cannot directly access your Mac's LAN** by default — they can only reach the internet through Docker's NAT. This gives you LAN isolation out of the box.

### Linux
Sandy automatically inserts `iptables` rules into the `DOCKER-USER` chain that block all RFC 1918 traffic from the container's bridge interface:

| Range | What it blocks |
|---|---|
| `10.0.0.0/8` | Home/office LAN, VPNs |
| `172.16.0.0/12` | Docker internals, some LANs |
| `192.168.0.0/16` | Home/office LAN |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT, Tailscale |

Rules are automatically cleaned up when sandy exits. Stale rules from a previous unclean exit are cleaned up on startup. If `iptables` is not accessible, sandy warns that LAN isolation is not active.

## Verifying Isolation

From inside the container, you can verify:

```bash
# Should FAIL — LAN is blocked
curl -m 5 http://192.168.1.1

# Should SUCCEED — public internet works
curl -m 5 https://api.anthropic.com
```

## What's in the Box

Sandy's base image is a self-contained development environment. Everything below is pre-installed and ready to use — no setup required.

### Language toolchains

| Toolchain | Version | Notes |
|---|---|---|
| Python 3 | Debian bookworm default | System Python; use `uv` for other versions |
| Node.js | 22 LTS | Via NodeSource |
| Go | 1.24 | |
| Rust | stable | Via rustup |
| C/C++ | build-essential | gcc, g++, make, libc-dev |

### System tools

| Tool | Purpose |
|---|---|
| `git` | Version control |
| `git-lfs` | Large file storage (auto-detected, auto-configured) |
| `gh` | GitHub CLI — PRs, issues, releases |
| `jq` | JSON processor |
| `ripgrep` (`rg`) | Fast code search |
| `curl` | HTTP client |
| `cmake` | Build system |
| `pkg-config` | Build helper |
| `socat` | Socket relay (SSH agent forwarding) |
| `tmux` | Terminal multiplexer (sandy's session wrapper) |
| `less` | Pager |
| `openssh-client` | SSH client |

### Python tools

| Tool | Purpose |
|---|---|
| `uv` | Fast Python version & package manager |
| `pip` / `pip3` | Package installer (auto `--user` outside venvs) |
| `python3-venv` | Virtual environment support |

### Libraries

| Library | Purpose |
|---|---|
| `libcairo2` | 2D graphics / PDF rendering |
| `libpango1.0-0` | Text layout / PDF rendering |
| `libgdk-pixbuf-2.0-0` | Image loading / PDF rendering |
| `libssl-dev` | TLS development headers |
| `ncurses-term` | Terminal definitions |

### Plugin marketplace

The [sandy-plugins](https://github.com/rappdw/sandy-plugins) marketplace is pre-configured in every sandbox. Browse and install plugins with:

```
/plugin                                    # browse available plugins
/plugin install synthkit@sandy-plugins     # install a plugin
/plugin update                             # update installed plugins
```

Available plugins:

| Plugin | Description |
|---|---|
| [synthkit](https://github.com/rappdw/synthkit) | Document synthesis — guided exploration, markdown to PDF/DOCX/HTML/email |

### Persistent packages

Packages installed inside sandy persist across sessions per project. Each project sandbox has dedicated bind-mounted directories for each package manager:

```bash
pip install flask          # persists in sandbox pip/ dir
npm install -g typescript  # persists in sandbox npm-global/ dir
go install golang.org/x/tools/gopls@latest  # persists in sandbox go/ dir
cargo install ripgrep      # persists in sandbox cargo/ dir
```

These are per-project — packages installed in one project don't leak to another.

### Python version management

The base image ships one system Python (Debian bookworm's default). If your project needs a specific version, use `uv`:

```bash
uv python install 3.11        # downloads once, persists across sessions
uv venv --python 3.11         # creates .venv in project dir
source .venv/bin/activate
uv pip install -r requirements.txt
```

Different projects can use different Python versions with the same sandy image — each project's sandbox stores its own `uv`-managed Python installations.

### Using host virtual environments and build artifacts

Your project directory is bind-mounted read-write, so `.venv/`, `node_modules/`, `target/`, and other build directories from the host are visible inside the container:

- **Python `.venv/`** — works if host and container have the same Python version at the same path (e.g. both have `/usr/bin/python3.12`). If versions differ, the venv's symlinks will be broken. Fix: `uv venv --python 3.12 && uv pip install -r requirements.txt`
- **Node.js `node_modules/`** — pure JS packages work fine. Native addons compiled on the host work if the host is also Linux with compatible glibc. Fix: `npm rebuild`
- **Rust `target/`** — reusable if both sides are Linux x86_64. macOS host → Linux container triggers a full rebuild automatically
- **Go `vendor/`** — pure source, always works

### Per-project tooling (`.sandy/Dockerfile`)

If your project needs system tools beyond the base image, create a `.sandy/Dockerfile` in your project directory:

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# No USER directive needed — entrypoint handles privilege dropping
RUN curl -LsSf https://github.com/typst/typst/releases/latest/download/typst-x86_64-unknown-linux-musl.tar.xz \
    | tar -xJ --strip-components=1 -C /usr/local/bin
ARG QUARTO_VERSION=1.8.27
RUN curl -fL "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /opt \
    && ln -s /opt/quarto-${QUARTO_VERSION}/bin/quarto /usr/local/bin/quarto
```

Sandy detects this file and builds a project-specific image layered on top of the standard sandy image. The project image:

- Rebuilds automatically when the Dockerfile changes or the base sandy image updates
- Is cached per-project (tagged as `sandy-project-<name>-<hash>`)
- Uses the `.sandy/` directory as build context, so you can `COPY` files from there

This is the right approach for system packages (`apt-get`), large binary tools, or anything that needs root to install. See [`examples/`](examples/) for ready-to-use configurations.

### Automatic environment detection

Sandy checks your project on startup and handles common issues:

- **`.python-version`** — if present, sandy auto-installs that Python version via `uv` (persists across sessions)
- **Broken `.venv`** — if `.venv/bin/python` is a dead symlink (host Python version differs from container), sandy warns with the fix command
- **Foreign native modules** — if `node_modules/` contains native addons compiled for a different platform (e.g. macOS), sandy warns with `npm rebuild` as the fix

These checks run on every session start and add negligible overhead.

## Terminal Notifications

Sandy passes through OSC escape sequences (9/99/777) from Claude Code to the outer terminal. This enables notification features in terminals like [cmux](https://www.cmux.dev/) and iTerm2 — pane rings, desktop alerts, and badges when Claude needs attention.

**cmux auto-setup**: When sandy detects it's running inside cmux (via the `CMUX_WORKSPACE_ID` environment variable), it automatically installs a notification hook that emits OSC 777 sequences on Claude Code events. No manual configuration needed — just run `sandy` in a cmux pane.

**Custom hooks**: If you have Claude Code hooks configured on the host (`~/.claude/hooks/`), sandy mounts them read-only into the container automatically. Host hooks take precedence over auto-setup (cmux auto-setup is skipped if `~/.claude/hooks/` exists on the host).

## Security Notes

- The container runs as a non-root user (`claude`, UID 1001)
- The root filesystem is read-only (`/tmp` and `/home/claude` are tmpfs)
- `no-new-privileges` prevents privilege escalation
- Credentials are seeded into per-project sandboxes, not shared across projects
- The working directory is bind-mounted read/write — Claude can modify your files there (that's the point)
- **Protected files**: Shell configs (`.bashrc`, `.zshrc`, etc.), `.git/hooks/`, `.claude/commands/`, `.claude/agents/`, `.vscode/`, and `.idea/` are mounted read-only to prevent config injection and hook tampering