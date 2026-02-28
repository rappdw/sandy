# Sandy TODO

## Lessons from Anthropic's sandbox-runtime

Analysis of [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) (Anthropic's official OS-level sandbox using bubblewrap/Seatbelt) for capabilities sandy should consider.

### High Value

- [x] **Mandatory protected files** — Mount shell configs (`.bashrc`, `.zshrc`, etc.), `.git/hooks/`, `.claude/commands/`, `.claude/agents/`, `.vscode/`, `.idea/` as read-only inside the container. Prevents config injection and git hook tampering. *(Implemented: read-only bind mount overlays at container launch.)*

- [ ] **Domain-based network filtering** — srt uses HTTP + SOCKS5 proxies to filter outbound traffic by domain (allow `github.com`, `npmjs.org`, block everything else). Sandy's iptables approach blocks LAN/private ranges but allows all internet traffic. A proxy layer would give finer control and prevent data exfiltration to arbitrary domains. Could be opt-in via `SANDY_ALLOWED_DOMAINS` or `.sandy/network.conf`.

- [ ] **Violation monitoring / logging** — srt logs sandbox violations in real-time so users can see what was blocked. Sandy currently blocks silently. Adding visibility (at minimum, logging denied network connections and write attempts to protected files) would help debugging and build trust. Could log to `~/.sandy/sandboxes/<project>/violations.log`.

- [ ] **Symlink attack prevention** — srt checks for symlinks that cross isolation boundaries (e.g., `.claude → /etc/passwd`). Sandy's bind mounts could be vulnerable to symlinks in the project directory pointing outside the intended scope. Should validate that protected paths and workspace contents don't symlink outside the project tree.

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

- [ ] **Emphasize the "one command" story** — Projects like [cco](https://github.com/nikvdp/cco) (173 stars) and [ClaudeCage](https://github.com/PACHAKUTlQ/ClaudeCage) (134 stars) are popular partly because they're drop-in `claude` replacements. Sandy has a similar UX (`curl | bash` install + `sandy` command) but could market this more prominently.

- [ ] **Document Lima/Colima as Docker alternative for macOS** — A significant user segment wants sandboxing on macOS without Docker Desktop. Documenting lightweight Docker alternatives would help.
