# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`sandy` — Claude's isolated sibling. A self-contained command that runs Claude Code in a Docker sandbox with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
```

Or install locally from a clone:

```sh
LOCAL_INSTALL=./sandy ./install.sh
```

## Usage

```sh
cd ~/my-project
sandy                        # interactive session
sandy -p "your prompt here"  # one-shot prompt
```

No `ANTHROPIC_API_KEY` required if using Claude Max (OAuth) — credentials are seeded from `~/.claude/` on first run.

## Per-project Sandboxes

Each project directory gets its own isolated `~/.claude` sandbox under `~/.sandy/sandboxes/`, named with a mnemonic prefix and hash (e.g. `myproject-a1b2c3d4`). On first run, `.credentials.json` and `settings.json` are seeded from the host's `~/.claude/`.

## Architecture

- **Two-phase Docker build**: A `sandy-base` image contains the OS, toolchains (Node.js 22, Go 1.24, Rust stable, Python 3, C/C++), and system tools. A `sandy-claude-code` image layers Claude Code on top. The base image rebuilds rarely; Claude Code updates rebuild only the thin top layer.
- `sandy` — Self-contained launcher (~820 lines of bash) installed to `~/.local/bin/`. On first run, generates Dockerfile.base, Dockerfile, entrypoint.sh, and tmux.conf in `~/.sandy/`, builds both Docker images, creates per-project sandbox directories, applies network isolation, and launches the container via `docker run`.
- `install.sh` — `curl | bash` installer that downloads `sandy` to `~/.local/bin/` and checks PATH setup.

## Auto-update

On each launch, sandy checks for newer Claude Code versions by comparing the installed version against the latest release. If an update is available, the image is rebuilt with `--no-cache`. Inside the container, `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates against the read-only filesystem.

## Git Submodule Support

When launched from a git submodule, sandy detects the `.git` file (vs directory), resolves the relative gitdir path, and mounts both the worktree and gitdir at the correct container paths to preserve the relative path relationship. The workspace path is passed via the `SANDY_WORKSPACE` environment variable.

## SSH Agent Relay

Two modes controlled by `SANDY_SSH`:
- `token` (default) — uses `gh auth token` for HTTPS-based git auth
- `agent` — forwards the host SSH agent into the container
  - **Linux**: direct socket mount
  - **macOS**: host-side TCP relay via `socat` (preferred) or `python3` fallback; in-container relay via `socat`

## Network Isolation Details

Per-instance Docker bridge networks are created with names keyed on PID (`sandy_net_$$`) to avoid races between concurrent sessions. On Linux, iptables DROP rules block RFC 1918 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and CGNAT/Tailscale (`100.64.0.0/10`), while allowing the container's own subnet. On macOS, Docker Desktop's VM provides LAN isolation by default. Rules are cleaned up on script exit.
