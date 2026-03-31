# Sandy Specification

**Version**: 0.7.11-dev
**Date**: 2026-03-30
**Source**: ~1,850-line bash script (`sandy`), installer (`install.sh`), test suite (`test/run-tests.sh`)

Sandy is a self-contained command that runs Claude Code in a Docker container with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes. One script, one command, zero configuration required.

---

## Table of Contents

1. [Command-Line Interface](#1-command-line-interface)
2. [Configuration System](#2-configuration-system)
3. [Versioning](#3-versioning)
4. [Per-Project Sandboxes](#4-per-project-sandboxes)
5. [Docker Image Build Pipeline](#5-docker-image-build-pipeline)
6. [Skill Pack System](#6-skill-pack-system)
7. [Container Runtime](#7-container-runtime)
8. [Network Isolation](#8-network-isolation)
9. [Protected Files](#9-protected-files)
10. [SSH Agent Relay](#10-ssh-agent-relay)
11. [Credential Management](#11-credential-management)
12. [Session Management](#12-session-management)
13. [Workspace Path Mapping](#13-workspace-path-mapping)
14. [Environment Detection](#14-environment-detection)
15. [Plugin Marketplace Management](#15-plugin-marketplace-management)
16. [Channel Integration](#16-channel-integration)
17. [Auto-Update](#17-auto-update)
18. [Security Model](#18-security-model)
19. [Test Suite](#19-test-suite)
20. [Installation](#20-installation)
21. [File Inventory](#21-file-inventory)

---

## 1. Command-Line Interface

### Usage Modes

```
sandy                          # Interactive session (resume last or start new)
sandy -p "prompt"              # One-shot prompt (no interactive session)
sandy --new                    # Force fresh session
sandy --resume                 # Open session picker (forwarded to claude)
sandy --remote                 # Remote-control server mode (headless)
```

### Administrative Flags

| Flag | Behavior |
|---|---|
| `--rebuild` | Force rebuild all Docker images |
| `--build-only` | Build images and exit (for CI/prewarming) |
| `--upgrade` | Self-update sandy from GitHub |
| `--version` | Print version string (e.g. `0.7.11-dev-a1b2c3d`) |
| `--help` | Show help text |

### Verbosity Flags

| Flag | Effect |
|---|---|
| `-v` | Show startup section headers, pause on exit |
| `-vv` | Add bash trace to `user-setup.sh` |
| `-vvv` | Also trace `entrypoint.sh` and show docker run flags |

### Argument Forwarding

All unrecognized arguments (including `-p "prompt"`, `--resume`, `--continue`) are forwarded to the `claude` binary inside the container.

### Flag Parsing

Flags are parsed with a `while [ $# -gt 0 ]` loop with `shift`. Sandy's flags are consumed; everything else is collected into `REMAINING_ARGS` and forwarded to `claude`.

---

## 2. Configuration System

### Load Order

1. `$SANDY_HOME/config` — user-level defaults (typically `~/.sandy/config`)
2. `$SANDY_HOME/.secrets` — user-level credentials
3. `.sandy/config` — per-project overrides
4. `.sandy/.secrets` — per-project credentials

Later files override earlier values.

### Parser

The config parser does **not** use `source`. It reads plain `KEY=VALUE` lines, strips quotes, validates against an allowlist, and exports only recognized keys. Lines not matching `^[A-Z_]+=.+` are ignored.

### Allowlisted Variables

| Variable | Default | Description |
|---|---|---|
| `SANDY_MODEL` | `claude-opus-4-6` | Claude model to use |
| `SANDY_SSH` | `token` | Git auth: `token` (gh CLI + HTTPS) or `agent` (SSH socket forward) |
| `SANDY_SKIP_PERMISSIONS` | `true` | Run with `--dangerously-skip-permissions` |
| `SANDY_CPUS` | auto-detected | CPU limit for container |
| `SANDY_MEM` | auto-detected | Memory limit (`available - 1GB`, min 2GB) |
| `SANDY_GPU` | disabled | GPU passthrough: `all`, or device IDs like `0,1` |
| `SANDY_SKILL_PACKS` | unset | Comma-separated skill packs (e.g. `gstack`) |
| `SANDY_ALLOW_LAN_HOSTS` | unset | Comma-separated IPs/CIDRs to allow through isolation |
| `SANDY_ALLOW_NO_ISOLATION` | unset | Set to `1` to skip iptables (Linux only) |
| `SANDY_CHANNELS` | unset | Channel plugins (e.g. `plugin:telegram@claude-plugins-official`) |
| `SANDY_VERBOSE` | `0` | Verbosity level (0-3) |
| `CLAUDE_CODE_OAUTH_TOKEN` | unset | Long-lived OAuth token (1-year validity) |
| `ANTHROPIC_API_KEY` | unset | API key (not needed with Claude Pro/Max) |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | Max output tokens per response |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | unset | Set to `1` to enable agent teams |
| `TELEGRAM_BOT_TOKEN` | unset | Telegram bot token |
| `TELEGRAM_ALLOWED_SENDERS` | unset | Comma-separated Telegram user IDs |
| `DISCORD_BOT_TOKEN` | unset | Discord bot token |
| `DISCORD_ALLOWED_SENDERS` | unset | Comma-separated Discord user IDs |

### Model Validation

`SANDY_MODEL` is validated against `^[a-zA-Z0-9._-]+$` to prevent injection.

---

## 3. Versioning

### Version Variables

- **`SANDY_VERSION`**: `X.Y.Z` for releases, `X.Y.(Z+1)-dev` for post-release development
- **`SANDY_COMMIT`**: Empty in source; baked in by `install.sh` for local installs; detected from git at runtime if empty

### Full Version String

`sandy_full_version()` produces strings like `0.7.11-dev-a1b2c3d` by combining `SANDY_VERSION` and the commit hash.

### Update Check

Compares only `SANDY_VERSION` (not hash) against GitHub release tags via `https://api.github.com/repos/rappdw/sandy/releases/latest`. Result cached in `~/.sandy/.update_check` with 24-hour TTL.

---

## 4. Per-Project Sandboxes

### Naming

Each project directory gets a sandbox at `~/.sandy/sandboxes/<NAME>-<HASH>/`:
- `<NAME>`: Sanitized `basename` of project directory (alphanumeric, dots, hyphens)
- `<HASH>`: First 8 characters of SHA256 of the full project path

### Directory Layout

The sandbox directory **is** `~/.claude` inside the container (mounted directly).

**Persistent directories** (bind-mounted into container):

| Sandbox subdir | Container mount | Purpose |
|---|---|---|
| `pip/` | `~/.pip-packages` | `PYTHONUSERBASE` — pip user installs |
| `uv/` | `~/.local/share/uv` | uv-managed Python versions |
| `npm-global/` | `~/.npm-global` | `npm install -g` packages |
| `go/` | `~/go` | `GOPATH` — go install binaries |
| `cargo/` | `~/.cargo` | Cargo registry cache + installed binaries |
| `gstack/` | `~/.gstack` | Skill pack state (if enabled) |
| `workspace-commands/` | `.claude/commands/` | User-created slash commands (writable overlay) |
| `workspace-agents/` | `.claude/agents/` | User-created agents (writable overlay) |
| `workspace-plugins/` | `.claude/plugins/` | Installed plugins (writable overlay) |

**Configuration files**:

| Path | Purpose |
|---|---|
| `settings.json` | Claude Code settings (seeded from host on first run) |
| `statsig/` | Feature flag cache (refreshed from host each launch) |
| `../<NAME>.claude.json` | Setup state: theme, terms, OAuth, onboarding (stored outside sandbox dir to avoid mount conflicts) |
| `history.jsonl` | Session history |
| `projects/<WORKSPACE_KEY>/` | Session files (`.jsonl` per session) |

### Seeding

On first run for a new sandbox:
1. Copy host `~/.claude/settings.json` → sandbox `settings.json`
2. Strip `enabledPlugins` from seeded settings (prevents host plugin leakage)
3. Copy host `~/.claude/.claude.json` → sandbox `.claude.json`, stripping the `projects` key
4. Copy host `~/.claude/statsig/` → sandbox `statsig/`
5. Create all persistent subdirectories

---

## 5. Docker Image Build Pipeline

Sandy generates all Dockerfiles, entrypoint scripts, and config files at runtime in `$SANDY_HOME/`. Each phase has content-hash-based caching — images only rebuild when their inputs change.

### Phase 1: Base Image (`sandy-base`)

**Dockerfile**: `Dockerfile.base`
**Rebuild trigger**: Content hash of Dockerfile.base changes, or `--rebuild` flag

Contents:
- **OS**: Debian bookworm-slim
- **System tools**: build-essential, git, git-lfs, jq, ripgrep, socat, tmux, curl, cmake, openssh-client, less, pkg-config, gosu
- **GitHub CLI**: `gh`
- **Node.js 22 LTS**: Via NodeSource
- **Go 1.24**: Multi-arch binary from go.dev
- **Rust stable**: Via rustup (installed to `/usr/local/rustup` and `/usr/local/cargo`)
- **Bun**: Via `curl https://bun.sh/install`
- **uv**: Via `curl https://astral.sh/uv/install.sh` (installed to `/usr/local/bin`)
- **Python 3**: Debian system Python + python3-venv
- **Libraries**: libcairo2, libgdk-pixbuf-2.0-0, libpango1.0-0, libssl-dev, ncurses-term
- **User**: `claude` (UID 1001, shell `/bin/bash`)

### Phase 2: Claude Code Image (`sandy-claude-code`)

**Dockerfile**: `Dockerfile`
**Rebuild trigger**: Content hash of (Dockerfile + entrypoint.sh + user-setup.sh + tmux.conf) changes, base image rebuilt, Claude Code version update, or `--rebuild` flag

Contents:
- `FROM sandy-base`
- Claude Code: Native binary installed via `curl https://claude.ai/install.sh`, relocated to `/usr/local/bin/claude` and `/opt/claude-code`
- synthkit dependencies: libpango1.0-dev, libcairo2-dev, libgdk-pixbuf2.0-dev (WeasyPrint needs these)
- synthkit: Installed via `UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install synthkit`
- `COPY`: entrypoint.sh, user-setup.sh, tmux.conf
- Claude Code version cached at `/opt/claude-code/.version`

### Phase 2.5a: Skill Pack Base Image (`sandy-skills-base-<pack>`)

**Dockerfile**: `Dockerfile.skills-base`
**Rebuild trigger**: Content hash changes, or Phase 2 image rebuilt
**Only generated when**: `SANDY_SKILL_PACKS` is set and a pack requires heavy base dependencies

Contents (for gstack):
- `FROM sandy-claude-code`
- Playwright installed via npm
- Chromium browser installed via `npx playwright install chromium`
- System deps for Chromium via `npx playwright install-deps chromium`

This image changes rarely (only when Playwright version changes) and caches the ~400MB Chromium download.

### Phase 2.5b: Skill Pack Code Image (`sandy-skills-<pack>`)

**Dockerfile**: `Dockerfile.skills`
**Rebuild trigger**: Content hash changes (new version SHA in download URL), base skills image rebuilt, or Phase 2 image rebuilt

Contents (for gstack):
- `FROM sandy-skills-base-<pack>`
- Download gstack source tarball at pinned version/SHA
- `bun install` + `bun run build`
- Make `bin/*` executable

This image rebuilds whenever a new commit is detected on the skill pack repo (fast, since Chromium is cached in the base).

### Phase 3: Per-Project Image (optional, `sandy-project-<name>-<hash>`)

**Dockerfile**: `.sandy/Dockerfile` in project directory
**Rebuild trigger**: Content hash changes, any upstream image rebuilt
**Build context**: `.sandy/` directory

User-provided Dockerfile with `ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}`. Sandy passes the appropriate base image (Phase 2, 2.5a, 2.5b, or 2 depending on configuration) as a build arg.

### Build Hash Caching

Each phase stores its content hash in `$SANDY_HOME/`:

| File | Phase |
|---|---|
| `.base_build_hash` | Phase 1 |
| `.build_hash` | Phase 2 |
| `.skills_base_build_hash` | Phase 2.5a |
| `.skills_build_hash` | Phase 2.5b |
| `<sandbox>/.project_build_hash` | Phase 3 |

A phase rebuilds if: hash differs from stored, upstream phase was rebuilt, Docker image doesn't exist locally, or `--rebuild` flag is set.

---

## 6. Skill Pack System

### Registry

Four parallel arrays define available skill packs:

```bash
SKILL_PACK_NAMES=(gstack)
SKILL_PACK_REPOS=("https://github.com/garrytan/gstack")
SKILL_PACK_VERSIONS=("main")          # Fallback only
SKILL_PACK_TAG_PREFIXES=("")          # Empty = use commit SHA
```

### Version Resolution

On each launch, `skill_pack_resolve_versions()` runs for each enabled pack:

1. **GitHub releases API** (5-second timeout): If `tag_prefix` is set, fetch latest non-draft, non-prerelease tag matching the prefix
2. **GitHub commits API** (5-second timeout): If no releases or no prefix, fetch latest commit SHA on default branch (truncated to 12 chars)
3. **Local cache**: `~/.sandy/.skill_version_<pack>` stores last successfully resolved version
4. **Hardcoded fallback**: `SKILL_PACK_VERSIONS` array entry, used only on first run if GitHub is unreachable

The resolved version is embedded in the generated Dockerfile. A new version = different Dockerfile content = hash mismatch = rebuild triggered.

### Container Activation

At container startup, `user-setup.sh`:
1. Symlinks `/opt/skills/<pack>/` → `~/.claude/skills/<pack>`
2. Symlinks individual skill directories (those containing `SKILL.md`) into `~/.claude/skills/`
3. Adds `/opt/skills/<pack>/bin` to PATH
4. Sets `PLAYWRIGHT_BROWSERS_PATH=/opt/skills/gstack/.browsers`

### Adding New Packs

Add entries to all four arrays (`SKILL_PACK_NAMES`, `SKILL_PACK_REPOS`, `SKILL_PACK_VERSIONS`, `SKILL_PACK_TAG_PREFIXES`) and add a build recipe case in `generate_skill_pack_dockerfiles()`.

---

## 7. Container Runtime

### Docker Run Flags

```
--rm -it
--name sandy-<SANDBOX_NAME>
--cpus <SANDY_CPUS>
--memory <SANDY_MEM>
--security-opt no-new-privileges:true
--cap-drop ALL
--cap-add SETUID --cap-add SETGID --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
--pids-limit 512
--read-only
--tmpfs /tmp:exec,size=1G
--tmpfs /home/claude:exec,size=2G,uid=1001,gid=1001
--network <NETWORK_NAME>
```

Optional: `--gpus <SANDY_GPU>` if GPU passthrough is enabled.

### Entrypoint Flow (Root Phase)

`entrypoint.sh` runs as root and performs:

1. Fix tmpfs home directory ownership to match host UID/GID
2. Seed `~/.ssh/known_hosts` from host mount
3. SSH agent relay setup (macOS: socat TCP→Unix relay; Linux: socket permissions fix)
4. Copy host SSH config from `/tmp/host-ssh` to `~/.ssh/` (dereferences symlinks, sets correct permissions)
5. Fix ownership of all persistent mount directories (pip, uv, npm, go, cargo, gstack)
6. Symlink Claude Code binary and data dir into home
7. Create pip/pip3 wrapper scripts (auto-add `--user` when outside virtualenvs)
8. Drop privileges: `exec gosu $RUN_UID:$RUN_GID /usr/local/bin/user-setup.sh "$@"`

### User Setup Flow (User Phase)

`user-setup.sh` runs as the `claude` user:

1. Set environment variables (HOME, CARGO_HOME, GOPATH, NPM_CONFIG_PREFIX, PYTHONUSERBASE, PATH)
2. Symlink system Rust toolchain binaries into `~/.cargo/bin`
3. Activate skill packs (symlink into `~/.claude/skills/`)
4. Create synthkit slash commands (`/md2pdf`, `/md2doc`, `/md2html`, `/md2email`)
5. Remap ANSI color 4 (dark blue → bright blue) for readability
6. Configure `settings.json` (merge defaults, set teammateMode, spinnerTips, permissions)
7. Configure git (safe.directory, user name/email)
8. Environment detection (.python-version, broken .venv, foreign native modules, git-lfs)
9. Git auth setup (token mode: URL rewriting + gh auth; agent mode: SSH config)
10. Plugin marketplace refresh (daily, or forced when channels configured)
11. Channel credential seeding (Telegram, Discord: write `.env` and `access.json`)
12. Launch Claude Code via tmux (or remote-control mode)

### UID/GID Remapping

If the host UID differs from the image default (1001), sandy generates custom `passwd` and `group` files with the host UID/GID and mounts them read-only. The entrypoint then uses `gosu` with the remapped UID/GID.

### Environment Variables Passed to Container

**Claude Code config**: `SANDY_WORKSPACE`, `SANDY_PROJECT_NAME`, `SANDY_MODEL`, `SANDY_SKIP_PERMISSIONS`, `SANDY_NEW_SESSION`, `SANDY_REMOTE_CONTROL`, `SANDY_VERBOSE`, `SANDY_CHANNELS`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`

**Credentials**: `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` (explicitly emptied if not set, to prevent host env leakage)

**Channel credentials**: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`

**Git**: `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GIT_TOKEN`, `SANDY_SSH`, `SSH_RELAY_PORT`

**System**: `HOST_UID`, `HOST_GID`, `DISABLE_AUTOUPDATER=1`, `ENABLE_CLAUDEAI_MCP_SERVERS=false`

### Resource Limits

- **CPU**: Auto-detected from `docker info` (number of CPUs), overridable via `SANDY_CPUS`
- **Memory**: Auto-detected as `available - 1GB` (minimum 2GB), overridable via `SANDY_MEM`
- **PIDs**: Hard limit of 512 processes
- **Tmpfs**: `/tmp` = 1GB, `/home/claude` = 2GB (persistent mounts bypass tmpfs)

---

## 8. Network Isolation

### Linux

Per-instance Docker bridge networks are created with names keyed on PID (`sandy_net_$$`) to avoid races between concurrent sessions.

**iptables rules** inserted into the `DOCKER-USER` chain:

| Range | Purpose |
|---|---|
| `10.0.0.0/8` | Home/office LANs, VPNs |
| `172.16.0.0/12` | Docker internals, some LANs |
| `192.168.0.0/16` | Home/office LANs |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT, Tailscale |

The container's own subnet is allowed. Additional hosts/CIDRs can be allowed via `SANDY_ALLOW_LAN_HOSTS`.

**Rule insertion order** (rules evaluated top-to-bottom):
1. Allow container's own subnet (inserted last, evaluated first)
2. Allow specific LAN hosts (if `SANDY_ALLOW_LAN_HOSTS` set)
3. DROP all private ranges

**Cleanup**: Rules and network removed on exit. Stale rules from previous unclean exits cleaned up on startup.

**Fail-closed**: If `iptables` is not available, sandy aborts unless `SANDY_ALLOW_NO_ISOLATION=1`.

### macOS

Docker Desktop runs containers in a lightweight Linux VM. Containers cannot directly access the Mac's LAN — Docker's NAT provides isolation out of the box. No iptables rules needed.

---

## 9. Protected Files

Certain files and directories in the workspace are overlaid at container launch to prevent modification.

### Read-Only Bind Mounts

| Path | Threat mitigated |
|---|---|
| `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile` | Shell config injection (aliases, PATH hijacking, env poisoning) |
| `.gitconfig` | Credential helper injection, alias hijacking |
| `.git/config` | Remote path manipulation, `core.fsmonitor` injection |
| `.gitmodules` | Submodule URL hijacking |
| `.git/hooks/` | Pre-commit, post-checkout, push hook injection |
| `.ripgreprc` | Search config injection |
| `.mcp.json` | MCP server config tampering |
| `.vscode/`, `.idea/` | IDE task/launch config injection |

Files that don't exist in the workspace are skipped (no empty placeholders created).

### Writable Sandbox Overlays

| Workspace path | Sandbox source | Behavior |
|---|---|---|
| `.claude/commands/` | `workspace-commands/` | Starts empty; Claude can create/modify freely |
| `.claude/agents/` | `workspace-agents/` | Starts empty; Claude can create/modify freely |
| `.claude/plugins/` | `workspace-plugins/` | Starts empty; managed via `/plugin install` |

Host content at these paths is hidden (not visible inside container). Changes persist in the sandbox across sessions. No changes to host filesystem.

### Symlink Protection

Before container launch, sandy scans the workspace (up to 5 levels deep, skipping `node_modules/`, `.venv/`, `.git/`) for symlinks pointing outside the project directory. If found, the user is prompted to confirm before proceeding.

---

## 10. SSH Agent Relay

### Token Mode (default, `SANDY_SSH=token`)

1. Query `gh auth token` on host
2. Pass token to container via `-e GIT_TOKEN=...`
3. In container: configure `git config --global url."https://oauth2:<TOKEN>@github.com/".insteadOf "git@github.com:"`
4. Authenticate `gh` CLI with the token

Fallback: If `gh auth token` fails, warn that git push/pull may not work.

### Agent Mode (`SANDY_SSH=agent`)

**Linux**: Direct socket mount. Host `SSH_AUTH_SOCK` socket mounted at `/tmp/ssh-agent.sock` inside container.

**macOS**: Two-hop relay.
1. **Host side**: `socat TCP-LISTEN:<PORT>,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:<SSH_AUTH_SOCK>`
2. **Container side** (in entrypoint): `socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,mode=0600,uid=$RUN_UID TCP:host.docker.internal:<PORT>`
3. Wait for socket to appear (retry loop, 50 attempts x 0.1s)

**SSH config**: Host `~/.ssh/` is mounted read-only at `/tmp/host-ssh`. The entrypoint copies each file (dereferencing symlinks, skipping dangling ones) to `~/.ssh/` with correct ownership and permissions (600 for keys, 644 for `.pub`/`config`/`known_hosts`).

---

## 11. Credential Management

### Priority Order

1. **Long-lived token** (`CLAUDE_CODE_OAUTH_TOKEN`): Valid 1 year, generated via `claude setup-token`. Recommended for headless servers.
2. **OAuth credentials**: From host `~/.claude/.credentials.json` (or macOS Keychain). Token expiry checked; refresh attempted on macOS via `claude auth login`.
3. **Fallback**: Skip credential setup; user directed to `/login` inside session.

### Token Expiry Check

`token_needs_refresh()` checks if `claudeAiOauth.expiresAt` is within 5 minutes of current time. Uses Node.js (preferred) or Python 3 (fallback) for timestamp comparison.

### Ephemeral Credential Loading

Credentials are loaded into a temporary file, mounted into the container at `~/.claude/.credentials.json`, and discarded on exit. They are never persisted in the sandbox.

### OAuth Token Isolation

`CLAUDE_CODE_OAUTH_TOKEN` is explicitly set to empty string in the container's environment when not configured, preventing accidental leakage from the host environment.

---

## 12. Session Management

### Tmux Integration

Sandy wraps Claude Code in a tmux session:
- **Session name**: `sandy` (fixed)
- **Window name**: `sandy: <PROJECT_NAME>`
- **Auto-resume**: If session files exist in `~/.claude/projects/<WORKSPACE_KEY>/` and no overriding flags (`--new`, `-p`, `--resume`, `--continue`), sandy automatically adds `--continue` to resume the last session
- **Fallback**: If `--continue` fails (stale session), retry without it

### Tmux Configuration

- History: 10,000 lines
- Mouse support enabled
- 256-color + RGB
- Escape time: 0ms
- OSC passthrough: `allow-passthrough on` (enables terminal notifications and clipboard)
- OSC 52 clipboard support for mouse selections
- Status bar: "sandy" prefix with time display

### Remote Control Mode

With `--remote`: no tmux wrapper, launches `claude remote-control --name "sandy: <PROJECT_NAME>"`. Browser/phone can connect to control the session.

### Terminal Notifications

Sandy passes through OSC escape sequences (9/99/777) from Claude Code to the outer terminal. When running inside cmux (detected via `CMUX_WORKSPACE_ID`), sandy auto-installs a notification hook that emits OSC 777 sequences.

Host-side hooks (`~/.claude/hooks/`) are mounted read-only into the container. Host hooks take precedence over auto-setup.

---

## 13. Workspace Path Mapping

The workspace is mounted inside the container at a path that mirrors the host's `$HOME`-relative location:

```
If host path starts with $HOME:
    container path = /home/claude/<relative-to-HOME>
Else:
    container path = host path (fallback for paths outside $HOME)
```

For example, `~/dev/sandy` on the host becomes `/home/claude/dev/sandy` inside the container. This preserves the relative path relationship needed for git submodules.

### Git Submodule Support

When `.git` is a file (submodule), sandy:
1. Reads the relative gitdir path from the `.git` file
2. Resolves absolute host path for both worktree and gitdir
3. Computes container paths using the same `$HOME`-relative mapping
4. Mounts both at the correct container paths, preserving the relative relationship

---

## 14. Environment Detection

On every session start, `user-setup.sh` checks the workspace:

### `.python-version`

If present, auto-installs the specified Python version via `uv python install` (idempotent, persists in sandbox's `uv/` directory).

### Broken `.venv`

If `.venv/bin/python` is a broken symlink (host/container Python version mismatch):
- Extracts version from symlink target
- Auto-installs matching version via `uv python install`
- Warns user with fix command

### Foreign Native Modules

Scans `node_modules/` for `.node` files. If they're not ELF binaries (e.g., Mach-O from macOS host), warns with `npm rebuild` as the fix.

### Git LFS

If workspace is a git repo and `.gitattributes` contains `filter=lfs` (checked up to 3 levels deep), runs `git lfs install` (idempotent).

---

## 15. Plugin Marketplace Management

### Configured Marketplaces

Sandy configures three plugin marketplaces in `settings.json` via `extraKnownMarketplaces`:

| Name | Source |
|---|---|
| `claude-plugins-official` | `{ source: "github", repo: "anthropics/claude-plugins-official" }` |
| `thinkkit` | `{ source: "github", repo: "rappdw/thinkkit" }` |
| `ait` | `{ source: "github", repo: "rappdw/ait" }` |

### Deprecated Marketplace Removal

The `sandy-plugins` marketplace is automatically removed from `settings.json` on startup if present.

### Refresh Logic

- Marketplace catalogs refreshed daily (24-hour cache via `~/.claude/plugins/.marketplace_updated` timestamp)
- Force refresh when channels are configured (channel plugins may need installing)
- Runs `claude plugin marketplace update` for each marketplace

### Built-in Slash Commands (synthkit)

If synthkit is installed, `user-setup.sh` creates four slash commands in `~/.claude/commands/`:
- `/md2pdf` — Convert markdown to PDF
- `/md2doc` — Convert markdown to Word (.docx)
- `/md2html` — Convert markdown to HTML
- `/md2email` — Convert markdown to email HTML (clipboard)

---

## 16. Channel Integration

Sandy supports Claude Code channels (Telegram, Discord) with automatic plugin installation and credential seeding.

### Setup Flow

For each configured channel:
1. Auto-install the channel plugin from the marketplace
2. Create `~/.claude/channels/<channel>/` directory
3. Write `.env` with bot token
4. Write `access.json` with either:
   - `"dmPolicy": "allowlist"` + populated `allowFrom` (if `ALLOWED_SENDERS` set)
   - `"dmPolicy": "pairing"` (if no allowlist, user pairs via `/telegram:access pair <code>`)

### Multiple Channels

Both Telegram and Discord can be enabled simultaneously:
```
SANDY_CHANNELS=plugin:telegram@claude-plugins-official plugin:discord@claude-plugins-official
```

---

## 17. Auto-Update

### Claude Code Updates

On each launch, sandy checks the installed Claude Code version (cached at `/opt/claude-code/.version`) against the latest release. If an update is available, the Phase 2 image is rebuilt with `--no-cache`. Inside the container, `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates against the read-only filesystem.

### Sandy Self-Update

`sandy --upgrade` downloads the latest `sandy` script from GitHub and replaces the local copy. Includes pre-flight check for write permissions.

---

## 18. Security Model

### Container Hardening

| Control | Setting |
|---|---|
| Root filesystem | `--read-only` |
| User | Non-root (`claude`, mapped to host UID) |
| Privilege escalation | `--security-opt no-new-privileges:true` |
| Capabilities | `--cap-drop ALL`, add back only SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER |
| Process limit | `--pids-limit 512` |
| Network | Per-instance isolated bridge, LAN blocked |
| Tmpfs | `/tmp` (1GB), `/home/claude` (2GB) |

### Threat Mitigations

| Threat | Mitigation |
|---|---|
| File access outside workspace | Read-only root, bind-mount only workspace |
| LAN/internal network access | iptables DROP rules (Linux), Docker VM NAT (macOS) |
| Shell config injection | `.bashrc`, `.zshrc`, etc. mounted read-only |
| Git hook injection | `.git/hooks/` mounted read-only |
| IDE config tampering | `.vscode/`, `.idea/` mounted read-only |
| Plugin leakage from host | Sandbox overlay for `.claude/plugins/`, `enabledPlugins` stripped from settings |
| Symlink escape | Pre-launch scan with interactive prompt |
| OAuth token leakage | Ephemeral credentials, explicit env var blocking |
| Fork bomb | PID limit of 512 |
| Privilege escalation | `no-new-privileges`, capability dropping |

### Not Mitigated

- **DNS/outbound exfiltration**: Public internet is intentionally available. No domain filtering.
- **Data exfiltration via workspace files**: Workspace is read-write (by design).

---

## 19. Test Suite

**Location**: `test/run-tests.sh` (~1,000 lines)
**Prerequisites**: Docker, sandy images already built
**Framework**: Custom bash test harness with `check`, `pass`, `fail` helpers

### Test Categories

**Toolchain availability** (8 tests): python3, node, go, rustc, cargo, uv, gcc, git

**Persistent packages** (3 tests): pip, npm -g, go install survive across sessions

**pip behavior** (2 tests): Installs to venv when active, `--user` when not; wrapper script creation

**PATH order** (1 test): `~/.local/bin` is first

**Read-only filesystem** (3 tests): Cannot write to `/usr`, can write to `/tmp` and home

**Dev environment detection** (3 tests): `.python-version` auto-install, broken `.venv` detection, foreign native module warning

**Sandbox isolation** (1 test): Packages don't leak between project sandboxes

**Protected files** (12 tests): Cannot write to `.bashrc`, `.zshrc`, `.git/hooks/`, `.git/config`, `.gitmodules`; sandbox overlays for commands/agents/plugins work correctly

**Git LFS** (2 tests): Available, auto-configured when `.gitattributes` has `filter=lfs`

**UID remapping** (2 tests): Container UID matches host, passwd overlay for non-default UID

**Config parser** (3 tests): Config loaded before SSH setup, doesn't use `source`, uses variable allowlist

**Container naming** (1 test): Name includes sandbox name

**Symlink protection** (3 tests): Detects escaping symlinks, ignores safe internal symlinks, runs before docker

**Terminal notifications** (6 tests): tmux passthrough, host hooks mounted, cmux detection/hook/dedup

**Skill packs** (14 tests): Registration, repo config, Dockerfile generation, build phases, user-setup activation


---

## 20. Installation

### `install.sh` Flow

1. **Preflight warnings** (non-blocking): Docker installed? Node.js installed? GitHub CLI authenticated?
2. **Create install directory**: Default `~/.local/bin`
3. **Download or copy**: If `LOCAL_INSTALL` env var set, copy local file; otherwise download from GitHub
4. **Bake commit hash**: If installing from a git repo, detect and bake `SANDY_COMMIT` into the script (BSD/GNU sed compatible)
5. **Set executable**: `chmod +x`
6. **PATH check**: Warn if `~/.local/bin` not in PATH, suggest shell-specific config

### First Run

1. Validate Docker installed
2. Generate build files in `$SANDY_HOME/`
3. Build Phase 1 (base) and Phase 2 (Claude Code) images (~15-25 min)
4. Build skill pack images if enabled (~5-10 min additional for Chromium)
5. Create sandbox directory structure and seed from host
6. Create Docker network and apply iptables rules
7. Load credentials
8. Launch container

### Subsequent Runs

1. Check image hashes — skip builds if unchanged (~0 sec)
2. Refresh statsig feature flags from host
3. Create network and iptables rules (~1 sec)
4. Load credentials
5. Launch container (~3-4 sec total startup)

---

## 21. File Inventory

### Repository Files

| File | Lines | Purpose |
|---|---|---|
| `sandy` | ~1,850 | Main launcher script |
| `install.sh` | 95 | Installer |
| `CLAUDE.md` | 207 | Claude Code agent guidance |
| `README.md` | 469 | User documentation |
| `RELEASE_NOTES.md` | 113 | Version history (v0.6.0–v0.7.5) |
| `TODO.md` | 91 | Roadmap and community checklist |
| `SPECIFICATION.md` | this file | Technical specification |
| `test/run-tests.sh` | ~1,000 | Integration test suite |
| `examples/gpu/Dockerfile` | 40 | Per-project GPU Dockerfile example |
| `examples/quarto-typst/.sandy/Dockerfile` | 16 | Per-project Quarto+Typst example |
| `analysis/` | — | Security and architecture audit documents |
| `research/` | — | Feature analysis and design sketches |

### Runtime-Generated Files (`$SANDY_HOME/`)

| File | Purpose |
|---|---|
| `Dockerfile.base` | Phase 1 base image definition |
| `Dockerfile` | Phase 2 Claude Code image definition |
| `Dockerfile.skills-base` | Phase 2.5a skill pack base definition |
| `Dockerfile.skills` | Phase 2.5b skill pack code definition |
| `entrypoint.sh` | Container root-phase entrypoint |
| `user-setup.sh` | Container user-phase setup script |
| `tmux.conf` | Tmux configuration |
| `passwd` / `group` | UID/GID remapping files (if needed) |
| `.base_build_hash` | Phase 1 content hash |
| `.build_hash` | Phase 2 content hash |
| `.skills_base_build_hash` | Phase 2.5a content hash |
| `.skills_build_hash` | Phase 2.5b content hash |
| `.update_check` | Cached update check result (24-hour TTL) |
| `.skill_version_<pack>` | Cached skill pack version |
| `config` | User-level configuration |
| `.secrets` | User-level credentials |
| `sandboxes/` | Per-project sandbox directories |
