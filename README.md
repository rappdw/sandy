[![License: MIT](https://img.shields.io/github/license/rappdw/sandy)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/rappdw/sandy)](https://github.com/rappdw/sandy/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()

# sandy — Claude's isolated sibling

Run Claude Code with `--dangerously-skip-permissions` in a Docker container with proper isolation:

- **Filesystem**: Read/write access limited to the mounted working directory only
- **Network**: Public internet access only — all LAN/private networks are blocked
- **Resources**: Capped CPU and memory (auto-detected from host)
- **Security**: Non-root user, read-only root filesystem, no privilege escalation
- **Per-project sandboxes**: Isolated `~/.claude` per working directory

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
```

Or install locally from a clone:

```bash
LOCAL_INSTALL=./sandy ./install.sh
```

## Quick Start

```bash
# cd into whatever project you want Claude to work on
cd /path/to/your/project

# Start an interactive session
sandy

# Or run with a one-shot prompt
sandy -p "Review the code in src/ for security issues"
```

No `ANTHROPIC_API_KEY` required if using Claude paid account (Pro/Max) (OAuth) — credentials are seeded from docker host (if present) on first run.

## Configuration

### Model selection

```bash
SANDY_MODEL=claude-sonnet-4-5-20250929 sandy
```

Defaults to `claude-opus-4-6` if not set.

### API key (non-OAuth)

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
sandy
```

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

## Development Environments

Sandy's base image includes Python 3, Node.js 22, Go 1.24, Rust stable, C/C++ (build-essential), and [`uv`](https://docs.astral.sh/uv/) for Python version management.

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

USER root
RUN apt-get update && apt-get install -y typst && rm -rf /var/lib/apt/lists/*
RUN curl -LO https://github.com/quarto-dev/quarto-cli/releases/download/v1.7.29/quarto-1.7.29-linux-amd64.deb \
    && dpkg -i quarto-*.deb && rm quarto-*.deb
USER claude
```

Sandy detects this file and builds a project-specific image layered on top of the standard sandy image. The project image:

- Rebuilds automatically when the Dockerfile changes or the base sandy image updates
- Is cached per-project (tagged as `sandy-project-<name>-<hash>`)
- Uses the `.sandy/` directory as build context, so you can `COPY` files from there

This is the right approach for system packages (`apt-get`), large binary tools, or anything that needs root to install.

### Automatic environment detection

Sandy checks your project on startup and handles common issues:

- **`.python-version`** — if present, sandy auto-installs that Python version via `uv` (persists across sessions)
- **Broken `.venv`** — if `.venv/bin/python` is a dead symlink (host Python version differs from container), sandy warns with the fix command
- **Foreign native modules** — if `node_modules/` contains native addons compiled for a different platform (e.g. macOS), sandy warns with `npm rebuild` as the fix

These checks run on every session start and add negligible overhead.

## Security Notes

- The container runs as a non-root user (`claude`, UID 1001)
- The root filesystem is read-only (`/tmp` and `/home/claude` are tmpfs)
- `no-new-privileges` prevents privilege escalation
- Credentials are seeded into per-project sandboxes, not shared across projects
- The working directory is bind-mounted read/write — Claude can modify your files there (that's the point)