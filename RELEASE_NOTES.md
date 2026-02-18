## sandy v0.2.0

### What's Changed

**Native Claude Code installation** — switched from `node:20-slim` to `debian:bookworm-slim` with the official Claude Code native installer. Node.js is no longer required inside the container.

**Removed Node.js dependency for SSH relay** — the in-container SSH agent relay now uses `socat`; the host-side relay prefers `socat` with a `python3` fallback. Node.js on the host is now optional (used only for JSON config merging).

**Auto-update check** — sandy checks for newer Claude Code versions on launch and rebuilds the image automatically when an update is available.

**Git submodule support** — when launched from a git submodule, sandy mounts the workspace at the correct depth to preserve relative gitdir paths.

**Container stability** — `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates inside the read-only container. `installMethod: 'native'` is set in `.claude.json` (with migration for existing sandboxes).

**Dynamic workspace paths** — the entrypoint now uses `SANDY_WORKSPACE` instead of hardcoded `/workspace`, supporting submodule and non-standard mount points.

### Fixes

- Removed leaked OAuth URL from README
- Updated installer to reflect Node.js is now optional

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
| `sandy` | Self-contained launcher (~670 lines of bash) |
| `install.sh` | `curl \| bash` installer |

### Requirements

- Docker
- No `ANTHROPIC_API_KEY` needed if using Claude Max (OAuth)
