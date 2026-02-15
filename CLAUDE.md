# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`sandy` — Claude's isolated sibling. A self-contained command that runs Claude Code in a Docker sandbox with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | sh
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

Each project directory gets its own isolated `~/.claude` sandbox under `~/.sandy/sandboxes/`, derived from the working directory path (e.g. `/Users/drapp/dev/myproject` → `~/.sandy/sandboxes/Users_drapp_dev_myproject/`). On first run, `.credentials.json` and `settings.json` are seeded from the host's `~/.claude/`.

## Architecture

- `sandy` — Self-contained launcher script installed to `~/.local/bin/`. On first run, generates Dockerfile, entrypoint.sh, and tmux.conf in `~/.sandy/`, builds the Docker image, creates per-project sandbox directories, applies network isolation, and launches the container via `docker run`.
- `install.sh` — `curl | sh` installer that downloads `sandy` to `~/.local/bin/` and checks PATH setup.

## Network Isolation Details

The bridge network `br-claude` (subnet `172.30.0.0/24`) is created via `docker network create`. On Linux, iptables DROP rules block RFC 1918 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and CGNAT/Tailscale (`100.64.0.0/10`), while allowing the container's own subnet. On macOS, Docker Desktop's VM provides LAN isolation by default. Rules are cleaned up on script exit. Stale rules from previous unclean exits are cleaned up on startup.
