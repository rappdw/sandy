## sandy v0.1.0

Run Claude Code in a Docker sandbox — so the power stays, but the blast radius shrinks.

### Features

- **One-command install** — `curl -fsSL ... | sh` or install from a local clone
- **Filesystem isolation** — read/write limited to the mounted working directory only
- **Network isolation** — public internet access only; all LAN/private networks are blocked
  - Linux: automatic `iptables` rules block RFC 1918, link-local, and CGNAT/Tailscale ranges
  - macOS: Docker Desktop VM provides LAN isolation by default
  - IPv6 disabled on container networks to prevent bypass of IPv4 iptables rules
  - Per-instance Docker networks keyed on PID — concurrent sandy sessions get independent networks and iptables rulesets with no race conditions
  - **Fail-closed**: if iptables rules cannot be applied on Linux, sandy refuses to start (override with `SANDY_ALLOW_NO_ISOLATION=1`)
- **Resource limits** — CPU and memory caps auto-detected from host
- **Security hardening** — non-root user, read-only root filesystem, `no-new-privileges`
  - SSH agent socket uses restrictive `0600` permissions (owner-only) instead of world-accessible
  - Claude Code's `--dangerously-skip-permissions` is now configurable via `SANDY_SKIP_PERMISSIONS` (default: `true`; set to `false` to keep the permission system active)
  - `SANDY_HOME` validated against shell metacharacters to prevent injection
- **Per-project sandboxes** — each working directory gets its own isolated `~/.claude` under `~/.sandy/sandboxes/`, with mnemonic names (e.g. `myproject-a1b2c3d4`)
- **Ephemeral credential loading** — OAuth/API credentials are read fresh from the host each launch (never persisted in the sandbox)
- **macOS Keychain support** — credentials are extracted from the Keychain when no `.credentials.json` file exists
- **macOS SSH relay validation** — relay startup failures are detected and reported instead of silently passing broken config to the container
- **Model selection** — defaults to `claude-opus-4-6`, configurable via `SANDY_MODEL`
- **tmux integration** — sessions run inside tmux with agent teams support enabled
- **Robust cleanup** — trap covers `EXIT`, `INT`, `TERM`, and `HUP` signals; cleanup failures are logged
- **`--help` flag** — usage, environment variable, and flags documentation
- **`--version` flag** — prints `sandy <version>`
- **`--rebuild` flag** — force rebuild of the sandbox Docker image without manually deleting cache files

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SANDY_MODEL` | `claude-opus-4-6` | Model to use |
| `ANTHROPIC_API_KEY` | — | API key (not needed with Claude Max / OAuth) |
| `SANDY_HOME` | `~/.sandy` | Sandy config directory |
| `SANDY_SSH` | `token` | Git SSH method: `token` (gh CLI HTTPS) or `agent` (SSH agent forwarding) |
| `SANDY_SKIP_PERMISSIONS` | `true` | Set to `false` to keep Claude Code's permission system active |
| `SANDY_ALLOW_NO_ISOLATION` | — | Set to `1` to allow launch when iptables rules cannot be applied (Linux only) |

### Files

| File | Purpose |
|---|---|
| `sandy` | Self-contained launcher (~560 lines of bash) |
| `install.sh` | `curl \| sh` installer |

### Requirements

- Docker
- No `ANTHROPIC_API_KEY` needed if using Claude Max (OAuth)
