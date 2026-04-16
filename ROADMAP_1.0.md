# Roadmap to 1.0-rc1

This plan walks from the current state of `main` to `1.0-rc1`. It's structured as a sequence of discrete PRs, each with a clear scope, exit criteria, and target version. **No new features** — 1.0 is a stability release. Every PR should make the existing surface more trustworthy without adding to it.

## Current state (2026-04-15)

- **Released**: `v0.10.0`, `v0.10.1`, `v0.11.0`, `v0.11.1`, `v0.11.2`
- **On main**: `0.11.3` (not yet tagged — cut pending)
- **M1 — shipped** as `v0.10.1`: PR 1.1 resume-fallback + codex grep-F + integration test image gating.
- **M2 — shipped** as `v0.11.0`: PR 2.1 venv overlay hardening (`uv venv --clear`, Python version precedence, symlink skip, drift warning, workspace mutex).
- **M2.5 — shipped** as `v0.11.1` / `v0.11.2` / `v0.11.3` (new milestone, inserted after ISOLATION_STRESS.md surfaced 10 findings during what was supposed to be M2.3 soak): Sprints 1 and 2 of the isolation hardening plan. Closes F1 (submodule gitdir RCE), F3 (protected-dir always-mount), F4 (expanded protected-file list), F5 (config tier-split), F7 (credential mount ro), F8 (persistent symlink approval) fully. F6 closed with an in-session-mutable compromise. F2 mitigated on macOS (launch warning + magic-hostname nullification); **full fix pulled into scope as Sprint 3**, see M2.7 below. F9 and F10 still open.
- **M2.3 — restart pending**: 7-day soak on `v0.11.3` as daily driver. Gate for starting M3. (The previous M2.3 clock on `v0.11.0` was interrupted by M2.5.)
- **M2.7 — not started**: new milestone. Sprint 3 egress proxy sidecar. The original plan deferred this to 1.1; pulled into rc1 because shipping 1.0 with a known Critical (F2 macOS) documented in its own spec is a credibility problem. See section below for scope and ordering.
- **M3 — not started**: user-setup.sh heredoc extract + `build_*_cmd` unify. Scope unchanged.
- **M4, M5 — not started**.

### Revised milestone ordering

M2.5 and the Sprint 3 decision shifted the downstream ordering. The new sequence:

```
M2.5 ✓ (isolation hardening Sprints 1+2) → tag 0.11.3
    ↓
M2.3 (restart 7-day soak on 0.11.3)          ← currently active
    ↓
M3 (heredoc extract + build_*_cmd unify)     → tag 0.12.0
    ↓
M2.7 (Sprint 3 egress proxy sidecar)         → tag 0.12.1 or 0.13.0-pre
    ↓
M2.7 soak (7-day)                            ← new gate, Sprint 3 is architecturally big
    ↓
M4 (surface stabilization)                   → tag 0.13.0
    ↓
M5 (14-day pre-RC soak)
    ↓
1.0.0-rc1
```

**Why M3 before M2.7 and not the reverse:** M3's user-setup.sh extraction is the highest-risk refactor on the roadmap (700 lines of container-side bash moving from a heredoc into a real template). M2.7 is the biggest additive change (~500 LOC Go binary, new Docker image, new sidecar network topology). Stacking them into one soak window destroys bisection when something regresses. Landing M3 first, soaking it, then landing M2.7 on a clean M3 base gives each change its own attribution window and keeps the total wall-clock roughly the same.

## Guiding principles

- **Each PR is independently reviewable and revertible.** If PR 4 breaks a user, reverting it must not force rolling back PR 5.
- **No PR introduces a new config key, flag, or user-visible feature.** The only additions are warnings, info messages, and internal refactors.
- **Every medium-or-higher finding from the code review gets addressed.** The low findings get fixed opportunistically as they fall into relevant PRs.
- **Soak before commit.** The two newest features (venv overlay, session-dir normalization) must accumulate real-world mileage before the RC is cut.
- **Documentation is part of done.** SPECIFICATION.md, CLAUDE.md, and README updates land in the same PR as the code they describe.

---

## Milestone 1 — Blocker fixes → `0.10.1`

Two bugs from the code review that would be embarrassing at 1.0. (A third "blocker" — session-dir name collision from aggressive normalization — was walked back during PR 1.1 execution after verifying that sandy's per-workspace sandbox isolation already prevents the collision. Each workspace gets a unique `$SANDBOX_DIR` keyed on `sha256($WORK_DIR)`, and `~/.claude/projects/` inside the container is per-sandbox, never shared. Two workspaces whose paths normalize to the same Claude Code project-dir name land in different sandboxes with completely separate session trees.)

### PR 1.1 — Fix resume fallback and codex grep-regex injection ✓ shipped as `v0.10.1`

**Scope** (both in `build_claude_cmd` and the codex trust-entry block):

1. **`cmd || cmd_base` fallback misfires on Ctrl-C** (sandy:1204, 1224-1226). Drop the fallback entirely. The auto-detect at 1213 already checks for session files before adding `--continue`, so the guess is never wrong. If `claude --continue` fails because the session file was deleted mid-launch, the user sees a clear error and can re-run — that's strictly better than silently spawning a fresh session on Ctrl-C.

2. **grep-regex injection in codex trust-entry check** (sandy:866). Change to `grep -qF -- "[projects.\"${SANDY_WORKSPACE}\"]"`.

**Version bump**: `0.10.1-dev` → `0.10.1`. Update `SANDY_VERSION` and add a RELEASE_NOTES entry.

**Exit criteria**:
- `bash test/run-tests.sh` passes.
- `bash test/run-integration-tests.sh` passes.
- Manual smoke test: Ctrl-C out of a resumed Claude session and confirm no second launch.

**Merge target**: `main`.

---

## Milestone 2 — Venv overlay hardening → `0.11.0`

The venv overlay is load-bearing but fresh. This milestone takes it from "works for the happy path" to "ready to be a 1.0 promise."

### PR 2.1 — Venv overlay race + validation ✓ shipped as `v0.11.0`

> **Execution note**: the materialization race fix landed differently than originally planned. The original scope proposed a host-side `flock` on `$SANDBOX_DIR/venv/.lock` plus a container-side fallback. During implementation this grew into a tangle (host flock + PID-suffixed container names + `status=exited` sweep + container-side venv flock), so the approach was simplified to a single `mkdir`-based workspace mutex at `$SANDY_HOME/sandboxes/.<sandbox>.lock` taken before any sandbox setup and released in the cleanup trap. One sandy per workspace at a time, no concurrent venv materialization, no in-container locking. Net `-128/+96` lines vs. the flock approach. Everything else in the scope below shipped as planned. The `uv venv` call also picked up `--clear` since the bind-mount target always pre-exists.

**Scope** (all in sandy around 1022-1059 and 2193-2216):

1. **Materialization race** (sandy:1028). Two concurrent sandy launches in the same workspace both run `uv venv` into the same bind mount. Fix: `flock -n` on `$SANDBOX_DIR/venv/.lock` around the materialization block. If flock fails, wait up to 30s for the other process to finish, then check for `pyvenv.cfg` and proceed to activation. Do the flock on the *host* side before `docker run` where possible — the host has a fixed path and can acquire the lock cleanly.

2. **`SANDY_VENV_PYTHON_VERSION` validation** (sandy:2205-2206). Wrap the parsed value with `[[ "$SANDY_VENV_PYTHON_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || SANDY_VENV_PYTHON_VERSION=""` before export. Garbage cfg → fall back to container default.

3. **Prefer `.python-version` over `pyvenv.cfg`** (sandy:1007-1015 vs 1022). If the host workspace has both, pass the `.python-version` value as `SANDY_VENV_PYTHON_VERSION` instead of parsing `pyvenv.cfg`. Document the precedence in CLAUDE.md's "Workspace .venv overlay" subsection.

4. **Python version drift warning** (sandy:1022-1052). After activation, compare the overlay's `pyvenv.cfg` version against `SANDY_VENV_PYTHON_VERSION`. On mismatch, print a warning with the fix command (`rm -rf $SANDBOX_DIR/venv` on the host, or `rm -rf .venv/*` inside the container followed by rematerialization).

5. **Symlinked `.venv` info message** (sandy:2197). Add `info "Skipping .venv overlay — .venv is a symlink"` when the skip branch fires. User sees a clear signal instead of silently wondering why overlay didn't engage.

**Tests** (in `run-tests.sh`):
- pyvenv.cfg with garbage version → empty `SANDY_VENV_PYTHON_VERSION`.
- `.python-version` present → takes precedence over `pyvenv.cfg`.
- Fixture workspace with symlinked `.venv` → info message in output, no mount added.

**Integration tests** (in `run-integration-tests.sh`):
- Launch sandy, `uv pip install six` inside, relaunch, verify six persists.
- Write a fake pyvenv.cfg with a different version, relaunch, verify the drift warning fires.

**Exit criteria**:
- All tests pass.
- Manual: two concurrent `sandy -p "import sys; print(sys.prefix)"` in the same empty-venv workspace — both succeed, no corrupt venv.
- Manual: flip host Python version with `uv python install 3.11 && uv venv --python 3.11`, relaunch sandy, drift warning fires.

### PR 2.2 — Sandbox version marker validation + version bump — partially shipped

- **Version bump** shipped as part of `v0.11.0` release work (`0.10.1` → `0.11.0-dev` → `0.11.0` → `0.11.1-dev`).
- **`.sandy_created_version` regex validation** was *not* done — deferred to **M4 PR 4.1** (allowlist/surface audit), where the validator fits naturally alongside the other surface-stability work. Tracked there.
- **CHANGELOG / RELEASE_NOTES**: shipped with `v0.11.0`.

### PR 2.3 — Soak baseline (no code, just time) — **restart pending on 0.11.3**

**This is not a PR, it's a gate.** The original M2.3 clock was set against `v0.11.0` and was interrupted when ISOLATION_STRESS.md surfaced ten findings mid-soak. Those findings became M2.5. The clock is now restarting against `v0.11.3` — the stable target that consolidates the Sprint 1/2 isolation hardening and its two follow-up bug fixes.

Use `v0.11.3` as daily driver for **at least 7 consecutive days** across regular projects (at minimum: sandy itself, one Python project with a venv, one multi-agent session). Log any surprises in a scratchpad. Issues found become hotfix PRs (`0.11.4`) and restart the clock; **M3 does not start until this gate clears**.

**Exit criteria**: 7-day diary with no unexpected behavior. If any surprises appear, fix, ship as `0.11.4`, and restart the 7-day clock against the fixed build.

---

## Milestone 2.5 — Isolation hardening → `0.11.1`, `0.11.2`, `0.11.3` ✓ shipped

This milestone didn't exist in the original roadmap. It was inserted after the 2026-04-13 ISOLATION_STRESS.md audit (run from inside a sandy container against its own source tree) surfaced 10 findings, two of them Critical host-escape / network-bypass paths. The findings made it clear that M2.3's 7-day soak on `v0.11.0` should not culminate in "that's it, move on to M3" — the hardening layer needed real work before soaking.

**Planning artifact**: `/home/claude/.claude/plans/enumerated-singing-steele.md` (Sprint 1, Sprint 2, and the original Sprint 3 carve-out). Three sprints, each with its own scope and exit criteria. Sprint 3 has since been re-scoped and pulled forward — see M2.7 below.

### Sprint 1 — rc1-blocker isolation fixes ✓ shipped as `v0.11.1`

Single commit on main (`4ca4251`). Closes F1, F3 (directory half), F4, F5, F7 from ISOLATION_STRESS.md. Also closes the smaller F2 mitigation half (launch warning + magic-hostname nullification).

**Nine sub-commits squashed:**

- **S1.0** — Empty-ro fixture foundation (`$SANDY_HOME/.empty-ro-file`, `$SANDY_HOME/.empty-ro-dir/`). Idempotent fixture creation in `ensure_build_files()`.
- **S1.1** — Submodule gitdir protection (F1). Walks `$WORK_DIR/.git/modules` and the gitdir-side `modules/` for `--separate-git-dir` layouts, mounts each submodule's `config`, `hooks/`, and `info/` ro. Nested submodules up to maxdepth 6. Also extended top-level `.git/` protection with `.git/HEAD`, `.git/packed-refs`, `.git/info/`.
- **S1.2** — Always-mount protected paths (F3). Directories get the empty-ro-dir fallback when host-absent. Files got the empty-ro-file fallback in the original commit, which **was walked back in Sprint 1.5** (see `91e6009`) because Docker's bind-mount auto-creation semantics materialized 0-byte stubs on the host workspace. Files are now existence-gated again; directories stay always-mount.
- **S1.3** — Expanded protected list (F4). Added `.envrc`, `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml` to the file list. Added `.github/workflows/`, `.circleci/`, `.devcontainer/` to the dir list. New `SANDY_ALLOW_WORKFLOW_EDIT` passive-safe opt-out for legitimate CI editing.
- **S1.4** — Config tier-split (F5). `_load_sandy_config()` takes a `tier` arg; privileged-only keys from passive sources were *silently dropped* in the first cut, then **softened to an interactive approval prompt in v0.11.2** (see `8192058`) after feedback that silent-drop was too aggressive for legitimate per-workspace `SANDY_SSH=agent` use. Also: `SANDY_ALLOW_LAN_HOSTS` use-site validation rejecting world-open CIDRs regardless of source.
- **S1.5** — Credential mount `:ro` symmetry (F7). Claude and Gemini creds now `:ro`. `trap cleanup EXIT INT TERM HUP QUIT ABRT`.
- **S1.6** — macOS network honesty (F2, mitigation only). Launch warning banner + `--add-host` nullification for `gateway.docker.internal`, `metadata.google.internal`, and (when `SANDY_SSH!=agent`) `host.docker.internal`. **Full fix pulled into M2.7** — was originally deferred to 1.1.
- **S1.7** — Symlink scan depth 5 → 8.
- **S1.8** — Single source of truth for protected path list via `_sandy_protected_files()` / `_sandy_protected_dirs()` helpers.
- **S1.9** — 18 new isolation regression tests in `test/run-tests.sh` (T14–T31).

### Sprint 2 — Settings re-seed + symlink approval ✓ shipped as `v0.11.1` / `v0.11.2` / `v0.11.3`

Single commit on main (`64a3018`), then two rounds of follow-up fixes.

- **S2.1** — Settings.json re-seeding (F6). Originally designed to mount a `:ro` sidecar at `~/.claude/settings.json` preventing any in-session mutation. **Walked back** in `v0.11.3` (`c6ae6c5`) after the strict `:ro` mount broke `/plugin install` with EROFS. Current semantics: rw inside the container, sandy re-reads the host copy every launch, preserves `enabledPlugins` from the previous sandbox session, re-overwrites sandy-managed keys. The agent *can* mutate its own settings mid-session; sandy-managed keys are the only invariants.
- **S2.2** — Persistent symlink approval (F8). First-encounter y/N prompt writes `$SANDBOX_DIR/.sandy-approved-symlinks.list`. Same-or-reduced set on relaunch proceeds silently; new escape causes a hard error at launch. No re-prompting on new escapes — a prompt can be trained past, a hard error forces a deliberate action.
- **S2.3** — 4 new tests (T31–T34).

### Post-sprint stabilization

Three follow-up patches shipped in `v0.11.2` and `v0.11.3`:

- **`91e6009`** — S1.2 file half revert (0-byte stubs on host).
- **`8192058`** — Passive-key silent-drop → interactive approval prompt.
- **`443c4f6`** — `SANDY_AUTO_APPROVE_PRIVILEGED=1` env-only test harness escape hatch.
- **`4ab70df`** — Silence socat stderr on SSH agent relay shutdown (macOS noise cleanup).
- **`7af29f8`** — SPECIFICATION.md sync for the protected-files revert and approval flow.
- **`b4c5849`** — Create empty-ro fixtures before fast-path exits (fresh-install launch bug).
- **`c6ae6c5`** — Plugin install EROFS walk-back + user-setup.sh ENOENT race fix.
- **`8670d57`** — S2.1 EROFS fix in `user-setup.sh` settings merge.

### Residual findings open at end of M2.5

| # | Finding | Severity | Status |
|---|---|---|---|
| F2 | macOS host/LAN reachable | Critical | mitigated + documented; **full fix is M2.7** |
| F3 (files half) | Agent can create `.bashrc`/`.envrc` in-session if host absent | High → **Medium** after mitigation | walked back from always-mount; detection via `git status`; 0-byte stub remediation helper added |
| F6 (in-session) | Agent can mutate `settings.json` within a session | High → **Medium** | sandy-managed keys re-overwritten every launch; in-session mutation window remains; the strict `:ro` sidecar approach broke plugins |
| F9 | DNS exfil via embedded resolver | Medium | deferred — naturally subsumed by M2.7 DNS allowlist |
| F10 | Fork bomb within pids-limit | Low | skipped (no urgency per original plan) |

---

## Milestone 2.7 — Egress proxy sidecar (Sprint 3) → `0.12.1` or `0.13.0-pre`

**New milestone, not in the original roadmap.** Pulled from 1.1 into rc1 because shipping 1.0 with a known Critical (F2 macOS network) documented in its own spec is a credibility problem. The launch warning is honest but not protective; users click through warnings and the current `--add-host` nullification is cosmetic against raw-IP LAN access.

**Ordering:** M2.7 lands *after* M3, not before or concurrent. M3 is the highest-risk *refactor* on the roadmap (heredoc extract); M2.7 is the biggest *architectural addition*. Stacking them into one soak means regression bisection has to untangle two huge changes. Landing M3 first, mini-soaking it, then landing M2.7 on a clean M3 base gives each change clean attribution.

### Scope discipline (tightened from the original Sprint 3 plan)

The original Sprint 3 plan scoped HTTP CONNECT + SOCKS5 + DNS allowlist with a full default allowlist. rc1 pulls this tighter:

- **rc1 ships HTTP CONNECT + DNS allowlist only.** SOCKS5 slips to `1.0.1` if it's not trivially in the box. Most tooling hits CONNECT first; SOCKS5 is a nice-to-have, not a blocker.
- **Permissive-first allowlist; tighten in 1.0.1+.** The rc1 allowlist covers the obvious set (Anthropic, OpenAI, Google APIs, npm, PyPI, GitHub, crates, Go proxy, GHCR). Users will hit edge cases (JFrog, private registries, HuggingFace, corp mirrors) during the M5 soak. Those become `SANDY_ALLOW_HOSTS` tuning reports, not blockers. **Do not try to get the list right on first try** — that's a recipe for the soak restarting every week when someone hits a missing host.
- **No MITM / cert injection / traffic logging / retries / caching.** Every one of those is tempting, every one is a rabbit hole. rc1's proxy is dumb: accept CONNECT, resolve DNS against allowlist, forward bytes. If that's ≤500 LOC of Go, great. If it's growing past 1000, stop and re-scope.
- **Linux iptables stays.** The proxy is **additive** on Linux, **replacement** only on macOS. Keep iptables as a belt-and-suspenders floor — zero cost, and it guards against bugs in the proxy itself.
- **Opt-in first, flip to default before rc1 cut.** Ship as `SANDY_EGRESS_PROXY=1` passive-safe key. First 3–4 days of the M2.7 soak, opt in manually. Catch obvious breakage without risking every launch. Then flip the default to on and soak the remaining 3–4 days against the real rc1 surface.

### Architecture

Two-network design per sandy container:

1. **Sidecar network** (`sandy_sidecar_<pid>`, bridge) — container can reach the proxy only.
2. **Proxy network** (`sandy_proxy_<pid>`, bridge) — proxy can reach the internet.

Container attaches only to the sidecar network with `--network sandy_sidecar_<pid>` plus `--dns <proxy-ip>` so all DNS queries go through the proxy. Proxy attaches to both networks.

**Not using `--internal`:** it breaks Docker's embedded DNS resolver for external lookups, and the proxy is providing its own DNS implementation anyway — the container never needs the Docker embedded resolver.

### PR 2.7.1 — Proxy binary (Go source + unit tests)

**Scope**: ~500 LOC of Go under `proxy/` implementing:
- HTTP CONNECT listener (port 3128)
- DNS listener (UDP 53) with allowlist matching (supports `*.example.com` wildcards)
- Allowlist loaded from `/etc/sandy-proxy.json` at startup
- Static binary, no runtime dependencies

**Tests**: unit tests for each protocol, allowlist matching edge cases, `NXDOMAIN` for non-allowlisted hosts.

**Exit criteria**: `go test ./proxy/...` passes. Proxy binary is ≤500 LOC (hard limit — if it's growing, re-scope).

### PR 2.7.2 — `sandy-proxy` Docker image

**Scope**: new `Dockerfile.proxy` in `$SANDY_HOME/` (generated template, same pattern as the other Dockerfiles). Phased between `sandy-base` and the agent images. Build once, cache aggressively — the proxy is stable code.

Hash-based rebuild logic consistent with the rest of the build pipeline (`.proxy_build_hash`).

### PR 2.7.3 — Launcher wiring

**Scope**: sandy creates the two networks per-launch (PID-keyed), starts the proxy container, injects `SANDY_EGRESS_PROXY=1` gate, tears everything down in the cleanup trap.

**`SANDY_EGRESS_PROXY` passive-safe key** — add to the passive allowlist in `_load_sandy_config()`. Default: `0` for the first week of M2.7 soak, then flipped to `1`.

**`SANDY_ALLOW_HOSTS` privileged-tier key** — comma-separated list of additional hosts to append to the allowlist. Privileged because user-added hosts expand the attack surface; must not be workspace-settable without the approval prompt.

### PR 2.7.4 — Remove macOS launch warning (problem now fixed)

**Scope**: one-line revert of the S1.6 warning banner. Keep the `--add-host` nullification as defense-in-depth.

### PR 2.7.5 — Integration tests

**Scope**: new tests in `test/run-integration-tests.sh`:
- Allowlisted host (e.g. `api.anthropic.com`) reaches its target from inside a sandy container
- Non-allowlisted host (e.g. `evil.example.com`) fails cleanly with `NXDOMAIN`
- Raw-IP to RFC 1918 address fails (verify on both macOS and Linux)
- Proxy survives container restart
- `SANDY_ALLOW_HOSTS=foo.bar.com` tunes the allowlist successfully
- Opt-out via `SANDY_EGRESS_PROXY=0` in an `.sandy/config` (passive source) works

### PR 2.7.6 — 7-day soak

**Gate, not a PR.** Opt-in for 3–4 days, flip default to on for 3–4 days, log surprises. Any new network failure = fix + restart 3–4-day window for that phase.

### Total budget

Plan for **2 weeks of focused work** on the binary + integration + test harness work, then **7 days of soak**. Plus the "`SANDY_ALLOW_HOSTS` kept hitting unexpected misses, let me cut 1.0.1 to tune it" possibility. rc1 is ~4–5 weeks of wall-clock from the start of M3.

---

## Milestone 3 — Architectural cleanup → `0.12.0`

With the behavioral fixes soaked, pay down the structural debt that the review surfaced. These PRs don't change user-visible behavior, but they make the 1.0 surface reviewable.

### PR 3.1 — Extract `user-setup.sh` from the heredoc

**Scope**: the ~700-line heredoc between `generate_user_setup()` (~sandy:665) and its closing `USERSETUP` marker (~sandy:1384) moves to a real file at `$SANDY_HOME/user-setup.sh.tmpl`. The template uses `@VAR@`-style placeholders for the small number of values that currently come from host-side variable expansion (there shouldn't be many — most of the heredoc is static bash). `generate_user_setup()` becomes a short function that reads the template, `sed`-substitutes the placeholders, and writes it to `$SANDY_HOME/user-setup.sh`.

**Why**: 40% of the review's findings lived in this heredoc. It's unshellcheckable as a string literal. After extraction:
- `shellcheck user-setup.sh.tmpl` runs as part of `test/run-tests.sh`.
- Diffs against `user-setup.sh.tmpl` show real changes instead of quoting noise.
- Future bugs in container-side logic can be unit-tested against the template directly.

**Approach**:
1. Copy the current heredoc body to `user-setup.sh.tmpl` verbatim. Replace any `$HOST_VAR` that refers to a value not available inside the container with `@HOST_VAR@`. Grep for `$` references in the heredoc — most should resolve to container-runtime values (`$HOME`, `$WORKSPACE`, `$SANDY_AGENT`) and stay as-is.
2. In `generate_user_setup()`, build the output by reading the template and substituting only the host-side values.
3. `install.sh` must ship `user-setup.sh.tmpl` alongside `sandy` — update the installer to copy both. Local installs (`LOCAL_INSTALL=./sandy`) need equivalent handling.
4. Add `shellcheck user-setup.sh.tmpl` to `test/run-tests.sh`. Fix every warning shellcheck flags — this is where you'll find the bugs review couldn't catch.

**Exit criteria**:
- `test/run-tests.sh` passes, including shellcheck with zero warnings on the template.
- `test/run-integration-tests.sh` passes.
- Manual: compare the generated `user-setup.sh` against the previous generated version byte-for-byte at an identical invocation. Any diff is an unintended behavior change.
- `install.sh` correctly ships the template — test a fresh install into a clean `$HOME`.

**Risk**: this is the most invasive PR on the roadmap. Budget extra review time. Do not bundle it with any other change.

### PR 3.1.5 — Post-extraction mini-soak (3 days, no code)

**Not a PR, a gate.** After PR 3.1 merges, daily-drive `main` (`0.11.x-dev` post-extraction) for **3 consecutive days** before starting PR 3.2.

**Why**: PR 3.1 is the highest-risk change on the whole roadmap — 700 lines of container-side bash moving from a heredoc into a real template, with sed-substitution added in the middle. Byte-for-byte diffing at build time catches gross errors, but subtle container-runtime regressions (env var expansion timing, shell escaping edge cases, first-launch vs. resume paths) only surface during real use. Stacking PR 3.2's `build_*_cmd` unification on top of an un-soaked PR 3.1 means that if something breaks, bisection has to untangle two large refactors at once.

The mini-soak costs three days and buys clean attribution. If PR 3.1 goes perfectly, those three days are spent as a daily-driver user — not wasted. If it doesn't, the three days save weeks of wrong-direction bisection later.

**Exit criteria**: 3 days of daily use with no template-related surprises. Any regression restarts the clock after the fix ships.

### PR 3.2 — Unify `build_*_cmd` functions

**Scope**: `build_claude_cmd`, `build_codex_cmd`, `build_gemini_cmd` (sandy:1185, 1239, 1278) currently duplicate verbose-mode exit-pause wrapping and arg-translation loops. Extract:

- `_sandy_wrap_cmd_exit_pause "$agent_name" "$cmd"` — handles the `if _sandy_is_headless` + verbose-mode pause suffix.
- `_sandy_translate_args "$agent_name" "$@"` — handles the `-p`/`--continue`/`--print` translations per agent.

Both helpers live near the existing `_sandy_build_agent_cmd` dispatcher. The three `build_*_cmd` functions shrink to agent-specific preamble + calls to the helpers.

**Why**: keeps the three agents in lockstep when new flags are added. Right now the Claude function has the `cmd || cmd_base` fallback (fixed in PR 1.1) while the others don't — that's how divergence starts.

**Exit criteria**: test suite green, manual smoke test for each agent in each of headless/interactive/verbose modes (9 combinations).

### PR 3.3 — Version bump to `0.12.0`

Standalone version bump + CHANGELOG. No code.

---

## Milestone 4 — Surface stabilization → `0.13.0`

Lock down the parts of the surface that become compatibility promises at 1.0.

### PR 4.1 — Config allowlist audit

**Scope**: walk every `SANDY_*` variable in `_load_sandy_config()` (sandy:1620-1640 or wherever it lives after PR 3.1).

For each key:
1. Confirm it's wired end-to-end (grep for uses — anything listed but unused gets removed).
2. Confirm it's documented in SPECIFICATION.md Appendix C.
3. Confirm the name follows consistent conventions (`SANDY_*` prefix, uppercase, no mixed styles).
4. Flag anything half-wired or experimental. Decisions: yank it, rename it, or commit to it.

**Deliverable**: SPECIFICATION.md Appendix C becomes a stability table:

| Key | Type | Default | Since | Stability |
|---|---|---|---|---|
| `SANDY_AGENT` | enum | `claude` | 0.1 | stable |
| `SANDY_VENV_OVERLAY` | bool | `1` | 0.10 | stable |
| ... | ... | ... | ... | ... |

Anything without "stable" at 1.0-rc1 gets removed from the allowlist before the RC cut.

**Exit criteria**: Appendix C covers 100% of the allowlist. Every entry has a "stable" marker or is removed.

### PR 4.2 — Sandbox compatibility story

**Decision required**. Pick one:

**Option A — forward-compat promise**: "Sandboxes created on any 1.x sandy work with any later 1.x sandy." Implementation:
- Add a test fixture: a sandbox directory snapshotted at 1.0-rc1. Every RC and release must pass a test that launches against the snapshot and resumes successfully.
- `SANDY_SANDBOX_MIN_COMPAT` becomes a hard floor enforced via `error` + exit, not a warning. Below the floor, refuse to launch and print the recreation command.

**Option B — auto-recreate**: "Sandboxes are tied to a sandy version; crossing the floor triggers automatic backup-and-recreate." Implementation:
- On version-mismatch detection, move the old sandbox to `$SANDBOX_DIR.bak-<version>` and recreate from scratch.
- Credentials are re-seeded from the host automatically; the user sees one "sandbox recreated" message.
- Old backups past 30 days are pruned on launch.

My recommendation: **Option A**. Simpler, more predictable, aligned with user mental models ("my sandbox is my sandbox"). Option B is tempting but the rug-pull feel is bad at 1.0.

**Exit criteria**: decision documented in SPECIFICATION.md + CLAUDE.md. Implementation and test landed.

### PR 4.3 — Multi-agent matrix tests

**Scope**: `run-integration-tests.sh` gains a test for each viable combination:

| Combo | Headless | Interactive | Auth modes tested |
|---|---|---|---|
| `claude` | ✓ | manual only | api_key, oauth |
| `gemini` | ✓ | manual only | api_key, oauth, adc |
| `codex` | ✓ | manual only | api_key, oauth |
| `claude,gemini` | routed to claude | manual only | claude's |
| `claude,codex` | routed to claude | manual only | claude's |
| `gemini,codex` | routed to gemini | manual only | gemini's |
| `claude,gemini,codex` | routed to claude | manual only | all three |

For each cell:
- Headless tests go in `run-integration-tests.sh` and run unattended.
- Interactive tests go in `TESTING_PLAN.md` as a manual checklist that must be walked through before each RC.

Cells that don't make sense (e.g. combos with no configured credentials) get documented as "not tested — requires X credential" rather than silently skipped.

**Exit criteria**: every cell in the matrix is either automated or on the manual RC checklist. Running the matrix takes < 15 minutes of wall time.

### PR 4.4 — Failure-mode integration tests

**Scope**: `run-integration-tests.sh` gains tests for the ways sandy can fail:

- Missing Docker daemon → clean error, non-zero exit.
- Corrupt `~/.claude/.credentials.json` → clean error, suggests re-login.
- Network unreachable → container still launches, agent prints a clear "offline" message.
- Read-only `$SANDY_HOME` → clean error, suggests `chmod`.
- Partial sandbox (e.g. `.sandy_created_version` present, `.claude/` missing) → sandy repairs or refuses cleanly.
- Docker image missing → rebuilds automatically (existing behavior, but assert it).

Each test should assert both the exit code and a specific substring of the error message, so future refactors can't silently degrade the error text.

**Exit criteria**: all six tests land and pass.

### PR 4.5 — Version bump to `0.13.0`

Standalone version bump + CHANGELOG.

---

## Milestone 5 — Pre-RC soak → `1.0.0-rc1`

### PR 5.1 — Pre-RC soak gate (no code)

**Not a PR, a gate.** Use `0.13.0` as your daily driver for **at least 14 consecutive days**. Same workflow as PR 2.3 but longer and with broader coverage:

- Every day, use sandy for at least one real task in each of: a Python project with venv, a JS/TS project, a Go or Rust project, a multi-agent session.
- Keep a running list of surprises in a scratchpad file (not committed).
- **Any surprise — even a cosmetic one — restarts the 14-day clock after it's fixed.**

This is the most important gate on the roadmap. Everything before it is "the review says it's ready"; this is "you've proven it's ready by living on it."

**Exit criteria**: 14 days of clean use, no surprises, no fixes applied during the window.

### PR 5.2 — 1.0-rc1 cut

**Scope**:

1. Version bump: `0.13.0` → `1.0.0-rc1`.
2. CHANGELOG: consolidated summary of all changes since the last release. Structure by user-visible impact (new features — *none*, behavior changes, bug fixes, deprecations, docs).
3. RELEASE_NOTES.md: a short blog-post-style writeup framing the 1.0 release. What does it mean? What's the stability promise? What's out of scope?
4. README.md: update any "beta" / "experimental" language.
5. SPECIFICATION.md: final review for accuracy. Every flag, path, and behavior mentioned must match `main`.
6. CLAUDE.md: update the "Versioning" section to describe the 1.x scheme.
7. Tag: `git tag 1.0.0-rc1`, push.
8. GitHub release: mark as pre-release, link to RELEASE_NOTES.md.

**Exit criteria**:
- Tag is pushed.
- Fresh install from the tag (`curl | bash` pointing at the tag, not `main`) produces a working sandy.
- All three test suites pass against the tag.
- The manual checklist from PR 4.3 has been walked through.

**After 5.2**: announce rc1 to whoever the audience is. Collect feedback for 1-2 weeks. Issues become `1.0.0-rc2` on a fast track; no feature additions. When rc2 (or rcN) soaks clean for a week, tag `1.0.0`.

---

## Out of scope (explicitly)

Things that will be tempting to slip in and must not be:

- **New agents.** If someone proposes integrating a fourth CLI, it's 1.1 territory.
- **New config keys.** If a bug fix seems to require one, it's the wrong fix.
- **Refactors beyond what's listed.** The `user-setup.sh` extraction is the one big structural change; everything else stays where it is.
- **Rebuilding the test harness.** Tests get *added*, not *restructured*.
- **Changing the Docker base image.** Stability, not modernization.
- **Adding Windows support, or anything that expands the platform surface.**

If any of these feel necessary, write them down in a `POST_1.0_IDEAS.md` scratch file and move on.

---

## Dependency graph

```
PR 1.1 (blockers) ✓ ──▶ tag 0.10.1 ✓
    │
    ▼
PR 2.1 (venv hardening) ✓ ──▶ tag 0.11.0 ✓
    │
    ▼
M2.5 Sprint 1 + Sprint 2 + stabilization ✓ ──▶ tag 0.11.1 ✓, 0.11.2 ✓, 0.11.3 ← cut pending
    │
    ▼
PR 2.3 (7-day soak on 0.11.3)    ← restart pending; gates M3
    │
    ▼
PR 3.1 (user-setup.sh extract)   ← must land alone
    │
    ▼
PR 3.1.5 (3-day mini-soak)       ← gates PR 3.2
    │
    ▼
PR 3.2 (build_*_cmd unify)
PR 3.3 (version bump)            ← blocks on 3.1, 3.2 ──▶ tag 0.12.0
    │
    ▼
M2.7 PR 2.7.1 (proxy Go binary + unit tests)
M2.7 PR 2.7.2 (sandy-proxy Dockerfile + phased build)
M2.7 PR 2.7.3 (launcher wiring + SANDY_EGRESS_PROXY opt-in)
M2.7 PR 2.7.4 (remove macOS launch warning)
M2.7 PR 2.7.5 (integration tests)
                                 ──▶ tag 0.12.1 or 0.13.0-pre
    │
    ▼
M2.7 PR 2.7.6 (7-day soak: 3-4d opt-in, 3-4d default-on)
    │
    ▼
PR 4.1 (allowlist audit + sandbox-marker validator)  ← parallel
PR 4.2 (compat story)                                ← parallel
PR 4.3 (multi-agent matrix)                          ← parallel
PR 4.4 (failure-mode tests)                          ← parallel
PR 4.5 (version bump)            ← blocks on 4.1-4.4 ──▶ tag 0.13.0
    │
    ▼
PR 5.1 (14-day soak gate on 0.13.0)
    │
    ▼
PR 5.2 (1.0.0-rc1 tag)
```

## Checkpoints

Treat each tag as a commitment: do not proceed to the next milestone until the previous tag's exit criteria are fully met. Tags are cheap; regrets at 1.0 are not.

| Tag | Status | Gates | What it proves |
|---|---|---|---|
| `0.10.1` | ✓ released | Blocker PRs merged + tests green | Review blockers are addressed |
| `0.11.0` | ✓ released | Venv hardening shipped; 7-day soak started | The two newest features are solid |
| `0.11.1` | ✓ released | M2.5 Sprint 1 shipped | Critical/High isolation gaps closed |
| `0.11.2` | ✓ released | M2.5 refinements (approval prompt, stub revert) | Sprint 1 fallout stabilized |
| `0.11.3` | cut pending | M2.5 stabilization fixes (plugin install, fast-path fixtures) | Stable target for restarted M2.3 soak |
| `0.12.0` | pending | M3 (heredoc extract + build unification) + 3-day mini-soak | 1.0 surface is reviewable |
| `0.12.1` or `0.13.0-pre` | pending | M2.7 (egress proxy sidecar) + 7-day soak | F2 macOS Critical finally closed |
| `0.13.0` | pending | M4 surface locked | Stability promises are explicit |
| `1.0.0-rc1` | pending | M5 14-day soak clean | Ready for users to form habits on |
| `1.0.0` | pending | rc soak clean | Stability over time |
