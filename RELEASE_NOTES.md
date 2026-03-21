## sandy v0.7.1

### Security Fix

**Plugin leakage** — Host-installed plugins (and their enabled state) no longer leak into the container. Previously, workspace `.claude/plugins/` was mounted read-only into the container, making host-installed plugins active inside sandy. The host's `enabledPlugins` in `settings.json` also survived into fresh sandboxes on hosts without `node` (the stripping code had no fallback).

### Changes

**Writable sandbox overlays** — `.claude/commands/`, `.claude/agents/`, and `.claude/plugins/` are now mounted as writable sandbox directories instead of read-only host mounts. All three start empty. Claude can create slash commands, agents, and install plugins freely; changes persist in the sandbox across sessions without touching the host filesystem.

**Marketplace configuration baked into image** — Both [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) and [sandy-plugins](https://github.com/rappdw/sandy-plugins) marketplaces are now configured inside the container via `user-setup.sh` (part of the Docker image). Previously, marketplace catalogs were seeded from the host's `~/.claude/plugins/marketplaces/` directory, which could carry unwanted state. Claude Code fetches marketplace catalogs from GitHub on first `/plugin` browse.

**jq fallback for settings merge** — The sandbox creation settings merge (defaults, `enabledPlugins` stripping) now falls back to `jq` when `node` is not available on the host. Previously, hosts without `node` got no settings manipulation, leaving host `enabledPlugins` intact in fresh sandboxes.

### Bug Fixes

- cmux test assertions now use `jq` instead of `node`, fixing test failures on hosts without Node.js
- Host marketplace catalog seeding removed (eliminates a class of state leakage from `~/.claude/plugins/`)

### Documentation

- Expanded README security section with per-file/directory table explaining what each mount protects against
- Documented [known Claude Code bug](https://github.com/anthropics/claude-code/issues/18949) where plugin skills don't appear in slash command autocomplete until first invocation

---

## sandy v0.7.0

### Breaking Changes

**Safe config parser** — `.sandy/config` is no longer `source`'d as a bash script. It is now parsed as plain `KEY=VALUE` lines with an allowlist of recognized variables. If your config used shell logic (e.g., `SANDY_MODEL=$(some_command)`), convert it to a static value. Supported keys: `SANDY_SSH`, `SANDY_MODEL`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_CPUS`, `SANDY_MEM`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`. This change prevents arbitrary code execution on the host from untrusted workspace files.

### Security Hardening

**Capability dropping** — The container now runs with `--cap-drop ALL` and only adds back the minimum capabilities needed by the entrypoint (`SETUID`, `SETGID`, `CHOWN`, `DAC_OVERRIDE`, `FOWNER`). Previously Docker's full default capability set was retained.

**Process limit** — Added `--pids-limit 512` to prevent fork bombs inside the container from exhausting the host's PID space.

**Expanded protected paths** — `.git/config`, `.gitmodules`, `.gitconfig`, `.ripgreprc`, `.mcp.json`, and `.claude/plugins/` are now mounted read-only inside the container, in addition to the existing protected files. This blocks `.git/config` injection attacks (e.g., malicious `core.hooksPath` or `core.fsmonitor` directives that could execute code on the host).

**OAuth token isolation** — `CLAUDE_CODE_OAUTH_TOKEN` is now explicitly blocked from leaking into the container from the host environment. Sandy manages credentials via `.credentials.json`.

**Permission bypass consistency** — `skipDangerousModePermissionPrompt` in `settings.json` now respects `SANDY_SKIP_PERMISSIONS=false`, so users who opt into Claude's permission prompts get them consistently.

### Bug Fixes

- Auto-resume now works correctly for git submodule workspaces (previously always looked in `-workspace/` regardless of actual mount path)
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS` set in `.sandy/config` now correctly reaches the container (was missing from `docker -e` flags)
- `SANDY_CPUS` and `SANDY_MEM` are now overridable from `.sandy/config` (resource detection moved after config loading)
- macOS SSH agent relay preflight now checks for both `socat` and `python3` (previously only checked `socat` but used `python3` for port allocation)
- `docker network rm` no longer prints the network name to stdout on cleanup
- Cleanup no longer prints a spurious warning about the ACCEPT rule on normal exit

### Structural Improvements

**Entrypoint split** — The 149-line `bash -c '...'` block inside the entrypoint has been extracted into a standalone `user-setup.sh` script. This eliminates single-quote restrictions, enables ShellCheck analysis, and produces useful error line numbers when debugging.

**Function decomposition** — `ensure_build_files()` (363 lines) has been split into 5 focused generator functions: `generate_dockerfile_base()`, `generate_dockerfile()`, `generate_entrypoint()`, `generate_user_setup()`, `generate_tmux_conf()`.

**Helper functions** — Added `sha256()` (replaces 4 duplicate shasum patterns) and `json_merge()` (consolidates repeated node -e JSON manipulation boilerplate, with warnings on parse failure instead of silent data loss).

### Cleanup

- Removed dead python3 SSH relay fallback (~44 lines, unreachable after socat preflight)
- Removed stale `NODE_OPTIONS` from Dockerfile (Claude Code is now a native binary)
- Removed redundant `DISABLE_SPINNER_TIPS=1` (settings.json is authoritative)
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is now opt-in (set to `1` in `.sandy/config` to enable)
- Added `ENABLE_CLAUDEAI_MCP_SERVERS=false` in the container (cloud MCP connectors can't work in the sandboxed network)

### New Tests

- Config parser injection protection (verifies `source` is not used)
- `.git/config`, `.gitmodules`, `.claude/plugins/` write-protection
- Container hardening flags (`--pids-limit`, `--cap-drop ALL`, OAuth token blocking)
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS` passthrough verification

---

## sandy v0.6.0

### What's Changed

**Terminal notification support** — Sandy's inner tmux now has `allow-passthrough on`, so OSC escape sequences (9/99/777) from Claude Code flow through to the outer terminal. This enables notification rings, desktop alerts, and sidebar badges in [cmux](https://www.cmux.dev/), iTerm2, and other notification-aware terminals.

**cmux auto-setup** — When sandy detects it's running inside cmux (via `CMUX_WORKSPACE_ID`), it automatically installs a notification hook that emits OSC 777 sequences on Claude Code events. No manual configuration needed. Host-side Claude Code hooks (`~/.claude/hooks/`) are also mounted read-only into the container.

**Symlink protection** — Before launching the container, sandy scans the workspace for symlinks that point outside the project directory. If any are found, sandy warns and prompts for confirmation, preventing Claude from accessing files outside the sandbox via symlink traversal.

**Plugin marketplace** — The [sandy-plugins](https://github.com/rappdw/sandy-plugins) marketplace is pre-configured in every sandbox. Install plugins with `/plugin install synthkit@sandy-plugins`. The marketplace is seeded on every launch, so existing sandboxes pick it up automatically.

**Project name in tmux** — The tmux pane border and window title now show the project name (e.g., `sandy: my-project`) instead of a numeric index.

**Build improvements** — Claude Code version is cached at build time so the update check doesn't re-query npm on every launch. The update check has a 10-second timeout to prevent hangs on slow networks.

**Fixes:**
- git-lfs no longer initializes in non-git directories
- Output token limit raised from 32K to 128K (`CLAUDE_CODE_MAX_OUTPUT_TOKENS`)
- Fixed bash `!` escaping in `node -e` blocks that could cause SyntaxError on some systems

**Documentation** — Added comprehensive "What's in the Box" section to README enumerating all pre-installed toolchains, system tools, libraries, and the plugin marketplace.

**Test suite** — Added tests for terminal notification passthrough, cmux auto-setup (including idempotency), and symlink protection.
