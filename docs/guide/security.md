# Security notes

What sandy protects in your workspace, and where the full threat model lives. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

- The container runs as a non-root user (`sandy`, mapped to host UID)
- The root filesystem is read-only (`/tmp` and `/home/sandy` are tmpfs)
- `no-new-privileges` prevents privilege escalation
- Credentials are seeded into per-project sandboxes, not shared across projects
- claude.ai account connectors are suppressed by default (`SANDY_CLAUDE_CONNECTORS=1` to opt in); `SANDY_SUSPICIOUS=1` additionally strips the OAuth refresh token so a distrusted workspace only ever sees a short-lived access token
- Claude Code's own `/sandbox` (`sandbox.enabled`) is forced **off** in the sandbox's `settings.json` every launch, even if your host settings turn it on — sandy's container is the boundary and its egress proxy the one policy chokepoint, so an inner sandbox would only add a second, uncoordinated proxy. Your other `sandbox.*` settings are left as they are, and a repository's own `.claude/settings.json` can still turn it on (Claude Code gives project settings precedence)
- The working directory is bind-mounted read/write — Claude can modify your files there (that's the point)
## Protected files and directories

The workspace is bind-mounted read/write so Claude can modify your project files. However, certain files and directories are overlaid with read-only or sandbox mounts to block the most dangerous attack vectors for an AI coding agent: shell config injection, git hook injection, and tool config tampering.

**Read-only mounts** — host content is visible but cannot be modified:

| Path | Why |
|---|---|
| `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile` | Blocks shell config injection (e.g. aliases, PATH hijacking) |
| `.gitconfig` | Blocks git config tampering (e.g. credential helpers, aliases) |
| `.ripgreprc` | Blocks search config injection |
| `.mcp.json` | Blocks MCP server config tampering |
| `.envrc` | Blocks `direnv` auto-sourcing (executes on `cd`) |
| `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version` | Blocks asdf/mise/nvm/pyenv/rbenv toolchain hijacking |
| `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc` | Blocks registry hijacking and credential exfiltration |
| `.pre-commit-config.yaml` | Blocks pre-commit hook injection |
| `.git/config`, `.gitmodules`, `.git/packed-refs` | Blocks git remote/hook path manipulation and ref spoofing (`.git/HEAD` is left writable so `git switch` works in-container — #80) |
| `.git/hooks/` | Blocks git hook injection (pre-commit, post-checkout, etc.) |
| `.git/info/` | Blocks `.git/info/attributes` filter-driver injection |
| `.git/modules/<sub>/{config,hooks,info}` | Same, for every submodule gitdir (walked recursively) |
| `.vscode/`, `.idea/` | Blocks IDE task/launch config injection |
| `.github/workflows/` | Blocks CI pipeline escape (opt-out via `SANDY_ALLOW_WORKFLOW_EDIT=1`) |
| `.circleci/`, `.devcontainer/` | Blocks CircleCI and devcontainer escape |
| `.mirror/` | Blocks Mirror extension injection (Python that Mirror runs), 2.9.0 |
| `.claude/settings.json`, `.claude/settings.local.json`, `.claude/hooks/` | Blocks agent→host Claude Code hook injection (a host `claude` run in the same dir would otherwise execute an agent-written hook) |
| `.sandy/` | Blocks tampering with sandy's own build inputs **when `.sandy/` exists at launch** (existence-gated, like every row here — a session that starts without one can create it, and is warned about at session end). A per-project `.sandy/Dockerfile` build is additionally approval-gated by a hash of the whole build context, which is what stops a planted one from building unreviewed |

A redirected `core.hooksPath` (e.g. `.githooks/`) is resolved at launch and its target directory is mounted read-only too, so the protection follows git's actual hook path rather than only the default `.git/hooks/`.

**Sandbox-mounted directories** — overlaid with writable sandbox copies so Claude can create and modify them without touching the host:

| Path | Behavior |
|---|---|
| `.claude/commands/` | Copied from the workspace on the sandbox's first launch (empty if the workspace has none). Claude can create new slash commands |
| `.claude/agents/` | Copied from the workspace on the sandbox's first launch (empty if the workspace has none). Claude can create new agents |
| `.claude/plugins/` | Copied from the workspace on the sandbox's first launch (empty if the workspace has none). Managed via `/plugin install` inside the container |

`.gemini/extensions/` and `.gemini/commands/` are overlaid the same way for Gemini. The copy is made once, on the sandbox's first launch: later edits to these directories on the host do not reach the sandbox, and the agent's edits never reach the host. `sandy --reset-sandbox` discards the copies, along with the rest of the sandbox's agent state, so the next launch copies them afresh. If that path is a symlink (or sits under one, such as `.claude -> elsewhere`) pointing outside the workspace, the dangerous-symlink prompt asks about it, wherever it points. Approved, the sandbox gets a copy of the target's contents, and the agent's changes stay in the sandbox. The copy that is mounted is always a real directory, never a link. Since 2.9.0, sandy refuses to launch a sandbox whose copy is still a link left by an earlier version, and tells you the `rm` command that fixes it. Sandy's cleanup of empty leftover directories (`.github/workflows/` and the overlay stubs) never removes anything through a symlink.

**Mount policy (existence-gated).** Protected files and directories are mounted read-only only when they exist on the host — a path the host doesn't have gets no mount (an always-mount-with-empty-stubs approach was tried and reverted: the stubs polluted `git status`, broke `direnv`, and confused IDE scanners). The trade-off is covered by **session-end detection**: sandy records which protected paths existed at launch, and on exit warns about any protected file or directory that newly appeared (e.g. an agent-written `.git/hooks/post-checkout` or `.github/workflows/ci.yml`), with the remediation command — so you can review it before the next `git pull`/`push`/IDE-open would fire it.

**Caveat — a host IDE on the shared workspace.** Sandy's protection assumes the *host* isn't independently reading the workspace while the agent runs. A common setup breaks that assumption: the same project directory open in a host IDE (VS Code, Cursor, JetBrains) at the same time as the sandy session. The workspace is bind-mounted read/write, so an auto-execution config the agent writes into it — `.vscode/tasks.json`, a `.githooks/` script, a `.devcontainer/`, a `.claude/settings.json` hook — can be run by that host IDE, entirely outside sandy's boundary. Sandy blocks the common vectors *when they exist at launch* (the read-only mounts above) and warns at session end about newly-appeared ones, but this is existence-gated **detection, not prevention**: an absent `.vscode/` is unprotected in-session, and the end-of-session warning can be missed before the IDE auto-runs the file. When working an untrusted repository, don't leave the same workspace open in a host IDE during the session — read sandy's session-end report first.
