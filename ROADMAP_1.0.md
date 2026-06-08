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

---

## Re-baseline (2026-05-16)

Honest update: between 2026-04-15 and 2026-05-16, the "no new features until 1.0" rule didn't hold. Useful work happened, but it pushed the roadmap off course. Rather than pretend the drift didn't happen, this section re-baselines on what `main` actually is and shifts every downstream milestone by one minor version.

### What shipped off-roadmap

`v0.11.4` cut as a hotfix on top of `v0.11.3` to remove empty-stub debris from the protected-dir overlays — that was roadmap-adjacent (M2.5 stabilization tail) and stayed in scope.

After `v0.11.4` (on `main`, version `0.12.0-dev`), the following landed as **new features** rather than stability work:

1. **Introspection surface** (`c9bf58b`, `0dfe5d4`): `--print-schema`, `--print-state`, `--validate-config` JSON commands. Generated config-key tables for `CLAUDE.md` and `SPECIFICATION.md`. New `SPEC_INTROSPECTION.md` stability contract.
2. **Workspace canonicalization + stale-lock recovery + env-var precedence** (`81dcddd`, `6a26899`): `pwd -P` normalization for sandbox naming, lock-holder PID liveness probe, `_SANDY_ENV_SET_KEYS` snapshot so env vars beat config files cleanly.
3. **OpenCode as 4th agent** (`59d2680`, `69a8276`, `42e2806`, `d61d90f`, `50042cc`, `a813312`, `200ed5a`, `b2ef82d`, `e29f5b1`): 8 phases. New `sandy-opencode` image, 4-pane tmux layout, credential probe order, `OPENCODE_MODEL` / `SANDY_OPENCODE_AUTH` / `CODEX_HOME` config keys.
4. **`SANDY_LOCAL_LLM_HOST`** (`42e2806`, `6745b56`): single-host iptables ACCEPT for local-LLM passthrough, `host.docker.internal` mapping on Linux, opencode.json auto-generation.
5. **`/ss` screenshot skill** (`085088e`): `SANDY_SCREENSHOT_DIR`, helper bake into base image, per-agent skill files for claude/gemini/codex.
6. **`SANDY_EXTRA_ENV`** (`8a39956`): user-defined env-var passthrough for MCP-server tokens.
7. **Synthkit deprecated-plugin cleanup** (`4497802`): settings.json seed drops `synthkit@sandy-plugins` from `enabledPlugins`.
8. **Hybrid protected-dirs model** (`4158024`): reverts S1.2's always-mount + empty-fixture for absent dirs. Replaces with existence-gated mounts + post-session detection of newly-appeared protected paths. Adds documentation for fanotify FAN_OPEN_PERM as the long-term direction.

That's ~3 net new config keys (`SANDY_LOCAL_LLM_HOST`, `SANDY_SCREENSHOT_DIR`, `SANDY_EXTRA_ENV`, plus a few opencode-specific), one new agent, one new skill subsystem, and one non-trivial security-model rewrite. All useful. None of it was on the path to a stability freeze.

### Decision: re-baseline at `0.12.0` ✓ cut 2026-05-16

Rather than continue adding features and pretending the roadmap is intact, **`v0.12.0` was cut from `main` as the new feature-freeze point** (commits `4d2b21f` release + `430711b` post-release bump to `0.12.1-dev`; GitHub release at https://github.com/rappdw/sandy/releases/tag/v0.12.0). The soak clock restarts here. Every downstream milestone shifts by one minor version. The work to do (M3, M2.7, M4, M5) is unchanged; only the version labels move.

| Original target | Re-baselined target |
|---|---|
| `0.12.0` = M3 (heredoc extract) | `0.13.0` = M3 |
| `0.12.1` / `0.13.0-pre` = M2.7 (egress proxy) | `0.13.1` / `0.14.0-pre` = M2.7 |
| `0.13.0` = M4 (surface stabilization) | `0.14.0` = M4 |
| `1.0.0-rc1` after M5 14-day soak | unchanged — `1.0.0-rc1` after M5 14-day soak |

The 14-day pre-RC soak is the only gate that doesn't move; it's an absolute commitment to "this is the surface 1.0 ships with," and it locks at whatever version M4 produces.

### Why now

The hybrid protection model (commit `4158024`) is the natural cut point. It closes an architectural debt that was actively producing user complaints (empty stubs in workspaces) and it's the last "big shape change" on `main`. Everything after this should be either:

- Refactors that preserve behavior (M3).
- Additive plumbing that's opt-in until soaked (M2.7's `SANDY_EGRESS_PROXY=1` gate).
- Surface lockdown (M4).
- Time (M2.3, M3.5, M2.7.6, M5).

If a "new feature" idea surfaces during M2.3 onward, it goes into `POST_1.0_IDEAS.md` and waits.

### Updated current state (refreshed 2026-05-30)

- **Released**: `v0.12.0` (2026-05-16), `v0.13.0` (2026-05-30).
- **On main**: `0.13.1-dev` (post-release bump).
- **M2.3 soak**: ✓ cleared on `v0.12.0`. M3 followed.
- **M3**: ✓ shipped as `v0.13.0`. PR 3.1 (heredoc extract, #4), PR 3.1.5 (3-day mini-soak), PR 3.2 (build_*_cmd unify, #5), PR 3.3 (version bump + default model → opus 4.8). 1.0 surface is now reviewable — the unshellcheckable container-side bash is linted, the four agent command-builders are unified.
- **M2.7, M4, M5**: unchanged scope, shifted version labels per the table above. **M2.7 (egress proxy sidecar) is next** — targets `0.13.1` / `0.14.0-pre`, closes the F2 macOS Critical.

### Residual findings tracker (carried forward)

| # | Finding | Severity | Status as of 2026-05-16 |
|---|---|---|---|
| F2 | macOS host/LAN reachable | Critical | mitigated + documented; full fix still in M2.7 |
| F3 (dirs half) | Always-mount-with-empty-fixture pollution | n/a | **closed** by `4158024` hybrid revert |
| F3 (files half) | Agent can create `.bashrc`/`.envrc` in-session if host absent | Medium | unchanged — detection only |
| F6 (in-session) | Agent can mutate `settings.json` mid-session | Medium | unchanged — sandy-managed keys re-overwritten on next launch |
| F9 | DNS exfil via embedded resolver | Medium | to be closed by M2.7 — the proxy's allowlist resolver replaces the embedded resolver (NXDOMAIN for non-allowlisted names; `HTTPS`/`SVCB` refused) |
| F10 | Fork bomb within pids-limit | Low | unchanged — skipped per original plan |

---

## Pre-2026-05-16 status (historical)

The section below preserves the original 2026-04-15 plan structure. It's no longer the source of truth for *when* things happen, but the milestone scope sections are still accurate. Read this section as "what each milestone contains"; read the re-baseline section above for "what version it targets and when."

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

### PR 2.3 — Soak baseline (no code, just time) — **active on `v0.12.0`** (clock started 2026-05-16)

**This is not a PR, it's a gate.** The history of this gate:

- Original clock set against `v0.11.0`, interrupted by ISOLATION_STRESS.md → M2.5.
- Restart clock set against `v0.11.3`, never formally started; `main` drifted ~10 features past it through April-May 2026 (see Re-baseline section).
- **Current clock**: started 2026-05-16 against `v0.12.0`. Expected to clear ~2026-05-23 assuming no surprises.

Use `v0.12.0` as daily driver for **at least 7 consecutive days** across regular projects (at minimum: sandy itself, one Python project with a venv, one multi-agent session, one workspace with `SANDY_SCREENSHOT_DIR` configured, one workspace using `SANDY_EXTRA_ENV`). Log any surprises in a scratchpad. Issues found become hotfix PRs (`0.12.x`) and restart the clock; **M3 does not start until this gate clears**.

**Exit criteria**: 7-day diary with no unexpected behavior. If any surprises appear, fix, ship as `0.12.x`, and restart the 7-day clock against the fixed build.

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

## Milestone 2.7 — Egress proxy sidecar (Sprint 3) → `0.13.1` or `0.14.0-pre`

> **Re-baseline note (2026-05-16):** original target was `0.12.1`/`0.13.0-pre`. After the `v0.12.0` re-baseline, the version label shifts up one minor — actual target is `0.13.1` or `0.14.0-pre`.

> **Replan note (2026-06-04):** the architecture section was reviewed and revised after a critique found that the original "not using `--internal`" decision would have made the proxy security theater on macOS (the very platform M2.7 exists to fix). The `--internal` decision is flipped, a mandatory day-1 spike is added (PR 2.7.0), the CONNECT-vs-transparent-SNI choice is left to the spike, and several integration gaps (tool compatibility under `--internal`, `SANDY_LOCAL_LLM_HOST` collision, no macOS CI) are now called out explicitly. The original text is preserved in git history (pre-`m2.7-replan`).

**New milestone, not in the original roadmap.** Pulled from 1.1 into rc1 because shipping 1.0 with a known Critical (F2 macOS network) documented in its own spec is a credibility problem. The launch warning is honest but not protective; users click through warnings and the current `--add-host` nullification is cosmetic against raw-IP LAN access.

**Ordering:** M2.7 lands *after* M3, not before or concurrent. M3 is the highest-risk *refactor* on the roadmap (heredoc extract); M2.7 is the biggest *architectural addition*. Stacking them into one soak means regression bisection has to untangle two huge changes. Landing M3 first, mini-soaking it, then landing M2.7 on a clean M3 base gives each change clean attribution.

### The load-bearing primitive: `--internal` (corrected 2026-06-04)

The single most important decision in this milestone is whether the container's network is `--internal`. **It must be.**

Why this is the whole ballgame: F2 exists because the container's default route points at its bridge gateway, which lives in Docker Desktop's VM, which NATs onto the host LAN. Putting the container on a two-network setup does **not** change that — if the network the container sits on is a normal (non-internal) bridge, the VM still installs a MASQUERADE rule for it and the container can still `curl http://192.168.1.1` straight to the home router. Nothing forces traffic through the proxy; a malicious/injected agent simply doesn't use it. Raw-IP LAN access — exactly what F2 demonstrated by reading the host SSH banner — sails right past. The proxy becomes decorative.

A Docker `--internal` bridge is precisely what removes the MASQUERADE rule and severs that off-bridge route. It is the actual isolation mechanism. The proxy is what gives *controlled* egress back; `--internal` is what takes *uncontrolled* egress away.

The original plan's stated reason to avoid `--internal` ("it breaks Docker's embedded DNS resolver for external lookups") is correct but irrelevant: the design already passes `--dns <proxy-ip>`, replacing the embedded resolver entirely. We *want* the embedded resolver gone. `--internal` does not break container→proxy (intra-bridge L2) or proxy→internet (the proxy's second, non-internal network). It only breaks the thing we're deliberately replacing.

**Corollary the original plan under-weighted:** once `--internal` is correct, the proxy is the *only* way off the bridge. The failure mode is no longer just "a host is missing from the allowlist" — it's "any tool that doesn't route through the proxy is completely broken." That reframes the tool-compatibility question from a footnote into a primary design constraint (see "Transport model" below).

### PR 2.7.0 — macOS `--internal` spike (MANDATORY, do first) — ✓ PASSED 2026-06-04

**Was a go/no-go gate; it passed.** Everything downstream rests on assumptions about Docker Desktop's macOS networking that **cannot be tested in CI** (GitHub Actions is Linux-only; the platform being fixed has zero automated coverage). `test/spike/macos-internal-network-spike.sh` proves them by hand, once, in ~1 hour:

1. An `--internal` bridge network blocks raw-IP LAN egress (`curl http://<lan-ip>` fails where it succeeds on a normal bridge). ✓
2. A dual-homed sidecar on `(--internal, normal)` is reachable by a container on the internal net (intra-bridge L2 works despite `--internal`). ✓
3. That sidecar can reach the internet via its non-internal leg. ✓
4. `--dns <sidecar-ip>` propagates into a container on the `--internal` network. ✓

**Result (real Docker Desktop, macOS, 2026-06-04): 14/14 PASS, 0 FAIL.** The baseline F2 exposure reproduced (LAN reachable on a normal bridge), then `--internal` blocked it; the sidecar was reachable and could egress; `--dns` propagated. Notably **A1c confirmed `host.docker.internal` is unreachable under `--internal`** — which forces the `SANDY_LOCAL_LLM_HOST` decision below (now resolved in-scope, not deferred). The architecture is sound on this Docker Desktop version. **M2.7 is greenlit.**

Keep the spike in the repo: it doubles as the manual macOS re-verification step in PR 2.7.5's checklist (re-run it whenever Docker Desktop updates).

### Transport model — hybrid (decided 2026-06-04)

Settled after weighing real workflows (several repos use `SANDY_SSH=agent`, i.e. git-over-SSH). The decision: **transparent SNI/Host for HTTPS + an HTTP CONNECT endpoint for SSH.** Neither pure model is sufficient on its own under `--internal`, and the hybrid is the only one that keeps the actual tool surface working.

Why not either pure option:
- **Pure HTTP CONNECT** requires every tool to honor `HTTP_PROXY`/`HTTPS_PROXY`; anything that ignores it (raw sockets, some static Go binaries) hard-fails under `--internal` (no fallback route exists). Annoying for HTTPS tooling.
- **Pure transparent SNI** is beautifully zero-config for HTTPS (DNS→proxy-IP, demux by SNI), but **cannot handle git-over-SSH at all** — SSH carries no SNI to demux on, and under `--internal` there's no bypass route (unlike today's Linux iptables "narrow hole," `--internal` removes the route entirely, so SSH *must* traverse the proxy).

The hybrid:
- **HTTPS (the 99% path): transparent.** The bundled resolver answers allowlisted names with the proxy's own IP (NXDOMAIN otherwise). The container connects normally; the proxy reads TLS SNI (:443) / HTTP Host (:80), allowlist-checks, forwards. No `HTTP_PROXY` env, nothing to configure — `pip`/`uv`/`npm`/`cargo`/`go`/git-over-HTTPS all Just Work.
- **SSH (and any explicit-tunnel need): CONNECT.** The proxy also exposes an HTTP CONNECT endpoint (allowing `CONNECT <allowlisted-host>:22`). `user-setup.sh` injects an ssh `ProxyCommand` so `git@github.com` tunnels through it — the standard corporate-proxy pattern. The CONNECT endpoint doubles as a manual escape hatch for any oddball proxy-aware tool.

**ECH mitigation (the one SNI edge case worth handling):** TLS 1.3 Encrypted Client Hello would blind the SNI read, but ECH requires the client to first fetch an ECH config via a DNS `HTTPS`/`SVCB` record — and we own the resolver. The proxy refuses to serve `HTTPS`/`SVCB` records, so clients fall back to plaintext SNI. (Moot today anyway — CLI tools don't enable ECH by default — but free to defend.) The other SNI edge cases all fail *closed* (no-SNI client → reject; raw-IP-no-DNS → no route under `--internal` → fails; non-:443/:80 protocols → handled by the CONNECT path or out of scope), so none is a security or silent-bypass risk.

Still out of scope for rc1: arbitrary raw TCP to non-HTTP/non-SSH services (Postgres, Redis, etc.) — that's the SOCKS5 story, deferred to 1.0.1. The enumerated rc1 tool surface is: each agent CLI's API calls, `git` over both HTTPS and SSH, `pip`/`uv`/`npm`/`cargo`/`go`, and the local-LLM forward (below).

### Scope discipline (carried forward, with corrections)

- **rc1 ships the hybrid transport (transparent HTTPS + CONNECT-for-SSH) + DNS allowlist + the local-LLM forward.** SOCKS5 / arbitrary-TCP to non-HTTP/non-SSH services slips to `1.0.1`. Under `--internal`, tools that don't speak the proxy hard-fail (no network) — they don't silently reach the internet — so the tool-compat surface is enumerated up front, not discovered in the soak: each agent CLI's API calls, `git` over HTTPS *and* SSH (`SANDY_SSH=agent`), `pip`/`uv`/`npm`/`cargo`/`go`, and `SANDY_LOCAL_LLM_HOST`.
- **Permissive-first allowlist; tighten in 1.0.1+.** rc1 covers the obvious set (Anthropic, OpenAI, Google APIs, npm, PyPI, GitHub, crates, Go proxy, GHCR). Edge cases (JFrog, private registries, HuggingFace, corp mirrors) become `SANDY_ALLOW_HOSTS` reports, not soak-restarts. **Do not try to get the list right on the first try.**
- **No MITM / cert injection / traffic logging / retries / caching.** rc1's proxy is dumb: match host against allowlist, forward bytes. It never terminates TLS — SNI is read from the unencrypted ClientHello, the bytes are passed through untouched, so there's no cert injection and no trust-store surgery. Budget: the hybrid (transparent demux + CONNECT + trivial resolver + allowlist) is more than a pure model — target **≤700 LOC**, hard ceiling **1000**; if approaching it, re-scope. **One dependency is allowed** (`miekg/dns`) — though the resolver here is trivial (constant-IP answer for allowlisted names, refuse `HTTPS`/`SVCB`, NXDOMAIN otherwise), so stdlib may suffice.
- **Linux: `--internal` makes the existing iptables DROP rules redundant** (a container that can't route off the bridge can't reach RFC1918 regardless). Keep the iptables path as a cheap belt-and-suspenders, but don't pretend it's load-bearing once `--internal` lands.
- **Opt-in first, flip to default before rc1 cut.** Ship as `SANDY_EGRESS_PROXY=1` passive-safe key. First 3–4 days of the soak, opt in manually; then flip the default on for the remaining 3–4 days.

### Architecture

Two networks per sandy launch (PID-keyed):

1. **Sidecar network** (`sandy_sidecar_<pid>`, **bridge `--internal`**) — the container and the proxy live here. No route off-bridge: this is what closes F2.
2. **Egress network** (`sandy_egress_<pid>`, normal bridge) — only the proxy attaches here; this is the proxy's path to the internet.

The container attaches **only** to the sidecar network, with `--dns <proxy-sidecar-ip>`. No `HTTP_PROXY` env for the HTTPS path (transparent), but the container's ssh config gets a `ProxyCommand` pointing at the proxy's CONNECT endpoint (see PR 2.7.3). The proxy is dual-homed (sidecar + egress).

### `SANDY_LOCAL_LLM_HOST` × `--internal` — proxy forwarding (decided 2026-06-04, in-scope for rc1)

Today `SANDY_LOCAL_LLM_HOST` pokes an iptables hole so the container can reach `host.docker.internal:port`. Under `--internal`, `host.docker.internal` is off-bridge and unreachable by construction (spike A1c confirmed). **Decision: the proxy forwards to it — `SANDY_LOCAL_LLM_HOST` and `SANDY_EGRESS_PROXY` work together, no mutual-exclusion footgun.**

Mechanism (reuses the hybrid's CONNECT/forward machinery, so it's nearly free once SSH-over-CONNECT exists):
- The configured `SANDY_LOCAL_LLM_HOST=host:port` is added to the allowlist as a `host:port` literal.
- The proxy listens on that port and does a **dedicated TCP forward** to `host.docker.internal:port` on its egress (non-internal) leg — where `host.docker.internal` *is* reachable (Docker Desktop maps it on a normal network). No demux needed: it's a fixed port→host:port mapping, simpler than the SNI path.
- For plain-HTTP local LLMs (Ollama, vLLM — the common case), no TLS is involved, so the forward is a raw byte pipe. The opencode auto-config continues to point at `http://host.docker.internal:<port>/v1`; DNS for `host.docker.internal` resolves to the proxy IP, and the proxy forwards.

Rationale for doing it now rather than deferring: the maintainer actively uses local-LLM passthrough, the forward path is shared with the SSH-CONNECT work (low marginal cost), and a hard-error "pick one" would be a poor rc1 experience for exactly the isolation-conscious users most likely to run a local model.

### PR 2.7.1 — Proxy binary (Go source + unit tests)

**Scope**: Go under `proxy/` implementing the hybrid transport:
- **DNS responder** (UDP 53): allowlisted name → proxy's own IP; refuse `HTTPS`/`SVCB` records (ECH defeat); `NXDOMAIN` otherwise. Closes F9 (DNS exfil).
- **Transparent listener** (:443 SNI demux, :80 Host demux): read the host from the unencrypted ClientHello / HTTP request line, allowlist-check, then splice bytes to the real host (resolved on the egress leg). Never terminates TLS.
- **CONNECT endpoint** (:3128): `CONNECT <host>:<port>` allowlist-checked, then byte-splice. Used by ssh `ProxyCommand` for git-over-SSH, available as a manual escape hatch.
- **Dedicated forward** for `SANDY_LOCAL_LLM_HOST`: listen on the configured port, splice to `host.docker.internal:port`.
- **Allowlist** loaded from `/etc/sandy-proxy.json` at startup: exact names, `*.example.com` wildcards, and `host:port` literals.

Static binary; at most one dependency (`miekg/dns`), though stdlib likely suffices given the trivial resolver.

**Tests**: allowlist matching (exact, wildcard, `host:port`); SNI extraction incl. no-SNI (→ reject) and split/oversized ClientHello; HTTP Host extraction; CONNECT allow/deny; `HTTPS`/`SVCB` refusal; `NXDOMAIN` for non-allowlisted; the local-LLM forward.

**Exit criteria**: `go test ./proxy/...` passes; binary ≤700 LOC excluding the dep (hard ceiling 1000 — if approaching it, re-scope, e.g. drop the local-LLM forward to 1.0.1).

### PR 2.7.2 — `sandy-proxy` Docker image

**Scope**: new generated `Dockerfile.proxy` in `$SANDY_HOME/`, phased between `sandy-base` and the agent images, hash-rebuild via `.proxy_build_hash`. Build once, cache aggressively.

### PR 2.7.3 — Launcher wiring — ✓ DONE 2026-06-08

> **Tri-state pivot (2026-06-08).** `SANDY_EGRESS_PROXY` shipped as a **tri-state**, not a binary: `0`=off, `1`=permissive (block private/LAN/host/metadata, allow all internet), `2`=strict (default allowlist + `SANDY_ALLOW_HOSTS` only). Permissive (1) closes F2 — the whole point of M2.7 — with ~zero friction (no allowlist to maintain, any public host just works) and is the **intended default-on posture for 1.0**. Strict (2) additionally blocks exfil-to-arbitrary-internet but fails closed. The proxy config consumes a `"mode"` field ("permissive"/"strict"); the proxy code (PR 2.7.1) was extended with a mode-aware `Policy` (commit on `m2.7-proxy`). This supersedes the original "default 0, flip to 1" plan — the flip target is now mode 1 specifically, and mode 2 is the opt-in hardened tier.

**Scope** (done): sandy creates the two networks per-launch (sidecar `--internal`, egress normal), starts the dual-homed `--read-only --cap-drop ALL` proxy container at a fixed sidecar IP (first non-overlapping `/24` from a candidate list, so `--ip` works), attaches the agent with `--network sidecar` + `--dns proxy-ip`, gates on the normalized `_SANDY_PROXY_ON` predicate, skips iptables in proxy mode, and tears down both networks + the proxy container in `cleanup()`.

**ssh `ProxyCommand` injection** (done) — when the proxy is on, the entrypoint prepends `Host * ProxyCommand socat - PROXY:<proxy-ip>:%h:%p,proxyport=3128` to `~/.ssh/config`, routing git-over-SSH through the proxy's CONNECT listener (`:3128`). `github.com:22` is in the default allowlist. macOS caveat: the SSH-*agent* socket relay can't cross `--internal`, so host-agent key signing is unavailable under the proxy on macOS (git-over-SSH still works); sandy warns and recommends `SANDY_SSH=token`.

**`SANDY_EGRESS_PROXY` passive-safe key** (done) — passive tier (per-project opt-in). Normalized once into `_SANDY_PROXY_ON` + `_SANDY_PROXY_MODE`.

**`SANDY_ALLOW_HOSTS` privileged-tier key** (done) — comma-separated additions to the allowlist. Privileged: user-added hosts expand the attack surface and must not be workspace-settable without the approval prompt.

**Allowlist assembly** — sandy composes `/etc/sandy-proxy.json` from the built-in default set + `SANDY_ALLOW_HOSTS` + (when set) the `SANDY_LOCAL_LLM_HOST` `host:port` literal, and mounts it into the proxy container.

**Interaction guardrails**: `SANDY_LOCAL_LLM_HOST` + proxy is now *supported* (forward path above), not an error; confirm `cleanup()` removes both networks + the proxy container on all trapped signals (EXIT INT TERM HUP QUIT ABRT), including the SIGKILL-leak caveat already documented for the main container.

### PR 2.7.4 — Remove macOS launch warning (problem now fixed)

**Scope**: revert the S1.6 macOS warning banner — **but only behind `SANDY_EGRESS_PROXY` being on**. If the proxy is off (opt-out, or a build without it), the warning must still fire: the honest-warning posture is correct whenever the real isolation isn't active. Keep the `--add-host` nullification as defense-in-depth regardless.

### PR 2.7.5 — Integration tests + manual macOS checklist

**Automated (Linux CI)** in `test/run-integration-tests.sh`:
- Allowlisted host (`api.anthropic.com`) reachable from inside a sandy container with the proxy on (transparent HTTPS path).
- Non-allowlisted host (`evil.example.com`) refused / `NXDOMAIN`.
- `SANDY_ALLOW_HOSTS=foo.bar.com` tunes the allowlist.
- Opt-out via `SANDY_EGRESS_PROXY=0` in a passive `.sandy/config` works.
- Proxy survives container restart; cleanup removes both networks.
- Tool-compat smoke through the proxy: `git clone` over **HTTPS**, `git clone` over **SSH** (`SANDY_SSH=agent` → ProxyCommand→CONNECT path), `pip install`, `npm install`.
- Local-LLM forward: a stub HTTP server on the host reachable via the proxy when `SANDY_LOCAL_LLM_HOST` is set alongside the proxy.
- ECH defeat: the resolver refuses `HTTPS`/`SVCB` queries.

**Manual macOS checklist (gates the rc1 cut — there is no macOS CI)**, documented in `TESTING_PLAN.md`:
- Re-run `test/spike/macos-internal-network-spike.sh` → all-PASS on the current Docker Desktop.
- Raw-IP to an RFC1918 LAN address fails with the proxy on.
- `host.docker.internal:22` (host SSHD) unreachable with the proxy on (the F2 repro).
- `git clone` over SSH succeeds in a `SANDY_SSH=agent` repo with the proxy on.
- Local Ollama/vLLM reachable via `SANDY_LOCAL_LLM_HOST` + proxy on.
- The same HTTPS tool-compat smoke as CI, run by hand on macOS.

### PR 2.7.6 — 7-day soak

**Gate.** Opt-in for 3–4 days, flip default on for 3–4 days, log surprises. Any new network failure = fix + restart that phase's window.

### Total budget

PR 2.7.0 spike: ✓ done (~1 hour, passed 2026-06-04). The hybrid transport + local-LLM forward adds modestly to the original estimate (more proxy LOC: ~700 vs ~500, plus ssh `ProxyCommand` wiring), so budget **~2–2.5 weeks** of build/test/harness work, then **7 days** of soak. Plus the "`SANDY_ALLOW_HOSTS` kept missing hosts → cut 1.0.1 to tune" possibility. The spike already de-risked the load-bearing assumption, so the remaining risk is implementation, not architecture.

---

## Milestone 3 — Architectural cleanup → `0.13.0`

> **Re-baseline note (2026-05-16):** original target was `0.12.0`. After the `v0.12.0` re-baseline cut from current `main`, this milestone now targets `0.13.0`. Scope below is unchanged.

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

### PR 3.3 — Version bump to `0.13.0`

Standalone version bump + CHANGELOG. No code. (Re-baselined: was `0.12.0` in the original plan.)

---

## Milestone 4 — Surface stabilization → `0.14.0`

> **Re-baseline note (2026-05-16):** original target was `0.13.0`. After the `v0.12.0` re-baseline, this milestone now targets `0.14.0`. Scope below is unchanged.

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

### PR 4.5 — Version bump to `0.14.0`

Standalone version bump + CHANGELOG. (Re-baselined: was `0.13.0` in the original plan.)

---

## Milestone 5 — Pre-RC soak → `1.0.0-rc1`

### PR 5.1 — Pre-RC soak gate (no code)

**Not a PR, a gate.** Use `0.14.0` (the M4 output — re-baselined; was `0.13.0` in the original plan) as your daily driver for **at least 14 consecutive days**. Same workflow as PR 2.3 but longer and with broader coverage:

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

Things that will be tempting to slip in and must not be. **This list got broken between 2026-04-15 and 2026-05-16** — see the Re-baseline section for what shipped off-roadmap. The list is restated here as the rule going forward from `v0.12.0`:

- **New agents.** A fourth CLI (opencode) already happened; a fifth is 1.1 territory.
- **New config keys.** `SANDY_LOCAL_LLM_HOST`, `SANDY_SCREENSHOT_DIR`, `SANDY_EXTRA_ENV`, `OPENCODE_MODEL`, `SANDY_OPENCODE_AUTH`, `CODEX_HOME` all shipped post-`0.11.4`. No more between now and `1.0.0`. If a bug fix seems to require one, it's the wrong fix.
- **New skill subsystems.** `/ss` shipped; nothing else.
- **Refactors beyond what's listed.** The `user-setup.sh` extraction is the one big structural change; everything else stays where it is.
- **Rebuilding the test harness.** Tests get *added*, not *restructured*.
- **Changing the Docker base image.** Stability, not modernization.
- **Adding Windows support, or anything that expands the platform surface.**

If any of these feel necessary, write them down in a `POST_1.0_IDEAS.md` scratch file and move on. The whole point of re-baselining at `0.12.0` is to make this constraint actually hold this time.

---

## Dependency graph

```
PR 1.1 (blockers) ✓ ──▶ tag 0.10.1 ✓
    │
    ▼
PR 2.1 (venv hardening) ✓ ──▶ tag 0.11.0 ✓
    │
    ▼
M2.5 Sprint 1 + Sprint 2 + stabilization ✓ ──▶ tag 0.11.1 ✓, 0.11.2 ✓, 0.11.3 ✓, 0.11.4 ✓
    │
    ▼
Off-roadmap feature drift (2026-04-15 → 2026-05-16)
    introspection, opencode, /ss, SANDY_EXTRA_ENV,
    SANDY_LOCAL_LLM_HOST, hybrid protected-dirs
    │
    ▼
0.12.0 cut ✓ ──▶ tag v0.12.0 ✓ (2026-05-16)
    │
    ▼
PR 2.3 (7-day soak on 0.12.0)    ← active; gates M3
    │
    ▼
PR 3.1 (user-setup.sh extract) ✓ (#4 merged 9178698)
    │
    ▼
PR 3.1.5 (3-day mini-soak) ✓     ← cleared 2026-05-30
    │
    ▼
PR 3.2 (build_*_cmd unify) ✓ (#5 merged 68b2ee1)
PR 3.3 (version bump) ✓          ──▶ tag 0.13.0 ✓ (2026-05-30)
    │
    ▼
M2.7 PR 2.7.0 (macOS --internal spike) ✓ PASSED 14/14 (2026-06-04)
    │  greenlit → architecture sound; transport = hybrid; local-LLM in-scope
    ▼
M2.7 PR 2.7.1 (proxy Go binary: transparent HTTPS + CONNECT-for-SSH  ✓ done
              + DNS allowlist + local-LLM forward; + mode-aware Policy)
M2.7 PR 2.7.2 (sandy-proxy Dockerfile + phased build)               ✓ done
M2.7 PR 2.7.3 (launcher wiring: sidecar --internal + egress net +   ✓ done
              proxy + ssh ProxyCommand + tri-state 0/1/2 + tests)
M2.7 PR 2.7.4 (remove macOS warning — only when proxy is on)        ← NEXT
M2.7 PR 2.7.5 (integration tests + manual macOS checklist)
                                 ──▶ tag 0.13.1 or 0.14.0-pre
    │
    ▼
M2.7 PR 2.7.6 (7-day soak: 3-4d opt-in, 3-4d default-on)
    │
    ▼
PR 4.1 (allowlist audit + sandbox-marker validator)  ← parallel
PR 4.2 (compat story)                                ← parallel
PR 4.3 (multi-agent matrix)                          ← parallel
PR 4.4 (failure-mode tests)                          ← parallel
PR 4.5 (version bump)            ← blocks on 4.1-4.4 ──▶ tag 0.14.0
    │
    ▼
PR 5.1 (14-day soak gate on 0.14.0)
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
| `0.11.3` | ✓ released | M2.5 stabilization fixes (plugin install, fast-path fixtures) | Stable target for restarted M2.3 soak (never restarted) |
| `0.11.4` | ✓ released | Empty-stub-debris cleanup hotfix | M2.5 tail closed |
| `0.12.0` | ✓ released 2026-05-16 | Re-baseline at current `main` (introspection, opencode, /ss, SANDY_EXTRA_ENV, hybrid protected-dirs) | Feature freeze restarts here |
| `0.13.0` | ✓ released 2026-05-30 | M3 (heredoc extract + build unification) + 3-day mini-soak; default model → opus 4.8 | 1.0 surface is reviewable |
| `0.13.1` or `0.14.0-pre` | pending | M2.7 (egress proxy sidecar) + 7-day soak | F2 macOS Critical finally closed |
| `0.14.0` | pending | M4 surface locked | Stability promises are explicit |
| `1.0.0-rc1` | pending | M5 14-day soak clean | Ready for users to form habits on |
| `1.0.0` | pending | rc soak clean | Stability over time |
