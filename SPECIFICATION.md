# Sandy Specification

**Version**: 0.11.4
**Date**: 2026-04-20
**Source**: ~3,150-line bash script (`sandy`), installer (`install.sh`), test suite (`test/run-tests.sh`)

Sandy is a self-contained command that runs an AI coding agent (Claude Code, Gemini CLI, OpenAI Codex CLI, or any comma-separated multi-agent combo) in a Docker container with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes. One script, one command, zero configuration required.

### Supported Agents

| `SANDY_AGENT` | Image | Description |
|---|---|---|
| `claude` (default) | `sandy-claude-code` | Claude Code — full feature support (channels, skill packs, synthkit, remote-control) |
| `gemini` | `sandy-gemini-cli` | Gemini CLI — Google OAuth / ADC / Vertex AI / API key auth |
| `codex` | `sandy-codex` | OpenAI Codex CLI — `OPENAI_API_KEY` env var or ChatGPT OAuth (read-only mount) |
| `<a>,<b>[,<c>]` (e.g. `claude,gemini`, `claude,codex`, `claude,gemini,codex`) | `sandy-full` | Multi-agent combo — one tmux pane per agent, in the order listed |
| `all` | `sandy-full` | Alias for `claude,gemini,codex` — all three agents in a 3-pane tmux session |

The previous `both` alias (= `claude,gemini`) was removed in `v0.12`. Using it now exits with an error pointing at the comma-separated syntax.

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

**Appendices (Implementation Detail)**

- A. [Generated File Templates](#appendix-a-generated-file-templates)
- B. [Runtime Parameters](#appendix-b-runtime-parameters)
- C. [JSON Schemas](#appendix-c-json-schemas)
- D. [Platform-Specific Behavior](#appendix-d-platform-specific-behavior)
- E. [Container Launch Assembly](#appendix-e-container-launch-assembly)

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

### Introspection Flags (machine-readable JSON)

All introspection flags are **fast-path handlers**: they run before image builds, sandbox setup, mutex acquisition, and docker availability checks, and exit immediately without side effects. This makes them safe to call from non-privileged UI processes, CI tooling, and headless contexts. Output is single-line JSON on stdout with `schema_version: 1`.

| Flag | Behavior |
|---|---|
| `--print-schema` | Emit the static sandy schema: version, config keys (by tier with type/default/description), CLI flags, agents and their credential probe orders, protected path lists, skill packs, schema compatibility declaration. Always exits 0. |
| `--print-state` | Emit runtime state: `sandy_home`, installed sandy images, per-sandbox metadata (`.sandy_created_version`, `.sandy_last_version`, size if cheaply obtainable), approval files (one per workspace hash), `docker_reachable` (bool), and running sandy containers (filtered by image name prefix). When Docker is unreachable, `docker_reachable: false` and `running_containers: null`. Always exits 0. |
| `--validate-config PATH` | Parse a config file, classify it as privileged (path under `$SANDY_HOME/`) or passive (anywhere else), and emit `{schema_version, path, source_tier, errors[], warnings[], unknown_keys[], privileged_keys_requiring_approval[], approval_status, approval_file_path}`. Exits 1 if the file does not exist or the flag was called with no argument; exits 0 otherwise (a "pending" approval is not an error — it's the normal state before first interactive approval). |

See `SPEC_INTROSPECTION.md` for field-by-field documentation and the stability contract (additive changes within schema_version=1, breaking changes bump the version).

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

1. `$SANDY_HOME/config` — user-level defaults (typically `~/.sandy/config`) — **privileged tier**
2. `$SANDY_HOME/.secrets` — user-level credentials — **privileged tier**
3. `.sandy/config` — per-project overrides — **passive tier**
4. `.sandy/.secrets` — per-project credentials — **passive tier**

Later files override earlier values, subject to tier restrictions below.

### Parser

The config parser does **not** use `source`. It reads lines via `grep -E '^[A-Z_]+=.+'`, strips leading/trailing single and double quotes from values (in order: double then single), validates the key against a tier-specific allowlist, and exports only recognized keys. Lines not matching the grep pattern are silently ignored — this includes comments (`#`), blank lines, and lowercase keys. If the config file is unreadable or missing, loading silently succeeds.

### Config Tiers (1.0-rc1)

Each call to `_load_sandy_config` takes a `tier` argument (`privileged` or `passive`). Privileged-tier sources may set any recognized key immediately. Passive-tier sources (the two workspace files) may set **passive-safe** keys immediately; any privileged-only key found in a passive source is **collected** into `_PASSIVE_PRIVILEGED_PENDING` rather than exported. After both passive sources load, `_resolve_passive_privileged_approval()` runs: it hashes the sorted `KEY=VALUE` set, checks `$SANDY_HOME/approvals/passive-<wd-hash>.list` (first line is the sha256 of the approved set), and either (a) silently exports if the hash matches, (b) prompts `y/N` on `/dev/tty` the first time with the exact KEY=VALUE list plus a rationale about repo-committed configs, or (c) fails closed in non-interactive mode (`_sandy_is_headless=true` or non-TTY stdin) with a pointer to "launch sandy interactively from this directory to approve." On approval, the file is written with the hash, a `# workspace:` comment, a `# approved:` timestamp, and the sorted KEY=VALUE lines, mode 600. Any edit to the workspace config that adds, removes, or changes a privileged key invalidates the hash and re-prompts on the next launch. Revocation is `rm` of the approval file. This prevents a malicious `.sandy/config` committed to a repo from disabling isolation, forwarding an SSH agent, or exfiltrating credentials without a deliberate, workspace-scoped user opt-in.

**CI / test-harness escape hatch**: `SANDY_AUTO_APPROVE_PRIVILEGED=1` in the process environment bypasses the prompt and exports the pending keys in-memory without writing an approval file. This is intentionally env-only — `SANDY_AUTO_APPROVE_PRIVILEGED` is not in the passive allowlist, so a committed `.sandy/config` cannot set it. Sandy's own `test/run-tests.sh` and `test/run-integration-tests.sh` set this flag at the top of each harness so the suites can run from the sandy repo directory (which carries a real `GEMINI_API_KEY` in `.sandy/.secrets` for integration testing) without blocking on stdin.

**Privileged-only keys** (allowed only from `$SANDY_HOME/config` and `$SANDY_HOME/.secrets`):
<!-- BEGIN AUTOGEN:privileged-key-list Run `test/regen-config-docs.sh` to update. -->
`SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`
<!-- END AUTOGEN:privileged-key-list -->

**Passive-safe keys** (allowed from any source):
<!-- BEGIN AUTOGEN:passive-key-list Run `test/regen-config-docs.sh` to update. -->
`SANDY_AGENT`, `SANDY_MODEL`, `SANDY_CPUS`, `SANDY_MEM`, `SANDY_GPU`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS`, `SANDY_CHANNEL_TARGET_PANE`, `SANDY_VERBOSE`, `SANDY_VENV_OVERLAY`, `SANDY_ALLOW_WORKFLOW_EDIT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `GEMINI_MODEL`, `SANDY_GEMINI_AUTH`, `SANDY_GEMINI_EXTENSIONS`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI`, `CODEX_MODEL`, `SANDY_CODEX_AUTH`, `CODEX_HOME`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`
<!-- END AUTOGEN:passive-key-list -->

### `SANDY_ALLOW_LAN_HOSTS` Sanity Check

After all config sources are loaded, `SANDY_ALLOW_LAN_HOSTS` (if set) is split on `,` and each entry is validated. Any entry matching `0.0.0.0/0` or `::/0` causes a hard error (`exit 1`) with a clear message. This check runs even against privileged-tier values — a user-level config with a world-open allowlist is almost always a mistake, and the launch refusal prevents silent negation of LAN isolation.

### Allowlisted Variables

The table below is generated from `sandy --print-schema` (the `_sandy_key_metadata` heredoc in the sandy script is the source of truth). Run `test/regen-config-docs.sh` after editing, adding, or retiering a key — `test/run-tests.sh` asserts the blocks are in sync.

<!-- BEGIN AUTOGEN:config-keys-table Run `test/regen-config-docs.sh` to update. -->
| Variable | Tier | Default | Description |
|---|---|---|---|
| `SANDY_SSH` | privileged | `token` | SSH auth mode: 'token' uses gh CLI (HTTPS); 'agent' forwards the host SSH agent. |
| `SANDY_SKIP_PERMISSIONS` | privileged | `true` | Skip Claude Code's in-session permission prompts (default: true). |
| `SANDY_ALLOW_NO_ISOLATION` | privileged | `0` | Allow launch when iptables rules cannot be applied (Linux only). |
| `SANDY_ALLOW_LAN_HOSTS` | privileged | unset | Comma-separated IPs/CIDRs to allow through LAN isolation. World-open entries rejected. |
| `ANTHROPIC_API_KEY` | privileged | unset | Anthropic API key for Claude Code. Not required when using Claude Max OAuth. |
| `CLAUDE_CODE_OAUTH_TOKEN` | privileged | unset | Claude Code OAuth token (alternative to ANTHROPIC_API_KEY). |
| `GEMINI_API_KEY` | privileged | unset | Google API key for Gemini CLI. |
| `OPENAI_API_KEY` | privileged | unset | OpenAI API key for Codex CLI. |
| `GOOGLE_API_KEY` | privileged | unset | Google API key for Vertex AI / ADC. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | privileged | unset | Enable Claude Code experimental agent-teams feature. |
| `SANDY_AGENT` | passive | `claude` | Agent(s) to launch. Comma-separated (e.g. 'claude,codex'). 'all' = 'claude,gemini,codex'. |
| `SANDY_MODEL` | passive | `claude-opus-4-7` | Model ID for the Claude agent. |
| `SANDY_CPUS` | passive | unset | CPU limit for container (default: auto-detected). |
| `SANDY_MEM` | passive | unset | Memory limit for container (e.g. '8g'; default: auto-detected). |
| `SANDY_GPU` | passive | unset | GPU passthrough: 'all', or device IDs like '0' / '0,1'. |
| `SANDY_SKILL_PACKS` | passive | unset | Comma-separated skill pack names (e.g. 'gstack'). |
| `SANDY_CHANNELS` | passive | unset | Comma-separated channel names (e.g. 'telegram,discord'). |
| `SANDY_CHANNEL_TARGET_PANE` | passive | `0` | Which tmux pane in multi-agent mode receives channel messages. |
| `SANDY_VERBOSE` | passive | `0` | Verbosity (0=quiet, 1=verbose, 2=debug, 3=full trace). |
| `SANDY_VENV_OVERLAY` | passive | `1` | Bind-mount a sandbox-owned .venv over the workspace's .venv inside the container. |
| `SANDY_ALLOW_WORKFLOW_EDIT` | passive | `0` | Remove .github/workflows from the read-only protection list. |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | passive | `128000` | Max output tokens per Claude response. |
| `GEMINI_MODEL` | passive | unset | Gemini model override. |
| `SANDY_GEMINI_AUTH` | passive | `auto` | Gemini credential probe strategy. |
| `SANDY_GEMINI_EXTENSIONS` | passive | unset | Comma-separated Gemini extensions to enable. |
| `GOOGLE_CLOUD_PROJECT` | passive | unset | Google Cloud project for Vertex AI. |
| `GOOGLE_CLOUD_LOCATION` | passive | unset | Google Cloud location for Vertex AI. |
| `GOOGLE_GENAI_USE_VERTEXAI` | passive | unset | Use Vertex AI backend for Gemini. |
| `CODEX_MODEL` | passive | unset | Codex model override. |
| `SANDY_CODEX_AUTH` | passive | `auto` | Codex credential probe strategy. |
| `CODEX_HOME` | passive | unset | Override CODEX_HOME inside the container. |
| `TELEGRAM_BOT_TOKEN` | passive | unset | Telegram bot token for the channel relay. |
| `TELEGRAM_ALLOWED_SENDERS` | passive | unset | Comma-separated Telegram user IDs allowed to send messages. |
| `DISCORD_BOT_TOKEN` | passive | unset | Discord bot token for the channel relay. |
| `DISCORD_ALLOWED_SENDERS` | passive | unset | Comma-separated Discord user IDs allowed to send messages. |
| `SANDY_AUTO_APPROVE_PRIVILEGED` | env-only | unset | Bypass the passive-privileged approval prompt. Intended for CI / test harnesses only. |
| `SANDY_DEBUG_CLEANUP` | env-only | unset | Print session-stub cleanup diagnostics on exit. |
<!-- END AUTOGEN:config-keys-table -->

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

As of v0.9.0, the sandbox directory contains **sibling** per-agent subdirs (`claude/`, `gemini/`, and `codex/` — the last added in v0.10.0) so any multi-agent combo can coexist in the same sandbox. Each subdir is mounted at `~/.claude`, `~/.gemini`, and `~/.codex` inside the container respectively.

```
~/.sandy/sandboxes/<name>-<hash>/
├── claude/                    # → /home/claude/.claude
│   ├── settings.json
│   ├── projects/
│   ├── plugins/
│   ├── statsig/
│   ├── channels/
│   ├── hooks/
│   └── history.jsonl
├── gemini/                    # → /home/claude/.gemini
│   ├── settings.json
│   ├── commands/              # TOML slash commands
│   ├── extensions/
│   └── tmp/                   # session history
├── codex/                     # → /home/claude/.codex
│   ├── config.toml            # sandbox_mode + [notice] + [projects] trust
│   ├── log/
│   ├── memories/
│   └── skills/                # SKILL.md files (synthkit seeds md2pdf etc.)
├── pip/                       # → /home/claude/.pip-packages
├── uv/                        # → /home/claude/.local/share/uv
├── npm-global/                # → /home/claude/.npm-global
├── go/                        # → /home/claude/go
├── cargo/                     # → /home/claude/.cargo
├── gstack/                    # legacy gstack state location; renamed to gstack.migrated/ on first 0.12+ launch
├── gstack.migrated/           # post-migration breadcrumb — safe to delete after verifying $WORK_DIR/.gstack/ works
├── workspace-commands/        # → .claude/commands/ (writable overlay)
├── workspace-agents/          # → .claude/agents/
└── workspace-plugins/         # → .claude/plugins/
```

`<NAME>.claude.json` is stored at `~/.sandy/sandboxes/<NAME>.claude.json` (outside the sandbox dir) to avoid mount conflicts.

**Layout migration (v1 → v1.5)**: On each launch, sandy detects the v1 layout marker (`settings.json` at the sandbox top level with no `claude/` subdir) and moves Claude-owned entries into `claude/`. Idempotent; pre-existing pkg-persistence and workspace-* directories are untouched.

### Seeding

Whenever `claude` is in `SANDY_AGENT`, sandy regenerates `<NAME>/claude/settings.json` **on every launch** (not just first run). As of 0.11.3 this is a plain rw file inside the sandbox mount — the pre-0.11.3 `:ro` sidecar overlay was reverted because it broke `/plugin install` with EROFS. The steps are:

1. Base: read host `~/.claude/settings.json` (or start from `{}` if absent).
2. Overlay: read the previous sandbox `<NAME>/claude/settings.json` (if it exists) and preserve `enabledPlugins` from it onto the base, so plugin installs survive across launches.
3. Merge sandy-required defaults (`teammateMode`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`) if not already present.
4. Merge `extraKnownMarketplaces` entries for `claude-plugins-official` and `sandy-plugins`; scrub deprecated entries (`thinkkit`, `ait`, `pka-skills`).
5. Write the merged result back to `<NAME>/claude/settings.json`.
6. (First run only) Copy host `~/.claude/.claude.json` → sandbox `<NAME>.claude.json`, stripping the `projects` key.
7. (First run only) Copy host `~/.claude/statsig/` → sandbox `claude/statsig/` (refreshed on every launch from a separate "always-refresh statsig" block).
8. (First run only) Create all persistent subdirectories.

At container launch, `<NAME>/claude` is bind-mounted rw at `/home/claude/.claude` — there is no child `:ro` overlay on `settings.json`. The agent can write to it (required for `/plugin install`), but sandy-managed keys are re-overwritten on the next launch.

**Consequence:** host-side edits to `~/.claude/settings.json` are picked up automatically on the next sandy launch, and the sandy-managed keys are always re-derived. Agent-owned state (`enabledPlugins`) is preserved across launches. The trade-off vs a strict reset: the agent can modify its own settings mid-session, and those modifications (to keys sandy doesn't manage) persist into the next session as well — the merge overlays rather than wipes.

Whenever `gemini` is in `SANDY_AGENT`, sandy creates `gemini/` and its `commands/`, `extensions/`, `tmp/` subdirs. Gemini settings.json is not seeded from the host (Gemini has no direct host-settings equivalent for sandy to copy).

For `SANDY_AGENT=codex`, sandy creates `codex/` and seeds `codex/config.toml` (first run only) with:

```toml
model = "gpt-5.5"
sandbox_mode = "danger-full-access"

[notice]
hide_full_access_warning = true
hide_gpt5_1_migration_prompt = true
"hide_gpt-5.1-codex-max_migration_prompt" = true
hide_rate_limit_model_nudge = true
hide_world_writable_warning = true
```

The `model = "gpt-5.5"` line sets a stable default model; users can override via `CODEX_MODEL` env var. The `sandbox_mode = "danger-full-access"` line is required — codex's Landlock sandbox does not nest cleanly inside sandy's Docker container. Sandy provides the outer isolation, and the CLI is additionally invoked with `--sandbox danger-full-access` as belt-and-suspenders in `build_codex_cmd`. The `[notice]` block suppresses first-run prompts; all five documented keys are seeded even if codex adds more over time.

**One-shot model migration**: existing sandboxes seeded with the old default (`model = "gpt-5.4"`) are auto-bumped to `gpt-5.5` on next launch. The migration matches the exact previous default line — any user-customized model (anything other than `"gpt-5.4"`) is preserved untouched.

The `[projects."<workspace>"] trust_level = "trusted"` entry is **appended at session start by `user-setup.sh`** (not at host-time) because it needs the container-side `$SANDY_WORKSPACE` path. Re-launches are idempotent: the entry is only appended if a matching line is not already present.

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

### Phase 2 (alt): Gemini CLI Image (`sandy-gemini-cli`)

**Dockerfile**: `Dockerfile.gemini`
**Rebuild trigger**: Content hash changes, base image rebuilt, or `--rebuild` flag

`FROM sandy-base` + `npm install -g @google/gemini-cli` + synthkit. Used only when `SANDY_AGENT=gemini`.

### Phase 2 (alt): Codex CLI Image (`sandy-codex`)

**Dockerfile**: `Dockerfile.codex`
**Rebuild trigger**: Content hash changes, base image rebuilt, Codex CLI version update detected, or `--rebuild` flag

Contents:
- `FROM sandy-base`
- Codex CLI: `npm install -g @openai/codex` (ships a prebuilt Rust binary per platform; Node is only the install vehicle)
- Version cached at `/opt/codex/.version`
- synthkit deps (libpango/cairo/gdk-pixbuf) + synthkit itself (so `md2pdf`, `md2doc`, `md2html`, `md2email` are on PATH)
- `COPY`: entrypoint.sh, user-setup.sh, tmux.conf

Used only when `SANDY_AGENT=codex`. The update check hits `https://api.github.com/repos/openai/codex/releases/latest` (not `/releases`) — upstream flags stable releases there, so sandy inherits their judgment rather than inventing a prerelease filter. The tag name `rust-vX.Y.Z` is stripped with `sed -E 's/.*"rust-v?([0-9][^"]*)"$/\1/'`. On parse failure the check returns no-update (stale but working).

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

User-provided Dockerfile must declare `ARG BASE_IMAGE` and use `FROM ${BASE_IMAGE}`. Sandy invokes `docker build --build-arg BASE_IMAGE=<IMAGE_NAME> -t sandy-project-<name>-<hash> .sandy/` where `<IMAGE_NAME>` is the most-derived image from the build chain (skills image if skill packs enabled, otherwise `sandy-claude-code`).

### Build Hash Caching

Each phase stores its content hash in `$SANDY_HOME/`:

| File | Phase |
|---|---|
| `.base_build_hash` | Phase 1 |
| `.build_hash` | Phase 2 (claude) |
| `.build_hash_gemini` | Phase 2 (gemini) |
| `.build_hash_codex` | Phase 2 (codex) |
| `.build_hash_both` | Phase 2 (claude+gemini) |
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

### Workspace State (gstack)

When `gstack` is enabled, `~/.gstack/` inside the container is bind-mounted from `<workspace>/.gstack/` on the host (auto-created if missing). This makes gstack state workspace-scoped — visible alongside `.git/` and `.venv/`, persisted independently of the sandbox identity.

A one-shot migration runs on the first 0.12+ launch: if `$SANDBOX_DIR/gstack/` (the legacy location) has content but `<workspace>/.gstack/` is absent, sandy `cp -a`'s the contents to the workspace and renames the legacy dir to `gstack.migrated/` (left in place; manual cleanup after verification).

A launch-time nudge prints a warning when the workspace is a git repo and `.gstack/` is not gitignored. Detection prefers `git check-ignore` (so it honors `.git/info/exclude` and parent `.gitignore`s); falls back to a literal grep of the workspace's `.gitignore` when git is unavailable. The warning is informational only — sandy launches normally either way.

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
5. Fix ownership of sandbox-backed persistent mount directories (pip, uv, npm, go, cargo). `~/.gstack/` is intentionally **not** chowned here — it's a workspace bind, so chown'ing inside the container would write through to the host workspace's ownership.
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

**Git**: `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GIT_TOKEN`, `GH_ACCOUNTS`, `SANDY_SSH`, `SSH_RELAY_PORT`

**System**: `HOST_UID`, `HOST_GID`, `DISABLE_AUTOUPDATER=1`, `FORCE_AUTOUPDATE_PLUGINS=true`

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

**Cleanup**: Rules and network removed on exit via trap handler.

**Fail-closed**: If `iptables` is not available, sandy aborts unless `SANDY_ALLOW_NO_ISOLATION=1`.

### macOS

**Network isolation is NOT active on macOS in 1.0-rc1.** Docker Desktop's VM does *not* provide LAN isolation. Containers can reach `host.docker.internal` (→ host gateway), the host's `localhost` services, and any device on the user's physical LAN (`192.168.x.x`, home router, NAS, printers, internal dashboards). Linux iptables DROP rules do not apply and cannot be applied from macOS. (Stress test April 2026 opened a live TCP connection to host SSHD and read its banner — see `ISOLATION_STRESS.md` finding F2.)

**Launch warning**: On non-Linux hosts, `apply_network_isolation` prints a warning banner informing the user that network isolation is not active and that the container can reach the host's LAN.

**Defense-in-depth (`--add-host`)**: sandy appends the following flags to `RUN_FLAGS` on macOS to nullify Docker Desktop's magic hostnames:

| Hostname | Mapped to | Condition |
|---|---|---|
| `gateway.docker.internal` | `127.0.0.1` | always |
| `metadata.google.internal` | `127.0.0.1` | always |
| `host.docker.internal` | `127.0.0.1` | only when `SANDY_SSH != agent` |

When `SANDY_SSH=agent`, `host.docker.internal` is *not* nullified because sandy's own in-container SSH agent relay (`socat … TCP:host.docker.internal:$SSH_RELAY_PORT`) depends on that hostname reaching the host. In that mode, sandy emits an extra warn line noting the exception.

This is defense-in-depth, not a fix — raw-IP access (`curl http://192.168.1.1`) is unaffected. The real fix is scheduled for sandy 1.1 as an egress proxy sidecar (HTTP CONNECT + SOCKS5 + DNS allowlist).

---

## 9. Protected Files

Certain files and directories in the workspace are overlaid at container launch to prevent modification. The lists of protected paths are emitted by three helper functions defined at the top of the `sandy` script (`_sandy_protected_files`, `_sandy_protected_git_files`, `_sandy_protected_dirs`). The test harness reads the same lists via `sandy --print-protected-paths` — single source of truth.

### Read-Only Bind Mounts

**Files (existence-gated — only mounted when present on host):**

| Path | Threat mitigated |
|---|---|
| `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile` | Shell config injection (aliases, PATH hijacking, env poisoning) |
| `.gitconfig` | Credential helper injection, alias hijacking |
| `.ripgreprc` | Search config injection |
| `.mcp.json` | MCP server config tampering |
| `.envrc` | `direnv` auto-sourcing on `cd` |
| `.tool-versions` | asdf toolchain version hijacking |
| `.mise.toml` | mise toolchain hijacking |
| `.nvmrc`, `.node-version` | Node version manager hijacking |
| `.python-version` | pyenv / uv auto-install hijacking |
| `.ruby-version` | rbenv/chruby hijacking |
| `.npmrc`, `.yarnrc`, `.yarnrc.yml` | npm/yarn registry hijacking, auth-token exfiltration |
| `.pypirc` | Python package index auth-token exfiltration |
| `.netrc` | HTTP credential exfiltration (curl/git/wget) |
| `.pre-commit-config.yaml` | pre-commit hook injection |

**Git-tree files (existence-gated — only mounted when present on host):**

| Path | Threat mitigated |
|---|---|
| `.git/config` | Remote path manipulation, `core.fsmonitor` injection, `core.hooksPath` redirect |
| `.gitmodules` | Submodule URL hijacking |
| `.git/HEAD` | Ref spoofing |
| `.git/packed-refs` | Ref spoofing |

**Directories (always mounted — empty fixture if absent on host):**

| Path | Threat mitigated |
|---|---|
| `.git/hooks/` | Pre-commit, post-checkout, push hook injection |
| `.git/info/` | `.git/info/attributes` filter-driver injection (arbitrary-command on checkout/add) |
| `.vscode/`, `.idea/` | IDE task/launch config injection |
| `.circleci/` | CircleCI pipeline escape |
| `.devcontainer/` | Devcontainer auto-open escape |
| `.github/workflows/` | GitHub Actions pipeline escape on `git push`. Omitted from the list when `SANDY_ALLOW_WORKFLOW_EDIT=1`. |

**Submodule gitdirs (recursive walk):**

`_protect_submodule_gitdirs` walks `$WORK_DIR/.git/modules/` (plus, for `--separate-git-dir` / worktree-of-submodule layouts, `$GITDIR_HOST/modules/`) up to `maxdepth 6`, matches `-type f -name config`, and for each submodule directory mounts:

- `<submodule>/config` → read-only
- `<submodule>/hooks/` → read-only (empty fixture if absent)
- `<submodule>/info/` → read-only (only if present on host)

This uses `while read -r -d ''` and shell-side `dirname` to avoid GNU-only `find -printf '%h\0'` — portable across macOS/BSD and GNU `find`.

**Mount policy (1.0-rc1, revised in 0.11.2 and 0.11.4)**: directories are always-mounted — if the host has no corresponding directory, sandy overlays an empty read-only directory (`$SANDY_HOME/.empty-ro-dir`) at the container path, blocking the agent from creating files there. Docker's bind-mount target auto-creation materializes empty stub dirs on the host workspace whenever a mount target doesn't exist under the rw workspace bind. 0.11.4 added two cleanup mechanisms to keep these stubs from accumulating (pre-0.11.4 the rationale was "empty dirs are benign" — in practice they littered every workspace):

1. **Session-scoped stub tracking.** Every stub sandy creates this session is appended to `$SANDBOX_DIR/.session-created-stubs`. The `cleanup()` EXIT trap reads the list and `rmdir`s each entry, then walks each entry's parent chain up to — but not including — `$WORK_DIR`, `rmdir`ing empty parents (catches `.github/` after `.github/workflows/` is removed). `rmdir` no-ops on populated dirs, so legitimate in-session writes survive. Positioned at the top of `cleanup()` so nothing earlier in the trap can short-circuit it. Covers the protected-dirs loop, the submodule-gitdir `hooks/` fallback, the `.claude/{commands,agents,plugins}` and `.gemini/{extensions,commands}` sandbox overlays, and `.claude/` itself (which `user-setup.sh` unconditionally `mkdir -p`s inside the container via the rw workspace bind).

2. **Pre-existing-debris preflight.** Workspaces touched by pre-0.11.4 sandy are already littered. On launch, sandy walks the protected-dirs list and `rmdir`s any that are empty. In a git repo it additionally requires the dir isn't git-tracked. Name-match against the small protected-dirs list + the empty check is a sufficient safety bar on its own; the git-tracked exclusion is an additional guard in repos. A 4-condition gate that required `git rev-parse --git-dir` to succeed was too strict — a workspace whose only `.git/` content is empty stubs of `.git/hooks` and `.git/info` isn't detected as a repo, so debris there persisted forever. Under `SANDY_DEBUG_CLEANUP=1`, the trap prints the number of stubs processed plus any `rmdir` failures with errno messages.

Files are existence-gated — if the host has no `.bashrc`/`.envrc`/etc., sandy adds no mount for that path. The original 1.0-rc1 plan called for always-mounting files too (with `$SANDY_HOME/.empty-ro-file` as the fallback), but Docker's bind-mount target auto-creation semantics cause 0-byte stub files to materialize on the host workspace whenever a mount target doesn't exist under an rw bind — polluting `git status` and breaking tools like direnv that react to file presence. The residual F3 gap for files (an agent can create `.bashrc`/`.envrc` in-session if the host didn't have one) is mitigated by the newly-created file showing up in host-side `git status` for user review. Git-tree files are also existence-gated because they are meaningless without a real git repo. The empty-dir fixture is seeded idempotently by `ensure_build_files()` on every launch; the empty-file fixture is also seeded (still used by `_sandy_protected_files` in the test harness's older flow, and kept for future use) but is not currently mounted by the production path.

**Stub cleanup preflight (files)**: sandy scans the workspace on launch for 0-byte files matching the protected-files list that are untracked by git. If any are found (typically leftover stubs from a workspace that ran a pre-0.11.2 always-mount build), sandy prints a one-shot `rm` remediation command. File stubs are not auto-removed — a 0-byte file could be intentional, and the git-untracked heuristic is only a best-effort safety check. Directory stubs *are* auto-removed (see above) because the name-match + empty gate is stronger.

**Intentionally excluded** from the protected list: package manifests (`Makefile`, `justfile`, `package.json`, `pyproject.toml`, `setup.py`, `Cargo.toml`, `build.rs`). The agent legitimately edits these as project source, and they are invoked explicitly by name rather than sourced on `cd` or filesystem scan.

### Writable Sandbox Overlays

| Workspace path | Sandbox source | Behavior |
|---|---|---|
| `.claude/commands/` | `workspace-commands/` | Starts empty; Claude can create/modify freely |
| `.claude/agents/` | `workspace-agents/` | Starts empty; Claude can create/modify freely |
| `.claude/plugins/` | `workspace-plugins/` | Starts empty; managed via `/plugin install` |

Host content at these paths is hidden (not visible inside container). Changes persist in the sandbox across sessions. No changes to host filesystem.

### Symlink Protection

Before container launch, sandy scans the workspace (up to 8 levels deep, skipping `node_modules/`, `.venv*/`, `.git/`) for symlinks pointing outside the project directory. If any are found, sandy consults the persisted approval list at `<NAME>/.sandy-approved-symlinks.list` before proceeding:

- **First launch (no approval list):** the user is prompted (`Proceed anyway? [y/N]`). On `y`, sandy writes the current set to `.sandy-approved-symlinks.list` and proceeds. On anything else, sandy aborts.
- **Identical or reduced set:** proceed silently. Removed entries are pruned from the list silently (deletion of a symlink is always benign).
- **New entry present:** hard error. Sandy names the new symlink in the error message and refuses to start. There is no second-chance prompt — the rationale is that a y/N prompt can be trained past ("I'll click yes again"), but a hard error forces an explicit user action to reapprove (delete the symlink and relaunch, or `rm <NAME>/.sandy-approved-symlinks.list` to clear the persisted set and re-prompt).

When the user accepts, sandy automatically mounts each symlink target into the container so the symlinks resolve correctly:
- **Absolute symlinks** (`data -> /home/user/shared/data`): Target is mounted at the raw symlink path (the literal path the OS looks up inside the container).
- **Relative symlinks** (`data -> ../../shared/data`): Target is mounted at its `$HOME`-relative container path, which is where the relative traversal lands from the container's workspace location.

Duplicate targets are deduplicated by container mount path.

---

## 10. SSH Agent Relay

### Token Mode (default, `SANDY_SSH=token`)

1. Query `gh auth token` on host for the active account's token (`GIT_TOKEN`)
2. Enumerate all authenticated accounts via `gh auth status`, collect each account's token via `gh auth token --user <account>`
3. Pass `GIT_TOKEN` to container (used for git URL rewriting)
4. Pass `GH_ACCOUNTS` to container as comma-separated `user:token` pairs (e.g. `user1:tok1,user2:tok2`)
5. In container: configure `git config --global url."https://oauth2:<TOKEN>@github.com/".insteadOf "git@github.com:"` (token mode only)
6. In container: authenticate `gh` CLI with all accounts from `GH_ACCOUNTS` (works in both token and agent modes)

Multi-account support: Users with multiple GitHub accounts (e.g. personal + enterprise) authenticated via `gh auth login` will have all accounts available inside the container. The `gh` CLI can then access repos from any authenticated account.

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

1. **Long-lived token** (`CLAUDE_CODE_OAUTH_TOKEN`): Valid 1 year, generated via `claude setup-token`. Recommended for headless servers. When set, this handles regular API calls; the credential file is still loaded alongside it (without token-refresh logic) so that cloud features like `/ultrareview` have access to the full OAuth credential object.
2. **OAuth credentials**: From host `~/.claude/.credentials.json` (or macOS Keychain). Token expiry checked; refresh attempted on macOS via `claude auth login`.
3. **Fallback**: Skip credential setup; user directed to `/login` inside session.

### Token Expiry Check

`token_needs_refresh()` checks if `claudeAiOauth.expiresAt` is within 5 minutes of current time. Uses Node.js (preferred) or Python 3 (fallback) for timestamp comparison.

### Ephemeral Credential Loading

Credentials are loaded into a temporary file, mounted into the container at `~/.claude/.credentials.json`, and discarded on exit. They are never persisted in the sandbox.

### OAuth Token Isolation

`CLAUDE_CODE_OAUTH_TOKEN` is explicitly set to empty string in the container's environment when not configured, preventing accidental leakage from the host environment.

### Gemini Credentials (whenever `gemini` is in `SANDY_AGENT`)

Sandy's `load_gemini_credentials()` tries the following sources, controlled by `SANDY_GEMINI_AUTH` (`auto` | `api_key` | `oauth` | `adc`):

| Mode | Source | Container mount / env |
|---|---|---|
| `api_key` | `GEMINI_API_KEY` env var on host | Forwarded via `-e GEMINI_API_KEY=…` |
| `oauth` | Host `~/.gemini/tokens.json` | Ephemeral copy mounted at `/home/claude/.gemini/tokens.json` **read-only** (1.0-rc1) |
| `adc` | `~/.config/gcloud/application_default_credentials.json` | Mounted read-only + `GOOGLE_APPLICATION_CREDENTIALS` env var |

In `auto` mode, all three are probed; a warning is emitted if none are found. OAuth tokens are copied to a tmpdir each launch and discarded on exit (same pattern as Claude credentials). Gemini's OAuth refresh is handled inside the CLI itself, so sandy does not run a refresh check.

Vertex AI routing is enabled by setting `GOOGLE_GENAI_USE_VERTEXAI=true` with `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_LOCATION`; all three are forwarded into the container when set.

**Note**: `gemini auth` (browser OAuth) must be run **on the host** — the container is headless and cannot open a browser.

### Codex Credentials (`SANDY_AGENT=codex`)

Sandy's `load_codex_credentials()` tries the following sources, controlled by `SANDY_CODEX_AUTH` (`auto` | `api_key` | `oauth`):

| Mode | Source | Container mount / env |
|---|---|---|
| `api_key` | `OPENAI_API_KEY` env var on host | Forwarded via `-e OPENAI_API_KEY=…` |
| `oauth` | Host `~/.codex/auth.json` (ChatGPT login) | Ephemeral copy mounted at `/home/claude/.codex/auth.json` **read-only** |

In `auto` mode (default), `OPENAI_API_KEY` wins if set; otherwise an `auth.json` ephemeral mount is used if present; otherwise a warning is emitted.

**The `auth.json` mount is read-only by design.** If codex needs to refresh an expired OAuth token mid-session, the write fails and codex falls back to an in-session re-login flow. This is the safer default: it prevents refreshed tokens from leaking back to the host, and prevents stale-token-on-exit races. Users who want fresh credentials on every launch get that automatically — sandy re-copies `auth.json` from the host at each launch.

**Note**: `codex login` (browser OAuth) must be run **on the host** — the container is headless and cannot open a browser.

---

## 12. Session Management

### Tmux Integration

Sandy wraps Claude Code in a tmux session:
- **Session name**: `sandy` (fixed)
- **Window name**: `sandy: <PROJECT_NAME>`
- **Auto-resume**: If session files (`.jsonl`) exist in `~/.claude/projects/<WORKSPACE_KEY>/` and no overriding flags (`--new`, `-p`, `--resume`, `--continue`), sandy automatically adds `--continue` to resume the last session. `WORKSPACE_KEY` is the container workspace path with all `/` replaced by `-` (e.g., `/home/claude/dev/sandy` → `-home-claude-dev-sandy`)
- **Fallback**: If `--continue` fails (stale session), retry without it

### Tmux Configuration

- History: 10,000 lines
- Mouse support enabled
- 256-color + RGB
- Escape time: 0ms
- OSC passthrough: `allow-passthrough on` (enables terminal notifications and clipboard)
- OSC 52 clipboard support for mouse selections
- Status bar: "sandy" prefix with time display

### Multi-Agent Mode (comma-separated `SANDY_AGENT`)

When `SANDY_AGENT` contains more than one agent (e.g. `claude,gemini`, `claude,codex`, `claude,gemini,codex`, or the alias `all`), the user-setup script creates a tmux session with one horizontally split pane per agent, in the order listed. The launch logic is factored into per-agent helpers (`build_claude_cmd()`, `build_gemini_cmd()`, `build_codex_cmd()`) so single-agent and multi-agent paths share the same command construction. Each pane is an independent process; exiting one leaves the others running.

The previous `both` alias (= `claude,gemini`) was removed in `v0.12` once the comma-separated syntax supported every combination. Using it now exits early with an error message pointing at the new syntax.

### Codex Headless Translation (`SANDY_AGENT=codex`)

`build_codex_cmd()` inspects the positional args for `-p`/`--print`/`--prompt`. If present, it emits `codex exec --sandbox danger-full-access <prompt>` (interactive becomes headless); otherwise `codex --sandbox danger-full-access` (TUI). The sandy `-p`/`--print`/`--prompt` flags are dropped and the remaining arg is passed as the positional prompt, because `codex exec` takes the prompt as a positional argument, not a flag. `--continue`/`-c` is silently dropped (codex has `codex resume` but no headless `--continue` equivalent — matches the gemini behavior).

`codex exec` uses only exit codes 0 (success) and 1 (failure). Sandy does not attempt to emulate Claude's richer exit-code semantics (no tool-denied, no context-exhausted signals) for codex. `--sandbox danger-full-access` on the CLI is belt-and-suspenders alongside the `sandbox_mode` in `config.toml`; do not remove either.

### Remote Control Mode

With `--remote`: no tmux wrapper, launches `claude remote-control --name "sandy: <PROJECT_NAME>"`. Browser/phone can connect to control the session.

**Only supported with `SANDY_AGENT=claude`.** Gemini CLI has no native WebSocket/daemon mode, and codex's `mcp-server`/`app-server` modes don't map cleanly to Claude's session-based `--remote` contract; `--remote` with any other value — `gemini`, `codex`, or any multi-agent combo — exits with an error. Tracked as a future enhancement pending upstream support.

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
| `sandy-plugins` | `{ source: "github", repo: "rappdw/sandy-plugins" }` |

The marketplace entries are merged into `$SANDBOX_DIR/claude/settings.json` host-side on every launch, next to the other sandy defaults (see §4 Seeding and §C.2). The merge happens before the container launches — as of 0.11.3 the settings file is rw inside the container (the pre-0.11.3 `:ro` sidecar broke `/plugin install`), so the marketplace merge could in principle live in `user-setup.sh`, but keeping it host-side avoids duplicating the node/jq/fallback triple across entrypoints.

### Deprecated Marketplace Removal

The `thinkkit`, `ait`, and `pka-skills` marketplaces are automatically removed on startup if present (same host-side merge block).

### Refresh Logic

- Marketplace catalogs refreshed daily (24-hour cache via `~/.claude/plugins/.marketplace_updated` timestamp)
- Force refresh when channels are configured (channel plugins may need installing)
- Runs `claude plugin marketplace update` for each marketplace

### Built-in Slash Commands (synthkit)

If synthkit is installed, `user-setup.sh` creates four slash commands in `~/.claude/commands/` (Claude, Markdown), `~/.gemini/commands/` (Gemini, TOML), and/or `~/.codex/skills/<name>/SKILL.md` (Codex, Markdown with YAML frontmatter):
- `/md2pdf` — Convert markdown to PDF
- `/md2doc` — Convert markdown to Word (.docx)
- `/md2html` — Convert markdown to HTML
- `/md2email` — Convert markdown to email HTML (clipboard)

For Gemini, the TOML files use `description` and `prompt` fields; the prompt embeds `!{md2pdf {{args}}}` shell execution and `{{args}}` argument substitution per Gemini's command format.

For Codex, skills are drop-in directories: `~/.codex/skills/<name>/SKILL.md`. The file **requires YAML frontmatter** with `name` and `description` keys delimited by `---`, followed by the skill body. Sandy writes one directory per tool (`md2pdf/`, `md2doc/`, `md2html/`, `md2email/`). Codex discovers these on launch and exposes them via `/skills`.

### Gemini Extensions (`SANDY_GEMINI_EXTENSIONS`)

When set, `user-setup.sh` iterates comma-separated URLs/local paths and runs `gemini extensions install <url>` for each, skipping any extension that already exists in `~/.gemini/extensions/`. Extensions persist across sessions via the `gemini/extensions/` sandbox mount.

---

## 16. Channel Integration

Sandy supports Claude Code channels (Telegram, Discord) via two distinct paths:

1. **In-container plugin path** (`SANDY_AGENT=claude` only) — auto-installs the Claude channel plugin from the marketplace and seeds credentials into `~/.claude/channels/`.
2. **Host-side tmux-inject relay** (any other `SANDY_AGENT` value — single `gemini`/`codex` or any multi-agent combo) — agent-agnostic, runs on the host and injects messages into the container's tmux session via `docker exec ... tmux send-keys`.

**Support matrix**:

| Channel | `claude` | `gemini` | `codex` | multi-agent |
|---|---|---|---|---|
| Telegram | in-container plugin | host relay | host relay | host relay |
| Discord | in-container plugin | — | — | — |

### In-Container Plugin Setup (Claude)

For each configured channel:
1. Auto-install the channel plugin from the marketplace
2. Create `~/.claude/channels/<channel>/` directory
3. Write `.env` with bot token
4. Write `access.json` with either:
   - `"dmPolicy": "allowlist"` + populated `allowFrom` (if `ALLOWED_SENDERS` set)
   - `"dmPolicy": "pairing"` (if no allowlist, user pairs via `/telegram:access pair <code>`)

### Host-Side Channel Relay (Gemini / Codex / Multi-agent)

`$SANDY_HOME/channel-relay.sh` is a generated bash script that long-polls the Telegram Bot API (`getUpdates`), filters messages by `TELEGRAM_ALLOWED_SENDERS`, and injects them into the container tmux session via:

```
docker exec <CONTAINER_NAME> tmux send-keys -t sandy.<PANE> "<text>" Enter
```

Launched as a background process before `docker run`, tracked via `CHANNEL_RELAY_PID`, and killed in the cleanup trap. The target pane is `SANDY_CHANNEL_TARGET_PANE` (default `0` = the first agent listed in `SANDY_AGENT`, or the sole pane in single-agent mode).

**Scope**: Telegram only in v0.9.0; Discord via relay is deferred. The relay is stateless — no chat threading, no attachment support, no edit-message reactions. For rich features, use the claude plugin path.

### Multiple Channels

Both Telegram and Discord can be enabled simultaneously with `SANDY_AGENT=claude`:
```
SANDY_CHANNELS=plugin:telegram@claude-plugins-official plugin:discord@claude-plugins-official
```

With any non-`claude` value (single `gemini`/`codex` or any multi-agent combo), only Telegram is currently supported through the relay; `SANDY_CHANNELS=discord` exits with an error.

---

## 17. Auto-Update

### Claude Code Updates

On each launch, sandy checks the installed Claude Code version (cached at `/opt/claude-code/.version`) against the latest release. If an update is available, the Phase 2 image is rebuilt with `--no-cache`. Inside the container, `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates against the read-only filesystem.

### Gemini / Codex Updates

For `SANDY_AGENT=gemini`, `_check_gemini_update` compares the in-image `gemini --version` against the npm registry's latest tag for `@google/gemini-cli`.

For `SANDY_AGENT=codex`, `_check_codex_update` compares the in-image `/opt/codex/.version` against `https://api.github.com/repos/openai/codex/releases/latest`. The tag format is `rust-vX.Y.Z`; sandy strips the prefix with `sed -E 's/.*"rust-v?([0-9][^"]*)"$/\1/'`. The `/releases/latest` endpoint returns only the release GitHub marks as "latest" (excludes prereleases by convention), so sandy inherits upstream's stable flagging instead of inventing its own policy — important because codex ships 30+ releases/month, most as prereleases. On parse failure the check returns no-update (stale but working, logged once).

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

---

## Appendix A: Generated File Templates

Sandy generates all build and runtime files as heredocs embedded in the script. Each function writes one or more files to `$SANDY_HOME/`. Variable expansion is noted for each template.

### A.1 Dockerfile.base (Phase 1)

**Generator**: `generate_dockerfile_base()` — quoted heredoc (`<<'DOCKERFILE_BASE'`), no variable expansion.

```dockerfile
FROM debian:bookworm-slim

# System tools + C/C++ toolchain
RUN apt-get update && apt-get install -y \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
    git-lfs \
    gosu \
    jq \
    less \
    libcairo2 \
    libgdk-pixbuf-2.0-0 \
    libpango1.0-0 \
    libssl-dev \
    ncurses-term \
    openssh-client \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    socat \
    tmux \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Go (arch-aware)
ARG GO_VERSION=1.24.1
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
       | tar -C /usr/local -xz

# Rust stable (system-wide)
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable \
    && chmod -R a+rX /usr/local/rustup /usr/local/cargo

# Bun
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# uv — fast Python package/version manager
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/usr/local/bin sh

# User
RUN useradd -m -s /bin/bash -u 1001 claude

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH="/home/claude/.local/bin:/usr/local/cargo/bin:/usr/local/go/bin:$PATH"
```

### A.2 Dockerfile (Phase 2)

**Generator**: `generate_dockerfile()` — unquoted heredoc (`<<DOCKERFILE`), expands `${BASE_IMAGE_NAME}`.

```dockerfile
FROM ${BASE_IMAGE_NAME}

RUN HOME=/home/claude su -s /bin/bash claude -c \
    "curl -fsSL https://claude.ai/install.sh | bash" \
 && cp -L /home/claude/.local/bin/claude /usr/local/bin/claude \
 && mv /home/claude/.local/share/claude /opt/claude-code \
 && { /usr/local/bin/claude --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' > /opt/claude-code/.version || true; }

# synthkit dependencies (WeasyPrint needs pango/cairo/gdk-pixbuf)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpango1.0-dev libcairo2-dev libgdk-pixbuf2.0-dev \
 && rm -rf /var/lib/apt/lists/*

RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin \
    uv tool install --python-preference system synthkit

COPY tmux.conf /etc/tmux.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY user-setup.sh /usr/local/bin/user-setup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/user-setup.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Key details:
- Claude Code is installed as user `claude`, then relocated to `/usr/local/bin/claude` (binary) and `/opt/claude-code` (data) so it survives the tmpfs overlay on `/home/claude`.
- `UV_TOOL_DIR=/opt/uv-tools` ensures synthkit's venv goes to an accessible location (not `/root/`).
- Version is cached at `/opt/claude-code/.version` for update detection.

### A.2b Dockerfile.codex (Phase 2, alt)

**Generator**: `generate_dockerfile_codex()` — unquoted heredoc (`<<DOCKERFILE`), expands `${BASE_IMAGE_NAME}`.

```dockerfile
FROM ${BASE_IMAGE_NAME}
# Install Codex CLI as a global npm package. The @openai/codex package ships
# a prebuilt Rust binary per platform; Node is only the installation vehicle.
RUN npm install -g @openai/codex \
 && mkdir -p /opt/codex \
 && { codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' > /opt/codex/.version || true; }
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpango1.0-dev libcairo2-dev libgdk-pixbuf2.0-dev \
 && rm -rf /var/lib/apt/lists/*
RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python-preference system synthkit
COPY tmux.conf /etc/tmux.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY user-setup.sh /usr/local/bin/user-setup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/user-setup.sh
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Key details:
- Version is cached at `/opt/codex/.version` for update detection.
- synthkit deps and synthkit itself are baked in so `md2pdf`/`md2doc`/`md2html`/`md2email` are on PATH regardless of whether Step 7's skill-seeding fires (e.g., if `synthkit` isn't installed at user-setup time).

### A.3 Dockerfile.skills-base (Phase 2.5a)

**Generator**: `generate_skill_pack_dockerfiles()` — mixed heredocs. Header is quoted (`<<'SKILLS_BASE_HEADER'`), gstack block is quoted (`<<'GSTACK_BASE_BLOCK'`). No variable expansion.

```dockerfile
FROM sandy-claude-code

# --- gstack base: Playwright + Chromium (rarely changes) ---
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/skills/gstack/.browsers

RUN mkdir -p /opt/skills/gstack \
 && cd /opt/skills/gstack \
 && npm init -y >/dev/null 2>&1 \
 && npm install playwright@latest --save >/dev/null 2>&1 \
 && npx playwright install-deps chromium \
 && npx playwright install chromium \
 && rm -rf node_modules package.json package-lock.json
```

Only generated when a pack requires heavy base dependencies (`needs_base=true`). The temporary npm project bootstraps Playwright just enough to install Chromium, then cleans up.

### A.4 Dockerfile.skills (Phase 2.5b)

**Generator**: `generate_skill_pack_dockerfiles()` — header uses unquoted heredoc (`<<SKILLS_HEADER`, expands `${skills_base_name}`), gstack block uses unquoted heredoc (`<<GSTACK_BLOCK`, expands `${repo}` and `${version}`).

```dockerfile
FROM sandy-skills-base-gstack

# --- gstack skill pack (${version}) ---
RUN mkdir -p /opt/skills/gstack \
 && curl -fsSL "${repo}/archive/${version}.tar.gz" \
    | tar -xz --strip-components=1 -C /opt/skills/gstack

RUN cd /opt/skills/gstack \
 && (bun install --frozen-lockfile 2>/dev/null || bun install) \
 && bun run build \
 && echo "${version}" > browse/dist/.version \
 && rm -rf node_modules/.cache

RUN chmod +x /opt/skills/gstack/bin/*
```

Image naming convention: `sandy-skills-base-<packs>` and `sandy-skills-<packs>` where `<packs>` is the sorted, lowercased, hyphen-joined pack list (e.g., `gstack`).

### A.5 entrypoint.sh

**Generator**: `generate_entrypoint()` — quoted heredoc (`<<'ENTRYPOINT'`), no variable expansion. Inner heredocs (`PIPWRAP`) also quoted.

The entrypoint runs as root and performs:

```bash
#!/bin/bash
# Verbose tracing at level 3+
if [ "${SANDY_VERBOSE:-0}" -ge 3 ]; then set -x; fi

# UID/GID from host (default 1001)
RUN_UID="${HOST_UID:-1001}"
RUN_GID="${HOST_GID:-1001}"

# 1. Fix tmpfs ownership
chown "$RUN_UID:$RUN_GID" /home/claude

# 2. Seed known_hosts
# Copies from /tmp/host-ssh-known_hosts if present
# Permissions: dir 700, file 644

# 3. SSH agent relay (if SANDY_SSH=agent)
#    macOS: socat UNIX-LISTEN → TCP:host.docker.internal:$SSH_RELAY_PORT
#    Wait: 50 attempts × 0.1s = 5s timeout for socket
#    Linux: chmod 600 + chown on mounted socket

# 4. Copy host SSH config
# From /tmp/host-ssh → ~/.ssh/ (cp -aL to dereference symlinks)
# Permissions: dir 700, keys 600, .pub/config/known_hosts 644

# 5. Fix persistent mount ownership
# Dirs: .pip-packages, .local/share/uv, .npm-global, go, .cargo, .gstack

# 6. Symlink Claude Code
# /usr/local/bin/claude → ~/.local/bin/claude
# /opt/claude-code → ~/.local/share/claude

# 7. pip/pip3 wrappers
# Auto-add --user when outside virtualenvs:
#   if [ -z "$VIRTUAL_ENV" ] && [ "${1:-}" = "install" ]; then
#       exec python3 -m pip install --user "$@"
#   fi

# 8. Drop privileges
exec gosu "$RUN_UID:$RUN_GID" /usr/local/bin/user-setup.sh "$@"
```

### A.6 user-setup.sh

**Generator**: `generate_user_setup()` — quoted heredoc (`<<'USERSETUP'`), no outer variable expansion. Inner heredocs for slash commands use quoted `<<'SKMD'`. Channel access.json uses both quoted and unquoted heredocs depending on mode.

Key implementation details not covered in the main spec:

**Settings.json merge (3-tier fallback)**:
1. **Node.js**: JSON repair (trailing commas, missing commas), merge defaults, strip `enabledPlugins`
2. **jq**: `//=` operator for defaults, `del(.enabledPlugins)`
3. **printf**: Last resort, only if file is exactly `{}`

JSON repair regexes:
- `/,(\s*[}\]])/g` → `$1` (remove trailing commas)
- `/(\"[^\"]*\")\s*\n(\s*\")/g` → `$1,\n$2` (add missing commas)

**ANSI color remap**: `printf "\033]4;4;rgb:61/8f/ff\033\\"` (dark blue → bright blue), restored on EXIT trap.

**Marketplace update cache**: Epoch timestamp written to `~/.claude/plugins/.marketplace_updated`. Stale after 86400 seconds (24 hours).

**Channel credential seeding** (`_seed_channel` function):
- Creates `~/.claude/channels/<chan>/` directory
- Writes `.env` (chmod 600) with `TOKEN_VAR=value`
- Writes `access.json` only if it doesn't already exist (preserves user edits)
- Allowlist computed by splitting comma-separated senders: `tr ',' '\n'` → awk to produce JSON array

**Claude Code launch**:
- Tmux mode: `tmux new-session -s sandy -n "sandy: <project>" -- bash -c "<cmd>"`
- Auto-continue: injects `--continue` if session files exist and no conflicting flags
- Fallback: `$CMD_WITH_CONTINUE || $CMD_WITHOUT_CONTINUE` (retries without `--continue` on failure)
- Remote mode: `claude remote-control --name "sandy: <project>"`

**Codex-specific user-setup additions**:
- Helper predicate `_sandy_has_codex() { [ "${SANDY_AGENT:-claude}" = "codex" ]; }` alongside `_sandy_has_claude` / `_sandy_has_gemini`.
- Synthkit seeding block (conditional on `command -v synthkit`) writes `~/.codex/skills/<name>/SKILL.md` with YAML frontmatter for `md2pdf`, `md2doc`, `md2html`, `md2email`.
- Trust-entry appending: after config.toml is in place, if `[projects."$SANDY_WORKSPACE"]` is not already present, append:
  ```toml
  [projects."<workspace>"]
  trust_level = "trusted"
  ```
  This must happen container-side because it needs the in-container workspace path.
- `build_codex_cmd()`: translates sandy's `-p`/`--print`/`--prompt` into `codex exec` with a positional prompt; drops `--continue`/`-c`; injects `--sandbox danger-full-access` and optional `--model`.
- Launch dispatch: the `codex` case sits alongside `claude` and `gemini` in the per-agent dispatch; multi-agent combos iterate over the parsed `_SANDY_AGENTS` array and call each `build_*_cmd` in pane order.

### A.7 tmux.conf

**Generator**: `generate_tmux_conf()` — quoted heredoc (`<<'TMUXCONF'`), no variable expansion.

```
set -g history-limit 10000
set -g mouse on
set -g default-terminal "tmux-256color"
set -as terminal-features ",tmux-256color:RGB"
set -as terminal-overrides ",*:U8=1"
set -sg escape-time 0

set -g pane-border-lines single
set -g pane-border-style "fg=colour240"
set -g pane-active-border-style "fg=colour51"
set -g pane-border-status top
set -g pane-border-format " #[fg=colour51]#{window_name}#[default] "

set -g status-position bottom
set -g status-style "bg=colour235,fg=colour248"
set -g status-left "#[fg=colour51,bold] sandy "
set -g status-left-length 10
set -g status-right "#[fg=colour248] %H:%M "
set -g status-right-length 10

set -g allow-passthrough on
set -g set-clipboard on
set -g focus-events on
setw -g aggressive-resize on
```

---

## Appendix B: Runtime Parameters

All magic numbers, thresholds, timeouts, and limits used in the sandy script.

### B.1 Resource Limits

| Parameter | Value | Context |
|---|---|---|
| Container memory | `available_GB - 1`, min 2GB | Auto-detected from `docker info --format '{{.MemTotal}}'`, converted via `/1073741824` |
| Container CPUs | All available (from `docker info --format '{{.NCPU}}'`) | Default 2 if detection fails |
| PID limit | 512 | `--pids-limit 512` |
| tmpfs `/tmp` | 1 GB, exec | `--tmpfs /tmp:exec,size=1G` |
| tmpfs `/home/claude` | 2 GB, exec | `--tmpfs /home/claude:exec,size=2G,uid=1001,gid=1001` |
| tmux history | 10,000 lines | `set -g history-limit 10000` |

### B.2 Timeouts

| Operation | Timeout | Context |
|---|---|---|
| GitHub releases API | 5 seconds | `curl --max-time 5` in `skill_pack_latest_release()` |
| GitHub commits API | 5 seconds | `curl --max-time 5` in `skill_pack_latest_release()` |
| Sandy update check API | 3 seconds | `curl --max-time 3` in `sandy_check_update()` |
| Claude Code version check | 5 seconds | `curl --max-time 5` against Google Cloud Storage |
| SSH socket wait (macOS) | 5 seconds | 50 iterations × 0.1s sleep in entrypoint |
| OAuth token expiry buffer | 5 minutes | 300,000 ms buffer before `expiresAt` |

### B.2a Sandbox Compatibility

| Parameter | Value | Context |
|---|---|---|
| `SANDY_SANDBOX_MIN_COMPAT` | `0.7.10` | Minimum sandy version whose sandboxes are still layout-compatible. Sandboxes created by older sandy (pre-c99eb97 workspace mount path change) trigger a launch-time warning recommending recreation. |
| `.sandy_created_version` | Written once on sandbox creation | Records the sandy version that created the sandbox. Missing on sandboxes created before 0.10.1. |
| `.sandy_last_version` | Refreshed every launch | Records the most-recent sandy version that touched the sandbox. |

### B.3 Cache TTLs

| Cache | TTL | File |
|---|---|---|
| Update check | 86,400 seconds (24 hours) | `$SANDY_HOME/.update_check` |
| Marketplace refresh | 86,400 seconds (24 hours) | `~/.claude/plugins/.marketplace_updated` |
| Skill pack version | Indefinite (refreshed each launch) | `$SANDY_HOME/.skill_version_<pack>` |

### B.4 File Permissions

| Path | Mode | Reason |
|---|---|---|
| `~/.ssh/` | 700 | SSH requires restrictive dir permissions |
| `~/.ssh/*` (private keys) | 600 | SSH refuses keys with group/other access |
| `~/.ssh/*.pub` | 644 | Public keys are non-sensitive |
| `~/.ssh/config` | 644 | SSH config readable |
| `~/.ssh/known_hosts` | 644 | Host fingerprints non-sensitive |
| SSH agent socket | 600 | Only owner should access agent |
| Channel `.env` files | 600 | Contains bot tokens |
| `.credentials.json` (ephemeral) | 600 | Contains OAuth tokens |
| pip/pip3 wrappers | +x | Must be executable |
| Skill pack `bin/*` | +x | Must be executable |
| cmux notification hook | +x | Must be executable |
| Rust/Cargo directories | a+rX | System-wide install, readable by all |

### B.5 Scan Depth Limits

| Scan | Max Depth | Excludes |
|---|---|---|
| Symlink protection | 8 levels | `node_modules/`, `.venv*/`, `.git/` |
| Submodule gitdir walk | 6 levels | — |
| Git LFS detection | 3 levels | — |

### B.6 Docker Security Flags

```
--security-opt no-new-privileges:true
--cap-drop ALL
--cap-add SETUID
--cap-add SETGID
--cap-add CHOWN
--cap-add DAC_OVERRIDE
--cap-add FOWNER
--read-only
```

Capabilities SETUID/SETGID are needed for `gosu` privilege drop. CHOWN/DAC_OVERRIDE/FOWNER are needed for the entrypoint to fix ownership of tmpfs and persistent mounts.

### B.7 Network Ranges (Linux iptables)

| CIDR | Purpose |
|---|---|
| `10.0.0.0/8` | Class A private (home/office LANs, VPNs) |
| `172.16.0.0/12` | Class B private (Docker internals, some LANs) |
| `192.168.0.0/16` | Class C private (home/office LANs) |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT / Tailscale |

### B.8 Default Values

| Variable | Default | Notes |
|---|---|---|
| `SANDY_MODEL` | `claude-opus-4-6` | Passed to `claude --model` |
| `SANDY_SSH` | `token` | Git authentication mode |
| `SANDY_SKIP_PERMISSIONS` | `true` | Skip trust dialog |
| `SANDY_VERBOSE` | `0` | No extra output |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | Max tokens per response |
| `HOST_UID` / `HOST_GID` | `1001` | Default container user if not remapped |
| Container user | `claude` | UID 1001, shell `/bin/bash` |

### B.9 Tool Versions

| Tool | Version | Install Method |
|---|---|---|
| Go | 1.24.1 | Multi-arch binary from go.dev |
| Node.js | 22 LTS | NodeSource `setup_22.x` |
| Rust | stable (latest) | rustup |
| Bun | latest | `curl https://bun.sh/install` |
| uv | latest | `curl https://astral.sh/uv/install.sh` |
| Python | Debian bookworm system default | `apt-get install python3` |

---

## Appendix C: JSON Schemas

### C.1 `access.json` (Channel Configuration)

Created at `~/.claude/channels/<channel>/access.json`. Two modes:

**Allowlist mode** (when `<CHANNEL>_ALLOWED_SENDERS` is set):
```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["user_id_1", "user_id_2"],
  "groups": {},
  "pending": {}
}
```

**Pairing mode** (when no allowlist configured):
```json
{
  "dmPolicy": "pairing",
  "allowFrom": [],
  "groups": {},
  "pending": {}
}
```

`allowFrom` is computed from the comma-separated env var: split on commas, trim whitespace, wrap each in quotes, join with commas.

The file is only written on first run — if it already exists, it's preserved to respect user edits.

### C.2 `settings.json` (Claude Code Configuration)

**Destination.** As of 0.11.3, the seeded settings file lives at `$SANDBOX_DIR/claude/settings.json` — inside the rw sandbox mount, no `:ro` overlay. It is regenerated from the host on every launch with merge-preserving semantics (agent-owned `enabledPlugins` is carried over from the previous sandbox session). The pre-0.11.3 approach used a `:ro` sidecar at `$SANDBOX_DIR/.seed-settings.json`, but that blocked `/plugin install` with EROFS and was reverted. See §4 Seeding for the full flow.

**Marketplace structure** (added idempotently to `extraKnownMarketplaces`):
```json
{
  "extraKnownMarketplaces": {
    "claude-plugins-official": {
      "source": { "source": "github", "repo": "anthropics/claude-plugins-official" }
    },
    "sandy-plugins": {
      "source": { "source": "github", "repo": "rappdw/sandy-plugins" }
    }
  }
}
```

Note the double-nested `source` — the outer key is the `extraKnownMarketplaces` schema, the inner object describes the repository.

**Sandy defaults merged on every launch** (Node.js tier):
```json
{
  "teammateMode": "tmux",
  "spinnerTipsEnabled": false,
  "skipDangerousModePermissionPrompt": true
}
```

`enabledPlugins` is deleted from the merged settings to prevent host plugin leakage. Because the sidecar is rebuilt each launch and mounted read-only, any in-container mutation fails with `EROFS` and host-side edits to `~/.claude/settings.json` are picked up on the next launch automatically.

**JSON repair** applied before parsing (handles common hand-editing errors):
- Remove trailing commas: regex `,(\s*[}\]])` → `$1`
- Add missing commas between keys: regex `("key")\s*\n(\s*"nextkey")` → `$1,\n$2`
- If parsing still fails, fall back to empty object `{}`

### C.3 `.claude.json` (User Setup State)

Stored at `$SANDY_HOME/sandboxes/<NAME>.claude.json` (outside the sandbox dir to avoid mount conflicts). Mounted into the container at `/home/claude/.claude.json`.

**Seeding from host** (Node.js):
```javascript
let d = JSON.parse(fs.readFileSync(hostPath));
delete d.projects;  // strip host project paths
fs.writeFileSync(sandboxPath, JSON.stringify(d, null, 2) + "\n");
```

Falls back to `cp` if Node.js parsing fails.

**Fallback if no host copy exists**:
```json
{
  "tipsDisabled": true,
  "installMethod": "native"
}
```

**Post-seed merge**: Always ensures `tipsDisabled: true` and `installMethod: "native"` are set.

### C.4 `.credentials.json` (OAuth Credentials)

Loaded ephemerally from the host, never persisted in the sandbox.

**Expected structure for token expiry check**:
```json
{
  "claudeAiOauth": {
    "expiresAt": 1234567890000
  }
}
```

`expiresAt` is milliseconds since epoch. The refresh check uses `Date.now() + 300000 > expiresAt` (5-minute buffer).

### C.5 Channel `.env` Files

Plain `KEY=VALUE` format at `~/.claude/channels/<channel>/.env`:

```
TELEGRAM_BOT_TOKEN=<token>
```
or
```
DISCORD_BOT_TOKEN=<token>
```

Permissions: 600 (owner read-write only).

### C.6 cmux Notification Hook

Auto-generated at `~/.claude/hooks/cmux-notify.sh` when cmux is detected. Merged into `$SANDBOX_DIR/claude/settings.json` host-side during the seed regeneration (see §C.2):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/home/claude/.claude/hooks/cmux-notify.sh"
          }
        ]
      }
    ]
  }
}
```

The hook script emits `\033]777;notify;<title>;<body>\033\\` OSC sequences.

### C.7 `.update_check` Cache

Plain text file at `$SANDY_HOME/.update_check`:

```
<epoch_timestamp> <latest_version>
```

Example: `1711843200 0.8.0`. Stale after 86,400 seconds.

### C.7b Codex `config.toml` (seeded by sandy)

Written to `$SANDBOX_DIR/codex/config.toml` on first launch of a new sandbox with `SANDY_AGENT=codex`. Mounted into the container at `/home/claude/.codex/config.toml`.

```toml
# Written by sandy on first launch. Safe to edit, but sandbox_mode must stay
# "danger-full-access" — sandy provides outer isolation; codex's Landlock
# sandbox does not nest cleanly in Docker containers.
model = "gpt-5.5"
sandbox_mode = "danger-full-access"

[notice]
hide_full_access_warning = true
hide_gpt5_1_migration_prompt = true
"hide_gpt-5.1-codex-max_migration_prompt" = true
hide_rate_limit_model_nudge = true
hide_world_writable_warning = true

# [projects."<workspace>"] trust_level = "trusted" appended at session start
# by user-setup.sh, where $SANDY_WORKSPACE is known.
```

The file is created exactly once per sandbox — re-runs preserve user edits. The `[notice]` list may grow upstream; sandy seeds all five documented keys as cheap insurance. Source-of-truth reference: `codex-rs/core/src/config.rs` in the openai/codex repository.

After the first session start, the file additionally contains the trust entry:

```toml
[projects."/home/claude/dev/myproject"]
trust_level = "trusted"
```

Appended by `user-setup.sh` only if a matching `^[projects."<workspace>"]` line is not already present (idempotent).

### C.7c Codex `auth.json` (ephemeral OAuth mount)

If the host has `~/.codex/auth.json` and `SANDY_CODEX_AUTH` is `auto` or `oauth`, sandy copies it to a tmpdir at launch and mounts it **read-only** into the container at `/home/claude/.codex/auth.json`. The tmpdir is removed on exit (cleanup trap). Schema is opaque to sandy — the file is produced by `codex login` on the host.

### C.8 `.skill_version_<pack>` Cache

Plain text file at `$SANDY_HOME/.skill_version_<pack>`:

```
<version_or_sha>
```

Example: `a1b2c3d4e5f6` (commit SHA) or `v1.2.3` (release tag). Updated whenever a newer version is resolved from GitHub.

---

## Appendix D: Platform-Specific Behavior

Sandy runs on both Linux and macOS. The following sections document every point where behavior diverges.

### D.1 Network Isolation

| Aspect | Linux | macOS |
|---|---|---|
| Mechanism | iptables `DOCKER-USER` chain | **None active in 1.0-rc1** (Docker Desktop does *not* provide LAN isolation) |
| Rules applied | DROP for 5 private ranges; ACCEPT for container subnet and allowed hosts | None — LAN, `host.docker.internal`, and host `localhost` are all reachable |
| Fail-closed | Aborts if iptables unavailable (unless `SANDY_ALLOW_NO_ISOLATION=1`) | Prints loud launch warning banner; proceeds without isolation |
| Defense-in-depth | n/a | `--add-host gateway.docker.internal:127.0.0.1`, `--add-host metadata.google.internal:127.0.0.1`, and (conditionally) `--add-host host.docker.internal:127.0.0.1` |
| Cleanup | Rules and bridge network deleted on exit | Bridge network deleted on exit |

**macOS `--add-host` condition:** `host.docker.internal` is only nullified when `SANDY_SSH != agent`. In agent mode, sandy's in-container SSH agent relay uses that hostname to reach the host-side socat relay (see §10); nullifying it would break SSH. An additional warn line is emitted in that case.

**Real fix scheduled for sandy 1.1**: an egress proxy sidecar (HTTP CONNECT + SOCKS5 + DNS allowlist) that implements uniform outbound allowlisting on both platforms. See `ISOLATION_STRESS.md` finding F2 and the Sprint 3 section of the rc1 remediation plan.

**Linux iptables flow**:
1. Test `sudo iptables -L DOCKER-USER -n` — if fails, abort (or allow with override)
2. Insert DROP rules for each private range (inserted first = evaluated last)
3. Insert ACCEPT for `SANDY_ALLOW_LAN_HOSTS` entries (if set)
4. Insert ACCEPT for container's own subnet (inserted last = evaluated first)
5. On exit: delete rules in reverse, remove Docker network

### D.2 SSH Agent Relay

| Aspect | Linux | macOS |
|---|---|---|
| Host → container | Direct Unix socket mount (`-v $SSH_AUTH_SOCK:/tmp/ssh-agent.sock`) | TCP relay via `socat` |
| Port allocation | N/A | `python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); ..."` |
| Host relay | N/A | `socat TCP-LISTEN:<port>,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:<SSH_AUTH_SOCK>` |
| Container relay | N/A (direct socket) | `socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,mode=0600 TCP:host.docker.internal:<port>` |
| Socket wait | N/A | 50 × 0.1s = 5s timeout |
| Dependency | None extra | Requires `socat` and `python3` on host (checked, error with `brew install` suggestion) |

### D.3 Credential Loading

| Aspect | Linux | macOS |
|---|---|---|
| Primary source | `~/.claude/.credentials.json` (file) | Same file |
| Fallback source | None | macOS Keychain: `security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w` |
| Token refresh | Skip (no browser available on headless Linux) | `claude auth login` (can open browser) |
| Browser detection | `can_open_browser()` always returns 1 (false) | Always returns 0 (true) |

### D.4 SHA256 Hash

```bash
sha256() { shasum -a 256 2>/dev/null || sha256sum; }
```

- macOS: `shasum -a 256` (Perl-based, ships with macOS)
- Linux: Falls through to `sha256sum` (coreutils)

### D.5 UID/GID Remapping

| Aspect | Linux | macOS |
|---|---|---|
| Host UID detection | `id -u` (typically non-root, e.g. 1000) | `id -u` (typically 501) |
| Image default UID | 1001 | 1001 |
| Remapping needed | Usually yes (1000 ≠ 1001) | Usually yes (501 ≠ 1001) |
| Implementation | Custom `passwd`/`group` files mounted read-only | Same |

**passwd sed pattern**: `sed "s/^claude:x:1001:1001:/claude:x:${HOST_UID}:${HOST_GID}:/"`
**group sed pattern**: `sed "s/^claude:x:1001:/claude:x:${HOST_GID}:/"`

### D.6 Error Recovery & Fallback Chains

**settings.json merge** (3 tiers, tried in order — target is `$SANDBOX_DIR/claude/settings.json`, rebuilt every launch with merge-preserving semantics):
1. **Node.js**: JSON repair → parse host → read previous sandbox → preserve `enabledPlugins` from previous → merge defaults → merge marketplaces → scrub deprecated → write
2. **jq**: Same shape via `--argjson prev "$_prev_plugins"` read from the previous sandbox settings
3. **printf**: Only if no file exists yet, writes minimal JSON

**.claude.json seeding** (2 tiers):
1. **Node.js**: Parse, delete `projects` key, write pretty-printed
2. **cp**: Raw copy if Node.js fails (host projects key preserved — less clean but functional)

**Token expiry check** (2 tiers):
1. **Node.js**: Parse credentials JSON, check `claudeAiOauth.expiresAt` against `Date.now() + 300000`
2. **Python 3**: Same logic via `json.loads` and `time.time() * 1000`
3. If neither available: warn and return "needs refresh"

**Skill pack version resolution** (3 tiers):
1. **GitHub releases API**: 5s timeout, looks for tags matching prefix
2. **GitHub commits API**: 5s timeout, gets latest commit SHA (truncated to 12 chars)
3. **Local cache file**: `$SANDY_HOME/.skill_version_<pack>`
4. **Hardcoded fallback**: `SKILL_PACK_VERSIONS` array entry

---

## Appendix E: Container Launch Assembly

The `docker run` command is assembled incrementally in a `RUN_FLAGS` array. This appendix documents the complete assembly in order.

### E.0 Workspace Mutex

Only one sandy may run against a given workspace at a time. Early in launch (after config loading, before sandbox seeding), sandy takes a per-workspace mutex:

```bash
mkdir -p "$SANDY_HOME/sandboxes"
SANDY_WORKSPACE_LOCK="$SANDY_HOME/sandboxes/.${SANDBOX_NAME}.lock"
if ! mkdir "$SANDY_WORKSPACE_LOCK" 2>/dev/null; then
    # error: another sandy is already running in this workspace (pid <holder>)
    exit 1
fi
echo "$$" > "$SANDY_WORKSPACE_LOCK/pid"
```

`mkdir` is used as the lock primitive because it is atomic on every POSIX filesystem and requires no external dependency (unlike `flock(1)`, which is not shipped on macOS by default). The lock dir is released by the cleanup trap (`trap cleanup EXIT INT TERM HUP`) on normal exit, Ctrl-C, or sandy crash. A SIGKILL (OOM, `kill -9`) leaves the lock dir behind — the error message on the next launch names the holding pid and the clear command (`rm -rf $SANDY_WORKSPACE_LOCK`).

Rationale: two agents editing the same codebase would step on each other's edits, and the sandbox-seeding / venv-materialization code paths assume exclusive ownership. Deliberate parallelism should use separate workspaces.

### E.1 Pre-Launch

**Stale container removal**: Before starting, any container with the same name is force-removed to handle unclean previous exits:
```bash
docker rm -f "sandy-<SANDBOX_NAME>" 2>/dev/null || true
```

### E.2 Base Flags

```bash
--rm -it
--name sandy-<SANDBOX_NAME>
--cpus <SANDY_CPUS>
--memory <SANDY_MEM>
--security-opt no-new-privileges:true
--cap-drop ALL
--cap-add SETUID --cap-add SETGID
--cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
--pids-limit 512
--read-only
--tmpfs /tmp:exec,size=1G
--tmpfs /home/claude:exec,size=2G,uid=1001,gid=1001
--network <NETWORK_NAME>
```

### E.3 GPU Passthrough (conditional)

If `SANDY_GPU` is set and Docker supports GPUs (`docker info --format '{{.Runtimes}}'` contains `nvidia` or `cdi`):
```bash
--gpus <SANDY_GPU>    # e.g., "all" or "device=0,1"
```

### E.4 Credential Mount (conditional)

If credentials were loaded (OAuth token or credentials file):
```bash
-v "<CRED_TMPDIR>/.credentials.json:/home/claude/.claude/.credentials.json"
```

The temporary directory is created per-launch and cleaned up on exit. The mount is **read-write** — Claude Code cloud features (e.g., `/ultrareview`) need to write refreshed or scoped tokens back to the credentials file during a session. The tmpdir is ephemeral (fresh each launch, `rm -rf` on exit), so in-session writes do not persist to the host. Codex `auth.json` and Gemini OAuth mounts remain `:ro` (these agents don't have equivalent cloud features that require token write-back). See §11 for credential loading rules per agent.

**Cleanup trap**: the `cleanup` function that removes `*_CRED_TMPDIR` directories is registered on `EXIT INT TERM HUP QUIT ABRT`. `SIGKILL` cannot be trapped, so a residual cleanup window exists in that case alone.

### E.5 .claude.json Mount

```bash
-v "<SANDY_HOME>/sandboxes/<NAME>.claude.json:/home/claude/.claude.json"
```

Always mounted — this file is seeded on first run and persists across sessions.

### E.6 Host Hooks Mount (conditional)

If `~/.claude/hooks/` exists on the host:
```bash
-v "$HOME/.claude/hooks:/home/claude/.claude/hooks:ro"
```

### E.7 Workspace Mount

```bash
-v "<HOST_PATH>:<CONTAINER_PATH>"
```

Where `CONTAINER_PATH` follows the workspace path mapping rules (Section 13).

### E.7a Workspace `.venv` Overlay (conditional)

If `$WORK_DIR/.venv` exists on the host, is not a symlink, and `SANDY_VENV_OVERLAY` is not `0`, sandy bind-mounts a sandbox-owned dir over the workspace venv path:

```bash
-v "<SANDBOX_DIR>/venv:<CONTAINER_PATH>/.venv"
-e "SANDY_VENV_OVERLAY_ACTIVE=1"
-e "SANDY_VENV_PYTHON_VERSION=<major.minor>"   # if parseable from pyvenv.cfg
```

Must appear **after** the workspace mount (E.7) so Docker can overlay it on top. The sandbox `venv/` dir is created on the host side before `docker run`.

**Python version resolution (host side)**, in order:
1. `$WORK_DIR/.python-version` — authoritative, user-maintained.
2. `$WORK_DIR/.venv/pyvenv.cfg` `version` / `version_info` line — fallback.

The result is normalized to `major.minor` (`cut -d. -f1-2`) and validated against `^[0-9]+\.[0-9]+$`. Values that don't match are discarded and `SANDY_VENV_PYTHON_VERSION` is left unset — the container then defaults to `3.12` in `user-setup.sh`.

**Symlinked `.venv/`** is explicitly skipped on the host side; an info message fires instead of silently proceeding. Rationale: the symlink target may be a path outside `$WORK_DIR` and overlaying it would shadow unpredictable host state.

Inside the container, `user-setup.sh`:
1. If `$WORKSPACE/.venv/pyvenv.cfg` does not exist, materializes a fresh venv via `uv venv --clear --python <version> $WORKSPACE/.venv`. The `--clear` flag is required: the overlay bind-mount target always exists as a directory, and `uv venv` otherwise refuses with "A directory already exists at: .venv". No in-container locking is needed — the host-side workspace mutex (§E.0) guarantees exclusive access.
2. After materialization (or on subsequent launches), compares the overlay's actual `pyvenv.cfg` version against `SANDY_VENV_PYTHON_VERSION`. Mismatch → prints a drift warning with the recreate command. No auto-recreate (would silently nuke installed packages).
3. Activates unconditionally if `$WORKSPACE/.venv/bin/python` exists (`VIRTUAL_ENV` + PATH prepend).

The host `.venv/` is never read or written by sandy — it is shadowed by the bind mount inside the container only.

### E.8 Git Submodule Mount (conditional)

If `.git` is a file (submodule), the gitdir is also mounted:
```bash
-v "<HOST_GITDIR>:<CONTAINER_GITDIR>"
```

Both paths use the same `$HOME`-relative mapping to preserve the relative relationship.

### E.9 Symlink Protection Scan

Before assembling mounts, sandy scans the workspace for symlinks escaping the project directory:
```bash
find <WORKSPACE> -maxdepth 8 \
    -path '*/node_modules' -prune -o \
    -path '*/.venv*' -prune -o \
    -path '*/.git' -prune -o \
    -type l -print
```

Each symlink's real path is checked against the workspace root. If any escape, sandy consults the persisted approval list `<SANDBOX_DIR>/.sandy-approved-symlinks.list` (one `<link>\t<target>` per line). The handling is one of three paths:

1. **No approval list yet (first launch):** prompt the user with
   ```
   These could allow Claude to access files outside the sandbox.
   Proceed anyway? [y/N]
   ```
   On `y`/`Y`, sandy writes the current set to the approval list and proceeds. Anything else aborts with exit 1.

2. **Current set is a subset of the approved list:** proceed silently. Sandy rewrites the list to drop entries the user has deleted (symlink removal is benign).

3. **Current set contains an entry not in the approved list:** **hard error**, naming the new symlink(s), with no re-prompt. Rationale: a y/N that fires every session can be trained past; a hard error forces a deliberate user action. Remediation is `rm` the offending link (restoring the approved state), or `rm <SANDBOX_DIR>/.sandy-approved-symlinks.list` to clear the persisted approval and get a fresh prompt on the next launch.

When the user accepts, each symlink target is mounted into the container (see Section 9, Symlink Protection). Mount path depends on symlink type:
- **Absolute**: `-v "<resolved_host_path>:<raw_symlink_value>"`
- **Relative**: `-v "<resolved_host_path>:<HOME_relative_container_path>"`

Deduplicated by container mount path.

### E.10 Protected File Mounts

Three categories, sourced from the single-source-of-truth helpers in `sandy` (`_sandy_protected_files`, `_sandy_protected_git_files`, `_sandy_protected_dirs`). The same three helpers are exposed to the test harness via `sandy --print-protected-paths`, which emits `file:<path>`, `gitfile:<path>`, and `dir:<path>` lines. See §9 for the full path list and threat model.

**Regular files — existence-gated (0.11.2)**:
```bash
while IFS= read -r f; do
    [ -e "<WORKSPACE>/$f" ] && -v "<WORKSPACE>/$f:<CONTAINER_WORKSPACE>/$f:ro"
done < <(_sandy_protected_files)
```
The always-mount-with-empty-fixture pattern was reverted for files in 0.11.2 because Docker creates mount targets on the host inside the rw workspace bind, causing 0-byte stub files to appear in the user's workspace (breaking direnv and polluting `git status`). See §9 for the residual F3 gap and its host-side detection mitigation.

**Git-tree files — existence-gated** (meaningless without a real git repo):
```bash
while IFS= read -r f; do
    [ -f "<WORKSPACE>/$f" ] && -v "<WORKSPACE>/$f:<CONTAINER_WORKSPACE>/$f:ro"
done < <(_sandy_protected_git_files)
```

**Directories — always mounted (1.0-rc1)**:
```bash
while IFS= read -r d; do
    if [ -d "<WORKSPACE>/$d" ]; then
        -v "<WORKSPACE>/$d:<CONTAINER_WORKSPACE>/$d:ro"
    else
        -v "<SANDY_HOME>/.empty-ro-dir:<CONTAINER_WORKSPACE>/$d:ro"
    fi
done < <(_sandy_protected_dirs)
```

**Submodule gitdir walk** — after the above loops:
```bash
_protect_submodule_gitdirs "<WORK_DIR>/.git/modules" "<CONTAINER_WORKSPACE>/.git/modules"
# When .git is a file (submodule worktree / --separate-git-dir):
[ -d "<GITDIR_HOST>/modules" ] && \
    _protect_submodule_gitdirs "<GITDIR_HOST>/modules" "<GITDIR_CONTAINER>/modules"
```

For each `config` sentinel file found under the root (up to `maxdepth 6`), the helper emits three mounts: `config:ro`, `hooks:ro` (empty fixture if absent), and `info:ro` (only if present). Uses `-print0` and shell-side `dirname` for macOS/BSD portability.

**`$SANDY_HOME/.empty-ro-file`** (zero-byte) and **`$SANDY_HOME/.empty-ro-dir/`** (empty) are created idempotently by `ensure_build_files()` on every launch and live alongside the generated Dockerfiles.

### E.11 Writable Sandbox Overlays

For each of `commands`, `agents`, `plugins`:
```bash
# Only mount if the workspace has .claude/<subdir> OR the sandbox already has data
if [ -d "<WORKSPACE>/.claude/<subdir>" ] || [ -d "<SANDBOX>/workspace-<subdir>" ]; then
    mkdir -p "<SANDBOX>/workspace-<subdir>"
    -v "<SANDBOX>/workspace-<subdir>:<CONTAINER_WORKSPACE>/.claude/<subdir>"
fi
```

This hides host content at these paths and provides a writable overlay from the sandbox.

### E.12 Persistent Package Mounts

```bash
-v "<SANDBOX>/pip:<HOME>/.pip-packages"
-v "<SANDBOX>/uv:<HOME>/.local/share/uv"
-v "<SANDBOX>/npm-global:<HOME>/.npm-global"
-v "<SANDBOX>/go:<HOME>/go"
-v "<SANDBOX>/cargo:<HOME>/.cargo"
```

If `gstack` is in `SANDY_SKILL_PACKS`:
```bash
-v "<WORKSPACE>/.gstack:<HOME>/.gstack"
```
Note: gstack mounts from the **workspace**, not the sandbox — see §6 "Workspace State (gstack)" for rationale and the one-shot migration from the legacy `<SANDBOX>/gstack/` location.

### E.13 Sandbox Mount

The sandbox directory itself becomes `~/.claude` inside the container:
```bash
-v "<SANDBOX_DIR>:/home/claude/.claude"
```

### E.13a Seed `settings.json` (conditional on `claude` agent)

As of 0.11.3, there is no child overlay on `settings.json`. The file lives at `<SANDBOX_DIR>/claude/settings.json` inside the rw sandbox mount (E.13) and is regenerated host-side by the pre-launch seed step (§4 Seeding) every launch. The regeneration re-reads the host `~/.claude/settings.json`, overlays sandy defaults and marketplaces, and preserves `enabledPlugins` from the previous sandbox session. No additional mount flag is emitted.

Rationale: the pre-0.11.3 approach used a `:ro` child overlay (`<SANDBOX_DIR>/.seed-settings.json → /home/claude/.claude/settings.json:ro`), but that caused `/plugin install` to fail with EROFS because Claude Code writes the plugin list to `settings.json` at install time. The merge-preserving rw approach trades strict F6 reset-on-launch for functional plugin installs, while still guaranteeing sandy-managed keys are re-overwritten every launch.

### E.14 SSH Mounts (conditional on `SANDY_SSH`)

**Token mode** (`SANDY_SSH=token`): No SSH mounts. Git token passed via environment variable.

**Agent mode** (`SANDY_SSH=agent`):

Linux:
```bash
-v "<SSH_AUTH_SOCK>:/tmp/ssh-agent.sock"
-e "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
```

macOS: Port passed via environment variable (relay handled by entrypoint):
```bash
-e "SSH_RELAY_PORT=<port>"
```

Both platforms (if `~/.ssh` exists):
```bash
-v "$HOME/.ssh:/tmp/host-ssh:ro"
```

If `~/.ssh/known_hosts` exists (mounted separately for token mode too):
```bash
-v "$HOME/.ssh/known_hosts:/tmp/host-ssh-known_hosts:ro"
```

### E.15 UID/GID Remapping (conditional)

If host UID ≠ 1001:
```bash
-e "HOST_UID=<uid>"
-e "HOST_GID=<gid>"
-v "<SANDY_HOME>/passwd:/etc/passwd:ro"
-v "<SANDY_HOME>/group:/etc/group:ro"
```

The passwd/group files are generated by sed:
```bash
sed "s/^claude:x:1001:1001:/claude:x:${HOST_UID}:${HOST_GID}:/" /etc/passwd > passwd
sed "s/^claude:x:1001:/claude:x:${HOST_GID}:/" /etc/group > group
```

### E.16 Environment Variables

All passed via `-e KEY=VALUE`:

```bash
# Workspace identity
SANDY_WORKSPACE=<container_path>
SANDY_PROJECT_NAME=<basename>

# Claude Code config
SANDY_MODEL=<model>
SANDY_SKIP_PERMISSIONS=<true|false>
SANDY_NEW_SESSION=<true|false>
SANDY_REMOTE_CONTROL=<true|false>
SANDY_VERBOSE=<0-3>
CLAUDE_CODE_MAX_OUTPUT_TOKENS=<128000>

# Channels (if configured)
SANDY_CHANNELS=<channel_spec>
TELEGRAM_BOT_TOKEN=<token>
TELEGRAM_ALLOWED_SENDERS=<ids>
DISCORD_BOT_TOKEN=<token>
DISCORD_ALLOWED_SENDERS=<ids>

# Git identity (auto-detected from host git config if not set)
GIT_USER_NAME=<name>
GIT_USER_EMAIL=<email>
SANDY_SSH=<token|agent>
GIT_TOKEN=<token>          # token mode only
GH_ACCOUNTS=<user1:tok1,user2:tok2>  # all gh-authenticated accounts

# Credentials (explicitly emptied if not set to prevent host env leakage)
ANTHROPIC_API_KEY=<key>             # empty string if unset
CLAUDE_CODE_OAUTH_TOKEN=<token>     # empty string if unset

# Agent teams (if configured)
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=<0|1>

# System
HOST_UID=<uid>
HOST_GID=<gid>
DISABLE_AUTOUPDATER=1
FORCE_AUTOUPDATE_PLUGINS=true
```

Git identity fallback: if `GIT_USER_NAME`/`GIT_USER_EMAIL` are not set via config, they are read from the host's `git config user.name` and `git config user.email`.

**Gemini-specific env** (whenever `gemini` is in `SANDY_AGENT`):
```bash
GEMINI_API_KEY=<key>                # if set
GEMINI_MODEL=<model>                # if set
SANDY_GEMINI_AUTH=<auto|api_key|oauth|adc>
GOOGLE_CLOUD_PROJECT=<proj>         # Vertex AI
GOOGLE_CLOUD_LOCATION=<region>
GOOGLE_GENAI_USE_VERTEXAI=<true>
GOOGLE_API_KEY=<key>
GOOGLE_APPLICATION_CREDENTIALS=/home/claude/.config/gcloud/application_default_credentials.json  # adc mode
```

**Codex-specific env** (`SANDY_AGENT=codex`):
```bash
OPENAI_API_KEY=<key>                # if set
CODEX_MODEL=<model>                 # if set
SANDY_CODEX_AUTH=<auto|api_key|oauth>
```

`CODEX_HOME` is intentionally **not** forwarded — sandy owns the in-container path (`/home/claude/.codex`) via the sandbox mount and overriding it would break the mount.

**Codex-specific mounts** (`SANDY_AGENT=codex`):
```bash
-v "$SANDBOX_DIR/codex:/home/claude/.codex"
# if OAuth path active:
-v "$CODEX_CRED_TMPDIR/auth.json:/home/claude/.codex/auth.json:ro"
```

The codex sandbox dir is writable (codex needs `log/`, `memories/`, session rollouts, sqlite state), but the `auth.json` file inside it is shadowed by a read-only overlay bind when OAuth is active. See §11 for the rationale of the read-only overlay.

### E.17 Final Command

```bash
docker run "${RUN_FLAGS[@]}" <IMAGE_NAME> "${REMAINING_ARGS[@]}"
```

Where `<IMAGE_NAME>` is the most-derived image in the build chain:
- `sandy-project-<name>-<hash>` if Phase 3 exists
- `sandy-skills-<packs>` if skill packs enabled
- `sandy-claude-code` otherwise
