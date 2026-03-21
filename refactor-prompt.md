# Sandy Refactor: Combined Analysis Prompt

Use this as a one-shot prompt with sandy or Claude Code. It's designed to spawn parallel subagents for the compatibility audit and structural cleanup, then synthesize findings into a single prioritized action plan.

---

## The Prompt

```
I want to do a thorough refactor and cleanup pass on the sandy codebase. Spawn three subagents to work in parallel, then synthesize their findings into a single prioritized action plan saved to analysis/refactor-plan.md.

IMPORTANT CONTEXT: The analysis/ directory contains a prior security/architecture audit and TODO.md has a roadmap from that work. Each agent should read these first to avoid duplicating prior findings. Focus on what's NEW or was MISSED.

---

### Agent 1: Claude Code Compatibility Audit

Research what has changed in Claude Code from late 2025 through March 2026, then compare against what sandy assumes. Check each of these specifically:

**Credentials & OAuth:**
- Sandy seeds .credentials.json into the container (line ~948) and mounts .claude.json (line ~950). Recent Claude Code versions require BOTH files for a session to work. Verify .claude.json schema — sandy seeds `tipsDisabled` and `installMethod` (lines 836-844). Are there new required fields? Has the OAuth session state structure changed?
- Is the new CLAUDE_CODE_OAUTH_TOKEN env var something sandy should support or explicitly block?

**Environment variables (entrypoint, lines 290-293):**
- DISABLE_AUTOUPDATER=1 — still valid?
- DISABLE_SPINNER_TIPS=1 — still recognized, or renamed/removed?
- CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 — still experimental, graduated, or gone?
- CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000 — sandy hardcodes this. Default is now 64k for Opus 4.6. Is the env var still respected? Any new behavior?
- Any NEW env vars sandy should set? (CLAUDE_CODE_DISABLE_CRON, CLAUDE_CODE_DISABLE_1M_CONTEXT, etc.)

**Installation method (Dockerfile, line ~196):**
- Sandy installs via `curl -fsSL https://claude.ai/install.sh | bash`. Is this still the recommended path? Has the installed file layout changed from ~/.local/{bin,share}/claude?
- Sandy relocates the binary to /usr/local/bin/claude and data to /opt/claude-code. Still valid?
- The version check hits `https://storage.googleapis.com/claude-code-dist-86c565f3.../latest` (line ~529). Is this endpoint still active?

**Permission model & flags:**
- `--dangerously-skip-permissions` (line ~407) — still supported?
- `--teammate-mode tmux` (line ~404) — still the right flag name/value?
- `claude remote-control` (line ~397) — still supported?
- `bypassPermissions` in settings — still honored? Any new sandbox keys?

**~/.claude directory structure:**
- Are there new subdirectories (debug/, plugins/, session-env/, file-history/) that need persistence or explicit exclusion?
- Session file path: sandy checks `~/.claude/projects/-workspace/*.jsonl` for auto-resume (line ~422). Has session storage changed?

**Deliverable:** A findings list with three categories: BROKEN (definitely wrong), STALE (probably fine but references deprecated things), CURRENT (verified still correct). Include line numbers and sources.

---

### Agent 2: Structural Cleanup & Dead Code

Analyze the sandy script (1,183 lines) for internal code quality issues. Read analysis/ and TODO.md first to skip known items.

**Dead code & unreachable branches:**
- Variables set but never read? Flag parsing options that don't connect to anything?
- The python3 fallback SSH relay (lines ~1108-1132) duplicates socat, which is guaranteed to be on the host (macOS preflight at line ~576 enforces it) AND in the container (base image). Is the python3 fallback dead code?
- The python3 fallback in token_needs_refresh() (lines ~889-901) — node is guaranteed in the base image AND on the host (install.sh checks for it). Dead code?

**Duplication:**
- `shasum -a 256 2>/dev/null || sha256sum` appears on lines ~506 and ~519. Factor into a helper.
- The .claude.json node -e blocks (lines ~836-844 and ~851-862) are near-duplicates. Merge?

**Version mismatch:**
- SANDY_VERSION="0.5.0" (line 19) but RELEASE_NOTES.md says v0.6.0. Confirm and flag.

**Heredoc sprawl:**
- ensure_build_files() is ~360 lines because it contains 5 heredocs. The tmux.conf and entrypoint.sh are written to disk anyway — should they be separate source files? What's the tradeoff?

**Entrypoint complexity:**
- The entrypoint mixes root-phase (lines ~207-286) and user-phase (lines ~287-434) in one heredoc. The user phase is ~150 lines of single-quoted bash inside `exec gosu ... bash -c '...'`. This is hard to debug, hard to shellcheck, and quoting errors are invisible. Evaluate splitting into two scripts (root-entrypoint.sh + user-setup.sh).

**Network isolation:**
- The iptables section (lines ~769-824) handles 5 private ranges + container subnet exception. Could `docker network create --internal` plus a selective allowlist be simpler? What would break?

**Session auto-resume:**
- Lines ~411-425 use `ls *.jsonl` to detect prior sessions. Is globbing reliable here? Edge cases?

**Deliverable:** Prioritized list in three tiers: (1) likely bugs or correctness issues, (2) simplifications that cut lines or reduce complexity, (3) readability improvements. Line references for everything.

---

### Agent 3: Settings, Config & Hardening Review

Review sandy's configuration surface and security posture for cruft, missed hardening, and UX issues.

**Settings generation (.claude.json, lines ~826-863):**
- Sandy generates .claude.json with tipsDisabled and installMethod. It does NOT set bypassPermissions here (that's via the CLI flag). Is there drift between what the CLI flag sets and what the file contains? Could they conflict?
- The node -e JSON manipulation is fragile — no error handling if the JSON is malformed. Evaluate using jq (available? not in base image) or making the node script more defensive.

**Per-project config (.sandy/config, line ~569):**
- This is `source`'d as raw bash. Any injection risk if the workspace is untrusted? The script already validates SANDY_HOME for metacharacters (line ~23) but not individual config values.
- Are there config keys documented in README/CLAUDE.md that aren't actually read anywhere in the script?

**Protected files (somewhere in mount setup):**
- Find where protected file mounts are set up. Are there new sensitive paths that should be protected? (e.g., .claude/plugins/, .claude/agents/ — agents/ is listed in CLAUDE.md as protected, verify it's implemented)

**Resource defaults:**
- SANDY_CPUS defaults to all available (line ~500). SANDY_MEM defaults to available minus 1GB (line ~501). Are these reasonable? Should there be a cap?
- tmpfs sizes: /tmp at 1G (line ~943), /home/claude at 2G (line ~944). The CLAUDE.md mentions 2GB limit. Has usage grown with larger Claude Code installs?

**Cleanup on exit:**
- The cleanup() trap (lines ~811-823) handles network rules, Docker network, cred tmpdir, and SSH relay PID. Is anything leaked on unclean exit? What about the CRED_TMPDIR if the script is killed with SIGKILL?

**Deliverable:** Findings list with categories: SECURITY (hardening gaps), CRUFT (stale settings or dead config), UX (improvements for the operator). Include line references.

---

### Synthesis

After all three agents complete, combine their findings into a single `analysis/refactor-plan.md` with:

1. **Critical fixes** — things that are broken or will break soon
2. **Quick wins** — low-effort, high-value cleanups (dead code removal, version bump, etc.)
3. **Refactors** — larger structural changes with effort estimates and tradeoffs
4. **Deferred** — things noted but not worth doing now, with rationale

For each item, include: the finding, which agent surfaced it, affected lines, and a suggested fix or approach.
```
