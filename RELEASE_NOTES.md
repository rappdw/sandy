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
