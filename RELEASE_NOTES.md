## sandy v0.3.0

### What's Changed

**Layered Docker image with language runtimes** — the Docker build is now two-phase: a `sandy-base` image installs OS packages and language toolchains (Node.js 22 LTS, Go 1.24, Rust stable, Python 3, C/C++ via build-essential), while the thin `sandy-claude-code` layer installs only Claude Code on top. The base image rebuilds rarely, so Claude Code updates are fast. Inside the container, Go, Rust, and npm are configured with writable home-directory paths so `go install`, `cargo install`, and `npm install -g` work out of the box.

**OAuth token refresh** — sandy now detects expired or soon-to-expire OAuth tokens before launch and automatically runs `claude auth login` to refresh them. Credential loading has been unified into a single `load_credentials()` helper that reads from `~/.claude/.credentials.json` or the macOS Keychain.

**Improved sandbox fidelity** — the Claude Code data directory (`~/.local/share/claude`) is now persisted via `/opt/claude-code` and symlinked back at runtime, so Claude Code finds both its binary and data directory at the expected paths. Statsig feature-flag caches are refreshed on every launch (not just on sandbox creation). Plugin marketplace catalogs are seeded into new sandboxes, and stale `enabledPlugins` entries are stripped.

**Home directory tmpfs increased** — the `/home/claude` tmpfs overlay was increased from 512 MB to 2 GB, giving language toolchains enough room for package caches and build artifacts.

### Fixes

- **UID mismatch on Linux** — the entrypoint now reads `HOST_UID`/`HOST_GID` from the host and runs `gosu` with matching IDs. All `chown` calls use the runtime UID/GID instead of the hardcoded `claude:claude` username, fixing permission errors on bind-mounted files when the host user's UID differs from 1001.
- **Bridge name length** — shortened the per-instance bridge name prefix from `br-claude-` to `br-sdy-` to stay within the Linux 15-character `IFNAMSIZ` limit.
- **git safe.directory** — changed from trusting only `$WORKSPACE` to trusting `*`, since the entire container is sandboxed and host UID mismatches are expected.
- **tmux stderr** — Claude Code's tmux session now captures stderr (`2>&1`) so error output is visible in the terminal.

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
| `sandy` | Self-contained launcher (~820 lines of bash) |
| `install.sh` | `curl \| bash` installer |

### Requirements

- Docker
- No `ANTHROPIC_API_KEY` needed if using Claude Max (OAuth)
