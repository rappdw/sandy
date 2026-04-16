## sandy v0.11.3

Stabilizes the isolation hardening that shipped in v0.11.1/v0.11.2. Two bug fixes that surfaced during daily-driver use of v0.11.2. This is the target for the M2.3 7-day soak before work on M3 (user-setup.sh heredoc extraction) or the Sprint 3 egress proxy sidecar begins.

### Bug Fixes

**Empty-ro fixtures missing on fast-path launches** — `ensure_build_files()` creates `$SANDY_HOME/.empty-ro-file` and `$SANDY_HOME/.empty-ro-dir/` for the protected-path overlay mounts added in v0.11.1. When sandy hit the cached-image fast path, the fixture-creation block ran *after* the fast-path exit, so brand-new `$SANDY_HOME` directories (fresh installs, `rm -rf ~/.sandy` recovery) would launch with the fixtures missing and `docker run` would fail on the first ro-overlay mount. Moved fixture creation before every fast-path exit so it runs unconditionally.

**`/plugin install` EROFS crash and user-setup.sh ENOENT race** — The v0.11.1 S2.1 implementation mounted a sidecar `:ro` at `~/.claude/settings.json` inside the container so sandy could re-seed it every launch without giving the agent write access. This broke `/plugin install` (and any in-session `claude plugin marketplace add`) because Claude Code writes the updated `enabledPlugins` list back to `settings.json` — EROFS on a read-only mount. Walked back the strict `:ro` sidecar: the file is now rw inside the container, sandy re-reads the host copy every launch and re-overwrites the sandy-managed keys (`extraKnownMarketplaces`, `teammateMode`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, cmux hooks) while preserving `enabledPlugins` from the previous sandbox session so `/plugin install` survives relaunches. Also fixed a related ENOENT race where `user-setup.sh` could run its settings-merge block before the sandbox `claude/` dir existed on a first launch.

**`/ultrareview` and cloud features fail with 404 inside sandy** — Three issues combined to break Claude Code's cloud features (like `/ultrareview`) inside sandy:

1. **`ENABLE_CLAUDEAI_MCP_SERVERS=false`** (primary cause) — sandy's entrypoint disabled Anthropic's cloud MCP servers with the rationale that "cloud MCP connectors can't work in the sandboxed network." That rationale was wrong: sandy blocks LAN, not internet; Anthropic's servers are fully reachable. `/ultrareview` coordinates parallel review agents server-side via this infrastructure. Fixed: removed the flag entirely. **This change requires an image rebuild** (`sandy --rebuild`).

2. When `CLAUDE_CODE_OAUTH_TOKEN` was set, sandy skipped the credential file flow entirely — no `.credentials.json` was mounted. Cloud features need the full OAuth object (refresh token, scopes, subscription info) that the env var alone doesn't carry. Fixed: sandy now always loads and mounts the credential file alongside the env var.

3. The v0.11.1 S1.5 change mounted `.credentials.json` read-only, which would block token refresh/scoping writes. Fixed: reverted to rw. The tmpdir is ephemeral (fresh each launch, `rm -rf` on exit), so in-session writes don't persist to the host. Codex and Gemini credential mounts remain `:ro`.

### Documentation

**CLAUDE.md** — "Per-project Sandboxes" and "Protected Files" sections updated to describe the current (walked-back) settings.json semantics and the 0-byte stub detection helper.

---

## sandy v0.11.2

Refinements to the v0.11.1 isolation hardening: a protected-files regression walk-back, a more user-friendly passive-config approval flow, and a test-harness escape hatch.

### Bug Fixes

**Protected-files always-mount created 0-byte host stubs** — The v0.11.1 S1.2 pattern tried to mount `$SANDY_HOME/.empty-ro-file` over missing `.bashrc`/`.envrc`/etc. so the agent couldn't create them in-session. Under Docker's bind-mount target auto-creation semantics, the missing target materialized as a real 0-byte file on the host workspace whenever the ro mount was applied beneath the rw workspace bind. That broke direnv (which blocks on empty `.envrc`), polluted `git status`, and tripped every tool that checks for file presence as a meaningful signal. Reverted to existence-gating for protected **files**; protected **directories** keep the always-mount behavior from v0.11.1 because empty dirs are benign on the host (git doesn't track them and no tool reacts to their mere presence).

Residual F3 gap: an agent can still create `.bashrc`/`.envrc`/etc. in-session if the host didn't have one. The mitigation is that the newly-created file shows up in `git status` on the host for review, which is the detection path. Sandy now also detects leftover 0-byte stub files from earlier buggy builds (untracked by git and matching the protected-files list) and prints a one-shot `rm` command to clean them up. Stubs are not auto-removed — a 0-byte file could be intentional.

**Silent socat stderr on SSH relay shutdown** — The macOS SSH-agent TCP relay helper was printing "socat[pid] E Connection reset by peer" on every normal container exit because the in-container `socat` closes the forwarded socket before the host-side helper sees EOF. Pure noise. Piped the helper's stderr through a filter that drops the expected shutdown message while preserving real errors.

### New Features

**Per-workspace passive-key approval prompt** — v0.11.1's config tier-split silently *dropped* any privileged key set from a workspace `.sandy/config` (e.g. `SANDY_SSH=agent` committed to a repo). That was too strict: users with legitimate reasons to set `SANDY_SSH=agent` at workspace scope had no way to opt in without moving the key to `$HOME/.sandy/config` (which is wrong — it's per-workspace state). Replaced the silent-drop with an interactive approval prompt the first time sandy sees a privileged key from a passive source. The exact `KEY=VALUE` set is printed and the user approves explicitly. Approvals are persisted to `$SANDY_HOME/approvals/passive-<workspace-hash>.list` (first line is a sha256 of the sorted `KEY=VALUE` set). Subsequent launches with the same set are silent; any edit to `.sandy/config` that changes a privileged key re-prompts. Revoke with `rm $SANDY_HOME/approvals/passive-<hash>.list`. Headless mode (`-p`/`--print`/`--prompt`) and non-TTY stdin fail closed — the keys are dropped with a pointer to "launch sandy interactively once from this directory to approve."

**`SANDY_AUTO_APPROVE_PRIVILEGED` escape hatch** — CI / test harnesses that run headless can't hit the interactive prompt, and sandy's own `test/run-tests.sh` and `test/run-integration-tests.sh` run from the sandy repo directory which has a committed `.sandy/.secrets` with `GEMINI_API_KEY`. Added an env-only escape hatch (`SANDY_AUTO_APPROVE_PRIVILEGED=1`) that bypasses the prompt and exports all collected passive privileged keys in-memory. Intentionally env-only — the passive config allowlist does not include this key, so a committed `.sandy/config` cannot set it. Only a trusted shell or test harness can.

### Documentation

**SPECIFICATION.md** — Sync of the protected-files revert and the new approval flow across Appendices C.2, D, and E.

---

## sandy v0.11.1

**1.0-rc1 isolation hardening.** Closes the Critical/High findings from the ISOLATION_STRESS.md audit (Sprints 1 and 2 of the remediation plan). Seven findings are fully closed; one (F2 macOS network) is mitigated and documented honestly, with a full fix scheduled for a new Sprint 3 egress-proxy sidecar that's now in scope for rc1.

### Isolation hardening — Sprint 1

**Submodule gitdir protection (F1, Critical)** — `.git/modules/<sub>/hooks/`, `.git/modules/<sub>/config`, and `.git/modules/<sub>/info/` were fully writable in v0.11.0. A planted `post-checkout` hook under a submodule's gitdir would have run on the host the next time the user ran `git submodule update` or `git pull --recurse-submodules` — a clean host RCE. Sandy now walks `$WORK_DIR/.git/modules` (and the gitdir-side `modules/` for `--separate-git-dir` / worktree-of-submodule layouts) at launch and mounts each submodule's `config`, `hooks/`, and `info/` read-only. Handles nested submodules up to maxdepth 6.

**Top-level `.git/` protection extended** — Added `.git/HEAD`, `.git/packed-refs`, and `.git/info/` to the ro-overlay set. `.git/info/attributes` is a known filter-driver injection vector; closing it was the specific reason for adding `.git/info/`.

**Always-mount protected directories (F3, High)** — Protected **directories** (`.git/hooks`, `.vscode`, `.idea`, `.github/workflows`, `.circleci`, `.devcontainer`) are now mounted read-only unconditionally. When the host has no corresponding directory, sandy mounts a zero-byte `$SANDY_HOME/.empty-ro-dir` as an empty ro stand-in. This closes the bypass where an agent could create `.vscode/` (or any other missing protected dir) inside the container, leaving a config file that would execute the next time the host IDE opened the workspace. (See v0.11.2 for the walk-back on the corresponding file-level always-mount.)

**Expanded protected files list (F4, High)** — Added `.envrc`, `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml`. Added `.github/workflows/`, `.circleci/`, `.devcontainer/` as protected directories. `.github/workflows/` is particularly dangerous because the escape fires on `git push` — long after the session ends; set `SANDY_ALLOW_WORKFLOW_EDIT=1` in `.sandy/config` to opt in to editing workflows when the agent is doing legitimate CI work.

**Config tier-split (F5, High)** — `_load_sandy_config()` now takes a `tier` argument: `privileged` for `$HOME/.sandy/config` and `$HOME/.sandy/.secrets`, `passive` for `$WORK_DIR/.sandy/config` and `$WORK_DIR/.sandy/.secrets`. Privileged-only keys (`SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, credential env vars, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) are dropped when encountered in a passive source. Workspace `.sandy/config` committed to a repo can no longer disable isolation, extract credentials, or enable agent-teams for the next launch. (v0.11.2 softens the silent-drop into an interactive approval prompt.)

**`SANDY_ALLOW_LAN_HOSTS` use-site validation** — Rejects world-open CIDRs (`0.0.0.0/0`, `::/0`) with a hard error at launch, regardless of source. Even a privileged user writing that in their host config is almost certainly a mistake.

**Credential mount `:ro` symmetry (F7, Medium)** — `~/.claude/.credentials.json` and `~/.gemini/oauth_creds.json` are now mounted `:ro` inside the container, matching the existing Codex `auth.json` treatment. Prevents token leakage back to the host tmpfile via a compromised session and prevents stale-token races on exit. In-session token refresh still works — Claude Code's retry logic hits the remote refresh endpoint, not the creds file.

**Cleanup trap expanded** — `trap cleanup EXIT INT TERM HUP QUIT ABRT`. `QUIT` and `ABRT` are the main signals that previously bypassed the cleanup block; `SIGKILL` still can't be trapped but the residual window is now minimal.

**Symlink scan depth** — Bumped from maxdepth 5 to maxdepth 8. The walker already excludes `node_modules/`, `.venv*/`, and `.git/`, so the extra depth is cheap and covers modern monorepo layouts.

### Isolation hardening — Sprint 2

**Persistent symlink approval (F8, Medium)** — Dangerous symlinks (absolute links, or relative links that escape the workspace via `..`) are surfaced at launch. On first encounter sandy prints a y/N prompt listing each link and its target; on approval the set is persisted to `$SANDBOX_DIR/.sandy-approved-symlinks.list`. Subsequent launches with the same-or-reduced set proceed silently. A **new** escape (e.g. `ln -s /etc/shadow new-link` created after initial approval) causes a **hard error** at the next launch — sandy refuses to re-prompt, because a y/N that fires every session can be trained past, whereas a hard error forces a deliberate action.

**Settings.json re-seeding** — `~/.claude/settings.json` is now regenerated from the host copy on every launch with merge-preserving semantics: sandy-managed keys (`extraKnownMarketplaces`, `teammateMode`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, cmux hooks) are re-overwritten, host-side edits to other keys propagate, and `enabledPlugins` is preserved from the previous sandbox session. The original Sprint 2 plan mounted this `:ro` to prevent in-session mutation entirely, but see v0.11.3 for why that got walked back.

### macOS network honesty (F2, Critical — documented + mitigated, full fix deferred)

**Launch warning banner** — On macOS sandy now prints a loud warning at every launch announcing that network isolation is not active (Docker Desktop's VM does not isolate the container from the host LAN or `host.docker.internal`; Linux iptables DROP rules cannot be applied from macOS). This replaces the previous SPECIFICATION.md claim that "Docker Desktop's VM provides LAN isolation by default" which the stress test disproved.

**Magic-hostname nullification** — On macOS, sandy adds `--add-host gateway.docker.internal:127.0.0.1` and `--add-host metadata.google.internal:127.0.0.1` to every container. When `SANDY_SSH!=agent`, sandy also nullifies `host.docker.internal:127.0.0.1` (but not in SSH agent mode, because sandy's own TCP agent relay uses that hostname). This is defense-in-depth — raw-IP access to the host LAN is unaffected — but it removes the easiest default-hostname path and anything that calls by name.

**Full fix is Sprint 3, now in scope for 1.0-rc1.** An egress proxy sidecar implementing HTTP CONNECT + DNS allowlist will land as part of the rc1 cut. Until Sprint 3 ships, treat macOS sandy as "process and filesystem isolation only; no network isolation."

### New Features (unrelated to isolation)

**`--agent` CLI flag** — Overrides `SANDY_AGENT` for a single invocation without editing `.sandy/config`. Accepts the same comma-separated syntax: `sandy --agent claude,codex`. Takes precedence over both `.sandy/config` and the environment.

**`doctor.sh`** — New host readiness check script at `doctor.sh`. Inspects Docker availability, image store, sandy installation, credential sources, and known problem patterns on the current host. Intended as the first thing to run when something doesn't work; exits non-zero if anything blocking is found.

### Breaking Changes

**`SANDY_AGENT=both` alias removed** — The `both` alias was removed in favor of the comma-separated syntax (`claude,gemini`). Sandy now errors out on `both` with a pointer to the new form. If you have `SANDY_AGENT=both` in a `.sandy/config`, update it to `SANDY_AGENT=claude,gemini`.

### Tests

Eighteen new isolation regression tests (T14–T31) in `test/run-tests.sh` covering: submodule gitdir hook/config readonly-ness, `.git/info/` protection, `.vscode/` blocking when absent on host, `.envrc` blocking, `.github/workflows` protection + `SANDY_ALLOW_WORKFLOW_EDIT` opt-out, privileged-key drops from passive sources, `SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0` hard error, Claude credentials `:ro`, macOS launch banner presence, conditional `host.docker.internal` nullification under SSH agent mode, and persisted symlink approval + new-escape hard error.

### Documentation

**ISOLATION_STRESS.md** — Preserved as-is for historical reference; findings status tracked in the new Sprint 3 section of ROADMAP_1.0.md.

**SPECIFICATION.md** — Major rewrite of Appendices C.2 (settings.json), D.1 (macOS vs Linux), E.4 (run flags), E.9 (mounts), E.10 (creds), and E.11 (network).

**CLAUDE.md** — New sections on config tiers, protected files, submodule gitdir protection, macOS network limitation, and persistent symlink approval.

---

## sandy v0.11.0

PR 2.1 — venv overlay hardening. Fixes the `.venv` overlay that shipped in v0.10.0 so it actually materializes cleanly and handles concurrent launches without corrupting sandbox state.

### Bug Fixes

**`.venv` overlay never materialized** — The overlay dir is a bind mount, so the target `$WORKSPACE/.venv` always exists as a directory. `uv venv` refuses to create a venv into any existing directory with "A directory already exists at: .venv", so the first-launch materialization silently failed and every session fell back to the system Python. Fixed by invoking `uv venv --clear` (wipes contents in place without rmdir-ing the mount point). The `--clear` flag is now a regression-guarded invariant in `run-tests.sh` §9k. Also: `uv venv` stderr was being suppressed, so the actual error was invisible to users — it's now captured and printed on failure.

**Python version precedence** — Sandy was parsing `pyvenv.cfg` for the host Python version, but `.python-version` (if present) is the authoritative user-maintained pin and should win. `.python-version` is now checked first, `pyvenv.cfg` is the fallback. The parsed value is validated against `^[0-9]+\.[0-9]+$`; garbage is dropped and the container defaults to `3.12`.

**Symlinked `.venv/`** — Overlay detection now explicitly skips symlinked `.venv/` with an info message. Overlaying a symlink would shadow whatever the target happens to point at — too risky to do silently.

**Version drift warning** — On relaunch, sandy now compares the overlay's actual `pyvenv.cfg` version against the host's wanted version (from `.python-version` / host `pyvenv.cfg`). A mismatch (e.g. the user bumped `.python-version` after the overlay was built) prints a warning with the recreate command. Auto-recreate is deliberately not done — it would silently nuke installed packages.

### New Features

**Workspace mutex** — Only one sandy may run against a given workspace at a time. On launch, sandy takes a per-workspace lock (`mkdir` on `$SANDY_HOME/sandboxes/.<name>.lock` — atomic on every POSIX filesystem, no external dependency). A second launch fails fast with a clear error naming the holding pid and the command to clear a stale lock (e.g. after `kill -9`). The lock is released by the cleanup trap on normal exit, Ctrl-C, or crash. Two agents editing the same codebase would step on each other's edits anyway; deliberate parallelism should use separate workspaces.

### Tests

**Integration test image-build gating** — `run-integration-tests.sh` sections 4/6/7b (in-container PATH/version/synthkit/WeasyPrint checks for codex/gemini/claude) were gated on `docker image inspect` and silently skipped when the image wasn't pre-built. They don't actually need credentials — only the image — so a developer without e.g. `OPENAI_API_KEY` would never exercise the sandy-codex image at all. Added an `ensure_image_built` helper that invokes `sandy --build-only` from a throwaway workspace; skip branches are now `fail` so a broken build is loud.

**§9k/§9l regression guards** — `uv venv --clear` is asserted present; the workspace mutex is asserted to use `mkdir` (not flock) and release in the cleanup trap; `CONTAINER_NAME` is asserted deterministic (no PID suffix); the previous `_SANDY_HAVE_FLOCK` gating is asserted removed.

### Documentation

**CLAUDE.md** — "Workspace `.venv` overlay" section rewritten to describe the new materialization flow (`uv venv --clear`, no in-container locking, drift check). New "Concurrent launches" paragraph documenting the mutex.

**SPECIFICATION.md** — New Appendix E.0 (Workspace Mutex). Appendix E.7a updated for the simplified `user-setup.sh` flow.

---

## sandy v0.10.1

M1 blocker fixes from the code review on the `codex-support` branch, on the road to 1.0-rc1.

### Bug Fixes

**Resume fallback misfires on Ctrl-C** — `build_claude_cmd` appended a `|| $cmd_base` fallback after `claude --continue` so a missing-session-file race would re-launch without `--continue`. In practice, **any** non-zero exit triggered the fallback — Ctrl-C, `/exit`, a failed headless prompt — so users would see an unexpected fresh Claude session appear after exiting a resumed one. Dropped the fallback entirely; the session-detect check at sandy:1213 already guarantees `--continue` is only added when a session file exists.

**grep-regex injection in codex trust-entry check** — The idempotency check for the `[projects."..."]` block in `~/.codex/config.toml` was `grep -q "^\[projects\.\"${SANDY_WORKSPACE}\"\]"`, interpolating the workspace path into a grep BRE unescaped. The `/` and `.` characters in the path are regex metacharacters, so two workspaces differing only in those positions could falsely appear identical and skip the append. Switched to `grep -qF --` (fixed-string match).

### Tests

**In-container checks build images on demand** — `run-integration-tests.sh` sections 4/6/7b (codex/gemini/claude in-container image checks — PATH, version file, synthkit, WeasyPrint) were gated on `docker image inspect` and silently skipped when the image wasn't pre-built. They don't actually need credentials — only the image — so a developer without e.g. `OPENAI_API_KEY` would never exercise the sandy-codex image at all. Added an `ensure_image_built` helper that invokes `sandy --build-only` from a throwaway workspace; skip branches replaced with `fail` so a broken build is loud.

**Regression guards in `run-tests.sh` §9h** — Assert that `build_claude_cmd` has no `cmd || cmd_base` fallback pattern, that `cmd_base` is not referenced, and that the codex trust-entry check uses `grep -qF`.

---

## sandy v0.10.0

### New Features

**OpenAI Codex CLI support** — Sandy now supports the OpenAI Codex CLI alongside Claude Code and Gemini CLI. Select it with `SANDY_AGENT=codex` in `.sandy/config` or as an environment variable. Credentials are probed in order: `OPENAI_API_KEY` env var (what codex CLI reads natively), then the host's `~/.codex/auth.json` (copied ephemerally and mounted **read-only** — prevents token leakage back to host and prevents stale-token races). On first launch, sandy seeds `~/.codex/config.toml` with `sandbox_mode = "danger-full-access"` (sandy provides outer isolation; codex's Landlock sandbox does not nest cleanly in Docker) and a `[notice]` block to suppress first-run prompts. Project trust entries are appended at session start.

**Multi-agent mode** — Any combination of Claude Code, Gemini CLI, and Codex CLI can now run side-by-side in a tmux multi-pane layout. Set `SANDY_AGENT` to a comma-separated list: `claude,codex`, `gemini,codex`, `claude,gemini,codex`, etc. Aliases: `both` = `claude,gemini`, `all` = `claude,gemini,codex`. Multi-agent combos use a new `sandy-full` Docker image that includes all three agents; single-agent modes continue to use their dedicated images. The sandbox directory has sibling `claude/`, `gemini/`, and `codex/` subdirs mounted at the respective home paths; v1 layouts are auto-migrated on launch.

**Workspace `.venv` overlay** — Projects with a host-created `.venv/` (from `uv venv` or `python -m venv`) no longer break inside sandy. The host venv's `bin/python` symlink points at a host-only interpreter path that doesn't exist in the Linux container; sandy now shadows the host `.venv/` with a sandbox-owned overlay mount. The overlay contains a fresh venv matching the host's Python version (parsed from `pyvenv.cfg`), materialized on first launch and persisted across sessions. Host venv is never modified. Opt out with `SANDY_VENV_OVERLAY=0`.

**Sandbox version tracking** — Every sandbox now gets a `.sandy_created_version` marker on creation and `.sandy_last_version` refreshed per launch. When a sandbox predates a known breaking change (currently the v0.7.10 workspace mount path change from `/workspace` → `/home/claude/<rel>`), sandy warns on launch with the recreation command. The threshold is controlled by `SANDY_SANDBOX_MIN_COMPAT` in the script and bumps alongside future breaking changes.

**Strengthened Gemini CLI support** — Gemini credential probing now covers three sources in order: `GEMINI_API_KEY` env var, host `~/.gemini/tokens.json` (copied ephemerally), and host `~/.config/gcloud/application_default_credentials.json` (Google ADC / Vertex AI). Override the source with `SANDY_GEMINI_AUTH=auto|api_key|oauth|adc`. Gemini now auto-trusts the workspace via a seeded `trustedFolders.json` (no more per-launch trust prompts), and `SANDY_GEMINI_EXTENSIONS` supports automated installation of Gemini extensions at session start.

### Bug Fixes

**Session auto-resume for paths with `_` or `.`** — Claude Code normalizes any non-alphanumeric character in the workspace path to `-` when naming its project directory (`~/.claude/projects/-home-claude-dev-equity-analyzer`), but sandy was only transforming `/`. For workspaces whose paths contained `_` or `.`, `--continue` looked at the wrong directory and silently started a fresh session. Both the auto-resume check and the project-dir pre-creation now use `sed 's/[^a-zA-Z0-9]/-/g'` to match Claude Code's transform.

**`gh` multi-account auto-switch** — When multiple GitHub accounts are configured, sandy now detects the repo owner from the workspace remote URL and switches `gh` to the matching account on session start. Previously, the last-logged-in account was active and pushes failed when the owner was different.

**Codex `auth.json` empty-file crash** — Codex creates an empty `auth.json` on first run when using API-key auth, then crashes on subsequent launches trying to parse it. Sandy now removes empty `auth.json` files from the sandbox on launch.

**Codex `config.toml` corruption recovery** — Empty or corrupt `config.toml` files in the sandbox are now detected and re-seeded, instead of causing codex to launch with broken configuration.

**Codex git-repo-check** — Added `--skip-git-repo-check` to the codex launch so sessions in non-git workspaces don't fail with a spurious check error.

**Codex auth env var** — Corrected the environment variable name passed to codex: `OPENAI_API_KEY` (what the CLI actually reads), not `CODEX_API_KEY`.

### Tests

**Integration test suite** — New `test/run-integration-tests.sh` runs end-to-end Docker-based tests exercising real sandy launches, credential flows, and agent invocations. Complements the existing `test/run-tests.sh` which continues to cover script-level assertions.

**Expanded script tests** — `test/run-tests.sh` gained coverage for the `.venv` overlay detection logic (allowlist, `pyvenv.cfg` parsing with both `version` and `version_info` keys, symlinked `.venv` skip, opt-out via `SANDY_VENV_OVERLAY=0`).

### Documentation

**`ROADMAP_1.0.md`** — The path from this release to `1.0.0-rc1` is captured as a discrete sequence of PRs with exit criteria, soak gates, and target versions. Five milestones: `0.10.1` (blocker fixes from code review), `0.11.0` (venv overlay hardening + 7-day soak), `0.12.0` (architecture cleanup), `0.13.0` (surface stabilization), `1.0.0-rc1` (14-day pre-RC soak).

**Updated `CLAUDE.md` and `SPECIFICATION.md`** — New sections covering the `.venv` overlay, sandbox version tracking, multi-agent mode, and the full list of allowlisted config variables (now 40+ keys spanning all three agents).

### Known Issues

The following are tracked in `ROADMAP_1.0.md` as **PR 1.1** and will ship as `v0.10.1`:

- **Resume fallback misfire**: the `claude --continue` fallback pattern spawns an unwanted fresh session on Ctrl-C. Fix: drop the fallback; the auto-detect already knows when sessions exist.
- **grep-regex injection in codex trust-entry check**: `$SANDY_WORKSPACE` is interpolated into a BRE without escaping. Fix: switch to `grep -F`.

---

## sandy v0.7.5

### New Feature

**GPU passthrough** — New `SANDY_GPU` config variable passes host GPUs into the container via `--gpus`. Set `SANDY_GPU=all` in `.sandy/config` or as an environment variable. Requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) on the host.

The base image stays lean — CUDA is layered per-project via `.sandy/Dockerfile`. A ready-to-copy example is included at [`examples/gpu/Dockerfile`](examples/gpu/Dockerfile) with full CUDA toolkit and PyTorch-only options. Works on x86_64 and arm64 (including DGX Spark).

---

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
