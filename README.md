[![License: MIT](https://img.shields.io/github/license/rappdw/sandy)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/rappdw/sandy)](https://github.com/rappdw/sandy/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()

# sandy — an isolated sibling for your coding agents

When you're giving AI agents real autonomy to write code, run tests, and modify systems, the environment needs OS-enforced boundaries, not permission prompts. Sandy is the tool we built to make that work.

Install it, run it. That's it.

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
cd /path/to/your/project
sandy
```

Sandy runs Claude Code or Gemini CLI (or both, side-by-side) in a Docker container with agent permission checks disabled — so the agent works without interruption while your system stays protected:

- **Filesystem**: Read/write limited to the mounted working directory only
- **Network**: Public internet only — all LAN/private networks blocked
- **Resources**: Capped CPU and memory (auto-detected from host)
- **Security**: Non-root user, read-only root filesystem, no privilege escalation
- **Protected files**: Shell configs, git hooks, and Claude commands mounted read-only
- **Per-project sandboxes**: Isolated `~/.claude`, credentials, and package storage per project
- **Dev environments**: Python, Node.js, Go, Rust, and C/C++ with persistent package installs
- **Terminal notifications**: OSC passthrough enabled — works with [cmux](https://www.cmux.dev/), iTerm2, and other notification-aware terminals

No `ANTHROPIC_API_KEY` required if using a Claude paid account (Pro/Max) — credentials are seeded from the host on first run.

## Why Sandy — Virtual Environments for Claude Code

Claude Code stores plugins, memory, hooks, credentials, and session history in a single global `~/.claude/` directory — shared across every project on your machine. This means a plugin installed for one project is active in all of them. Credentials are shared. Memory bleeds between contexts.

Sandy fixes this with **per-project sandboxes** — the same idea as Python virtual environments, but for your entire Claude Code environment:

```
~/.sandy/sandboxes/
├── webapp-a1b2c3d4/        # project A gets its own .claude/
│   └── .claude/
│       ├── plugins/         # plugins installed here stay here
│       ├── memory/          # auto-memory is project-scoped
│       └── settings.json    # settings don't leak across projects
└── ml-pipeline-e5f6g7h8/   # project B is completely independent
    └── .claude/
        └── ...
```

Each project sandbox also gets **isolated package storage** — pip, npm, go, cargo, and uv installs persist across sessions but never leak between projects. Credentials are read fresh from the host each launch and mounted ephemerally — never persisted to the sandbox.

This means you can run multiple sandy sessions across different projects simultaneously, each with its own plugins, memory, context, and installed tools — just like activating different Python venvs.

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

Sandy loads config from two levels, with project overriding user:

1. **User-level**: `~/.sandy/config` and `~/.sandy/.secrets` — apply to all projects on this machine
2. **Per-project**: `.sandy/config` and `.sandy/.secrets` — override user-level for this project

```bash
# ~/.sandy/config — user-level defaults for all projects
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-...       # long-lived token (better in ~/.sandy/.secrets)

# .sandy/config — per-project overrides
SANDY_SSH=agent                          # use SSH agent instead of gh token
SANDY_MODEL=claude-sonnet-4-5-20250929   # override default model
```

Only allowlisted `KEY=VALUE` lines are parsed (not sourced as a shell script). Use `.secrets` files for credentials — they should not be committed. See the environment variables table below for supported keys.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SANDY_AGENT` | `claude` | AI agent to run: `claude` (Claude Code), `gemini` (Gemini CLI), or `both` (dual-pane tmux with Claude on the left and Gemini on the right) |
| `SANDY_MODEL` | `claude-opus-4-6` | Claude model to use (applies to `claude` / `both`) |
| `GEMINI_API_KEY` | (unset) | Google API key for Gemini CLI. Put in `.sandy/.secrets` |
| `GEMINI_MODEL` | (unset) | Gemini model override |
| `SANDY_GEMINI_AUTH` | `auto` | Force Gemini auth path: `auto`, `api_key`, `oauth`, or `adc` |
| `SANDY_GEMINI_EXTENSIONS` | (unset) | Comma-separated Gemini extension URLs/paths to install on first launch |
| `GOOGLE_CLOUD_PROJECT` | (unset) | GCP project ID (Vertex AI) |
| `GOOGLE_CLOUD_LOCATION` | (unset) | GCP region (Vertex AI) |
| `GOOGLE_GENAI_USE_VERTEXAI` | (unset) | Set `true` to route Gemini through Vertex AI |
| `SANDY_CHANNEL_TARGET_PANE` | `0` | tmux pane target for Telegram relay in dual-agent mode (`0` = Claude, `1` = Gemini) |
| `SANDY_SSH` | `token` | Git auth method: `token` (gh CLI + HTTPS) or `agent` (SSH agent forwarding) |
| `SANDY_SKIP_PERMISSIONS` | `true` | Set to `false` to keep Claude Code's permission system active |
| `SANDY_HOME` | `~/.sandy` | Sandy config/build/sandbox directory |
| `SANDY_CPUS` | auto-detected | CPU limit for the container |
| `SANDY_MEM` | auto-detected | Memory limit for the container |
| `SANDY_ALLOW_LAN_HOSTS` | (unset) | Comma-separated IPs/CIDRs to allow through LAN isolation (e.g. `192.168.1.50,10.0.0.0/24`) |
| `SANDY_ALLOW_NO_ISOLATION` | (unset) | Set to `1` to allow launch without iptables rules (Linux) |
| `CLAUDE_CODE_OAUTH_TOKEN` | (unset) | Long-lived OAuth token from `claude setup-token`. Put in `.sandy/.secrets`. Recommended for headless servers |
| `ANTHROPIC_API_KEY` | (unset) | API key — not needed with Claude Pro/Max (OAuth) |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | Max output tokens per response (Claude Code default is 32K) |
| `SANDY_SKILL_PACKS` | (unset) | Comma-separated skill packs to install (e.g. `gstack`). Built as a cached Docker layer |
| `SANDY_GPU` | (disabled) | GPU passthrough: `all` for all GPUs, or device IDs like `0` or `0,1`. Requires [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) |
| `SANDY_CHANNELS` | (unset) | Channel plugins to enable (e.g. `plugin:telegram@claude-plugins-official`) |
| `TELEGRAM_BOT_TOKEN` | (unset) | Telegram bot token (from BotFather). Put in `.sandy/.secrets`, not `.sandy/config` |
| `TELEGRAM_ALLOWED_SENDERS` | (unset) | Comma-separated Telegram user IDs for allowlist (e.g. `123456,789012`) |
| `DISCORD_BOT_TOKEN` | (unset) | Discord bot token. Put in `.sandy/.secrets`, not `.sandy/config` |
| `DISCORD_ALLOWED_SENDERS` | (unset) | Comma-separated Discord user IDs for allowlist |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | (unset) | Set to `1` to enable experimental agent teams |

### Flags

| Flag | Description |
|---|---|
| `--new` | Start a fresh session (default: resume last) |
| `--resume` | Open session picker (forwarded to claude) |
| `--remote` | Start in [remote-control](https://code.claude.com/docs/en/remote-control) server mode (connect from browser/phone) |
| `--rebuild` | Force rebuild of the Docker image |
| `--build-only` | Build images and exit (for CI) |
| `--upgrade` | Update sandy to the latest version from GitHub |
| `-p "prompt"` | One-shot prompt (no interactive session) |

All other arguments are forwarded to `claude`.

### Headless / remote servers

**Recommended**: Use a long-lived token (valid 1 year) to avoid OAuth expiry entirely:

1. On a machine with a browser, run: `claude setup-token`
2. Copy the token and add to `~/.sandy/.secrets` on the headless server (applies to all projects):
   ```
   CLAUDE_CODE_OAUTH_TOKEN=your_token_here
   ```
3. Run `sandy` — no browser needed, no `/login` needed

**Fallback** (without a long-lived token): Sandy skips the browser-based OAuth flow on Linux and directs you to use `/login` inside the session.

The `/login` URL is long and Claude Code wraps it with indentation, which breaks copy-paste. To work around this on macOS:

1. Select the wrapped URL text in your terminal and copy it (Cmd+C)
2. Clean and open it with: `pbpaste | tr -d ' \n\t' | xargs open`

To automate this as a global keyboard shortcut (e.g., Ctrl+Cmd+U):

1. Open **Automator** > File > New > **Quick Action**
2. Set "Workflow receives" to **no input** in **any application**
3. Add a **Run Shell Script** action with: `pbpaste | tr -d ' \n\t' | xargs open`
4. Save as "Open Cleaned URL"
5. Assign a shortcut in **System Settings > Keyboard > Keyboard Shortcuts > Services**

### Running Gemini CLI (`SANDY_AGENT=gemini`)

Sandy supports four Gemini auth paths, probed automatically unless `SANDY_GEMINI_AUTH` pins a specific one:

| Path | How to set up | When to use |
|---|---|---|
| API key | `GEMINI_API_KEY=...` in `.sandy/.secrets` | Simplest; works on headless servers |
| OAuth | Run `gemini auth` **on the host** once — sandy copies `~/.gemini/tokens.json` into the container ephemerally on each launch | Free-tier Gemini with browser login |
| ADC | `gcloud auth application-default login` on the host | Google Cloud / Vertex AI workflows |
| Vertex AI | ADC + `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT=...`, `GOOGLE_CLOUD_LOCATION=...` | Enterprise / Vertex billing |

`gemini auth` must be run on the host because the container is headless and cannot open a browser. `--remote` is not supported with `gemini` or `both` — Gemini CLI has no native WebSocket/daemon mode.

### Dual-agent mode (`SANDY_AGENT=both`)

Runs Claude Code and Gemini CLI side-by-side in a single tmux session with a horizontal split (Claude left, Gemini right). Both credentials are loaded, both share the same workspace mount, and each agent has its own config at `~/.claude` and `~/.gemini` respectively. Exiting one pane leaves the other running.

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

Two plugin marketplaces are pre-configured in every sandbox: [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) and [sandy-plugins](https://github.com/rappdw/sandy-plugins). Browse and install plugins with:

```
/plugin                                    # browse available plugins
/plugin install synthkit@thinkkit          # install a plugin
/plugin update                             # update installed plugins
```

**Known issue — slash command autocomplete**: Plugin skills (e.g. `/boardroom`, `/md2pdf`) are lazy-loaded by Claude Code and won't appear in slash command autocomplete until invoked once — either by typing the request naturally (e.g. "run a boardroom debate about X") or via the fully qualified name (e.g. `synthkit:boardroom`). After first invocation, they appear in autocomplete for the rest of the session. This is a [known Claude Code bug](https://github.com/anthropics/claude-code/issues/18949) — the slash command resolver only indexes the legacy `commands/` system and ignores `skills/` entries (despite commands being [merged into skills](https://code.claude.com/docs/en/skills.md)).

### Skill packs

Skill packs are optional Docker image layers that bake curated skill collections into the container. They're not included by default — enable them per-project and they're built once, cached, and instantly available on subsequent launches.

```bash
# .sandy/config
SANDY_SKILL_PACKS=gstack
```

| Pack | Description | Source |
|------|-------------|--------|
| `gstack` | 28 Claude Code skills (QA, review, ship, browse, etc.) + headless Chromium browser engine | [garrytan/gstack](https://github.com/garrytan/gstack) |

First launch with a new skill pack takes a few minutes (downloading, compiling, installing Chromium). After that, launches are instant — everything is cached in a Docker image layer. Sandy auto-checks for newer skill pack releases on each launch and rebuilds when updates are available.

Skills are automatically discovered by Claude Code at session start. Skill pack `bin/` directories are added to PATH.

### GPU support

Sandy can pass host GPUs into the container for ML/AI workloads. This requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) installed on the host.

Enable via environment variable or `.sandy/config`:

```bash
# .sandy/config
SANDY_GPU=all          # all GPUs
SANDY_GPU=0            # specific GPU
SANDY_GPU=0,1          # multiple GPUs
```

The sandy base image does not include CUDA. Use `.sandy/Dockerfile` to layer GPU tools for projects that need them (see [`examples/gpu/Dockerfile`](examples/gpu/Dockerfile) for a ready-to-copy starting point). The per-project image is cached and only rebuilds when `.sandy/Dockerfile` changes.

**Example — CUDA + Python ML (works on x86_64 and arm64, including DGX Spark):**

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Add NVIDIA CUDA apt repository (arch-aware — maps aarch64 to sbsa for Debian)
RUN CUDA_ARCH="$(uname -m)"; [ "$CUDA_ARCH" = "aarch64" ] && CUDA_ARCH="sbsa"; \
    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/debian12/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb" \
        -o /tmp/cuda-keyring.deb \
    && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-toolkit \
    && rm -rf /var/lib/apt/lists/*
```

For a lighter setup that skips system CUDA and uses pre-built wheels:

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN pip install --user torch torchvision torchaudio
```

**Platform notes:**
- **x86_64**: Standard NVIDIA GPUs (RTX, A100, H100, etc.) — fully supported
- **arm64 / DGX Spark**: Grace Blackwell architecture — fully supported (base image and CUDA repo are multi-arch)
- **macOS**: Docker Desktop does not support GPU passthrough; `SANDY_GPU` has no effect

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
ARG QUARTO_VERSION=1.9.36
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

**Clipboard**: Sandy's tmux uses OSC 52 to copy mouse selections to the system clipboard. In iTerm2, enable this under **Settings > General > Selection > "Applications in terminal may access clipboard"**. With this enabled, click-drag selections in the container are automatically copied to your Mac clipboard.

## Channels (Telegram, Discord)

Sandy supports [Claude Code channels](https://code.claude.com/docs/en/channels) — push messages from Telegram or Discord into your running session. Sandy auto-installs the channel plugin and seeds credentials on startup.

### Quick setup (Telegram)

1. Create a bot via [BotFather](https://t.me/BotFather) and copy the token
2. Add to `.sandy/.secrets` (gitignored):
   ```
   TELEGRAM_BOT_TOKEN=123456789:AAH...
   TELEGRAM_ALLOWED_SENDERS=your_telegram_user_id
   ```
3. Add to `.sandy/config`:
   ```
   SANDY_CHANNELS=plugin:telegram@claude-plugins-official
   ```
4. Run `sandy` — the plugin is auto-installed, credentials are seeded, and Claude starts with the channel active

To find your Telegram user ID, message [@userinfobot](https://t.me/userinfobot). If `TELEGRAM_ALLOWED_SENDERS` is omitted, sandy starts in `pairing` mode — DM your bot, then run `/telegram:access pair <code>` inside the session.

### Quick setup (Discord)

1. Create an application at the [Discord Developer Portal](https://discord.com/developers/applications)
2. In the **Bot** section, create a bot, reset the token, and copy it
3. Enable **Message Content Intent** under **Privileged Gateway Intents**
4. Use **OAuth2 > URL Generator** with the `bot` scope and these permissions: View Channels, Send Messages, Send Messages in Threads, Read Message History, Attach Files, Add Reactions. Open the generated URL to invite the bot to your server.
5. Add to `.sandy/.secrets` (gitignored):
   ```
   DISCORD_BOT_TOKEN=your_discord_bot_token
   DISCORD_ALLOWED_SENDERS=your_discord_user_id
   ```
6. Add to `.sandy/config`:
   ```
   SANDY_CHANNELS=plugin:discord@claude-plugins-official
   ```
7. Run `sandy` — the plugin is auto-installed, credentials are seeded, and Claude starts with the channel active

If `DISCORD_ALLOWED_SENDERS` is omitted, sandy starts in `pairing` mode — DM your bot, then run `/discord:access pair <code>` inside the session.

### Using both channels

Set both tokens in `.sandy/.secrets` and list both plugins in `.sandy/config`:

```
SANDY_CHANNELS=plugin:telegram@claude-plugins-official plugin:discord@claude-plugins-official
```

### Channels with Gemini / dual-agent mode

When `SANDY_AGENT` is `gemini` or `both`, sandy uses a **host-side Telegram relay** instead of the in-container plugin — it long-polls the Telegram Bot API on the host and injects messages into the container's tmux session via `docker exec … tmux send-keys`. This is agent-agnostic but lower-fidelity: no chat threading, no edit-message updates, no attachments. Set `SANDY_CHANNEL_TARGET_PANE=1` to route messages to the Gemini pane in dual mode (default is pane 0 = Claude). Discord via relay is not supported yet — use `SANDY_AGENT=claude` for Discord.

### Per-project secrets

`.sandy/.secrets` uses the same `KEY=VALUE` format as `.sandy/config` but is intended for credentials. Add it to `.gitignore`:

```
.sandy/.secrets
```

## Security Notes

- The container runs as a non-root user (`claude`, mapped to host UID)
- The root filesystem is read-only (`/tmp` and `/home/claude` are tmpfs)
- `no-new-privileges` prevents privilege escalation
- Credentials are seeded into per-project sandboxes, not shared across projects
- The working directory is bind-mounted read/write — Claude can modify your files there (that's the point)
### Protected files and directories

The workspace is bind-mounted read/write so Claude can modify your project files. However, certain files and directories are overlaid with read-only or sandbox mounts to block the most dangerous attack vectors for an AI coding agent: shell config injection, git hook injection, and tool config tampering.

**Read-only mounts** — host content is visible but cannot be modified:

| Path | Why |
|---|---|
| `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile` | Blocks shell config injection (e.g. aliases, PATH hijacking) |
| `.gitconfig` | Blocks git config tampering (e.g. credential helpers, aliases) |
| `.ripgreprc` | Blocks search config injection |
| `.mcp.json` | Blocks MCP server config tampering |
| `.git/config` | Blocks git remote/hook path manipulation |
| `.gitmodules` | Blocks submodule URL hijacking |
| `.git/hooks/` | Blocks git hook injection (pre-commit, post-checkout, etc.) |
| `.vscode/`, `.idea/` | Blocks IDE task/launch config injection |

**Sandbox-mounted directories** — overlaid with writable sandbox copies so Claude can create and modify them without touching the host:

| Path | Behavior |
|---|---|
| `.claude/commands/` | Starts empty. Claude can create new slash commands |
| `.claude/agents/` | Starts empty. Claude can create new agents |
| `.claude/plugins/` | Starts empty. Managed via `/plugin install` inside the container |

Files that don't exist in the workspace are skipped — no empty placeholders are created