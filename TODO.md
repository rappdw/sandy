# Sandy TODO

## Lessons from Anthropic's sandbox-runtime

Analysis of [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) (Anthropic's official OS-level sandbox using bubblewrap/Seatbelt) for capabilities sandy should consider.

### High Value

- [x] **Mandatory protected files** — Mount shell configs (`.bashrc`, `.zshrc`, etc.), `.git/hooks/`, `.claude/commands/`, `.claude/agents/`, `.vscode/`, `.idea/` as read-only inside the container. Prevents config injection and git hook tampering. *(Implemented: read-only bind mount overlays at container launch.)*

- [ ] **Domain-based network filtering** — srt uses HTTP + SOCKS5 proxies to filter outbound traffic by domain (allow `github.com`, `npmjs.org`, block everything else). Sandy's iptables approach blocks LAN/private ranges but allows all internet traffic. A proxy layer would give finer control and prevent data exfiltration to arbitrary domains. Could be opt-in via `SANDY_ALLOWED_DOMAINS` or `.sandy/network.conf`.

- [ ] **Violation monitoring / logging** — srt logs sandbox violations in real-time so users can see what was blocked. Sandy currently blocks silently. Adding visibility (at minimum, logging denied network connections and write attempts to protected files) would help debugging and build trust. Could log to `~/.sandy/sandboxes/<project>/violations.log`.

- [x] **Symlink protection** — Scans workspace for symlinks that escape the project tree before mounting. Prompts user to confirm if dangerous symlinks are found. Skips node_modules, .venv, and .git directories. *(Implemented: interactive prompt at startup.)*

### Medium Value

- [ ] **Dynamic config updates** — srt supports `--control-fd` for runtime permission changes without restarting the sandbox process. Sandy's model (one container per session) makes this less critical, but a mechanism to reload config (e.g., re-reading `.sandy/config` on signal) could be useful for long-running sessions.

- [ ] **MITM proxy support** — srt can route traffic through an inspection proxy with custom CA certs. Useful for enterprises that need traffic visibility or have corporate proxies. Could integrate with the domain-based filtering above.

- [ ] **Configuration validation** — srt uses Zod schemas for strict config validation. Sandy has no config file yet, but if one is added (e.g., `.sandy/config.json` for network rules, protected paths, resource limits), schema validation would prevent misconfiguration.

### Lower Priority / Future

- [ ] **Per-command sandboxing** — srt can sandbox individual commands, not just entire sessions. Sandy isolates the whole session. Per-command isolation would be a significant architectural change but could allow finer-grained permissions.

- [ ] **macOS native sandbox fallback** — For users without Docker, could use macOS `sandbox-exec` (Seatbelt) as a lighter-weight alternative. This is what srt does natively. Would broaden sandy's audience but is a large effort.

- [ ] **Web UI / monitoring dashboard** — Community project [sandboxed.sh](https://github.com/Th0rgal/sandboxed.sh) has a browser interface for managing multiple agent sessions. Could be valuable for teams.

## Community & Discoverability

- [ ] **Get listed in [awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code)** — Sandy doesn't appear in any community lists. Would increase visibility.

  <details>
  <summary>How to submit & draft issue text</summary>

  **Steps:**
  1. Go to https://github.com/hesreallyhim/awesome-claude-code/issues/new
  2. Select the **"Recommend a resource"** issue template (do NOT submit a PR — only the repo owner's Claude submits PRs)
  3. Fill in the template with the details below

  **Suggested section:** Tooling > General (alongside `run-claude-docker`, `viwo-cli`, `TSK`)

  **Resource name:** sandy

  **Resource URL:** https://github.com/rappdw/sandy

  **Description:**

  > **sandy** — Claude's isolated sibling. A single command that runs Claude Code in a fully sandboxed Docker container.
  >
  > `curl | bash` install, then just run `sandy` from any project directory. No config needed.
  >
  > **Key features:**
  > - **Filesystem isolation**: Read-only root filesystem, non-root user, no-new-privileges
  > - **Network isolation**: LAN/private ranges blocked via iptables, internet access preserved
  > - **Per-project sandboxes**: Each project gets its own isolated `~/.claude`, credentials, and package storage
  > - **Persistent dev environments**: pip, npm, go, cargo, and uv installs survive across sessions per project
  > - **Multi-language toolchains**: Python 3, Node.js 22, Go 1.24, Rust stable, C/C++ pre-installed
  > - **Protected files**: Shell configs, `.git/hooks/`, `.claude/commands/`, `.claude/agents/` mounted read-only to prevent injection attacks
  > - **Per-project Dockerfile**: Drop a `.sandy/Dockerfile` in your project to layer custom tools (e.g., quarto, typst) on top
  > - **SSH agent relay**: Token-based (default) or socket-forwarded git authentication
  > - **Auto-update**: Detects new Claude Code releases and rebuilds automatically
  > - **Git submodule support**: Correctly mounts worktree and gitdir for submodule workspaces
  >
  > Self-contained bash script (~950 lines). Works on Linux and macOS (via Docker Desktop or Colima).

  </details>

- [x] **Emphasize the "one command" story** — Projects like [cco](https://github.com/nikvdp/cco) (173 stars) and [ClaudeCage](https://github.com/PACHAKUTlQ/ClaudeCage) (134 stars) are popular partly because they're drop-in `claude` replacements. Sandy has a similar UX (`curl | bash` install + `sandy` command) but could market this more prominently. *(Done: README now leads with three-line install-and-run.)*

- [x] **Document Docker Desktop alternatives for macOS** — A significant user segment wants sandboxing on macOS without Docker Desktop. Sandy just needs a Docker-compatible CLI — document alternatives like Rancher Desktop, Colima, and Lima that provide this without a Docker Desktop license. *(Done: README Prerequisites section lists Rancher Desktop, Docker Desktop, Colima, and Lima.)*

## Plugin Marketplaces

Sandy currently seeds the official Anthropic plugin marketplace (copied from host) and `rappdw/sandy-plugins` (added via `extraKnownMarketplaces` in settings.json). Consider seeding additional community marketplaces to give users a richer plugin catalog out of the box.

- [ ] **Evaluate and seed community plugin marketplaces** — Candidates to investigate (verify repos exist, have valid `marketplace.json`, and are actively maintained before adding):

  | Marketplace | Focus | Why consider |
  |---|---|---|
  | `claudebase/marketplace` | Full-stack dev + security (SAST, dependency scanning) | Aligns with sandy's security-conscious audience |
  | `ahmedasmar/devops-claude-skills` | Terraform, K8s, CI/CD, GitOps, AWS | Natural fit for devs running containerized workflows |
  | `alirezarezvani/claude-skills` | 190+ skills across 9 domains | Broadest coverage, actively maintained |
  | `kivilaid/plugin-marketplace` | 100+ plugins, code review/testing/deployment | Good breadth |

  **Note:** `obra/superpowers-marketplace` has been merged into the official Anthropic marketplace — no need to add separately. Some of the above may also migrate to official over time; check before adding.
