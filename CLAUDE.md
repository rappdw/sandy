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

## Per-project Configuration

Create `.sandy/config` in any project directory to set per-project defaults:

```sh
SANDY_SSH=agent                          # use SSH agent forwarding
SANDY_MODEL=claude-sonnet-4-5-20250929   # override model
```

This file is sourced as a bash script on every launch. Any sandy environment variable can be set here: `SANDY_MODEL`, `SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`.

## Per-project Sandboxes

Each project directory gets its own isolated `~/.claude` sandbox under `~/.sandy/sandboxes/`, named with a mnemonic prefix and hash (e.g. `myproject-a1b2c3d4`). On first run, `.credentials.json` and `settings.json` are seeded from the host's `~/.claude/`.

## Architecture

- **Three-phase Docker build**: A `sandy-base` image contains the OS, toolchains (Node.js 22, Go 1.24, Rust stable, Python 3, C/C++), and system tools. A `sandy-claude-code` image layers Claude Code on top. An optional per-project image (from `.sandy/Dockerfile`) layers project-specific tools on top of that. Each phase only rebuilds when its inputs change.
- `sandy` — Self-contained launcher (bash script) installed to `~/.local/bin/`. On first run, generates Dockerfile.base, Dockerfile, entrypoint.sh, and tmux.conf in `~/.sandy/`, builds both Docker images, creates per-project sandbox directories, applies network isolation, and launches the container via `docker run`.
- `install.sh` — `curl | bash` installer that downloads `sandy` to `~/.local/bin/` and checks PATH setup.

## Versioning

`SANDY_VERSION` in the `sandy` script follows this convention:

- **Release**: `X.Y.Z` (e.g. `0.7.10`). Set this when tagging a release.
- **Post-release**: `X.Y.(Z+1)-dev` (e.g. `0.7.11-dev`). Bump to this immediately after cutting a release.

`SANDY_COMMIT` is a separate variable that holds the git short hash. It's empty in the source file — at runtime, `sandy_full_version()` detects it from git if running from a repo checkout, and `install.sh` bakes it in for local installs. The full version string displayed is e.g. `0.7.11-dev-a1b2c3d`.

The update check logic compares only `SANDY_VERSION` (not the hash) against GitHub release tags.

## Skill Packs

Optional Docker image layers that bake curated skill collections into the container. Skills are not included by default — they're built once and cached as a Docker layer.

### Configuration

Set `SANDY_SKILL_PACKS` in `.sandy/config` or as an environment variable:

```sh
SANDY_SKILL_PACKS=gstack
```

### Available Packs

| Pack | Description | Source |
|------|-------------|--------|
| `gstack` | 28 Claude Code skills (QA, review, ship, browse, etc.) + headless Chromium browser engine | [rappdw/gstack](https://github.com/rappdw/gstack) (fork tracking upstream [garrytan/gstack](https://github.com/garrytan/gstack)) |

### How It Works

Skill packs add a build phase (Phase 2.5) between the Claude Code image and the optional per-project image. The generated `Dockerfile.skills` clones the skill pack at a pinned version, builds it, and installs dependencies (e.g. Playwright Chromium for gstack's `/browse` command). The resulting `sandy-skills-{hash}` image is cached and reused across projects that share the same skill pack configuration.

At container startup, `user-setup.sh` symlinks `/opt/skills/{pack}/` into `~/.claude/skills/` so Claude Code discovers the skills automatically. Skill pack `bin/` directories are added to PATH.

First build takes a few minutes (downloading + compiling). Subsequent launches are instant.

### Version Resolution

Skill pack versions are resolved dynamically from GitHub releases on each launch — there is no hardcoded version pin. The resolution order is:

1. **GitHub releases API** — fetches the latest non-draft, non-prerelease tag matching the pack's prefix (e.g. `sandy/v*` for gstack). 5-second timeout.
2. **Local cache** — `~/.sandy/.skill_version_{pack}` stores the last successfully resolved version.
3. **Hardcoded fallback** — `SKILL_PACK_VERSIONS` array in the sandy script, used only on first run if GitHub is unreachable.

When a new version is detected, the `Dockerfile.skills` is regenerated with the updated version. The content hash changes, which triggers a rebuild of the skill pack image automatically.

### Adding New Packs

Add entries to `SKILL_PACK_NAMES`, `SKILL_PACK_REPOS`, `SKILL_PACK_VERSIONS`, and `SKILL_PACK_TAG_PREFIXES` arrays in the sandy script, then add a build recipe case in `generate_skill_pack_dockerfile()`.

## Auto-update

On each launch, sandy checks for newer Claude Code versions by comparing the installed version against the latest release. If an update is available, the image is rebuilt with `--no-cache`. Inside the container, `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates against the read-only filesystem.

## Workspace Mount Path

The workspace is mounted inside the container at a path that mirrors the host's `$HOME`-relative location. For example, if you run sandy from `~/dev/sandy`, the workspace appears at `/home/claude/dev/sandy` inside the container. If the workspace is outside `$HOME`, it falls back to mounting at the real host path. The container path is passed via the `SANDY_WORKSPACE` environment variable.

## Git Submodule Support

When launched from a git submodule, sandy detects the `.git` file (vs directory), resolves the relative gitdir path, and mounts both the worktree and gitdir at the correct container paths using the same `$HOME`-relative mapping to preserve the relative path relationship.

## SSH Agent Relay

Two modes controlled by `SANDY_SSH`:
- `token` (default) — uses `gh auth token` for HTTPS-based git auth
- `agent` — forwards the host SSH agent into the container
  - **Linux**: direct socket mount
  - **macOS**: host-side TCP relay via `socat` (preferred) or `python3` fallback; in-container relay via `socat`

## Language Environments

The base image ships with fixed versions of each toolchain: Python 3 (Debian bookworm's default), Node.js 22, Go 1.24, Rust stable, and C/C++ (build-essential). `uv` is also pre-installed for Python version management.

### Persistent Package Installs

Packages installed via `pip install`, `npm install -g`, `go install`, `cargo install`, and `uv` persist across sessions. Each per-project sandbox has dedicated subdirectories that are bind-mounted into the container:

| Sandbox dir | Container mount | What it stores |
|---|---|---|
| `pip/` | `~/.pip-packages` | `PYTHONUSERBASE` — pip user installs (scripts + site-packages) |
| `uv/` | `~/.local/share/uv` | uv-managed Python versions |
| `npm-global/` | `~/.npm-global` | `npm install -g` packages |
| `go/` | `~/go` | `GOPATH` — `go install` binaries |
| `cargo/` | `~/.cargo` | `cargo install` binaries + registry cache |

These are per-project — packages installed in one project sandbox don't leak to another.

### Python Version Management

The base image includes a single system Python (whatever Debian bookworm ships). For projects that need a specific Python version, use `uv`:

```sh
uv python install 3.11
uv venv --python 3.11
source .venv/bin/activate
uv pip install -r requirements.txt
```

Downloaded Python versions persist in the `uv/` sandbox directory, so `uv python install` only downloads once per project sandbox.

Plain `pip install` also works — `PYTHONUSERBASE` and `pip.conf` (`user=true`) are set so installs go to the persistent `pip/` mount by default. Inside an activated virtualenv, pip correctly installs to the venv instead.

### Host Virtual Environments and Build Artifacts

The project directory is bind-mounted read-write into the container. This means `.venv/`, `node_modules/`, `target/`, and other build directories from the host are visible and writable inside the container.

**Python `.venv/`**: A host-created venv will work inside the container *if* the host and container have the same Python version at the same path (e.g. both have `/usr/bin/python3.12`). If versions differ, the venv's `bin/python` symlink and script shebangs will be broken. In that case, recreate the venv inside sandy: `uv venv --python 3.12 && uv pip install -r requirements.txt`.

**Node.js `node_modules/`**: Pure JavaScript packages work fine. Native addons (`.node` files) compiled on the host will work if the host is also Linux with compatible glibc. If you see `MODULE_NOT_FOUND` errors on native modules, run `npm rebuild` inside the container.

**Rust `target/`**: Incremental build artifacts from the host are reusable if both sides are Linux x86_64. Cross-platform (e.g. macOS host → Linux container) will trigger a full rebuild — Cargo handles this automatically.

**Go `vendor/`**: Pure source code, always works across environments.

### Automatic Environment Detection

On every session start, the entrypoint checks the workspace for common issues:

- **`.python-version`**: Auto-installs the specified Python version via `uv python install` (idempotent, persists).
- **Broken `.venv`**: If `.venv/bin/python` is a dead symlink (host/container Python mismatch), warns with the fix command.
- **Foreign native modules**: If `node_modules/` contains `.node` files compiled for a different platform (e.g. macOS → Linux), warns with `npm rebuild` as the fix.

### Gotchas

- **Read-only root filesystem**: The container runs with `--read-only`. System-wide installs (`apt-get install`, `pip install` without `--user`) will fail. Use the user-scoped mechanisms above, or `uv` for Python versions.
- **npm global vs local**: `npm install` (without `-g`) writes to `node_modules/` in the project directory (host-mounted, persists). `npm install -g` writes to the persistent `npm-global/` sandbox mount. Both survive across sessions.
- **Cargo symlinks**: The entrypoint symlinks system Rust toolchain binaries (`rustc`, `cargo`, etc.) into the persistent `~/.cargo/bin`. User-installed binaries (e.g. `cargo install ripgrep`) coexist alongside them.
- **PATH order**: `~/.local/bin` > `PYTHONUSERBASE/bin` > `npm-global/bin` > `GOPATH/bin` > `CARGO_HOME/bin` > system PATH. User installs always take precedence.
- **tmpfs size limit**: The home directory tmpfs is 2GB. Large build artifacts or many installed packages may hit this — but persistent mounts (pip, npm, go, cargo, uv) bypass the tmpfs entirely.

## Network Isolation Details

Per-instance Docker bridge networks are created with names keyed on PID (`sandy_net_$$`) to avoid races between concurrent sessions. On Linux, iptables DROP rules block RFC 1918 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and CGNAT/Tailscale (`100.64.0.0/10`), while allowing the container's own subnet. On macOS, Docker Desktop's VM provides LAN isolation by default. Rules are cleaned up on script exit.

## Protected Files

Certain sensitive files and directories in the workspace are mounted read-only inside the container to prevent modification by Claude Code. This blocks shell config injection, git hook injection, and IDE config tampering.

**Protected files**: `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile`, `.gitconfig`, `.ripgreprc`, `.mcp.json`, `.git/config`, `.gitmodules`
**Protected directories**: `.git/hooks/`, `.vscode/`, `.idea/`
**Sandbox-mounted directories**: `.claude/commands/`, `.claude/agents/`, `.claude/plugins/` — these are overlaid with writable sandbox copies so Claude can create and modify commands, agents, and plugins without touching the host. All three start empty; plugins are managed via `/plugin install`.

Protected files/directories are overlaid as read-only bind mounts at container launch. The host filesystem is unaffected. Files that don't exist in the workspace are skipped (no empty placeholders created).

## Terminal Notifications

Sandy's inner tmux is configured with `allow-passthrough on`, which forwards OSC escape sequences (9/99/777) from Claude Code through to the outer terminal. This enables notification features in terminals like cmux and iTerm2.

Host-side Claude Code hooks (`~/.claude/hooks/`) are mounted read-only into the container at `/home/claude/.claude/hooks/`. This allows hooks configured on the host (e.g., cmux notification hooks) to work inside sandy without duplication.
