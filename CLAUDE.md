# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Keeping Documentation in Sync

When modifying the `sandy` script, update `SPECIFICATION.md` to reflect any changes to behavior, flags, configuration, generated files, runtime parameters, JSON schemas, or platform-specific logic. The spec has five appendices (A–E) with implementation-level detail — these must stay accurate:

- **Appendix A** (Generated File Templates): Update when Dockerfile content, entrypoint.sh, user-setup.sh, or tmux.conf changes
- **Appendix B** (Runtime Parameters): Update when timeouts, limits, permissions, default values, or tool versions change
- **Appendix C** (JSON Schemas): Update when settings.json, access.json, .claude.json, or credentials handling changes
- **Appendix D** (Platform-Specific Behavior): Update when Linux/macOS divergence points change
- **Appendix E** (Container Launch Assembly): Update when docker run flags, mounts, or environment variables change

Also update `README.md` and this file (`CLAUDE.md`) if user-facing behavior changes. Run `test/run-tests.sh` to verify test assertions still match.

## What This Is

`sandy` — an isolated sibling for your coding agents. A self-contained command that runs Claude Code, Gemini CLI, OpenAI Codex CLI (or any combination side-by-side) in a Docker sandbox with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes.

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

## Testing

Tests require Docker and built sandy images, so they must be run **outside** of sandy's isolation (i.e., on the host, not inside a sandy container). The test suite needs direct access to Docker to build and inspect images.

```sh
bash test/run-tests.sh              # pure-script tests (needs Docker + built images)
bash test/run-integration-tests.sh  # headless end-to-end (needs Docker + API keys)
```

Since Claude Code running inside sandy cannot access Docker, running tests requires the user to execute them manually on the host. When making changes to the `sandy` script or tests, ask the user to run the test suite and share the results.

See `TESTING_PLAN.md` for manual validation steps that require interactive TUI sessions.

## Per-project Configuration

Create `.sandy/config` in any project directory to set per-project defaults:

```sh
SANDY_SSH=agent                          # use SSH agent forwarding
SANDY_MODEL=claude-sonnet-4-5-20250929   # override model
```

This file is parsed as plain `KEY=VALUE` lines (not sourced — no shell code execution). Values are validated against an allowlist of recognized variables.

### Config tiers (1.0-rc1)

Sandy loads configuration from four sources in order: `$HOME/.sandy/config`, `$HOME/.sandy/.secrets`, `$WORK_DIR/.sandy/config`, `$WORK_DIR/.sandy/.secrets`. The first two are **privileged** sources — they can set any recognized key. The last two are **passive** sources (workspace-local, committable to version control) — they can only set a restricted subset of keys freely; any attempt to set a **privileged-only** key from a workspace triggers an interactive approval prompt the first time and is remembered per workspace.

- **Privileged-only keys** (require per-workspace approval when set from a passive source): `SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`. These would let a malicious `.sandy/config` committed to a repo disable isolation or exfiltrate credentials, so sandy collects them, prints the exact `KEY=VALUE` set, and asks for explicit approval before honoring them. Approvals are persisted to `$SANDY_HOME/approvals/passive-<workspace-hash>.list` (first line is a sha256 of the sorted `KEY=VALUE` set). Subsequent launches with the same set are silent; any edit to `.sandy/config` that changes a privileged key re-prompts. Revoke with `rm $SANDY_HOME/approvals/passive-<hash>.list`. Headless mode (`-p`/`--print`/`--prompt`) and non-TTY stdin fail closed — the keys are dropped with a pointer to "launch sandy interactively once from this directory to approve."

**CI / test harness escape hatch:** set `SANDY_AUTO_APPROVE_PRIVILEGED=1` in the environment (not in any config file) to bypass the prompt entirely and export all collected passive privileged keys in-memory. This is intentionally env-only — the passive config allowlist does not include `SANDY_AUTO_APPROVE_PRIVILEGED`, so a committed `.sandy/config` cannot set it. Only a trusted shell or test harness can. Sandy's own `test/run-tests.sh` and `test/run-integration-tests.sh` set this because they run from the sandy repo directory, which has its own `.sandy/.secrets` with `GEMINI_API_KEY`.
- **Passive-safe keys** (allowed from any source): `SANDY_AGENT`, `SANDY_MODEL`, `SANDY_CPUS`, `SANDY_MEM`, `SANDY_GPU`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS`, `SANDY_CHANNEL_TARGET_PANE`, `SANDY_VERBOSE`, `SANDY_VENV_OVERLAY`, `SANDY_ALLOW_WORKFLOW_EDIT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `GEMINI_MODEL`, `SANDY_GEMINI_AUTH`, `SANDY_GEMINI_EXTENSIONS`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI`, `CODEX_MODEL`, `SANDY_CODEX_AUTH`, `CODEX_HOME`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`.

Additionally, `SANDY_ALLOW_LAN_HOSTS` is validated at use-site to reject world-open entries (`0.0.0.0/0`, `::/0`) with a hard error at launch — even when set from a privileged source.

## Agent Selection

Sandy supports Claude Code (default), Gemini CLI, OpenAI Codex CLI, or **any combination side-by-side in multi-pane tmux**, selectable per-project via `SANDY_AGENT` in `.sandy/config`:

```sh
SANDY_AGENT=gemini              # single agent: claude (default), gemini, codex
SANDY_AGENT=claude,codex        # any comma-separated combo (2 or 3 agents)
SANDY_AGENT=claude,gemini,codex # all three in a 3-pane layout
SANDY_AGENT=all                 # alias for claude,gemini,codex
```

Single-agent modes use their own Docker images (`sandy-claude-code`, `sandy-gemini-cli`, `sandy-codex`); multi-agent combos use `sandy-full` (which includes all three agents). All share the common `sandy-base`. Gemini CLI and Codex CLI are installed via `npm install -g @google/gemini-cli` and `npm install -g @openai/codex` respectively. Gemini launches with `GEMINI_SANDBOX=false`; Codex launches with `--sandbox danger-full-access` plus `sandbox_mode = "danger-full-access"` in its `config.toml` (belt-and-suspenders — codex's Landlock sandbox does not nest cleanly in Docker, and sandy already provides whole-session isolation). The sandbox directory has sibling `claude/`, `gemini/`, and `codex/` subdirs mounted at `~/.claude`, `~/.gemini`, and `~/.codex` respectively; v1 layouts with `settings.json` at the sandbox top level are auto-migrated on launch.

**Gemini credentials** are probed in this order (override via `SANDY_GEMINI_AUTH=auto|api_key|oauth|adc`): `GEMINI_API_KEY` env var, host `~/.gemini/tokens.json` (copied ephemerally), host `~/.config/gcloud/application_default_credentials.json` (Google ADC / Vertex AI).

**Codex credentials** are probed in this order (override via `SANDY_CODEX_AUTH=auto|api_key|oauth`): `OPENAI_API_KEY` env var (what codex CLI reads natively), host `~/.codex/auth.json` (copied ephemerally and mounted **read-only** — prevents token leakage back to host and prevents stale-token races). Because `auth.json` is mounted read-only, in-session OAuth refresh will fail — users must re-login inside the container if the token expires. On first launch, sandy seeds `~/.codex/config.toml` with `model = "gpt-5.4"`, `sandbox_mode = "danger-full-access"`, and a full `[notice]` block to suppress all first-run prompts; a `[projects."$SANDY_WORKSPACE"] trust_level = "trusted"` entry is appended at session start by `user-setup.sh` (it needs the container-side workspace path).

**Feature support by agent**:

| Feature | `claude` | `gemini` | `codex` | multi-agent |
|---|---|---|---|---|
| Skill packs | yes | — | — | yes (claude pane only) |
| Synthkit commands | yes (slash commands, Markdown) | yes (slash commands, TOML in `~/.gemini/commands/`) | yes (skills context, SKILL.md in `~/.codex/skills/` — invoked via natural language, not `/`) | per agent |
| Channels (Telegram) | in-container plugin | host-side tmux relay | host-side tmux relay | host-side tmux relay |
| Channels (Discord) | yes | — | — | — |
| `--remote` | yes | — | — | — |
| Gemini extensions (`SANDY_GEMINI_EXTENSIONS`) | — | yes | — | yes (when gemini is in the combo) |

Codex headless mode (`-p` / `--print` / `--prompt`) translates to `codex exec` — the prompt is passed as a positional arg, not a flag. Codex `exec` only returns exit codes 0 or 1 (no nuanced exit codes like Claude's `--print` has). `--continue` / `-c` is silently dropped (codex has `codex resume` but no headless continuation flag). Multi-agent combos use comma-separated syntax (e.g., `claude,codex`); `all` is an alias for `claude,gemini,codex`. The old `both` alias was removed in `v0.12` — sandy now errors out with a pointer to the comma-separated syntax.

The Telegram host-side relay (`$SANDY_HOME/channel-relay.sh`) is an agent-agnostic long-polling bridge that injects messages into the container's tmux session via `docker exec ... tmux send-keys`. In multi-agent mode, `SANDY_CHANNEL_TARGET_PANE=0|1|2` selects which pane receives messages (default `0` = first pane in `SANDY_AGENT`).

## Per-project Sandboxes

Each project directory gets its own isolated `~/.claude` sandbox under `~/.sandy/sandboxes/`, named with a mnemonic prefix and hash (e.g. `myproject-a1b2c3d4`). `.claude.json` is seeded from the host's `~/.claude/` on first run. `settings.json` is regenerated on **every launch** at `$SANDBOX_DIR/claude/settings.json` (inside the rw sandbox mount) with merge-preserving semantics: sandy re-reads the host copy every launch so host-side edits propagate, but preserves `enabledPlugins` from the previous sandbox session so `/plugin install` survives across launches. The file is rw inside the container — the stricter `:ro` sidecar approach from pre-0.11.3 broke plugin installs with EROFS, so it was reverted. The trade-off: the agent *can* mutate its own settings within a session, but the sandy-managed keys (`extraKnownMarketplaces`, `teammateMode`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, cmux hooks) are re-overwritten every launch. Credentials (`.credentials.json`) are read fresh from the host each launch and mounted ephemerally — never persisted to the sandbox.

### Sandbox version tracking

On creation, each sandbox gets a `.sandy_created_version` file recording the sandy version that created it; `.sandy_last_version` is refreshed on every launch. On launch, sandy compares the created-version against `SANDY_SANDBOX_MIN_COMPAT` (currently `0.7.10`) and warns if the sandbox pre-dates a known breaking change. Sandboxes with no marker file pre-date the tracking itself and are warned about conservatively.

The current breaking-change threshold is the workspace mount path change (c99eb97, v0.7.10): sandy now mounts the workspace at `/home/claude/<rel>` instead of `/workspace`. Sandboxes created before that carry cached absolute paths inside venvs (`pyvenv.cfg`, `.pth` files, editable installs) and Python package caches that reference `/workspace/...` and silently break inside the new layout. Fix: `rm -rf ~/.sandy/sandboxes/<name> && sandy --rebuild`.

When introducing further sandbox-incompatible changes, bump `SANDY_SANDBOX_MIN_COMPAT` in the sandy script so users get a warning on their next launch.

### Workspace `.venv` overlay

Projects that use `uv venv` or `python -m venv` on the host create a `.venv/` whose `bin/python` is a symlink to a host-only interpreter path (e.g. `/Users/you/.local/share/uv/python/cpython-3.10-macos-aarch64/bin/python3.10`). That symlink is broken inside sandy's Linux container, and any attempt to use the venv fails — worse, a subsequent `uv pip install` would recreate `.venv` from scratch and wipe its `site-packages`.

Sandy solves this by bind-mounting a sandbox-owned overlay over `$WORKSPACE/.venv` inside the container. The host venv is shadowed (not modified); the container sees an independently-managed venv that uses a Linux interpreter matching the host's Python version.

**How it works:**

1. On launch, sandy checks `$WORK_DIR/.venv` on the host. If it exists and is not a symlink, sandy creates `$SANDBOX_DIR/venv/` and bind-mounts it at `$WORKSPACE/.venv` inside the container. Sandy learns the host's wanted Python version from `.python-version` if present (authoritative — user-maintained), falling back to parsing `pyvenv.cfg` if not, and passes the result via `SANDY_VENV_PYTHON_VERSION`. The parsed value must match `^[0-9]+\.[0-9]+$` — garbage is dropped and the container falls back to its default. A symlinked `.venv/` is skipped with an explicit info message (symlinks can point anywhere and overlaying them is too risky).
2. On first launch, the overlay dir is empty. The entrypoint runs `uv python install <version>` and `uv venv --clear --python <version> $WORKSPACE/.venv` to materialize a fresh venv. (`--clear` is required because the bind-mount target always exists, and uv venv otherwise refuses with "A directory already exists at: .venv".) The user then runs `uv sync` / `uv pip install -e .` / `pip install -r requirements.txt` once to populate it. No in-container locking is needed — the host-side workspace mutex (see "Concurrent launches" below) guarantees exclusive access.
3. On subsequent launches, the overlay is already populated — the entrypoint skips materialization and goes straight to activation (`VIRTUAL_ENV` + PATH prepend). Persistence is free via the bind mount. Before activation, the entrypoint compares the overlay's actual `pyvenv.cfg` version against `SANDY_VENV_PYTHON_VERSION`; on mismatch (e.g. the user bumped `.python-version` after the overlay was built), sandy prints a drift warning with the recreate command. Auto-recreate is deliberately not done — it would silently nuke installed packages.

**Opt out** with `SANDY_VENV_OVERLAY=0` in `.sandy/config`. The fallback is warn-only: sandy prints a message explaining that the host venv's interpreter isn't reachable inside the container and suggests `rm -rf .venv && uv venv && uv pip install -e .` — but that's destructive to the host venv and rarely what you want.

**Non-standard venv names** (`venv/`, `.venv-py311/`, etc.) are not overlaid — only the standard `.venv/` is. The fallback warn-only path still applies to any dangling `.venv/bin/python` symlink in those layouts.

**Host venv is never touched.** The overlay is a shadow — the host filesystem is untouched by sandy. After sandy exits, the host's `.venv/` is exactly as it was before.

**Concurrent launches.** Only one sandy may run against a given workspace at a time. On launch, sandy takes a workspace mutex (`mkdir` on `$SANDY_HOME/sandboxes/.<name>.lock`, which is atomic on every POSIX filesystem and needs no external dependency). A second launch against the same workspace fails fast with a clear error naming the holding pid and the command to clear a stale lock (e.g. after a `kill -9`). Two agents editing the same codebase would step on each other's edits anyway — use separate workspaces for parallel work.

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
| `gstack` | 28 Claude Code skills (QA, review, ship, browse, etc.) + headless Chromium browser engine | [garrytan/gstack](https://github.com/garrytan/gstack) |

### How It Works

Skill packs add two build phases (Phase 2.5a and 2.5b) between the Claude Code image and the optional per-project image:

- **Phase 2.5a — Base image** (`sandy-skills-base-{pack}`): Installs heavy, rarely-changing dependencies like Playwright and Chromium. This image is cached and only rebuilds when the base Dockerfile changes.
- **Phase 2.5b — Code image** (`sandy-skills-{pack}`): Downloads the skill pack source at a pinned version, runs `bun install` and `bun run build`. This layer rebuilds when a new version is detected, but is fast since Chromium is already in the base.

At container startup, `user-setup.sh` symlinks `/opt/skills/{pack}/` into `~/.claude/skills/` so Claude Code discovers the skills automatically. Skill pack `bin/` directories are added to PATH.

First build takes a few minutes (downloading Chromium). Subsequent version updates rebuild only the code layer and are much faster.

### Version Resolution

Skill pack versions are resolved dynamically from GitHub on each launch — there is no hardcoded version pin. The resolution order is:

1. **GitHub releases API** — fetches the latest non-draft, non-prerelease tag matching the pack's tag prefix (if configured). 5-second timeout.
2. **GitHub commits API** — if no releases exist or no tag prefix is set, fetches the latest commit SHA on the default branch.
3. **Local cache** — `~/.sandy/.skill_version_{pack}` stores the last successfully resolved version.
4. **Hardcoded fallback** — `SKILL_PACK_VERSIONS` array in the sandy script, used only on first run if GitHub is unreachable.

When a new version is detected, `Dockerfile.skills` is regenerated with the updated version. The content hash changes, which triggers a rebuild of the code image (Phase 2.5b) automatically. The base image (Phase 2.5a) is unaffected.

### Adding New Packs

Add entries to `SKILL_PACK_NAMES`, `SKILL_PACK_REPOS`, `SKILL_PACK_VERSIONS`, and `SKILL_PACK_TAG_PREFIXES` arrays in the sandy script, then add a build recipe case in `generate_skill_pack_dockerfiles()`.

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

Per-instance Docker bridge networks are created with names keyed on PID (`sandy_net_$$`) to avoid races between concurrent sessions. On Linux, iptables DROP rules block RFC 1918 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and CGNAT/Tailscale (`100.64.0.0/10`), while allowing the container's own subnet. Rules are cleaned up on script exit.

**macOS limitation (1.0-rc1).** Docker Desktop's VM does *not* provide LAN isolation. Containers can reach `host.docker.internal` (→ host gateway), the host's `localhost` services, and any device on the user's physical LAN (`192.168.x.x`, home router, NAS, printers, internal dashboards). Linux iptables DROP rules are not applied and cannot be applied from macOS. As defense-in-depth, sandy nullifies the Docker Desktop magic hostnames (`gateway.docker.internal`, `metadata.google.internal`, and — when `SANDY_SSH!=agent` — `host.docker.internal`) via `--add-host … :127.0.0.1`, but raw-IP access is unaffected. Sandy prints a launch warning banner on macOS announcing that network isolation is not active. A full fix — an egress proxy sidecar that implements HTTP CONNECT + SOCKS5 + DNS allowlist — is scheduled for sandy 1.1. Until then, treat macOS sandy as "process and filesystem isolation only; no network isolation."

## Protected Files

Certain sensitive files and directories in the workspace are mounted read-only inside the container to prevent modification by the agent. This blocks shell config injection, git hook injection, IDE config tampering, language-toolchain hijacking, CI pipeline escapes, and git filter-driver injection.

**Protected files**: `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile`, `.gitconfig`, `.ripgreprc`, `.mcp.json`, `.envrc`, `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml`

**Protected git files** (only mounted when present on host): `.git/config`, `.gitmodules`, `.git/HEAD`, `.git/packed-refs`

**Protected directories**: `.git/hooks/`, `.git/info/`, `.vscode/`, `.idea/`, `.github/workflows/`, `.circleci/`, `.devcontainer/`

**Submodule gitdirs**: sandy walks `.git/modules/` (and the gitdir-side `modules/` for `--separate-git-dir` / worktree-of-submodule layouts) and mounts each submodule's `config`, `hooks/`, and `info/` read-only. Without this, a planted `post-checkout` hook in `.git/modules/<sub>/hooks/` would execute on the host the next time `git submodule update` or `git pull --recurse-submodules` ran (Critical escape, F1 in ISOLATION_STRESS.md).

**Sandbox-mounted directories**: `.claude/commands/`, `.claude/agents/`, `.claude/plugins/` — these are overlaid with writable sandbox copies so Claude can create and modify commands, agents, and plugins without touching the host. All three start empty; plugins are managed via `/plugin install`.

**Mount policy (1.0-rc1).** Protected **directories** are always-mounted: if the host has no corresponding directory, sandy mounts an empty directory (`$SANDY_HOME/.empty-ro-dir`) read-only at that path, closing the existence-gated bypass for `.vscode/`, `.github/workflows/`, etc. Docker's bind-mount target auto-creation leaves empty stub dirs on the host — sandy records every stub it creates this session in `$SANDBOX_DIR/.session-created-stubs` and `rmdir`s them in the cleanup trap on exit (the `rmdir` no-ops on populated dirs, so it's safe if the user or agent legitimately wrote into one). At launch, sandy also auto-cleans pre-existing empty stubs left by earlier sandy versions under a 4-condition safety gate: workspace is a git repo, dir name matches the protected-dirs list exactly, dir is empty, dir isn't git-tracked. This handles one-shot migration for projects that accumulated debris before this cleanup pass existed. Protected **files** are **existence-gated**: if the host has no `.bashrc`/`.envrc`/etc., sandy adds no mount for that path. This is a regression from the original plan (which also always-mounted files), because Docker's bind-mount target auto-creation semantics cause 0-byte stub files to materialize on the host workspace whenever a mount target doesn't exist under an rw bind — breaking direnv (blocks on empty `.envrc`), polluting `git status`, and tripping any tool that checks for file presence. The residual F3 gap for files is: an agent can create `.bashrc`/`.envrc`/etc. in-session if the host didn't have one. The mitigation is that the newly-created file is then visible in `git status` on the host for review, which is the detection path. Intentionally excluded from protection entirely: package manifests (`Makefile`, `package.json`, `pyproject.toml`, `Cargo.toml`, etc.) — the agent legitimately edits these, and they are invoked explicitly by name rather than sourced on `cd` or filesystem scan.

Sandy also detects leftover 0-byte stub files from earlier buggy builds of the always-mount pattern (untracked by git and matching the protected-files list) and prints a one-shot `rm` command to clean them up. File stubs are not auto-removed — a 0-byte file could be intentional, so the user runs the remediation command themselves. Directory stubs *are* auto-removed (the safety gate is stronger: empty + untracked + in a git repo + exact name match against the small protected-dirs list).

**`SANDY_ALLOW_WORKFLOW_EDIT`** (passive-safe): set to `1` in `.sandy/config` to remove `.github/workflows/` from the protection list for that project. Useful when the agent is doing legitimate CI work. Default is off — workflows are dangerous because the escape fires on `git push`, long after the session ends.

Protected files/directories are overlaid as read-only bind mounts at container launch. The host filesystem is unaffected.

### Persistent symlink approval (1.0-rc1)

Dangerous symlinks (absolute links, or relative links that escape the workspace via `..`) are surfaced to the user at launch. On first encounter sandy prints a y/N prompt listing each link and its target; on approval the set is persisted to `$SANDBOX_DIR/.sandy-approved-symlinks.list` (one `link<TAB>target` per line).

On subsequent launches:

- **Identical or reduced set** → proceed silently (symlink deletions update the list).
- **New escape present** → **hard error at launch**, naming the offending link(s), with remediation (`rm` the link, relaunch, re-approve). Sandy refuses to re-prompt — a y/N that fires every session can be trained past, whereas a hard error forces a deliberate action.

## Terminal Notifications

Sandy's inner tmux is configured with `allow-passthrough on`, which forwards OSC escape sequences (9/99/777) from Claude Code through to the outer terminal. This enables notification features in terminals like cmux and iTerm2.

Host-side Claude Code hooks (`~/.claude/hooks/`) are mounted read-only into the container at `/home/claude/.claude/hooks/`. This allows hooks configured on the host (e.g., cmux notification hooks) to work inside sandy without duplication.
