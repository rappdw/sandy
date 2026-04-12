# Roadmap to 1.0-rc1

This plan walks from the current state of `codex-support` to `1.0-rc1`. It's structured as a sequence of discrete PRs, each with a clear scope, exit criteria, and target version. **No new features** — 1.0 is a stability release. Every PR should make the existing surface more trustworthy without adding to it.

Current baseline: `main` @ v0.10.0 (tag `v0.10.0`), version string `0.10.1-dev` on `main` post-release.

## Guiding principles

- **Each PR is independently reviewable and revertible.** If PR 4 breaks a user, reverting it must not force rolling back PR 5.
- **No PR introduces a new config key, flag, or user-visible feature.** The only additions are warnings, info messages, and internal refactors.
- **Every medium-or-higher finding from the code review gets addressed.** The low findings get fixed opportunistically as they fall into relevant PRs.
- **Soak before commit.** The two newest features (venv overlay, session-dir normalization) must accumulate real-world mileage before the RC is cut.
- **Documentation is part of done.** SPECIFICATION.md, CLAUDE.md, and README updates land in the same PR as the code they describe.

---

## Milestone 1 — Blocker fixes → `0.10.1`

Two bugs from the code review that would be embarrassing at 1.0. (A third "blocker" — session-dir name collision from aggressive normalization — was walked back during PR 1.1 execution after verifying that sandy's per-workspace sandbox isolation already prevents the collision. Each workspace gets a unique `$SANDBOX_DIR` keyed on `sha256($WORK_DIR)`, and `~/.claude/projects/` inside the container is per-sandbox, never shared. Two workspaces whose paths normalize to the same Claude Code project-dir name land in different sandboxes with completely separate session trees.)

### PR 1.1 — Fix resume fallback and codex grep-regex injection

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

### PR 2.1 — Venv overlay race + validation

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

### PR 2.2 — Sandbox version marker validation + version bump

**Scope**:

1. **Validate `.sandy_created_version` content** (sandy:2009). Regex-check `^[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9]+)?$`. On failure, fall through to the "unknown" branch rather than displaying garbage in the warning.

2. **Version bump**: `0.10.1` → `0.11.0-dev`, then `0.11.0` for the actual release.

3. **CHANGELOG**: venv hardening + session fixes from 0.10.1.

**Exit criteria**: test suite green, version displayed correctly.

### PR 2.3 — Soak baseline (no code, just time)

**This is not a PR, it's a gate.** Before tagging `0.11.0`, use `0.11.0-dev` as your daily driver for **at least 7 consecutive days** across your regular projects (at minimum: sandy itself, one equity_analyzer-style Python project, one multi-agent session). Log any surprises in a scratchpad. Issues found become PRs in Milestone 3.

**Exit criteria**: 7-day diary with no unexpected behavior. If any surprises appear, fix and restart the 7-day clock.

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
PR 1.1 (blockers)
    │
    ▼
PR 2.1 (venv hardening) ─┐
PR 2.2 (version bump)    ├──▶ PR 2.3 (soak) ──▶ tag 0.11.0
                         │
PR 3.1 (user-setup.sh extract)   ← blocks on 0.11.0 soak being clean
PR 3.2 (build_*_cmd unify)       ← can run parallel with 3.1
PR 3.3 (version bump)            ← blocks on 3.1, 3.2 ──▶ tag 0.12.0
                         │
PR 4.1 (allowlist audit)         ← parallel
PR 4.2 (compat story)            ← parallel
PR 4.3 (multi-agent matrix)      ← parallel
PR 4.4 (failure-mode tests)      ← parallel
PR 4.5 (version bump)            ← blocks on 4.1-4.4 ──▶ tag 0.13.0
                         │
                         ▼
                   PR 5.1 (14-day soak gate)
                         │
                         ▼
                   PR 5.2 (1.0.0-rc1 tag)
```

## Checkpoints

Treat each tag as a commitment: do not proceed to the next milestone until the previous tag's exit criteria are fully met. Tags are cheap; regrets at 1.0 are not.

| Tag | Gates | What it proves |
|---|---|---|
| `0.10.1` | Blocker PRs merged + tests green | Review blockers are addressed |
| `0.11.0` | Venv hardening + 7-day soak | The two newest features are solid |
| `0.12.0` | Architecture cleanup | 1.0 surface is reviewable |
| `0.13.0` | Surface locked | Stability promises are explicit |
| `1.0.0-rc1` | 14-day soak clean | Ready for users to form habits on |
| `1.0.0` | rc soak clean | Stability over time |
