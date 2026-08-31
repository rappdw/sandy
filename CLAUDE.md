# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Keeping Documentation in Sync

When modifying the `sandy` script, update `SPECIFICATION.md` to reflect any changes to behavior, flags, configuration, generated files, runtime parameters, JSON schemas, or platform-specific logic. The spec has five appendices (A–E) with implementation-level detail — these must stay accurate:

- **Appendix A** (Generated File Templates): Update when Dockerfile content, entrypoint.sh, user-setup.sh, or tmux.conf changes
- **Appendix B** (Runtime Parameters): Update when timeouts, limits, permissions, default values, or tool versions change
- **Appendix C** (JSON Schemas): Update when settings.json, access.json, .claude.json, or credentials handling changes
- **Appendix D** (Platform-Specific Behavior): Update when Linux/macOS divergence points change
- **Appendix E** (Container Launch Assembly): Update when docker run flags, mounts, or environment variables change

Also update `README.md` and this file (`CLAUDE.md`) if user-facing behavior changes. Run `test/run-tests.sh` to verify test assertions still match.

### Auto-generated config tables

The privileged/passive key lists and the Allowlisted Variables table in `CLAUDE.md` and `SPECIFICATION.md` are generated from `sandy --print-schema` — their source of truth is the `_sandy_key_metadata` heredoc in the sandy script. When you add, remove, or retier a config key, run:

```sh
test/regen-config-docs.sh        # rewrite the autogen blocks in place
test/regen-config-docs.sh --check # verify no drift (used by test/run-tests.sh)
```

Sentinels `<!-- BEGIN AUTOGEN:<name> -->` / `<!-- END AUTOGEN:<name> -->` mark the rewritten regions. Anything outside the sentinels is hand-maintained prose — edit that directly. `test/run-tests.sh` runs `--check` and fails if the committed blocks don't match the current schema.

### user-setup.sh template mirror

The `generate_user_setup()` heredoc body in the sandy script is the source of truth for the container-side `user-setup.sh`. It's mirrored to `templates/user-setup.sh.tmpl` so `shellcheck` can lint it as a real file (a heredoc string literal is unshellcheckable). When you edit the heredoc body, run:

```sh
test/regen-template.sh         # rewrite templates/user-setup.sh.tmpl from the heredoc
test/regen-template.sh --check # verify no drift (used by test/run-tests.sh)
```

`test/run-tests.sh` runs both `--check` and `shellcheck` against the template; the suite fails if the heredoc and template diverge or if any shellcheck warning is introduced. The sandy script itself remains single-file and `sandy --upgrade`-compatible — the template file is a derivative used only for review and lint, not shipped to users.

## What This Is

`sandy` — an isolated sibling for your coding agents. A self-contained command that runs Claude Code, Gemini CLI, OpenAI Codex CLI (or any combination side-by-side) in a Docker sandbox with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
```

Or install locally from a clone:

```sh
LOCAL_INSTALL=./sandy ./install.sh
```

## Usage

```sh
cd ~/my-project
sandy                        # interactive session
sandy -p "your prompt here"  # one-shot prompt
```

No `ANTHROPIC_API_KEY` required if using Claude Max (OAuth) — credentials are seeded from `~/.claude/` on first run.

## Testing

Tests require Docker and built sandy images, so they must be run **outside** of sandy's isolation (i.e., on the host, not inside a sandy container). The test suite needs direct access to Docker to build and inspect images.

```sh
bash test/run-tests.sh              # pure-script tests (needs Docker + built images)
bash test/run-integration-tests.sh  # headless end-to-end (needs Docker + API keys)
```

Since Claude Code running inside sandy cannot access Docker, running tests requires the user to execute them manually on the host.

**Acceptance harnesses run against an isolated `$SANDY_HOME`.** `test/lib-isolated-home.sh` redirects `SANDY_HOME` to a throwaway temp dir before any container launches, so the fixture sandboxes these harnesses create never land in the developer's real state. This matters because `--print-state` is the fleet API and **nothing marks a sandbox as a test artifact** — a fixture is indistinguishable from a real one to every consumer, so leaked fixtures both bury real entries and present as auto-enrollment surface to any policy with a catch-all profile. (A downstream fleet consumer read 48 sandboxes where 14 were theirs; 34 were fixtures from ten separate runs, whose workspaces were long-deleted temp dirs.)

The temp home is **seeded with the real one's build cache** (generated Dockerfiles + `.build_hash*`) and nothing else — deliberately not `sandboxes/` or `approvals/`. The seeding is not an optimization: the image build gate's first condition is `[ ! -f "$HASH_FILE" ]`, so an unseeded home rebuilds every image with `--no-cache --pull` on every run. Isolation was chosen over teardown because a killed run still leaks, which is exactly how ten runs' worth accumulated. Set `SANDY_TEST_NO_ISOLATE=1` to opt out. Guarded by `run-tests.sh §105`. When making changes to the `sandy` script or tests, ask the user to run the test suite and share the results.

`test/run-integration-tests.sh` also supports three tuning knobs: `SANDY_INTEG_ONLY=7,13` / `SANDY_INTEG_SKIP=19,20,21` to run or skip a comma-separated subset of sections by id (exact-token match; SKIP wins when a section is in both), and `SANDY_INTEG_NO_MODEL_PIN=1` to disable the default Haiku model pin used for claude smoke launches and run every claude launch at sandy's own default model instead.

See `TESTING_PLAN.md` for manual validation steps that require interactive TUI sessions.

### bash-3.2 / BSD portability lint (`test/lint-bash32.sh`)

CI is Ubuntu + bash 5 + GNU userland; the maintainer's machine is macOS + bash 3.2 + BSD. Three constructs parse or expand **differently** there, so `bash -n` in CI passes and the break surfaces only on one machine — and each fails in a way that doesn't announce itself:

| Code | Construct | How it failed here |
|---|---|---|
| `SRCSUB` | nested `source <(...)` inside `$( )` | bash 3.2 sources nothing → exit 127 → ERR trap aborted the run (§83) |
| `PYBACK` | backtick or `$(` inside a **double-quoted** `python3 -c "..."` body | bash expands it regardless of Python comment syntax — a `` `sandy` `` in a comment made the suite **execute the real sandy binary** (§68) |
| `APOSQ` | apostrophe in a comment inside a multi-line **single-quoted** program argument (`jq '...'`, `awk '...'`) | the apostrophe closes the string and the shell reinterprets the rest as code — `bash -n` fails while `APOSCS` reports clean, since it only scans `$( )` |
| `GREPM` | `grep -n … \| head` under `pipefail`, or a flag cluster whose numeric argument was split off before `-m` | grep dies on `EPIPE` (exit 2) and the ERR trap **aborts the suite mid-run** — a race, so it passes locally and fails in CI; a partial run still prints its passes |
| `APOSCS` | apostrophe in a comment inside a multi-line `$( )` | bash 3.2 doesn't skip comments when scanning a command substitution → unterminated quote → **parse abort**, while the summary still printed "945 passed, 0 failed" (§86) |

```sh
bash test/lint-bash32.sh              # lint the repo's shell scripts
bash test/lint-bash32.sh --self-test  # prove the detectors still detect
bash test/lint-bash32.sh --list       # the target set, for coverage assertions
```

`run-tests.sh §89` runs it and asserts both that the tree is clean **and** that the detectors fire on known-bad fixtures — a linter whose patterns quietly stopped matching would otherwise report success forever. Validated by replay against this repo's own history: pointed at the commits *before* each fix, it flags all three original defects at their exact lines. Deliberately **not** checked: `set -E` ERR traps firing in command-substitution subshells (real — see `sandy:1043` — but not reliably detectable statically, and a false positive is worse than a miss here).

Fixes: `SRCSUB` → extract-then-`eval`; `PYBACK` → a **quoted** heredoc (`python3 - arg <<'PY'`); `APOSCS` and `APOSQ` → reword the comment to avoid apostrophes; `GREPM` → `grep -m1` rather than `grep | head -1`.

## Git branch work inside sandy (`.git/HEAD` is writable as of 1.5.0, #80)

As of 1.5.0 (#80) sandy leaves `.git/HEAD` **read-write**, so `git switch <branch>` / `git checkout <branch>` / `git checkout -b` **work inside the container** — HEAD is a symref (which branch is checked out), not a host-code-execution vector. What stays bind-mounted **read-only** (the anti-ref-spoofing / hook-injection defense — see "Protected Files"): `.git/config`, `.gitmodules`, `.git/packed-refs`, `.git/hooks`, `.git/info`, and submodule gitdirs. Consequences of *those* staying `:ro`:

- `git commit`, `git reset`, `git switch`, `git checkout -b` — **work** (HEAD + loose refs are writable).
- Repo-local `git config` writes (`.git/config`) — **fail** (`:ro`). The most common way to hit this is **`git push -u` / `--set-upstream`**, which writes the tracking ref into `.git/config`: it reports `could not write config file .git/config: Device or resource busy` *after* the push has already succeeded, which reads like a failed push and is not one. Use `git push origin <branch>:<branch>`.
- Deleting a **packed** branch ref, `git pack-refs`, `git gc` (repacking refs) — **fail** with `error: ... .git/packed-refs: Device or resource busy` (`:ro`). Loose-ref deletes still work.

Separately, and by a *different* mechanism — the **protected workspace dirs** list rather than `.git/` internals — any git operation that has to rewrite a tracked file living under one of those `:ro` paths fails. In practice that means **`git reset --hard` fails whenever the repo tracks a file under `.github/workflows/`** (`unable to unlink old '.github/workflows/…': Read-only file system`), because `--hard` rewrites every tracked file, including ones it did not need to change. Use a **mixed reset** (`git reset <ref>`, no `--hard`): it moves HEAD and the index but leaves the worktree alone, so a file whose content already matches is simply seen as clean. This is the protection working as intended, not a bug — but it is friction that arrives the moment a workflow file becomes tracked, so it is worth knowing before it looks like repo corruption.

**Session-end notice.** Because HEAD is writable, sandy snapshots the launch branch and, at session end, prints a yellow notice if HEAD was left on a different (or detached) branch — a host `git`/IDE would otherwise silently see a checkout you didn't choose. It's informational (the RCE vectors above stay `:ro`), and names the `git switch <launch-branch>` to restore.

**The HEAD-preserving pattern** is still the way to land a PR from inside sandy — `main` is protected by a required-status-checks ruleset, so every change goes via PR + CI, never a direct push, and this flow keeps HEAD on `main` (and works even where `git gc`/packed-ref ops don't):

1. Make edits and `git commit` on the current branch.
2. `git branch -f <feature> HEAD` — labels a loose ref at that commit.
3. `git push origin <feature>`.
4. `git reset --hard origin/main` to move the branch back (preserve any uncommitted `.gitignore`/untracked changes across the reset).
5. `gh pr create --head <feature> --base main`.

You can now also `git switch -c <feature>` and work on it directly; just note the session-end notice if you leave HEAD off `main`.

## Introspection Surface

Sandy exposes four machine-readable JSON flags that run as **fast-path handlers** — they exit before Docker, image builds, and workspace mutex acquisition, so they're cheap to call from UI frontends, CI, and non-interactive contexts:

- `--print-schema` — static schema: sandy version, config keys by tier (with type, default, description), CLI flags, agents + credential probe orders, protected path lists, skill packs, schema compatibility declaration (`schema_version: 1`).
- `--print-state` — runtime state: installed images, per-sandbox metadata, approval files, `docker_reachable`, running sandy containers (filtered by image name prefix), plus (full mode only) `dangling_images` and `orphaned_containers` reclaim counts — see "Unified resource reclaim" below. Gracefully reports `docker_reachable: false` when docker is absent. Each sandbox also carries `size_bytes` (1.8.0, #176) — allocated disk usage in bytes (`du -skx`, times 1024), **full mode only**; light mode always reports it `null` since a `du` walk over a multi-GB sandbox is exactly the latency class the light-mode poll budget exists to avoid. A poller that wants a cheap, frequent read should stick to light mode and fetch full mode only when a size figure is actually needed. Top level, both modes, also carries `host_id`/`host_id_source` (1.8.0, #179) — advisory host identity (`uname -n` by default, or the env-only `SANDY_HOST_ID` override) for attributing rows when a fleet tool merges `--print-state` output across multiple hosts, since sandbox names hash only the workspace path and so collide across hosts. See SPEC_INTROSPECTION.md for the full field contract.
- `--validate-config PATH` — parses a config file, classifies it by path as privileged (`$SANDY_HOME/…`) or passive (anywhere else), and reports errors, unknown keys, privileged-from-passive keys that require approval, and the target approval file path. Exit 0 on success (including "approval pending"), 1 only for file-not-found or missing-argument.
- `--print-version` (1.7.0, #159) — `{schema_version, version, commit, full_version}`. Exists because `--print-schema`'s own `sandy.version` is the payload a consumer would be caching in the first place (chicken-and-egg) — `--print-version` is the standalone probe. `full_version` is the intended cache key, not `version`: on a dev channel `version` stays e.g. `"1.7.0-dev"` across every commit until the final release, so a cache keyed on it never invalidates across exactly the upgrades that matter, while `full_version` (`"1.7.0-dev-d89aaba"`) changes every commit. `commit` is `""`, not `null`, when unknown (matches `--print-schema`'s `sandy.commit` convention) — see `_sandy_commit_hash()`, the single helper both emitters call so they can't drift. Pre-1.7.0 sandy does not recognize `--print-version`: the catch-all forwards unrecognized flags straight to the wrapped agent instead of erroring, so a caller must first confirm 1.7.0+ via the guaranteed `sandy <full_version>` format of `--version` (safe on every sandy version) before calling `--print-version`.

See `SPEC_INTROSPECTION.md` for the stability contract and field-by-field JSON schema. When adding a new config key to `SANDY_PRIVILEGED_KEYS`, `SANDY_PASSIVE_KEYS`, or `SANDY_ENV_ONLY_KEYS` in the sandy script, also add a row to the `_sandy_key_metadata` heredoc (pipe-separated `key|type|default|pattern|since|stability|description`) so it appears in `--print-schema` output, then run `test/regen-config-docs.sh` to propagate the change into the `SPECIFICATION.md` and `CLAUDE.md` config tables.

`cli_flags` in `--print-schema` is hand-curated, not derived — `--workspace` was accepted by every daemon-family parser (`--start`/`--attach`/`--stop`/`--update-sessions`/`--reset-sandbox`, plus the bare launch path) since 1.1.0 but was missing from `cli_flags` until 1.7.0 (#156). Any flag added to any parser (a fast-path `if [[ "${1:-}" == "--flag" ...` dispatch, or a `--flag)`/`--flag=*)` case label) must therefore either gain a matching `cli_flags` entry or be added to one of the three explicit exception lists (sub-option, private/debug, or forwarded-to-agent) in `test/run-tests.sh` §91 — that section statically diffs the two and fails the build on drift in either direction. As of 1.7.0, `--print-schema`, `--print-state`, `--validate-config`, and (also 1.7.0, #159) `--print-version` all carry a guaranteed stream contract — exactly one JSON document on stdout and nothing else (0 bytes of stderr), even on JSON-shaped failures, with only the no-argument `--validate-config` usage error departing from it (0 bytes of stdout, a `[sandy] ERROR: ...` line on stderr) — pinned by `test/run-tests.sh` §92 (and, for `--print-version`'s version-specific composition/identity guarantees, §93) and detailed in `SPEC_INTROSPECTION.md`.

## Self-Attestation Marker

On every launch (all egress modes), sandy writes `$SANDBOX_DIR/sandy-session.json` and bind-mounts it **read-only** at `/etc/sandy-session.json` inside the container. It is the single authoritative, in-container signal that the agent is genuinely running inside sandy and at what isolation level:

```json
{ "schema": 1, "sandy_version": "...", "egress_mode": "off|permissive|strict",
  "workspace": "...", "host_uid": 501, "host_gid": 20,
  "launched_at": "2026-06-11T12:00:00Z", "session_nonce": "<hex>",
  "effort": "high", "permission_mode": "bypassPermissions", "cred_mode": "full" }
```

The `effort` field records the reasoning effort sandy **pinned** for the claude agent via `SANDY_EFFORT` (a JSON string like `"high"`), or `null` when sandy did not pin it (the agent ran at Claude Code's own default — currently `high`). This makes a run's effort provable after the fact rather than inferred from the ephemeral live statusline — the gap that let a red-team run silently at default effort. `schema` stays `1` (additive field).

The `permission_mode` field records the permission mode sandy **pinned** into settings.json for the claude agent this launch: `"bypassPermissions"` when `SANDY_SKIP_PERMISSIONS=true` (the default), or `null` when sandy did not pin it (skip-permissions off, or claude isn't in `SANDY_AGENT`). Same "provable after the fact" rationale as `effort` — Claude Code 2.1.232 has been observed overwriting sandy's `permissions.defaultMode: bypassPermissions` pin with `"auto"` via an in-container settings.json write ~13s after launch (#151), and since sandy writes settings.json host-side *before* `docker run`, this marker field is what sandy pinned at launch, not necessarily what's in effect right now — pair it with the session-end drift notice (see "Per-project Sandboxes" below) for the live picture. This does not change sandy's default or add a config key.

**Why it exists.** Env vars (`SANDY_EGRESS_MODE`, `SANDY_WORKSPACE`) are spoofable and the *absence* of a path proves nothing, so an in-container probe that distrusts env vars otherwise cannot tell a sandy container apart from the bare host VM — the `sandy-isolation-test` red-team hit exactly this, running in sandy `=0` on macOS/OrbStack but concluding it was not in sandy at all (uid `501`, OrbStack `mac` virtiofs mounts, and `CapBnd` retaining sandy's documented `--cap-add` set all read as "ordinary VM" without an anchor). Because the marker is a `:ro` bind mount, a committed workspace config cannot forge it.

**Tamper-evidence.** `session_nonce` is freshly generated each launch (`openssl rand`, falling back to `/dev/urandom`) and forwarded out-of-band: it is printed host-side under `SANDY_VERBOSE=1` so an external verifier (a test harness, CI) can confirm the file's nonce matches the launch it expects. The nonce is deliberately **not** exported as an env var — the read-only file is the trust root, env is not. An operator can also **pin** the nonce via the `SANDY_SESSION_NONCE` env var (validated `^[A-Za-z0-9._-]{8,128}$`; an invalid value warns and falls back to auto-mint, never failing the launch) so a harness that chose the value host-side can prove a run is the one it launched: the `sandy-isolation-test` kit sets a per-run `<random>-<base>-<mode>` value and its adjudicator checks the `:ro` marker reports it back, confirming the run is genuine and un-substituted. `SANDY_SESSION_NONCE` is **env-only** — not a recognized config key and never forwarded into the container — so a committed workspace `.sandy/config` cannot pin it and the read-only file stays the sole trust root. In-container tooling should assert on this file, not on uid/caps/env heuristics (which is what misfired in the red-team run). The launcher writes the file at the same point it forwards `SANDY_EGRESS_MODE` (Appendix E); the JSON schema is in Appendix C.

## Per-project Configuration

Create `.sandy/config` in any project directory to set per-project defaults:

```sh
SANDY_SSH=agent                          # use SSH agent forwarding
SANDY_MODEL=claude-sonnet-4-5-20250929   # override model
```

This file is parsed as plain `KEY=VALUE` lines (not sourced — no shell code execution). Values are validated against an allowlist of recognized variables.

### Config tiers (1.0-rc1)

Sandy loads configuration from four sources in order: `$HOME/.sandy/config`, `$HOME/.sandy/.secrets`, `$WORK_DIR/.sandy/config`, `$WORK_DIR/.sandy/.secrets`. The first two are **privileged** sources — they can set any recognized key. The last two are **passive** sources (workspace-local, committable to version control) — they can only set a restricted subset of keys freely; any attempt to set a **privileged-only** key from a workspace triggers an interactive approval prompt the first time and is remembered per workspace.

**Precedence:** env vars set before launch (`SANDY_AGENT=codex sandy ...` or shell-level `export`) win over both host and workspace config — sandy snapshots which keys are already in the env at startup and skips them during config loading. Among config files, workspace passive overrides host privileged for keys both sources set. The CLI flag `--agent` overrides everything for SANDY_AGENT specifically. Final precedence top-down: `--agent` flag > env var > workspace `.sandy/config` > host `~/.sandy/config` > sandy default.

- **Privileged-only keys** (require per-workspace approval when set from a passive source):
  <!-- BEGIN AUTOGEN:privileged-key-list Run `test/regen-config-docs.sh` to update. -->
  `SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `SANDY_LOCAL_LLM_HOST`, `SANDY_ALLOW_HOSTS`, `SANDY_EXTRA_ENV`, `SANDY_AGENT_ARGS`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `SANDY_SCREENSHOT_DIR`, `SANDY_GEMINI_EXTENSIONS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`
  <!-- END AUTOGEN:privileged-key-list -->

  These would let a malicious `.sandy/config` committed to a repo disable isolation or exfiltrate credentials, so sandy collects them, prints the exact `KEY=VALUE` set, and asks for explicit approval before honoring them. Approvals are persisted to `$SANDY_HOME/approvals/passive-<workspace-hash>.list` (first line is a sha256 of the sorted `KEY=VALUE` set). Subsequent launches with the same set are silent; any edit to `.sandy/config` that changes a privileged key re-prompts. Revoke with `rm $SANDY_HOME/approvals/passive-<hash>.list`. Headless mode (`-p`/`--print`/`--prompt`) and non-TTY stdin fail closed — the keys are dropped with a pointer to "launch sandy interactively once from this directory to approve."

  **CI / test harness escape hatch:** set `SANDY_AUTO_APPROVE_PRIVILEGED=1` in the environment (not in any config file) to bypass the prompt entirely and export all collected passive privileged keys in-memory. This is intentionally env-only — the passive config allowlist does not include `SANDY_AUTO_APPROVE_PRIVILEGED`, so a committed `.sandy/config` cannot set it. Only a trusted shell or test harness can. Sandy's own `test/run-tests.sh` and `test/run-integration-tests.sh` set this because they run from the sandy repo directory, which has its own `.sandy/.secrets` with `GEMINI_API_KEY`.

- **Passive-safe keys** (allowed from any source):
  <!-- BEGIN AUTOGEN:passive-key-list Run `test/regen-config-docs.sh` to update. -->
  `SANDY_AGENT`, `SANDY_MODEL`, `SANDY_TEAMMATE_MODE`, `SANDY_EFFORT`, `SANDY_CPUS`, `SANDY_MEM`, `SANDY_GPU`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS`, `SANDY_CHANNEL_TARGET_PANE`, `SANDY_VERBOSE`, `SANDY_VENV_OVERLAY`, `SANDY_EGRESS_PROXY`, `SANDY_EGRESS_NO_ISOLATION`, `SANDY_EGRESS_STRICT`, `SANDY_EGRESS_LOG`, `SANDY_ALLOW_WORKFLOW_EDIT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `GEMINI_MODEL`, `SANDY_GEMINI_AUTH`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI`, `CODEX_MODEL`, `SANDY_CODEX_AUTH`, `OPENCODE_MODEL`, `SANDY_OPENCODE_AUTH`, `GROK_MODEL`, `SANDY_GROK_AUTH`, `SANDY_TOOL_AUDIT`, `SANDY_CLAUDE_CONNECTORS`, `SANDY_SUSPICIOUS`, `SANDY_HANDOFF_DIRS`
  <!-- END AUTOGEN:passive-key-list -->

- **Value-aware exceptions** (passive for values that *strengthen* isolation, approval-gated for values that *weaken* it): a few passive keys are not uniformly safe from a committed `.sandy/config` because one of their values lowers the sandbox's protection. `_sandy_passive_value_privileged()` routes those weakening values through the same per-workspace approval prompt as a privileged key, while leaving the strengthening/neutral values frictionless — *"a repo may make the sandbox tighter, never looser."* The gated values are: `SANDY_EGRESS_NO_ISOLATION=1` (proxy off), `SANDY_EGRESS_STRICT=0` (downgrade a host-set strict), `SANDY_EGRESS_PROXY=0` (deprecated alias for proxy-off), and `SANDY_ALLOW_WORKFLOW_EDIT=1` (drops `.github/workflows/` protection). This closes the hole where a committed workspace config could silently disable network isolation (threat-model adversary #2) — on macOS with the proxy off that is *total* loss of network isolation. Guarded by `run-tests.sh §65`.

Additionally, `SANDY_ALLOW_LAN_HOSTS` is validated at use-site to reject world-open entries (`0.0.0.0/0`, `::/0`) with a hard error at launch — even when set from a privileged source.

## Agent Selection

Sandy supports Claude Code (default), Gemini CLI, OpenAI Codex CLI, OpenCode (sst/opencode), Grok Build (xAI), or **any combination side-by-side in multi-pane tmux**, selectable per-project via `SANDY_AGENT` in `.sandy/config`:

```sh
SANDY_AGENT=grok                        # single agent: claude (default), gemini, codex, opencode, grok
SANDY_AGENT=claude,codex                # any comma-separated combo (2–4 agents; hard cap of 4 — the layout is a 2x2 grid)
SANDY_AGENT=claude,gemini,codex,opencode # four in a 2x2 layout
SANDY_AGENT=all                         # alias for claude,gemini,codex,opencode (unchanged; grok is opt-in, not in `all`, so the default stays a 4-pane grid)
```

Single-agent modes use their own Docker images (`sandy-claude-code`, `sandy-gemini-cli`, `sandy-codex`, `sandy-opencode`, `sandy-grok`); multi-agent combos use `sandy-full` (which includes all five agents). With five selectable agents but a 2x2-grid layout, sandy hard-errors on a 5+ combo. Grok Build is installed via `curl -fsSL https://x.ai/cli/install.sh | bash` (a prebuilt binary, not npm — sandy relocates it to `/usr/local/bin/grok` since `/home/claude` is a tmpfs); its config/session lives in the `grok/` sandbox subdir mounted at `~/.grok`. All share the common `sandy-base`. Gemini CLI, Codex CLI, and OpenCode are installed via `npm install -g @google/gemini-cli`, `npm install -g @openai/codex`, and `npm install -g opencode-ai` respectively. Gemini launches with `GEMINI_SANDBOX=false`; Codex launches with `--sandbox danger-full-access` plus `sandbox_mode = "danger-full-access"` in its `config.toml` (belt-and-suspenders — codex's Landlock sandbox does not nest cleanly in Docker, and sandy already provides whole-session isolation). The sandbox directory has sibling `claude/`, `gemini/`, `codex/`, and `opencode/` subdirs. The first three mount at `~/.claude`, `~/.gemini`, and `~/.codex`; OpenCode straddles two XDG paths and uses `opencode/{config,share}` mounting at `~/.config/opencode` and `~/.local/share/opencode` respectively. v1 layouts with `settings.json` at the sandbox top level are auto-migrated on launch.

**Gemini credentials** are probed in this order (override via `SANDY_GEMINI_AUTH=auto|api_key|oauth|adc`): `GEMINI_API_KEY` env var, host `~/.gemini/tokens.json` (copied ephemerally), host `~/.config/gcloud/application_default_credentials.json` (Google ADC / Vertex AI).

**Codex credentials** are probed in this order (override via `SANDY_CODEX_AUTH=auto|api_key|oauth`): `OPENAI_API_KEY` env var (materialized as an ephemeral `auth.json` mounted **read-only** — codex 0.139+ no longer reads the env var for first-party auth, so sandy writes what `codex login --with-api-key` would write), host `~/.codex/auth.json` (copied ephemerally and mounted **read-only** — prevents token leakage back to host and prevents stale-token races). Because `auth.json` is mounted read-only, in-session OAuth refresh will fail — users must re-login inside the container if the token expires. On first launch, sandy seeds `~/.codex/config.toml` with `model = "gpt-5.5"`, `sandbox_mode = "danger-full-access"`, and a full `[notice]` block to suppress all first-run prompts; a `[projects."$SANDY_WORKSPACE"] trust_level = "trusted"` entry is appended at session start by `user-setup.sh` (it needs the container-side workspace path).

**Grok credentials** — Grok Build authenticates fully headless from **`XAI_API_KEY`** (docs.x.ai; resolution order `model.api_key > env_key > active session token > XAI_API_KEY`), so — unlike codex — sandy has **no auth file to materialize**: it just forwards the env var (privileged tier, like the other agent keys). The alternative is an interactive `grok login` OAuth session, which persists in the rw `~/.grok` mount across launches (host `~/.grok` OAuth-session seeding is a possible follow-up, deliberately kept out of the persisted mount for now). Model via `GROK_MODEL` (passed as `-m`; default `grok-4.5`); probe override via `SANDY_GROK_AUTH=auto|api_key|oauth`. Headless (`-p`) adds `--no-auto-update` (grok can't self-update against the read-only rootfs anyway; docs.x.ai headless-scripting). Auto-update *detection* isn't wired (grok installs via `install.sh` with no version API) — `sandy --rebuild` re-fetches latest; a monthly-freshness rebuild trigger (like the proxy image) is a candidate follow-up.

**OpenCode credentials** are provider-agnostic — opencode reads `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, etc. natively from the env, and sandy forwards whichever the user has set. The OAuth path mounts host `~/.local/share/opencode/auth.json` read-only when present (override the probe with `SANDY_OPENCODE_AUTH=auto|api_key|oauth`). OpenCode's flexibility is what makes the **local-LLM passthrough** below useful — point the config at a local Ollama/vLLM endpoint and pair with `SANDY_LOCAL_LLM_HOST`.

**OpenCode config seeding.** Provider/model selection lives in `~/.config/opencode/opencode.json`. On every new sandbox creation sandy resolves three input states in order:

1. **Host config exists** at `~/.config/opencode/opencode.json` → sandy seeds it into the sandbox. Subsequent in-container edits persist via the bind mount; host-side changes are picked up on the next sandbox creation.
2. **No host config but `SANDY_LOCAL_LLM_HOST` is set** → sandy auto-generates a starter `opencode.json` from a `curl http://${SANDY_LOCAL_LLM_HOST}/v1/models` probe (jq if available, regex fallback otherwise). The generated config defines a `local` provider via `@ai-sdk/openai-compatible` pointing at `http://host.docker.internal:<port>/v1`, registers the served model id, and pins it as the default. To customize, copy the generated file to `~/.config/opencode/opencode.json` — the next sandbox creation will then prefer the host file (state 1).
3. **Neither** → opencode would silently fall back to its built-in default model (currently `gemini-3-pro-preview`), which fails confusingly on first request without `GOOGLE_GENERATIVE_AI_API_KEY`. Sandy warns loudly at launch with the three possible fixes (set an API key, write the config, or set `SANDY_LOCAL_LLM_HOST`) but proceeds — opencode may still succeed if the user has another auth path the warning didn't anticipate.

**Local-LLM passthrough.** Sandy normally blocks all RFC 1918 (LAN) traffic. To let an in-container agent (typically OpenCode) reach a local LLM server on the Docker host without disabling that posture, set `SANDY_LOCAL_LLM_HOST=<ip>:<port>` (e.g. `127.0.0.1:11434` for Ollama). Sandy validates the format, rejects world-open IPs (`0.0.0.0`, `::`) and out-of-range ports, then inserts a single `iptables ACCEPT` rule limited to that exact `host:port` against the Docker bridge gateway. On Linux it also adds `--add-host=host.docker.internal:host-gateway` so the hostname resolves (Docker Desktop does this automatically on macOS, but Linux daemons require explicit mapping). Tweak the user's `~/.config/opencode/opencode.json` to set the provider's `baseURL` to `http://host.docker.internal:<port>/v1`. Macros and `SANDY_ALLOW_LAN_HOSTS` remain orthogonal — `SANDY_LOCAL_LLM_HOST` is a single narrow opening for the localhost LLM use-case, not a general LAN unblock.

**Feature support by agent**:

| Feature | `claude` | `gemini` | `codex` | `opencode` | `grok` | multi-agent |
|---|---|---|---|---|---|---|
| Skill packs | yes | — | — | — | — | yes (claude pane only) |
| Synthkit commands | yes (slash commands, Markdown) | yes (slash commands, TOML in `~/.gemini/commands/`) | yes (skills context, SKILL.md in `~/.codex/skills/`) | — (v0) | — (v0; tool binaries on PATH) | per agent |
| Channels (Telegram) | in-container plugin | host-side tmux relay | host-side tmux relay | host-side tmux relay (untested in v0) | host-side tmux relay (untested in v0) | host-side tmux relay |
| Channels (Discord) | yes | — | — | — | — | — |
| `--remote` | yes | — | — | — | — | — |
| Gemini extensions (`SANDY_GEMINI_EXTENSIONS`) | — | yes | — | — | — | yes (when gemini is in the combo) |
| Local-LLM passthrough (`SANDY_LOCAL_LLM_HOST`) | — | — | — | yes | — | yes (when opencode is in the combo) |
| Provider choice via own config | — | — | — | yes | — | — |

Codex headless mode (`-p` / `--print` / `--prompt`) translates to `codex exec --skip-git-repo-check` — the prompt is passed as a positional arg, not a flag, and the trust/git-repo gate is skipped (codex 0.139+ refuses `exec` outside a trusted dir or git repo; sandy provides the outer isolation). OpenCode headless mirrors that pattern: `opencode run <prompt>`. Both `exec` and `run` only support `0`/`1` exit codes (no nuanced codes like Claude's `--print`). `--continue` / `-c` is silently dropped for both (neither has a headless continuation flag). **Grok** headless is Claude-shaped instead: `-p`/`--print`/`--prompt` map to grok's `-p` print flag (the prompt stays a positional arg, not a subcommand like `exec`/`run`), plus `--no-auto-update`; `--continue`/`-c` dropped. Multi-agent combos use comma-separated syntax (e.g., `claude,codex`); `all` is an alias for `claude,gemini,codex,opencode`. With grok there are now **five** selectable agents but the layout is a 2x2 grid, so sandy hard-errors on a 5+ combo (`all` deliberately stays 4). The old `both` alias was removed in `v0.12` — sandy now errors out with a pointer to the comma-separated syntax.

The Telegram host-side relay (`$SANDY_HOME/channel-relay.sh`) is an agent-agnostic long-polling bridge that injects messages into the container's tmux session via `docker exec ... tmux send-keys`. In multi-agent mode, `SANDY_CHANNEL_TARGET_PANE=0|1|2` selects which pane receives messages (default `0` = first pane in `SANDY_AGENT`).

**Verification reality (#22).** `test/acceptance-pane-topology.sh` (invoked as `run-integration-tests.sh` §21) is the Docker-runtime end-to-end proof that a multi-agent launch actually forms the documented split-pane layout: it launches every combo shape (dual, left+2-right, 2×2 grid) via `--start`, then inspects the real tmux session with `list-panes` (pane count + geometry, asserted as *relationships* between pane coordinates — never absolute sizes, since a detached daemon session has no attached client size) and `capture-pane` (which agent is actually rendering in which on-screen position). Identity is proven via the **`@sandy_pane_agent` tmux pane option**, which sandy's multi-agent branch sets on every pane **unconditionally** (by pane-id, from the launcher). It serves double duty: it drives the per-pane **border label** (#64 — `pane-border-format` renders `#{@sandy_pane_agent}`, falling back to the window name for single-agent/untagged panes) *and* it is the harness's agent-proof identity. Only the `[sandy:pane-agent]` scrollback marker remains env-gated: under `SANDY_TEST_PANE_TAGS=1` it is prepended to each pane's command as a `capture-pane` fallback for an image predating the option. The harness reads identity from the pane option (via `list-panes -F '#{@sandy_pane_agent}'`), falling back to the scrollback marker only for such an older image. The pane option is the robust source because it binds to the pane running each agent's command (correct regardless of the pane-index shuffle) and — unlike both a scrollback marker (which a *real credentialed* agent wipes when it redraws/clears its small 2×2 pane) and `select-pane -T` (OSC-2-title-clobberable) — the agent cannot touch it. This replaced flaky identity failures seen on a maintainer host run where live agents cleared their panes before `capture-pane` read the marker. A per-combo retry + settle gate further absorb transient container-startup races. `SANDY_TEST_PANE_TAGS` is an internal env-only test hook, like `SANDY_AUTO_APPROVE_PRIVILEGED` above — it is not in `SANDY_PASSIVE_KEYS`/`SANDY_PRIVILEGED_KEYS`/`SANDY_ENV_ONLY_KEYS` and has no `_sandy_key_metadata` row, so it never appears in `--print-schema` and a committed `.sandy/config` can never set it; only forwarded into the container when a caller (the harness) explicitly exports it. Guarded structurally by `run-tests.sh §80` (harness exists/executable, references the right primitives, §21 wiring present, marker gate present, negative key-tier assertions) since the real container/tmux behavior needs Docker.

Building this harness surfaced a real nuance worth knowing before trusting a raw pane index: tmux's `pane_index` does **not** track spawn order once a later split re-splits an *earlier* pane, which is exactly what the 4-agent 2x2-grid code path does (`split-window -v -t sandy.0` as the last step, splitting pane 0 again after panes 1 and 2 already exist) — tmux inserts the new pane's index immediately after the pane it split rather than appending at the end, so in the 4-agent grid `sandy.1` ends up holding the *fourth* spawned agent (bottom-left) rather than the second, `sandy.2` holds the second (top-right), and `sandy.3` holds the third (bottom-right); only `sandy.0` reliably matches the first agent. The **on-screen layout is still correct** (each agent lands in its documented visual quadrant — top-left/top-right/bottom-right/bottom-left as documented above), which is why the acceptance harness derives each pane's role from its actual coordinates rather than assuming `pane_index == spawn order`. This does NOT affect the 2- and 3-agent combos (every split there targets the then-highest-index pane, so index tracks spawn order exactly). It DOES mean `SANDY_CHANNEL_TARGET_PANE=1|2|3` against a 4-agent combo will not reliably route to the "Nth agent in `SANDY_AGENT`" the way the paragraph above implies — that's a separate, unfixed gap tracked for its own follow-up, out of scope for #22 (which is about proving the topology, not routing pane-targeted messages by raw index).

## Per-project Sandboxes

Each project directory gets its own isolated `~/.claude` sandbox under `~/.sandy/sandboxes/`, named with a mnemonic prefix and hash (e.g. `myproject-a1b2c3d4`). The hash is over the workspace path canonicalized via `pwd -P` (resolves symlinks and folds case-collisions on case-insensitive filesystems like default macOS APFS), so `cd et` and `cd ET` from the same parent directory produce the same sandbox. Each launch writes `$SANDBOX_DIR/WORKSPACE.json` (non-hidden, visible in plain `ls`) recording the canonical workspace path, the user-typed path (when different — i.e. case-collision or symlink), first/last launch timestamps, and first/last sandy versions. On launch, sandy scans sibling sandboxes for matching `workspace_path` (with a legacy heuristic for sandboxes pre-dating the marker) and warns when duplicates are found — manual cleanup only, no auto-merge. `.claude.json` is seeded from the host's `~/.claude/` on first run. `settings.json` is regenerated on **every launch** at `$SANDBOX_DIR/claude/settings.json` (inside the rw sandbox mount) with merge-preserving semantics: sandy re-reads the host copy every launch so host-side edits propagate, but preserves `enabledPlugins` from the previous sandbox session so `/plugin install` survives across launches. The file is rw inside the container — the stricter `:ro` sidecar approach from pre-0.11.3 broke plugin installs with EROFS, so it was reverted. The trade-off: the agent *can* mutate its own settings within a session, but the sandy-managed keys (`extraKnownMarketplaces`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, `skipAutoPermissionPrompt`, `permissions.defaultMode`, cmux hooks) are re-overwritten every launch. `skipAutoPermissionPrompt` suppresses Claude Code 2.1.x's *"Make auto mode your default permission mode?"* offer, which is pure friction in a sandbox where sandy already pins `bypassPermissions`; it tracks `SANDY_SKIP_PERMISSIONS`, so with skip off the offer still appears. 2.1.x ships a one-time migration that **deletes** that key whenever `permissions.defaultMode != "auto"` — precisely sandy's configuration — so re-seeding every launch is what makes the suppression stick. As of 1.7.0 `teammateMode` is **no longer seeded at all** — the `--teammate-mode` CLI flag governs the session. It is also **opt-in** as of 1.7.0: `SANDY_TEAMMATE_MODE` is empty by default, so sandy passes no `--teammate-mode` at all and Claude Code applies its own default (set it to e.g. `tmux` to opt in). A host `settings.json` value is left untouched. That in-session mutability is exactly what let Claude Code 2.1.232 silently overwrite the `permissions.defaultMode` pin with `"auto"` a few seconds into a run (#151); since sandy can only seed the file before `docker run`, it snapshots the pinned mode at launch and, at session end, prints a yellow drift notice if the mode changed underneath it — informational only, and sandy re-pins on the next launch regardless. Credentials (`.credentials.json`) are read fresh from the host each launch and mounted ephemerally — never persisted to the sandbox.

### Sandbox version tracking

On creation, each sandbox gets a `.sandy_created_version` file recording the sandy version that created it; `.sandy_last_version` is refreshed on every launch. On launch, sandy reads the created-version and classifies it against `SANDY_SANDBOX_MIN_COMPAT` (currently `0.7.10`) via the pure `_sandbox_compat_classify()` helper:

- **below the floor** → **hard error; sandy refuses to launch** and prints the recreation command. (See "Sandbox compatibility (1.x forward-compat promise)" below.)
- **unknown / invalid** (no marker — pre-0.10.1 — or an unreadable one) → warn only. We can't prove it's below the floor, so we don't refuse.
- **at/after the floor** → silent.

The current breaking-change threshold is the workspace mount path change (c99eb97, v0.7.10): sandy now mounts the workspace at `/home/claude/<rel>` instead of `/workspace`. Sandboxes created before that carry cached absolute paths inside venvs (`pyvenv.cfg`, `.pth` files, editable installs) and Python package caches that reference `/workspace/...` and silently break inside the new layout. Fix: `rm -rf ~/.sandy/sandboxes/<name> && sandy --rebuild`.

When introducing further sandbox-incompatible changes, bump `SANDY_SANDBOX_MIN_COMPAT` in the sandy script — but see the forward-compat promise below for the 1.x constraint on moving it.

### Sandbox compatibility (1.x forward-compat promise)

From 1.0, sandy makes a **forward-compatibility promise**: *a sandbox created by any `1.x` sandy works with any later `1.x` sandy.* The mechanism is `SANDY_SANDBOX_MIN_COMPAT` as a **hard floor** — below it sandy refuses to launch (rather than the pre-1.0 warn-and-limp, which let an incompatible sandbox run into silently-broken cached paths). The promise constrains the floor: **within `1.x`, `SANDY_SANDBOX_MIN_COMPAT` must never advance above `1.0.0`.** A layout change that would break `1.x` sandboxes is a `2.0` change, not a `1.x` one.

The floor is enforced only when the created-version is *known and provably below it* — unknown/unreadable markers warn but launch (fail-open on uncertainty, fail-closed on proof). A non-destructive **sandbox migration utility** (rewrite cached paths in place instead of `rm -rf` + recreate) is tracked in `docs/POST_1.0_IDEAS.md`; until it exists, the remediation is recreation.

Tests: `run-tests.sh §51` unit-tests `_sandbox_compat_classify` (below-floor/ok/unknown/invalid); `run-integration-tests.sh §14` exercises the real launch path (downgrade a sandbox's marker → assert refuse; restore → assert proceed). The frozen sandbox snapshot fixture (`test/fixtures/frozen-sandbox-1.0/`, created at the 1.0.0-rc1 cut and deliberately never updated) plus `run-tests.sh §60` prove on every later release that a 1.0-era sandbox still classifies `ok` against the *live* floor and that the floor itself hasn't moved above `1.0.0`. If §60 fails, the change is `2.0.0` territory — read the fixture README before "fixing" the test.

### Workspace `.venv` overlay

Projects that use `uv venv` or `python -m venv` on the host create a `.venv/` whose `bin/python` is a symlink to a host-only interpreter path (e.g. `/Users/you/.local/share/uv/python/cpython-3.10-macos-aarch64/bin/python3.10`). That symlink is broken inside sandy's Linux container, and any attempt to use the venv fails — worse, a subsequent `uv pip install` would recreate `.venv` from scratch and wipe its `site-packages`.

Sandy solves this by bind-mounting a sandbox-owned overlay over `$WORKSPACE/.venv` inside the container. The host venv is shadowed (not modified); the container sees an independently-managed venv that uses a Linux interpreter matching the host's Python version.

**How it works:**

1. On launch, sandy checks `$WORK_DIR/.venv` on the host. If it exists and is not a symlink, sandy creates `$SANDBOX_DIR/venv/` and bind-mounts it at `$WORKSPACE/.venv` inside the container. Sandy learns the host's wanted Python version from `.python-version` if present (authoritative — user-maintained), falling back to parsing `pyvenv.cfg` if not, and passes the result via `SANDY_VENV_PYTHON_VERSION`. The parsed value must match `^[0-9]+\.[0-9]+$` — garbage is dropped and the container falls back to its default. A symlinked `.venv/` is skipped with an explicit info message (symlinks can point anywhere and overlaying them is too risky).
2. On first launch, the overlay dir is empty. The entrypoint runs `uv python install <version>` and `uv venv --clear --python <version> $WORKSPACE/.venv` to materialize a fresh venv. (`--clear` is required because the bind-mount target always exists, and uv venv otherwise refuses with "A directory already exists at: .venv".) The user then runs `uv sync` / `uv pip install -e .` / `pip install -r requirements.txt` once to populate it. No in-container locking is needed — the host-side workspace mutex (see "Concurrent launches" below) guarantees exclusive access.
3. On subsequent launches, the overlay is already populated — the entrypoint skips materialization and goes straight to activation (`VIRTUAL_ENV` + PATH prepend). Persistence is free via the bind mount. Before activation, the entrypoint compares the overlay's actual `pyvenv.cfg` version against `SANDY_VENV_PYTHON_VERSION`; on mismatch (e.g. the user bumped `.python-version` after the overlay was built), sandy prints a drift warning with the recreate command. Auto-recreate is deliberately not done — it would silently nuke installed packages.

**Opt out** with `SANDY_VENV_OVERLAY=0` in `.sandy/config`. The fallback is warn-only: sandy prints a message explaining that the host venv's interpreter isn't reachable inside the container and suggests `rm -rf .venv && uv venv && uv pip install -e .` — but that's destructive to the host venv and rarely what you want.

**Security residual when the overlay is off/skipped (sandbox-escape eval Issue C).** With the overlay active (default), agent writes to `$WORKSPACE/.venv` are diverted into the sandbox overlay, so a host IDE Python extension executing `.venv/bin/python` during discovery runs the *untouched* host interpreter — sandy avoids the "agent tampers with an interpreter the host later executes" class by construction. When the overlay is **off** (`SANDY_VENV_OVERLAY=0`) or **skipped** (symlinked `.venv`; non-standard names like `venv/` which aren't overlaid), the venv sits directly on the rw workspace mount, and an agent *can* modify an interpreter the host later runs. Sandy emits a one-line launch warning in both the overlay-off and symlinked-`.venv` branches naming this residual; the guidance is to re-enable the overlay or keep the host's Python tooling closed on the workspace during an untrusted session. Non-standard venv names get no warning (they aren't detected) — only standard `.venv/` is.

**Non-standard venv names** (`venv/`, `.venv-py311/`, etc.) are not overlaid — only the standard `.venv/` is. The fallback warn-only path still applies to any dangling `.venv/bin/python` symlink in those layouts.

**Host venv is never touched.** The overlay is a shadow — the host filesystem is untouched by sandy. After sandy exits, the host's `.venv/` is exactly as it was before.

**Concurrent launches.** Only one sandy may run against a given workspace at a time. On launch, sandy takes a workspace mutex (`mkdir` on `$SANDY_HOME/sandboxes/.<name>.lock`, which is atomic on every POSIX filesystem and needs no external dependency) and writes its PID into `$LOCK/pid`. A second launch against the same workspace reads that PID and probes liveness via `kill -0`: if the holding process is still running, sandy fails fast with a clear error naming the pid; if the PID is gone (e.g. after a `kill -9` or OOM), sandy auto-clears the stale lock and proceeds. PID reuse is theoretically possible — if the OS recycled the PID to an unrelated process, `kill -0` says "alive" and sandy errors out (false positive); the user clears manually. That's the safer default than a false negative that clobbers an active session. The introspection surface (`sandy --print-state`) reports `lock_holder_alive: true|false|null` per sandbox so external tools can see the same view. Two agents editing the same codebase would step on each other's edits anyway — use separate workspaces for parallel work.

## Daemon Mode (`--start` / `--attach` / `--stop`, milestone 1.1.0, #17)

Decouples a session's lifetime from the launching client, so a session survives a closed terminal / VSCode quit and can be reattached later. Additive: bare `sandy` is byte-unchanged (every daemon branch is gated on `SANDY_START` / `SANDY_ATTACH` / `SANDY_STOP` / `SANDY_DAEMON_SUPERVISOR` / the container-side `SANDY_DAEMON`).

**Architecture — "the container is the daemon; a host-side supervisor owns the lock+helpers+trap."** `sandy --start` forks a detached **supervisor** (`nohup … & disown` — deliberately *not* `setsid`, which is util-linux and absent on macOS, daemon-mode's primary platform) which re-execs sandy with `SANDY_DAEMON_SUPERVISOR=1`. The supervisor acquires the workspace lock with *its own* PID (keeping the #14 PID-owned lock model), builds `RUN_FLAGS` with a **detached** container (`-d --restart unless-stopped --name sandy-<sandbox>`, and crucially **no `--rm`** — docker rejects `--rm` with `--restart`; removal is done by `cleanup()`/`--stop`), spawns the helper processes (SSH/channel relays, egress proxy + its `docker logs -f` streamer) as its children, installs the normal cleanup trap, then blocks on a bounded-sleep wait loop (`while :; do sleep 300 & wait $!; done` — NOT `sleep infinity`, a GNU coreutils extension that BSD/macOS sleep rejects with an instant usage error, which would drop the supervisor straight into its EXIT trap and tear the fresh daemon down; guarded by `run-tests.sh §70`). Container-side, when `SANDY_DAEMON=1` the entrypoint creates the tmux session detached and `exec tail -f /dev/null` instead of `tmux attach`. The `--start` client streams the supervisor log and exits `0` only once `docker exec <c> tmux has-session -t sandy` succeeds.

**State = container labels** (not a state file — survives sandy upgrades, can't drift from docker): `sandy.daemon=true`, `sandy.workspace_path`, `sandy.session=<sandbox-name>`, `sandy.started_at`, `sandy.daemon_pid=<supervisor pid>`.

**D9 — container existence is the durable source of truth; the lock is the live-operation guard.** A running labeled daemon container = "this session exists," *even with no supervisor* (after a reboot, `--restart unless-stopped` resurrects the container on the same fixed proxy IP but the supervisor does not come back). So idempotency (`--start`), the busy-check (bare `sandy`, `--attach`), and `--stop` all key off the **container**, not lock/supervisor liveness. `--start` refuses headless (`-p`/`--print`/`--prompt`) — a one-shot under `--restart unless-stopped` would restart-loop.

**D6 refinement — "container-as-truth" means a container with a LIVE inner session.** A container that is up but whose agent session has *exited* (a zombie: the #47 supervisor died, or the agent exited and a restart raced the ~60s teardown-detection window) must not read as "already running" and wedge the user out. So the `--start` idempotency check and the bare-`sandy` DEC-B check both **probe the inner session** (`docker exec … tmux has-session`, with a short mid-startup retry so a container that's merely still-launching isn't misread and reaped out from under a concurrent start) before honoring the container. A dead-session zombie is **reaped via `"$0" --stop`** and the operation proceeds fresh (`--start` starts a new session; bare `sandy` falls through to interactive). Guarded by `run-tests.sh §73` (structural) + `acceptance-daemon.sh §6.5` (real-docker: kill the inner session → assert `--start` reaps and replaces the container).

**Decisions (documented for the `sandy-ui` consumer contract):**
- **DEC-A — concurrent attach = last-wins** via `tmux attach -d` (a second client cleanly displaces the first; the displaced client exits `3`). Never plain `tmux attach` (that mirrors — the one banned outcome).
- **DEC-B — bare `sandy` over a *live* daemon session = error-with-hint + exit `1`** (points at `--attach` / `--stop`); keyed off the container label so a supervisor-less rebooted session is respected, not clobbered. "Live" is now verified by an inner-session probe (D6 refinement above) — a dead-session zombie is reaped and bare `sandy` proceeds to interactive rather than erroring.
- **DEC-C — exit codes.** `--attach`: `0` = session ended while attached, `3` = clean detach (session lives), `4` = no such session, `5` = attach failed. `--stop`: `0` = stopped, `4` = no such session, `5` = teardown failed. A client attached when `--stop` runs elsewhere sees the container vanish → exits `0`. **Post-attach, `5` is reserved for a failure to *establish* the attach** — once `tmux attach` returns, the outcome is only `3` (session still up) or `0` (session gone). The session-gone case includes the brief window where the container is *still up* but the inner session has ended (the agent exited and the #47 supervisor watch-loop is mid-teardown): that maps to `0`, not `5`, so sandy-ui stops sticky-reconnecting a dying session. A single transient `docker exec` probe failure is absorbed by a one-shot re-probe before the `0` verdict. `--start`: `0` = ready, `6` = **refused before launch** (an approval could not be granted — user-actionable in one step), `7` = container crash-looping, `8` = timed out waiting for the inner session, `1` = anything unclassified. Those three were collapsed onto `1` until #221; a consumer could only tell them apart by scraping the streamed human-readable log, which is the fragility #160 removed from the introspection flags. The distinction matters because `6` is fixable by answering one prompt while `7`/`8` are not.

  **No exit code observed is NOT a verdict (#157).** Every `--attach` code above is *evidence-backed*: sandy discards `tmux attach`'s own return value and re-derives the answer by probing live state afterward. If the sandy process is killed by a signal — the common case being a pty teardown (`SIGHUP`) when an editor closes a terminal, which sandy-ui hits routinely — that probe **never runs**, and a supervising parent sees `code === null` with no exit code at all. This means *the decision procedure did not execute*; it does **not** mean the session failed, and it must not be mapped onto `5`. A killed **local client** says nothing about the **durable session**, which under D9 is owned by the running labeled container. Consumers must reconcile against `--print-state` (or simply re-run `--attach`, which returns `4` if the session is genuinely gone) rather than infer liveness from the absence of a code. Sandy deliberately does not guess here: asserting "the session survived" without probing would be a claim with no evidence behind it, which is the same declared-vs-actual drift #151 exists to catch. Note also that `5` is currently unreachable on the `--attach` path — both `exit 5` sites live in `--stop` — so classifying an unknown state as "attach failed" maps it onto a code `--attach` never emits.

**`--stop` interplay with the #14 lock:** if the supervisor PID is alive, `--stop` signals it (`kill -TERM`) so the supervisor's *own* trap releases the lock (nothing else ever removes a live-owned lock). If the supervisor is dead (D9 reboot case), `--stop` tears the container/networks down directly and reaps the now-stale lock (whose holder PID is provably dead). This is the only unavoidable cleanup duplication, bounded to container+network+lock.

**Introspection:** `--print-schema` `cli_flags` includes `--start`/`--attach`/`--stop` (a consumer feature-detects daemon support on their presence). Each `--print-state` `running_containers[]` entry carries `sandbox` (the `sandboxes[].name` join key), `daemon` (bool), and `attached_clients` (int|null tmux client count). All additive — `schema_version` stays `1`.

**Verification reality:** daemon-mode is a Docker-runtime feature; `run-tests.sh` covers static/structural/introspection contract only. The end-to-end container lifecycle (survival across abrupt client kill, helper reparenting, `--stop` teardown) lives in `test/acceptance-daemon.sh`, which is both independently runnable (the release gate) **and invoked as `run-integration-tests.sh` §19**, so a full integration run on a real Docker host always exercises it.

## Fleet updates (`sandy --update-sessions`, milestone 1.2.0, #41)

Daemon mode makes launches rare — a session can sit up for days, running an ever-staler image with nothing to trigger a rebuild or move it onto a new one. `sandy --update-sessions [--dry-run] [--yes] [--idle-for <minutes>] [--rebuild]` is a **global** maintenance command (ignores cwd; operates on every daemon session on the host) that refreshes images and rolling-restarts stale sessions:

1. **Enumerate** every `sandy.daemon=true` container in one `docker ps` call (labels: `sandy.session`, `sandy.workspace_path`, plus the container's image).
2. **Per-session image refresh** — **DEC-U1**: for each session, run `cd <workspace_path> && "$0" --build-only` (a real child process, `--rebuild` forwarded if given). The orchestrator never guesses the image stack (agent selection, skills, project image) — each workspace's own `--build-only` resolves it from its own `.sandy/config`, exactly the same pipeline a normal launch uses. Distinct workspaces sharing an image converge via the on-disk hash files: the first child to reach a given image builds it, the rest see "up to date" and no-op.
3. **Staleness check** — compares the container's running image id (`docker inspect -f '{{.Image}}' <cid>`) against its image name's current id (`docker image inspect -f '{{.Id}}' <image>`); different = stale = restart candidate. This is the same `_sandy_image_stale` helper `--print-state` full mode uses for `image_stale` (below) — one source of truth.
4. **Idle gate** (only with `--idle-for N`) — **DEC-U5**: with no `--idle-for`, every stale session is a restart candidate; the default is predictable, not activity-heuristic. When given, last tmux activity is probed via `docker exec -u "$(id -u)" <cid> tmux display -p -t sandy '#{window_activity}'` (ALWAYS `-u` — the 1.1.0 lesson); a failed probe is treated as ACTIVE (fail-safe — never restart a session you can't positively prove is idle).
5. **Plan + confirm** — prints a human-readable table (session, workspace, stale, idle age, action+reason — an action command like `--prune-orphans`, not introspection JSON). **DEC-U4**: `--dry-run` still runs step 2 (builds are side-effect-free for a running session) so the printed plan reflects a real comparison, not a stale guess, but performs no stop/start. Otherwise: nothing-to-restart exits `0` immediately; a TTY without `--yes` gets a y/N prompt; non-TTY without `--yes` errors "pass `--yes`" and exits `1` (cron must opt in explicitly) — this gate only fires when there's actually something to restart.
6. **Rolling restart** (serial) — **DEC-U2**: compose the hardened daemon primitives verbatim, `"$0" --stop --workspace <path>` then `SANDY_UPDATE_RESTART=1 "$0" --start --workspace <path>`, no new lifecycle surface. **DEC-U8**: relies on the `--start` child's own exit code (0 = attachable, 1 = failed with the crash-loop teardown from 255b479) — no duplicate readiness polling. A failed stop/start is reported and the loop continues with remaining sessions.
7. **Summary + exit codes** — restarted (with per-session wall-time), skipped (with reason), failed. Exit `0` = all clean / nothing to do; `1` = any failure, or the non-TTY refusal.

**DEC-U3 — `sandy.updated_at` label.** The orchestrator exports `SANDY_UPDATE_RESTART=1` for the `--start` child; the supervisor's daemon `RUN_FLAGS` branch, when it sees that env var, adds `--label "sandy.updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"`. Internal env-only signal — like `SANDY_DAEMON_SUPERVISOR`, not a config key, no `_sandy_key_metadata` row — that rides ordinary env inheritance through the nohup re-exec (same mechanism `SANDY_AUTO_APPROVE_PRIVILEGED` already relies on). This is the sandy-ui sticky-reconnect discriminator: "restarted for an image update" vs. "user manually stopped and started it" (which never sets the label).

**DEC-U7 — placement.** Flag-parsed (`SANDY_UPDATE_SESSIONS=true` + sub-option vars) with a dispatcher in the `--start`/`--attach`/`--stop` family (post-preflight — it needs docker — before config-load side effects). It does **not** resolve a workspace mutex of its own; every mutation goes through `"$0" --stop`/`"$0" --start` child processes, which manage their own locks exactly as they do for a normal interactive invocation.

**Introspection:** `--print-schema` `cli_flags` includes `--update-sessions`. `--print-state` **full mode only** carries `image_stale` (true/false/null tri-state) per `running_containers[]` entry — **DEC-U6**: costs one **batched** `docker inspect` for all sandy containers (#52 — was one per container) plus one `docker image inspect` per unique image name, over the `#25` light-mode two-spawn budget, so light mode omits the key entirely. `--print-state` full-mode `orphan_networks` likewise batches its per-candidate `docker network inspect` into one call (#52). All additive — `schema_version` stays `1`.

**Verification reality:** like daemon mode, this is a Docker-runtime feature — `run-tests.sh §71` covers structure/contract behind a stubbed docker (including a real child `--build-only` run against the stub, primed once so it takes the "up to date" fast path). The real rolling restart (new container IDs, `sandy.updated_at` landing, both sessions attachable post-restart) lives in `test/acceptance-update-sessions.sh`, independently runnable and **invoked as `run-integration-tests.sh` §20**. Every `--update-sessions` call in that harness is `--workspace`-scoped, so it only touches its own scratch sessions — but its `--rebuild` step rebuilds the shared agent image, which correctly marks any other daemon sessions on the host as stale afterward.

## Fleet emergency stop (`sandy --stop-all`, HF-incident Issue 8)

The post-mortem's executive guidance is that every agent needs a named owner *"who has the pre-authorized authority to shut it down immediately without waiting for committee approval,"* and its summary asks for *"a tested shutdown path."* Sandy has a clean **per-session** one — `sandy --stop [--workspace PATH]` — but under daemon mode a user can accumulate many long-lived sessions across workspaces, and the only way to stop them all was to enumerate by hand (or reach for `docker` directly, which skips sandy's lock/network cleanup and leaks orphans `--gc` must later reap).

`sandy --stop-all [--dry-run] [--yes]` is a **fast-path** in the `--gc` maintenance family (parses its own sub-flags, exits before config load / mutex; needs only a reachable Docker daemon). It enumerates every `sandy.daemon=true` container in one `docker ps` (the same label filter `--update-sessions`/`_sandy_update_enum_sessions` use — inlined because that helper is defined far later in the file), prints the plan (session, workspace), then — **DEC-U2 composition** — invokes `"$0" --stop --workspace <path>` per session **serially**, reusing the hardened per-session teardown (its own lock release, the atomic agent+proxy+network removal) verbatim rather than duplicating any lifecycle surface. `--dry-run` lists and stops nothing; `--yes` skips the confirm; non-TTY without `--yes` errors and exits 1 (cron/panic-button discipline mirrors `--gc`/`--update-sessions`); a failed stop is reported and the loop continues, exiting 1 if any failed. `--print-schema` `cli_flags` advertises it. Guarded by `run-tests.sh §71b` (dry-run-lists-stops-nothing, non-TTY exit 1, empty-fleet exit 0, the `"$0" --stop` composition, cli_flags presence — all behind a stubbed docker, mirroring §71).

## Architecture

- **Three-phase Docker build**: A `sandy-base` image contains the OS, toolchains (Node.js 24, Go 1.26, Rust stable, Python 3, C/C++), and system tools. A `sandy-claude-code` image layers Claude Code on top. An optional per-project image (from `.sandy/Dockerfile`) layers project-specific tools on top of that. Each phase only rebuilds when its inputs change. The per-project `.sandy/Dockerfile` build is **approval-gated** (`_sandy_project_dockerfile_approved`): its `RUN` commands execute on the host daemon with unfiltered network, so an unapproved/edited Dockerfile prompts on an interactive TTY and **fails closed** (skips the build, uses the base image) when non-interactive — a committed or agent-written Dockerfile can't build unattended. Approval is a per-workspace sha256 in `$SANDY_HOME/approvals/dockerfile-<hash>.list`; `.sandy/` is also in the protected-dirs list so an existing one is `:ro` in-session (HF-incident Issue 7).
- `sandy` — Self-contained launcher (bash script) installed to `~/.local/bin/`. On first run, generates Dockerfile.base, Dockerfile, entrypoint.sh, and tmux.conf in `~/.sandy/`, builds both Docker images, creates per-project sandbox directories, applies network isolation, and launches the container via `docker run`.
- `install.sh` — `curl | bash` installer that downloads `sandy` to `~/.local/bin/` and checks PATH setup.

## Versioning

`SANDY_VERSION` in the `sandy` script follows this convention:

- **Release**: `X.Y.Z` (e.g. `1.0.0`). Set this when tagging a release.
- **Release candidate**: `X.Y.Z-rcN` (e.g. `1.0.0-rc1`). Tagged and GitHub-released as a **pre-release**. During an rc window: no feature additions; fixes fast-track to `-rc(N+1)`; an rc that soaks clean for a week tags as the final `X.Y.Z`.
- **Post-release**: `X.Y.(Z+1)-dev` (e.g. `1.0.1-dev`). Bump to this immediately after cutting a final release. After cutting an **rc**, bump to `X.Y.Z-rc(N+1)-dev` instead (e.g. `1.0.0-rc2-dev`) — the final version number stays reserved until an rc graduates.

`SANDY_COMMIT` is a separate variable that holds the git short hash. It's empty in the source file — at runtime, `sandy_full_version()` detects it from git if running from a repo checkout, and `install.sh` bakes it in for local installs. The full version string displayed is e.g. `1.0.1-dev-a1b2c3d`.

The update check logic compares only `SANDY_VERSION` (not the hash) against GitHub release tags, via `_ver_lt()`, which **strips everything after the first `-`** (so `-dev` and `-rcN` builds compare as their base `X.Y.Z`). Two consequences: the update check uses `releases/latest`, which skips pre-releases, so stable users are never nagged toward an rc; and rc users are *not* nagged when the same-numbered final ships (`1.0.0-rc1` ≡ `1.0.0` after the strip) — rc users upgrade with an explicit `sandy --upgrade`.

**1.x semver discipline**: within `1.x`, `X.Y.(Z+1)` = fixes only, `X.(Y+1).0` = additive (new keys/flags allowed, no retiering or renames), `2.0.0` = anything that breaks the sandbox forward-compat promise, the introspection `schema_version: 1` contract, or config-key tier semantics. See "Sandbox compatibility (1.x forward-compat promise)" above for the compat-floor rule (`SANDY_SANDBOX_MIN_COMPAT` never moves above `1.0.0` within `1.x`; guarded by `run-tests.sh §60`).

## Skill Packs

Optional Docker image layers that bake curated skill collections into the container. Skills are not included by default — they're built once and cached as a Docker layer.

### Configuration

Set `SANDY_SKILL_PACKS` in `.sandy/config` or as an environment variable:

```sh
SANDY_SKILL_PACKS=gstack
```

### Available Packs

| Pack | Description | Source |
|------|-------------|--------|
| `gstack` | 28 Claude Code skills (QA, review, ship, browse, etc.) + headless Chromium browser engine | [garrytan/gstack](https://github.com/garrytan/gstack) |

### How It Works

Skill packs add two build phases (Phase 2.5a and 2.5b) between the Claude Code image and the optional per-project image:

- **Phase 2.5a — Base image** (`sandy-skills-base-{pack}`): Installs heavy, rarely-changing dependencies like Playwright and Chromium. This image is cached and only rebuilds when the base Dockerfile changes.
- **Phase 2.5b — Code image** (`sandy-skills-{pack}`): Downloads the skill pack source at a pinned version, runs `bun install` and `bun run build`. This layer rebuilds when a new version is detected, but is fast since Chromium is already in the base.

At container startup, `user-setup.sh` symlinks `/opt/skills/{pack}/` into `~/.claude/skills/` so Claude Code discovers the skills automatically. Skill pack `bin/` directories are added to PATH.

First build takes a few minutes (downloading Chromium). Subsequent version updates rebuild only the code layer and are much faster.

### Persistent state (gstack)

`gstack` writes per-project state to `~/.gstack/` inside the container. Sandy bind-mounts this from `<workspace>/.gstack/` on the host so state is workspace-scoped (visible alongside `.git/` and `.venv/`) rather than tied to the sandbox identity. The directory is auto-created on launch if missing.

If the workspace isn't yet gitignoring `.gstack/`, sandy prints a one-line warning at launch — `git check-ignore` is consulted when git is available, with a literal `.gitignore` grep as fallback. Add `.gstack/` to `.gitignore` (or `.git/info/exclude` if you don't want to commit the gitignore change) to suppress.

Pre-0.12 sandy mounted `~/.gstack` from `$SANDBOX_DIR/gstack/` instead. On the first launch after upgrading, sandy migrates the state in one shot: if `$SANDBOX_DIR/gstack/` has content but `<workspace>/.gstack/` doesn't, the contents are `cp -a`'d over and the legacy dir is renamed to `gstack.migrated/`. The `.migrated/` dir is left in place — manual cleanup (`rm -rf $SANDBOX_DIR/gstack.migrated`) is fine once you've confirmed the new location works.

### Version Resolution

Skill pack versions are resolved dynamically from GitHub on each launch — there is no hardcoded version pin. The resolution order is:

1. **GitHub releases API** — fetches the latest non-draft, non-prerelease tag matching the pack's tag prefix (if configured). 5-second timeout.
2. **GitHub commits API** — if no releases exist or no tag prefix is set, fetches the latest commit SHA on the default branch.
3. **Local cache** — `~/.sandy/.skill_version_{pack}` stores the last successfully resolved version.
4. **Hardcoded fallback** — `SKILL_PACK_VERSIONS` array in the sandy script, used only on first run if GitHub is unreachable.

When a new version is detected, `Dockerfile.skills` is regenerated with the updated version. The content hash changes, which triggers a rebuild of the code image (Phase 2.5b) automatically. The base image (Phase 2.5a) is unaffected.

### Adding New Packs

Add entries to `SKILL_PACK_NAMES`, `SKILL_PACK_REPOS`, `SKILL_PACK_VERSIONS`, and `SKILL_PACK_TAG_PREFIXES` arrays in the sandy script, then add a build recipe case in `generate_skill_pack_dockerfiles()`.

## Auto-update

On each launch, sandy checks for newer Claude Code versions by comparing the installed version against the latest release. If an update is available, the image is rebuilt with `--no-cache`.

**No image is built when the resources a build needs are unreachable (#218).** The version check and the build pull from *different* endpoints, and **partial reachability is the normal failure mode** — captive portals and in-flight wifi routinely allow one CDN while blocking another, so a successful update check proves nothing about whether a rebuild can succeed. Observed on in-flight wifi: the check reached `storage.googleapis.com`, flipped `NEEDS_BUILD=true`, and the forced `--no-cache` rebuild died at `apt-get update` with exit 100 — aborting the launch under `set -e` on exactly the network where the already-built local image was most wanted, and re-dying on every retry.

So **every** build site — base, proxy, agent, both skill-pack layers, and the per-project `.sandy/Dockerfile` — passes through `_sandy_build_allowed`, which probes the actual build dependencies (`deb.debian.org`, `registry.npmjs.org`) rather than general connectivity. If they are unreachable: an existing image is kept and the refresh deferred; if there is **no** existing image, sandy fails **immediately** with an accurate message instead of after a multi-minute apt timeout that names the wrong cause. The probe is lazy and memoized, so a launch that needs no build pays nothing.

The agent build additionally tolerates a build that fails *despite* the probe passing (the probe runs host-side while `docker build` runs in Docker's VM, and networks drop mid-build): with a usable image present it warns and continues, since the hash file is only written on success so the rebuild retries next launch. Hash-change and missing-image builds keep failing hard — there is nothing known-good to fall back to. A deferred refresh is reported at session end, so the auto-patch CVE posture below does not erode silently. Guarded by `run-tests.sh §107`. Inside the container, `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates against the read-only filesystem.

### Wrapped-agent security / CVE watch (sandbox-escape eval Issue E)

Sandy wraps four third-party agents (Claude Code, Gemini CLI, Codex, OpenCode), each installed at **floating-latest** via `npm install -g @anthropic-ai/claude-code | @google/gemini-cli | @openai/codex | opencode-ai`. Pillar's "Week of Sandbox Escapes" hit three of these four upstreams, so a wrapped-agent CVE is a realistic event and sandy needs a defined posture, not just "it's in a container." Sandy's boundary never *relies* on the wrapped agent being un-compromised (the whole point is containment), but a vulnerable agent still widens the in-box blast radius, so keeping them current matters.

- **Auto-patch pickup (the default).** Floating-latest + the per-launch update check means a new upstream release is pulled on the next launch (the Claude check triggers a `--no-cache` agent-image rebuild; codex/gemini/opencode ride the same rebuild). So a *patched* release reaches users automatically — no reproducibility, but low patch latency, which is the right trade for a security wrapper. Force it with `sandy --rebuild`.
- **What's installed is recorded.** Each generated agent Dockerfile writes the resolved version to `/opt/<agent>/.version` at build time (`claude|codex|opencode --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'`), so the running image's exact agent versions are auditable in-container.
- **Advisory sources to watch** (for the maintainer's CVE checklist): Claude Code — `anthropics/claude-code` releases + GitHub Security Advisories; Gemini CLI — `google-gemini/gemini-cli`; Codex — `openai/codex`; OpenCode — `sst/opencode`. `npm audit`/OSV against each package name also surfaces transitive advisories.
- **Responding to a wrapped-agent CVE.** *Patched upstream:* `sandy --rebuild` pulls it. *Bad release / regression (need to pin away from latest):* temporarily pin the version in the agent's `npm install -g <pkg>@<good-version>` line in the generated Dockerfile (the install sites), rebuild, and unpin once upstream ships a fix. There is no in-agent allowlist sandy depends on, so the response is always "change what's installed," never "reconfigure the agent."

**Deferred (candidate follow-up, not in scope for a Low/process finding):** a `SANDY_<AGENT>_MIN_VERSION` enforcement floor that refuses to launch an agent below a pinned minimum, and surfacing the `/opt/<agent>/.version` values in `--print-state`. Floating-latest already auto-patches, so a hard floor is a niche pin-away-from-bad-release control; it adds four per-agent config keys plus container-side version-compare enforcement, disproportionate to this finding's severity. Tracked in `docs/POST_1.0_IDEAS.md`.

**Predecessor-image GC (#36).** A same-tag rebuild (base, proxy, or agent — the regularly-rebuilt images; the auto-update path above rebuilds the agent image on a regular cadence) re-tags the image name onto a new id and leaves the old id untagged (`<none>:<none>`), dangling forever. Sandy captures the image id before each of these rebuilds and, after a *successful* rebuild, best-effort `docker rmi`s the predecessor (`_sandy_prune_old_image`). No `-f`, so it silently no-ops when the old id is still referenced by a child image (e.g. the old base under an as-yet-unrebuilt agent) or a running container — those are reclaimed on a later launch once nothing references them. This is the fix-slice of #36; the feature-level unified reclaim across every sandy resource kind is `sandy --gc`, below.

### Proxy image freshness (HF-incident Issue 3)

The **agent** image auto-rebuilds on a new agent version (above), but the **proxy** image only rebuilt when its git ref changed — i.e. when `SANDY_VERSION` changed — so between sandy releases the proxy's `golang:1.26-trixie` base and Go stdlib (the TLS/HTTP/CONNECT I/O of the security-critical component) froze while the agent next to it self-updated weekly: the wrong patch-latency ordering for the component the incident's attacker chose. Fix: `generate_dockerfile_proxy()` writes a **monthly freshness epoch** (`date -u +%Y-%m`) into `Dockerfile.proxy`, so its content hash moves once a month and triggers a rebuild without a sandy release; that rebuild adds **`--pull`** so `FROM golang:1.26-trixie` re-resolves to the current digest and picks up Go stdlib / Debian security fixes (`--no-cache` already rebuilt the binary but never re-pulled the base). The pinned line matters as much as the mechanism: `golang:1.24-bookworm` is a *floating minor* tag, so it genuinely delivered 12 patch releases (through Go 1.24.13, pushed 2026-02-04) — but once Go 1.24 left Go's 2-release support window there were no further 1.24.x pushes, and from ~Feb 2026 the monthly `--pull` re-resolved to an unchanged digest, refreshing only the Debian layer. Moving to the 1.26 line restores actual stdlib patch delivery; keeping the pin on a *supported* Go minor is what makes this mechanism work at all. `sandy --rebuild` forces it immediately. `--print-state` full mode reports `proxy_image_created` (the image's build timestamp) so `sandy-ui`/the user can see staleness. Guarded by `run-tests.sh §49`.

### Maintenance-family exit-code rule (C1)

The commands below (`--gc`, `--reset-sandbox`, `--remove-sandbox`, `--stop-all`, `--update-sessions`, and any future addition to this family) share one rule for what `1` vs `0` means, stated once here so later commands cite it instead of re-deriving it: **refusal is exit `1` when the goal state is UNMET; skip is exit `0` when it is ALREADY MET.** Concretely — `--reset-sandbox`/`--remove-sandbox` exit `1` when a live workspace lock blocks the operation (the sandbox was NOT reset/removed, the goal is unmet); a future `--provision` would exit `0` when a live session already satisfies it (the sandbox already IS provisioned, the goal is met, nothing to do); `--doctor` (read-only, no mutation) exits `0` unless a required check actually fails. The distinction is whether the command's stated goal was achieved by the end of the run, not whether it did any work.

### `sandy --gc` — unified Docker-resource reclaim (#36)

`sandy --gc [--dry-run] [--yes]` is a **global** maintenance fast-path command (same pre-preflight family as `--print-state`/`--prune-orphans` — it runs before config load, mutex acquisition, or any image build, needing only a reachable Docker daemon) that reaps every kind of leaked sandy-owned Docker resource in one pass:

1. **Dead-owner containers** — any `sandy-*`/`sandy-proxy-*` container nothing live still owns.
2. **Orphaned networks** — delegates to the existing `_sandy_reap_orphan_networks`/`_sandy_orphan_networks_list` (unchanged — DEC-4b), so `--gc` and `--prune-orphans` can never drift on network handling; `--prune-orphans` remains a documented subset of `--gc`, not deprecated.
3. **Orphaned per-project images** (`sandy-project-<x>`) — no sandbox directory still references them.
4. **Orphaned skill-pack images** (`sandy-skills(-base)?-<x>`) — no sandbox's workspace still configures that pack set.
5. **Dangling sandy images** — `<none>:<none>` images left over from a rebuild (the same class `_sandy_prune_old_image` targets one-off; `--gc` sweeps whatever slipped past it), scoped to sandy's own images via the `sandy.managed=1` build label (see below).

**Container-liveness predicate.** Reuses the daemon-mode D6/D9 rule verbatim: *the container is truth only with a LIVE inner tmux session.* Agent-vs-proxy is decided by **image**, never by name prefix — a workspace whose sanitized basename happens to be `proxy` produces an agent container literally named `sandy-proxy-<hash>`, so a name-prefix test would misclassify it as a proxy sidecar (this was a real regression, fixed before 1.3.0 shipped). The lister is a two-pass walk: **pass 1** classifies every AGENT container (any recognized sandy image other than `sandy-proxy`) and records the KEPT set. For a `sandy.daemon=true` agent, "not running" is dead and reaped, but a *running* container is only reaped when `docker exec ... tmux has-session -t sandy` actually **fails** — retried 5x/1s (mirroring `--start`'s own mid-startup retry) so a container whose supervisor hasn't created the session yet isn't misread as a zombie; a live session is **never touched, regardless of `sandy.daemon_pid` liveness** (the D9 lesson: a rebooted host can resurrect a `--restart unless-stopped` container on a dead supervisor pid while the session itself is perfectly healthy). For a non-daemon-labeled agent (a foreground/interactive container), SANDBOX_NAME is derived by stripping only the `sandy-` prefix, and it's KEPT only when its workspace's `$SANDY_HOME/sandboxes/.<name>.lock/pid` is live (the same `lock_holder_alive` test `--print-state`/#14 already use). **Pass 2** judges every PROXY container (image `sandy-proxy`) purely by its *paired agent's* pass-1 KEPT status — never by the proxy's own running state or lock file: a daemon's proxy is never `sandy.daemon`-labeled, so if it were judged by its own lock (which holds the *supervisor's* pid), a SIGKILL/OOM'd supervisor would make gc reap a live session's proxy and strand its agent on a routeless sidecar (the exact failure the atomic agent+proxy teardown in `cleanup()` exists to prevent) — this was also a real regression, fixed before 1.3.0 shipped. The image-name gate (not the `sandy.managed` label) is the operative container predicate, so it works retroactively against containers started by a pre-1.3.0 sandy.

**Provenance label (`sandy.managed=1`).** Every `docker build` sandy runs (base, proxy, agent, skills-base, skills, per-project — all six sites) now stamps `--label sandy.managed=1`. This is the scoping filter for all three image listers (dangling/project/skills), so a dangling `<none>` image from some unrelated tool's build churn is never touched. **Retroactive gap:** images built by a pre-1.3.0 sandy lack this label and are invisible to the dangling-image lister; they fall back to whatever manual/`_sandy_prune_old_image` cleanup already applied, and the gap closes naturally as images get rebuilt going forward. The running agent container and the proxy sidecar also now carry an analogous `sandy.managed=true` label — additive future-proofing, not yet the operative container predicate (see above).

**Reap ordering:** containers → networks → project images → skills images → dangling images last (mirrors how `docker rmi` without `-f` no-ops on anything still referenced, so container/network teardown happens before anything that might still reference an image).

**Flow:** compute all five lists up front → print a human-readable plan ("Would remove ...", verb-oriented, not introspection JSON) → nothing to reclaim exits 0 immediately → `--dry-run` prints the plan and exits 0 before any confirm → otherwise `--yes` skips the prompt, a TTY without it gets a y/N, and non-TTY without it errors "pass `--yes`" and exits 1 → reap in the order above → a before/after re-count (not the attempt count) reports what actually freed, so a resource that raced back to life between the plan and the reap isn't falsely claimed.

`--print-state` full mode carries two new top-level keys mirroring `image_stale`'s FULL-MODE-ONLY convention: `dangling_images` and `orphaned_containers` (both `null` in light mode, even when real orphans exist, to stay within the light-mode two-spawn budget).

**Verification reality:** like daemon mode and fleet updates, this is a Docker-runtime feature — `run-tests.sh §79` covers structure/contract behind a stubbed docker (the D9 survival case as the top behavioral assertion, dangling-image label scoping as the key safety assertion, dry-run, and non-TTY exit-1). Real reclaim against a live Docker daemon is deferred to a maintainer-run acceptance script, the same pattern as `test/acceptance-daemon.sh`/`test/acceptance-update-sessions.sh`.

**Daemon-log polish (#51).** The `sandy --start` supervisor runs non-interactively (nohup, no TTY) but streams its log to the `--start` client, so sandy forces ANSI colors on when `SANDY_DAEMON_SUPERVISOR=1` (otherwise every `[sandy]` line renders white) and quiets the long base-image build with `-q` under the supervisor (otherwise BuildKit's plain-progress dumps hundreds of apt lines into the streamed log). Both are gated on supervisor mode — the interactive experience is unchanged (base build stays verbose so the user sees progress on the first long build).

### `sandy --reset-sandbox` — rebuild one project's sandbox from known-good (HF-incident Issue 5)

The post-mortem's remediation lesson: *"surgically cleaning a runtime environment is a losing battle against fast-moving attack agents — architect services to be destroyed and redeployed from known-good images."* Sandy's **container** is already immutable-ish (`--read-only`, tmpfs home, images rebuilt on hash change), but its **sandbox** is not — `pip/`, `uv/`, `npm-global/`, `go/`, `cargo/` bins sit on `PATH` and `.claude/plugins` persists into every later session for that project (`THREAT_MODEL` R5), so a poisoned session can carry over. The documented recovery was a manual `rm -rf ~/.sandy/sandboxes/<name>` against a *hashed* dir name the user had to look up (and which also destroys `WORKSPACE.json` lineage, the approved-symlinks list, opencode config). After a "did the agent do something weird?" moment, that should be one command.

`sandy --reset-sandbox [--workspace PATH] [--keep-approvals] [--dry-run] [--yes]` is a **filesystem-only** fast-path in the `--gc` maintenance family (no Docker, no config load, no mutex acquisition — it runs before all of that). It resolves the target workspace (default cwd) the *same way the launch path does* — `pwd -P` canonicalize → `basename-<8-char-sha256>` sandbox name — so it targets exactly the sandbox a launch from there would use. It **refuses while a live session holds the workspace mutex** (`$SANDY_HOME/sandboxes/.<name>.lock/pid` + `kill -0`, the same #14/`--print-state` liveness test) — resetting under a running session would corrupt its state. It prints the plan (each persistent entry with its `du -sh` size), then destroys everything in the sandbox dir **except `WORKSPACE.json`** (lineage always preserved) and — with `--keep-approvals` — `.sandy-approved-symlinks.list`; the next launch re-materializes `pip/uv/npm/go/cargo` + agent state from scratch. `--dry-run` prints the plan and mutates nothing; `--yes` skips the confirm; non-TTY without `--yes` errors and exits 1 (same discipline as `--gc`). `--print-schema` `cli_flags` advertises it. Guarded by `run-tests.sh §79b` (dry-run-no-mutation, real-reset-removes-state-preserves-WORKSPACE.json, `--keep-approvals`, live-lock refusal, cli_flags presence — all behind a stubbed filesystem, no Docker).

### `sandy --remove-sandbox` — permanently delete a sandbox directory (#178)

`--reset-sandbox` (above) only resolves a target by **canonicalizing a workspace directory that still exists** — its `pwd -P` step has nothing to hash once the workspace itself is gone (moved, renamed, deleted), and it always preserves `WORKSPACE.json` lineage regardless. `--remove-sandbox` is the tool for that gap: it deletes the **entire** sandbox directory and preserves **nothing** — `WORKSPACE.json` goes with the rest.

**Three mutually exclusive selectors** (more than one → exit 1 before any resolution):

1. **Workspace mode** (default cwd, or `--workspace PATH`) — identical `pwd -P` + `basename-<8-char-sha256>` resolution as `--reset-sandbox`. Strict: the workspace directory **must exist**. There is deliberately no fallback to hashing an unresolved literal path — that would be a second, weaker resolution path on an `rm -rf` command, and the whole point of the other two selectors is to give a workspace-is-gone case an *equally* trusted path in rather than a degraded one.
2. **`--sandbox NAME`** — the exact sandbox directory name under `$SANDY_HOME/sandboxes/`, for a sandbox whose workspace is already gone. Validated as a single path segment: rejects empty, any `/`, any leading `.` (lock directories are hidden siblings `.<name>.lock`), any `..` substring, and anything outside `[A-Za-z0-9._-]`.
3. **`--orphans`** — every sandbox whose recorded `workspace_path` no longer exists. Predicate (conservative — "when uncertain, keep," the same rule `--gc`'s listers use): a sandbox is an orphan iff `WORKSPACE.json` exists **and** `workspace_path` is non-empty **and** `[ ! -e "$workspace_path" ]`. A legacy sandbox with no marker is never an orphan (unknowable, not provably gone); a `workspace_path` that exists as a non-directory is also not an orphan. `--remove-sandbox --orphans --dry-run` is the human-readable orphan listing — there is no separate `--list-orphans` flag, mirroring how `--gc --dry-run` is its own listing. `--print-state` also carries a machine-readable `workspace_exists` tri-state per sandbox (see SPEC_INTROSPECTION.md) for programmatic orphan detection.

**Removal preserves nothing, and also reaps orbiting state** that would otherwise be permanent orphans with no other reaper: the sibling lock directory `$SANDY_HOME/sandboxes/.<name>.lock`, and — when the workspace path is known — the per-workspace approval files `approvals/passive-<h>.list` and `approvals/dockerfile-<h>.list`, keyed on the **16-char** sha256 hash of the canonical workspace path (sandy:~5632/~7595 — *not* the 8-char hash the sandbox directory name itself uses; these are two different hashes of the same path, at two different lengths, for two different purposes). A legacy sandbox with no recorded workspace path skips the approval reap silently — there is nothing to key off. When the sandbox carries a `.handoff-enabled` marker, the plan prints a loud note that removal un-enrolls it from the handoff fleet — `--reset-sandbox` guards against *silent* un-enrollment by preserving the marker, but an explicit, confirmed `--remove-sandbox` is not silent, so the marker is destroyed along with everything else. Any `agent-args.<agent>` per-agent launch-args files (see "Per-agent override" above) are named in the plan the same way, one NOTE line per file, and destroyed along with the rest of the sandbox.

**Safety architecture**, layered rather than relying on any single check: (1) one trusted resolution path per selector, as above; (2) `--sandbox NAME` input validation, above; (3) a **containment assert immediately before every `rm -rf`** — `case "$dir" in "$SANDY_HOME/sandboxes/"?*) ;; *) exit 1 ;; esac` plus a basename-has-no-slash recheck — `--reset-sandbox` only ever removes *entries inside* an already-validated directory, but this removes a *whole* directory, so it earns its own check at the point of use, not just at candidate-collection time; (4) the same live-workspace-lock refusal as `--reset-sandbox` (`$SANDY_HOME/sandboxes/.<name>.lock/pid` + `kill -0`) — single-target modes hard-error and exit 1 with nothing touched, `--orphans` skips that one sandbox with a yellow warning and continues (matching `--update-sessions`' per-item failed-stop handling); (5) a **best-effort running-container guard** — the D9 daemon-mode lesson is that a `--restart unless-stopped` container can be alive on a *dead* supervisor pid (a rebooted host), so the lock test alone would deprovision a sandbox out from under a healthy session. One batched `docker ps --format '{{.Names}}'` call; a candidate is treated as live only on an **exact, whole-line** name match against `sandy-<name>` or `sandy-proxy-<name>` — never a prefix test, which was a real pre-1.3.0 `--gc` regression (a workspace whose basename is `proxy` produces an agent container literally named `sandy-proxy-<hash>`). Docker absent or unreachable → the guard silently **passes** (fail-open, since this command's whole point is to work without Docker); (6) confirmation discipline identical to `--reset-sandbox`/`--gc`: the plan is always printed (workspace path, last-used timestamp, `du -sh` size, per target); zero removable candidates exits 0 immediately; `--dry-run` exits 0 before any confirm; `--yes` skips the prompt; a TTY without it gets a y/N read from `/dev/tty`; non-TTY without it errors and exits 1.

**Why this is NOT in `--gc`**, despite being in the same filesystem-adjacent maintenance family: (1) `--gc`'s safety envelope rests on "a false-positive reap costs a rebuild, not data loss" — sandbox directories hold non-reproducible state (installed packages, plugins, approvals, the handoff outbox, `WORKSPACE.json` lineage itself), so folding sandbox deletion into `--gc` would break the invariant that makes `--gc`'s imprecision tolerable; (2) users already run `sandy --gc --yes` in cron — adding sandbox deletion would silently change what an *already-given* `--yes` does; (3) `--gc` requires a reachable Docker daemon and judges liveness by container/tmux state, while this command is filesystem-only and judges primarily by the workspace mutex (Docker is only a best-effort supplementary guard, item 5 above). Both commands cross-reference each other in their docs so neither reads as forgotten.

**Two residuals** (procedural mitigation only, not solvable in code — see SPEC_INTROSPECTION.md's `workspace_exists` entry for the full discussion): a workspace on a slow/unreachable network mount can make the `[ -d ]` liveness check block; and a workspace that is merely *unmounted* (removable media, a not-currently-mounted network share) reads identically to one that was genuinely deleted. Both are mitigated by the same procedural discipline — the plan is always shown, `--yes`/confirmation is always required, and **operators should not cron `sandy --remove-sandbox --orphans --yes` on a host where workspaces live on removable or intermittently mounted media.**

`--print-schema` `cli_flags` advertises `--remove-sandbox`, and the `--workspace` `cli_flags` entry's description was updated to name it among the flags it is honored by (the #156 drift discipline — a flag's description must list every command that actually accepts it). Guarded by `run-tests.sh §99` (fabricated `$SANDY_HOME` fixture covering all three selectors, dry-run inertness, blast-radius precision, stale-lock and approval reap, live-lock and live-container refusal/skip, Docker-absent fail-open, invalid `--sandbox` names, two-selector rejection, non-TTY refusal, nonexistent-target error, and both `--print-schema`/`--print-state` introspection surfaces — all behind a stubbed filesystem and a PATH-stubbed `docker`, no real Docker required).

### `sandy --provision` — non-interactive sandbox creation via the real launch path (#177)

A sandbox is **only a launch artifact** — `mkdir -p "$SANDBOX_DIR"` happens during a launch, so there was no way to create one without starting an interactive agent session. A downstream fleet provisioner hit this as a bring-up step that read, in full, *"launch each sandbox once"*: one interactive session per sandbox, started and immediately abandoned, purely to harvest a side effect.

**What this deliberately is NOT: a flag that creates the directories.** That is the tempting shortcut and it is wrong for the same reason "the handoff directory being present is sufficient" was rejected (see "Handoff directories" above) — hand-created state that no container ever mounted *looks wired and is not*. A flag manufacturing sandbox state from inside sandy would be worse than the hand-created case, because it would carry sandy's own authority, and it would be a second code path free to drift from the real one. The ask is the opposite: **run the real launch path, non-interactively**, so the handoff pair, the settings seed, and `WORKSPACE.json` all come from the paths that normally produce them.

**Mechanism — DEC-U2 composition, no new lifecycle surface** (mirrors `--stop-all`/`--update-sessions`): `SANDY_PROVISION=1 "$0" --start --workspace <ws>`, then `"$0" --stop --workspace <ws>`. `SANDY_PROVISION` is an internal env-only signal — no `_sandy_key_metadata` row, not in `SANDY_ENV_ONLY_KEYS` — that rides the same nohup env-inheritance path `SANDY_UPDATE_RESTART` already uses (sandy:110-113) into the `--start` supervisor, which stamps a `sandy.provisioned_at=<ISO ts>` container label (mirrors `sandy.updated_at`/DEC-U3) when it sees the flag.

**Completion** = `--start` exit `0` (the inner tmux session is attachable) followed by `--stop` exit `0`. `--stop` exit `4` after a successful `--start` is **also** success — the session was stopped by other means in the interim, but the launch itself already completed, which is what proves provisioning. `--stop` exit `5` (a real teardown failure) is reported as a failure — a live, unstoppable session is not a completed provision.

**Consumer note — exit `0` attests to sandy's goal, not necessarily yours.** Under the C1 rule `0` means *the sandbox is provisioned*. A caller whose actual goal is something narrower — a handoff pair on disk, a particular seeded file — must check for **that**, not read sandy's success as its own. The concrete case a fleet consumer hit: against a container that started **before** handoff creation became unconditional (1.7.0), `--provision` correctly exits `0` and no handoff pair appears. That is the contract working as documented, but it is an easy misread, so verify the artifact you care about rather than the exit code alone.

**Guard against a live session — safe no-op, exit 0.** Two probes, both consulted, in order: (1) the workspace mutex `$SANDY_HOME/sandboxes/.<name>.lock/pid` + `kill -0` (catches a foreground interactive session *and* a live daemon supervisor — the same #14/`--print-state` liveness test every command in this family reuses); (2) a running daemon container for the workspace (the D9 lesson — a `--restart unless-stopped` container can be alive on a *dead* supervisor pid after a host reboot, which guard 1 alone would miss). This follows the C1 rule above verbatim: a live session means the sandbox is *already* provisioned, so that's `0` (goal met, nothing to do), never a `1` refusal.

**TOCTOU — never stop a session this run did not create.** `--provision` mints a random ownership token per run (`openssl rand -hex 8`, same portable fallback chain as the session nonce, but a **separate value** — the session nonce is the self-attestation trust root and a docker label is readable by anything that can run `docker inspect`), passes it to the `--start` child as `SANDY_PROVISION_ID`, and the supervisor stamps it as `sandy.provision_id`. Both TOCTOU reads require the container to carry **that exact token**, so the check proves *ownership* rather than mere stability. `sandy.provisioned_at` remains a pure ISO-8601 timestamp alongside it (informational; identity lives in its own label so the timestamp never carries two meanings).

Why a token rather than a finer timestamp: `provisioned_at` is second-granularity, so a fleet bring-up loop provisioning two sandboxes within the same second produced **byte-identical** stamps, and a stability-only check could mistake another workspace’s session for its own. Sub-second precision is *not* the fix — `date`’s `%N` is GNU-only and this code runs in the host-side supervisor, so on macOS it would emit a literal `N`, making every stamp identical and collisions **more** likely, invisibly to a Linux CI. Randomness removes the clock from the correctness argument entirely.

**Command surface.** `sandy --provision [--workspace PATH] [--dry-run] [--yes]` is a fast-path in the `--gc`/`--reset-sandbox` maintenance family, parsing its own trailing sub-flags — but (unlike the filesystem-only members of that family) it **needs a reachable Docker daemon**, since it actually launches a container. Single workspace (default cwd), resolved with the exact `--reset-sandbox`/`--remove-sandbox` recipe (`pwd -P` canonicalize → `basename-<8-char-sha256>`). Flow order: docker preflight → workspace resolve → guard 1 (lock) → guard 2 (daemon container) → print plan → `--dry-run` exits 0 → confirm gate (`--yes` / TTY y/N / non-TTY error exit 1) → execute with child stdio **inherited** (streamed, not captured — the user should see the real launch happen, the same way `--stop-all`/`--update-sessions` stream their composed calls).

**Always re-runnable; never skipped because the sandbox directory exists.** Directory presence proves nothing — the same principle that made the handoff directories' creation unconditional in 1.7.0 (above). The command's entire value is the proof that a real launch happened; the two liveness guards are what make re-running it safe, not a check on the directory.

**Verification reality.** `run-tests.sh §102` covers `--provision`'s own guard/TOCTOU/exit-code logic behind a fabricated `$SANDY_HOME` and a tiny stubbed `docker`, using a technique worth naming: a thin executable **wrapper** stands in for `$0`. Invoked as `--start`/`--stop` it is a fully test-controlled fake (reads/writes a small fake-docker state directory); invoked any other way it `source`s the real, unmodified sandy script — sourcing (not `exec`, not a nested `bash -c`) is what keeps `$0` pinned to the wrapper's own path, so when `--provision`'s real code later runs `"$0" --start ...` / `"$0" --stop ...`, that recursive call re-enters the wrapper and hits the fake cases instead of the real daemon supervisor pipeline. This proves `--provision`'s own logic — guards, the TOCTOU comparison, exit-code composition — against 100% real code, without ever running a real child `--start`. The real Docker-runtime end-to-end proof (a genuine daemon session actually coming up, `--print-state` reflecting it, a real second `--provision` run against a live session correctly no-op'ing) is maintainer-run in `test/acceptance-provision.sh`, mirroring `test/acceptance-daemon.sh`, and is also invoked as `run-integration-tests.sh §24`.

### `sandy --doctor` — standalone preflight diagnostics (#124)

`doctor.sh` (repo root, curl-able: `curl -fsSL .../doctor.sh | bash`) predates sandy having a Docker-runtime maintenance family, and stayed a separate script — but `install.sh` installs **only** the `sandy` script (see `install.sh`), so `doctor.sh` never lands on an installed system and `sandy --doctor` could not have invoked it as a sibling file. The fix: `doctor.sh`'s body now lives inside `sandy` itself, as a **quoted** heredoc (`<<'SANDY_DOCTOR_HOST'`) in `_sandy_doctor_host()` — that heredoc is the single source of truth. The repo-root `doctor.sh` is a **generated, committed** mirror kept in sync by `test/regen-doctor.sh`, which exactly mirrors the `test/regen-template.sh` pattern documented above (a heredoc string literal is unshellcheckable, so the mirror exists for lint/review, and — for `doctor.sh` specifically — so it stays curl-able and byte-runnable standalone for a machine that doesn't have sandy installed yet):

```sh
test/regen-doctor.sh         # rewrite doctor.sh from the heredoc
test/regen-doctor.sh --check # verify no drift (used by test/run-tests.sh)
```

`test/run-tests.sh` runs `--check` so an edit to the heredoc without regenerating fails the suite (mirrors the `user-setup.sh.tmpl` drift gate, and `test/lint-bash32.sh` lints `doctor.sh` in its target set either way).

**Hazard, and why the HOST section is a child process, not inlined.** `doctor.sh` contains `sandy --version 2>/dev/null | head -1` — under `sandy --doctor` this is a **recursive self-exec** of the real sandy binary (harmless: it's just `--version`, a fast non-recursive fast-path). That line is safe today only because it runs in a **child shell with no `pipefail`**, so the `| head` closing early produces an inert `EPIPE`. `_sandy_doctor_host()` therefore pipes the heredoc body to a fresh `bash` (`bash <<'SANDY_DOCTOR_HOST' ... SANDY_DOCTOR_HOST`) rather than `source`/`eval`-ing it into sandy's own `set -euo pipefail` shell — inlining it would turn that `EPIPE` into exactly the GREPM failure class `test/lint-bash32.sh` exists to catch. The dispatcher captures `_sandy_doctor_host`'s exit code via `... || rc=$?` rather than a bare call, for the same underlying reason: a bare nonzero return from a function under `set -e` aborts the whole script before the RUNTIME section ever runs.

**`sandy --doctor [--fix] [--yes]`** is a **global** fast-path in the `--gc`/`--stop-all` maintenance family — parses its own trailing sub-flags, dispatches before config load/mutex/image build. Two sections:

- **HOST** — runs the embedded `doctor.sh` body unchanged: bash/git/curl/docker presence, PATH, `gh`/node-or-jq/socat recommendations, Claude credential detection, sandy install status. This is sandy's only **required**-failure source for `--doctor`.
- **RUNTIME** — reuses sandy's own predicates **verbatim, never re-implemented** (the DEC-4b lesson: a duplicated lister is how gates drift): `_sandy_image_stale` for every running `sandy-*` container (batched via `_sandy_prefetch_container_inspect`), `sandy-proxy` image build date, and the orphaned-resource counts `--gc` already computes (`_sandy_orphan_networks_list`, `_sandy_dead_owner_containers_list`, `_sandy_orphaned_project_images_list`, `_sandy_orphaned_skills_images_list`, `_sandy_dangling_images_list`). It silently re-probes `docker info` to gate these — RUNTIME never re-prints what HOST already reported; an unreachable docker collapses the whole docker-dependent half of RUNTIME to one `skipped: docker unreachable (see Required above)` line. Two filesystem-only checks run regardless of docker: workspace-lock sanity (`$SANDY_HOME/sandboxes/.<name>.lock/pid` + `kill -0`, the identical stale-lock predicate the launch path's own auto-clear uses) and a **read-only** orphaned-sandbox count (`WORKSPACE.json` present, `workspace_path` non-empty, `[ ! -e "$workspace_path" ]` — the same conservative predicate `--remove-sandbox --orphans` uses). **Every RUNTIME finding is a warning, never a required failure** — a stale image, an orphaned resource, an orphaned sandbox, none of these mean sandy can't run, unlike a missing docker/git/curl.

**Exit-code contract** (the maintenance-family rule from `--gc`/`--remove-sandbox`: refusal = 1 when the goal state is unmet, skip = 0 when it's already met, applied here as *diagnosis*): **0 iff every required HOST check passes; 1 otherwise. Warnings — from either section — never affect the exit code.** This is the crisp contract CI and sandy-ui health probes depend on.

**`--fix` is deliberately narrow — exactly two remediations, both delegated to existing code, never reimplemented:** (1) `rm -rf` a stale workspace lock whose pid is numeric and provably dead (byte-identical predicate to the launch path's stale-lock auto-clear); (2) reap orphaned networks via the existing `_sandy_reap_orphan_networks` (the same reaper `--gc`/`--prune-orphans` use). **Nothing else** — no sandbox, image, or container is ever touched by `--fix`; the orphaned-sandbox count stays read-only always (an unmounted volume reads as "gone" — #178's `workspace_exists` residual applies here too, so the remediation stays the explicit, confirmed `sandy --remove-sandbox --orphans`, never an implicit side effect of `--doctor --fix`).

**`--yes` without `--fix` is a hard error (exit 1), not silently inert** — a CI job that meant `--fix --yes` and lost the `--fix` token must not quietly run read-only and report success. With `--fix` given and something to fix: nothing-to-fix short-circuits with a plain message (no prompt at all — mirrors `--gc`'s "nothing to reclaim" fast exit, and means the non-TTY refusal below is only reachable when a fix is actually pending); otherwise a TTY without `--yes` is prompted (`/dev/tty`, y/N); non-TTY without `--yes` errors and **exits 1, mutating nothing** (same discipline as every other command in this family).

Introspection: `--print-schema` `cli_flags` advertises `--doctor`, and the `--workspace` entry's "NOT accepted by" list names it (`--doctor` takes no `--workspace` — it's a global check, like `--gc`). `--help` carries its own left-column entry in the Maintenance block (`run-tests.sh §91` ratchets this — a flag missing its own `--help` entry fails the build). Guarded by `run-tests.sh §101`: the exit-code contract (pass/required-failure/warning-does-not-fail, asserted explicitly), read-only-without-`--fix`, `--fix` clearing a dead lock while leaving a live one (pid `$$`) untouched, a static assertion that the `--fix` code path contains no `docker rm`/`rmi` call, `--yes`-without-`--fix` and non-TTY-without-`--yes` refusals (both exit 1, both mutate nothing), orphaned-sandbox counting and its read-only-under-`--fix` guarantee, and `test/regen-doctor.sh --check` drift detection (including a scratch-copy mutation proving the detector actually fires, not just that it runs) — all behind a stubbed filesystem and a PATH-stubbed `docker`, no real Docker required.

## claude.ai account connectors (`SANDY_CLAUDE_CONNECTORS`, #129)

The Claude OAuth token sandy mounts is **account-scoped**, so every claude.ai *account connector* the user has ever enabled (Gmail, Google Drive, …) was silently reachable from **every** sandbox — including untrusted-repo sessions, with no additional prompt. Found in the field: a maintainer noticed all sandy instances could read their Gmail after connecting it once on claude.ai. That is ambient authority crossing the per-project boundary sandy exists to draw, and none of the existing defenses covered it — the egress proxy, `:ro` mounts, and per-project credential sandboxes all address different things, while the token is mounted whole *by design* because it is how the agent authenticates.

**Connectors are now suppressed by default.** `SANDY_CLAUDE_CONNECTORS=1` exposes them for one instance.

The mechanism is Claude Code's own `disableClaudeAiConnectors` setting, seeded as a **managed** settings.json key — always overwritten, in **both** directions. That last part is load-bearing rather than cosmetic. Claude Code's own schema text (verified against the installed binary, 2.1.250) reads:

> *"When true in any settings source, claude.ai MCP cloud connectors are not auto-fetched or connected. … **Any-source-true wins: a project can opt out, but a project-level false cannot override a user-level true.**"*

So exposing connectors is **not** simply "write `false`" — an inherited `true` from the host's `~/.claude/settings.json` would survive sandy's merge and silently defeat the opt-in. Seeded in all three settings branches (node, jq, and the no-tool last resort): a security default that varies by which tools happen to be installed is not a default, and the no-tool host is the one with the fewest other defenses.

**Tier: value-aware.** `0` is passive-safe from any source; `=1` *weakens* the sandbox, so from a workspace `.sandy/config` it goes through the per-workspace approval prompt like `SANDY_EGRESS_NO_ISOLATION=1`. Conveniently, Claude Code's any-source-true-wins resolution already matches sandy's own rule — *a repo may make the sandbox tighter, never looser*.

**Two honest limits.** It gates **auto-fetched** connectors only: a claudeai-proxy server passed explicitly via `--mcp-config` still follows the normal MCP trust flow. And it is **Claude-only** — the account-connector rider is a Claude Code phenomenon, so this is coverage, not parity with codex/gemini/opencode.

Defense in depth: `claudeAiMcpEverConnected` — host metadata listing which connectors exist — is stripped from the `.claude.json` seed regardless of the knob. The settings key is the gate; this is simply not handing over a list of what is behind it. Guarded by `run-tests.sh §110`.

## Suspicious workspaces (`SANDY_SUSPICIOUS`, #130)

The mounted Claude `.credentials.json` carries the **refresh token** — permanent, renewable account access until manually revoked — and permissive-mode egress allowlists (pypi, github) are plausible exfil channels for a poisoned dependency. `SANDY_SUSPICIOUS=1` is the hardened posture for a workspace you actively distrust, the pre-broker slice of #121:

- **Refresh token stripped** before mounting: the container gets the short-TTL access token only, so an exfiltrated copy dies at `expiresAt` and cannot be renewed. The strip is **verified after the rewrite** (a `refreshToken` surviving anywhere fails it) and **fails closed** — on any error, *no* credentials file is mounted rather than an unstripped one. Trade-off, stated: in-session token refresh stops working when the access token expires; relaunch or `/login`. Acceptable-to-desirable for a deliberately short suspicious session.
- **Disposable-key mode**: with `ANTHROPIC_API_KEY` set and no long-lived token, the OAuth file is not mounted at all — instantly revocable compartmentalization.
- **Connectors forced off** (overrides an approved `SANDY_CLAUDE_CONNECTORS=1`) and **egress defaults to strict**; an explicit egress choice still wins but is named loudly.
- **`cred_mode` recorded** in `/etc/sandy-session.json` (`oauth-token` | `access-token-only` | `full` | `api-key` | `none`) — the *worst credential actually present*, so a run's blast radius is provable after the fact, not inferred. Recorded on every launch, suspicious or not.

Tier: passive-safe to turn **on** from a committed `.sandy/config` (a repo may declare itself suspicious); `=0` from a workspace is approval-gated (never looser). **Honest limits:** a long-lived `CLAUDE_CODE_OAUTH_TOKEN` is *not* shrunk by this — it is recorded honestly and warned about; the specifics are Claude-only; the access token remains exfiltrable for its remaining TTL. Real prevention — the token never entering the container — is #121. Guarded by `run-tests.sh §112`.

## Screenshots / `/ss` skill

Set `SANDY_SCREENSHOT_DIR=<host-path>` (privileged: set freely in `~/.sandy/config`, or per-workspace `.sandy/config` with one-time approval) to mount a host folder of screenshots into the container at `/home/claude/screenshots` (read-only). Sandy exposes the in-container path as `$SANDY_SCREENSHOTS_PATH`. When set, sandy generates a per-agent `/ss` skill at sandbox setup so the agent can "see" what the user just captured.

Validation at launch: rejects shell metacharacters and overly-broad targets (literal `$HOME` or `/`). A non-existent directory is a warn-and-skip — sandy intentionally won't let Docker auto-create an empty stub on the host.

`SANDY_SCREENSHOT_DIR` has no default — leaving it unset disables the feature entirely (no mount, no env var, no skill files generated). macOS users typically set it to `~/Desktop` (default capture location, configurable via `defaults read com.apple.screencapture location`); Linux users to wherever their capture tool drops files (e.g. `~/Pictures/Screenshots`).

**Per-agent UX:**

| Agent | Invocation | Format |
|---|---|---|
| `claude` | `/ss [N] [action]` | slash command (`~/.claude/commands/ss.md`) |
| `gemini` | `/ss [N] [action]` | slash command (`~/.gemini/commands/ss.toml`) |
| `codex` | "look at my recent screenshot" (description-matched) | skill (`~/.codex/skills/screenshot/SKILL.md`) |
| `opencode` | manual: `opencode "explain $(sandy-ss-paths 1)"` | no slash-command surface in v0 |

All four are powered by `/usr/local/bin/sandy-ss-paths` (baked into the base image), which lists newest N image paths from `$SANDY_SCREENSHOTS_PATH` (default 1) and is callable from any agent's bash escape hatch.

## Handoff directories (`SANDY_HANDOFF_DIRS`, #132 slice 1)

`SANDY_HANDOFF_DIRS=1` (passive-safe, default `0`) creates and mounts a per-sandbox cross-workspace handoff directories: `$SANDBOX_DIR/handoff/outbox` read-write at `~/.handoff/outbox`, and `$SANDBOX_DIR/handoff/inbox` **read-only** at `~/.handoff/inbox`. `inbox` is `:ro` because only the host (or, eventually, a relay running outside the container) should be able to place files there — the agent can stage outgoing files in `outbox` but can't write into, or tamper with, whatever lands in `inbox`. The mount flag is the actual boundary: the containerized process runs as the host uid and owns both directories, so against a plain rw mount an in-container `chmod` would succeed. (`chown` to another uid would *not* — the agent runs unprivileged via gosu with an empty effective capability set, so that fails with `EPERM` regardless of the mount flag. Only the `chmod` half is load-bearing here.) Verified live on a `:ro` bind: `chmod u+w` on an agent-owned file returns `Read-only file system`, not a permission error.

**This is substrate only — nothing moves files.** There is no relay, no host-side or in-container helper, no skill/slash-command surface, no turn initiation, no peer list, no manifest format, and no `archive/` subdirectory (its ownership/mode is unsettled pending #132's relay design — shipping it now would be guessing). The two directories are created empty and stay empty until something else writes to them; today, nothing does.

**Tier rationale.** The key is passive-safe because nothing sandy ships moves files into or out of these directories. The trust edge belongs on `SANDY_HANDOFF_PEERS` (unshipped, will be privileged-tier when it lands) — the same layering already used for `SANDY_CHANNELS` (passive) vs. `TELEGRAM_BOT_TOKEN` (privileged): declaring the shape of a channel is safe, but the credential/peer that lets it actually move data needs approval.

**One residual, stated rather than glossed.** "Grants no capability" would be too strong. `$SANDBOX_DIR/handoff/outbox` **persists across sessions**, and it is precisely the directory a future relay is designed to drain — so a committed passive `SANDY_HANDOFF_DIRS=1` lets a repo stage content *today* that could be delivered the day an operator approves `SANDY_HANDOFF_PEERS`, with no prompt mentioning the pre-existing files. This does not justify the privileged tier (an approval prompt for two empty directories is disproportionate, and the peer key is where the edge actually is), but it imposes a hard requirement on #132: **the relay must quarantine or ignore outbox content predating the first peer approval.** Remediation today is `sandy --reset-sandbox`, which destroys `handoff/` along with the rest of the sandbox's persistent state.

Default `0` — unset means **nothing is mounted**, no env vars are added, and `~/.handoff` does not exist inside the container. The host directories themselves are created on **every** launch as of 1.7.0, regardless of the flag. That is deliberate: it makes *directory presence carries no information* true by **construction** rather than by convention — previously presence was ambiguous (a launch with the pair enabled, or someone's `mkdir`), and a rule that must be asserted is weaker than one that cannot be violated. It also removes a step from fleet provisioning: `$SANDBOX_DIR` is itself a launch artifact, so a sandbox that *has* a marker has already been launched — with the pair created unconditionally, enrolling it is the marker alone, not a re-launch purely to harvest a side effect. Unmounted the directories are inert: nothing bind-mounts them and the agent has no path to them. The cost is two empty directories per sandbox on the host.

**Operator-side enable (`$SANDBOX_DIR/.handoff-enabled`).** A marker file at the **top level** of the sandbox dir enables the pair with no workspace config at all. It ORs with `SANDY_HANDOFF_DIRS` (either alone suffices; both together is fine), its contents are ignored so `touch` works, and it is resolved *before* the existing gate — so the `~/.handoff` collision refusal and the `:ro` inbox flag apply identically to both paths rather than being duplicated for one.

Why it exists: a workspace `.sandy/config` **travels with the repository**. Clone that repo elsewhere and the pair is enabled on a sandbox nobody made that decision about. The marker is per-machine, per-sandbox, and lives in state a repo cannot carry — same passive tier, but it cannot be cloned into existence. It is also what makes fleet provisioning practical: enrolling 15 sandboxes is 15 `touch`es in sandy's own state rather than 15 edits across 15 git repositories, in a directory that is not gitignored in most of them.

**Top level, specifically not under `claude/`** — that subdirectory is mounted at `~/.claude` with writable `commands/agents/plugins` overlays, so a marker there would be one the *agent* could create for itself, converting an operator decision into agent self-service. Nothing bind-mounts the sandbox top level (only subdirs plus the `:ro` session marker file), so the agent has no path to it; `run-tests.sh` §97 asserts that, so a future mount that covered it would fail rather than silently hand the agent a way to enroll itself.

**Directory presence is deliberately NOT a trigger.** Hand-creating `handoff/{inbox,outbox}` still enables nothing. A stray `mkdir`, a restored backup, or an `rsync -a` of a sandbox dir would otherwise silently open a channel for a sandbox nobody chose — a directory is an artefact that can arrive by accident, a marker file is a statement of intent.

`--reset-sandbox` **preserves** `.handoff-enabled` like `WORKSPACE.json`, because enrollment is operator state rather than agent-touched session state; destroying it would silently un-enroll a sandbox from a fleet, with the mounts simply not appearing and no error. The `handoff/` directories themselves are still destroyed, so staged outbox content does not survive a reset — which is what the residual note above relies on.

`--print-state` reports `handoff_enabled` per sandbox so a fleet operator can see which are enrolled without stat-ing N paths. It reports the **marker only** — a workspace `SANDY_HANDOFF_DIRS=1` also enables the pair but lives in the workspace, and `--print-state` does not read workspace configs — so `false` means "not enrolled via the marker", not "the pair is off next launch". Additive; `schema_version` stays `1`. Guarded by `run-tests.sh §86` (structure) and `test/acceptance-handoff-dirs.sh` (real-Docker mount/mode behavior, invoked as `run-integration-tests.sh §23`).

## Forwarding user-defined env vars (`SANDY_EXTRA_ENV`)

Sandy normally only forwards env vars it knows about (model selection, agent credentials, channel tokens, etc.). For tokens consumed by user-installed MCP servers or other in-container tooling that sandy has no opinion on, set `SANDY_EXTRA_ENV` to a comma-separated list of env-var names to forward.

```sh
# in ~/.sandy/config (privileged, host-only)
SANDY_EXTRA_ENV=HA_TOKEN,LINEAR_API_KEY
```

Then put the values either in your shell environment (`export HA_TOKEN=...`) or in `~/.sandy/.secrets`:

```sh
# in ~/.sandy/.secrets
HA_TOKEN=ey...
LINEAR_API_KEY=lin_...
```

**Source resolution order** for the forwarded values:

```
env  >  workspace/.sandy/.secrets  >  workspace/.sandy/config
      >  ~/.sandy/.secrets          >  ~/.sandy/config
```

Env wins absolutely. Among files, workspace overrides host (matches sandy's standard config-loader precedence: workspace passive beats host privileged for keys both sources set). Within each tier, `.secrets` beats `config` (last-match-wins iteration order).

Per-workspace tokens (different value per project — common with HA, CI tokens, etc.) belong in `<workspace>/.sandy/.secrets`. User-wide tokens belong in `~/.sandy/.secrets`. Either works.

**Security boundary lives on the names, not the values.** `SANDY_EXTRA_ENV` is privileged-tier — a workspace setting it triggers the standard passive-privileged approval prompt. Once you've approved `HA_TOKEN`, the value can come from anywhere. The original threat (a committed `.sandy/config` setting `SANDY_EXTRA_ENV=AWS_SECRET_KEY` to exfiltrate your host env) is gated by the prompt the user sees before any value is forwarded.

**Validation:** each name must match `[A-Z_][A-Z0-9_]*` (POSIX env-var convention) — invalid names are skipped with a warning. Names that already match a sandy-recognized key (e.g. `ANTHROPIC_API_KEY`) are also skipped — those go through their own typed path. A listed name with no value anywhere produces a launch-time warning ("`HA_TOKEN` has no value") but doesn't fail the launch.

## Persistent agent args (`SANDY_AGENT_ARGS`)

Some projects need a fixed set of extra CLI flags on the underlying agent (`claude`/`codex`/`gemini`/`opencode`) on **every** launch — e.g. a non-default `--mcp-config <path>`, or an agent's experimental flags. Passing them as command-line args to `sandy` works but doesn't persist, and — critically — **a shell wrapper can't cover non-CLI launchers**: `sandy-ui` (and any programmatic caller) invoke `sandy` directly. `SANDY_AGENT_ARGS` declares them in config so they apply uniformly to bare `sandy`, headless `-p`, the `--start` daemon, and sandy-ui:

```sh
# in <workspace>/.sandy/config (or ~/.sandy/config)
SANDY_AGENT_ARGS=--mcp-config .mcp.custom.json --some-experimental-flag value
```

- **Where it applies.** The value is resolved into a per-agent env channel (`SANDY_AGENT_ARGS_CLAUDE`/`_GEMINI`/`_CODEX`/`_OPENCODE`/`_GROK`, internal — not a config key) that the container-side dispatcher prepends onto each pane's own command before dispatch, so it reaches whichever agent(s) launch — by default, EVERY selected agent gets the same `SANDY_AGENT_ARGS` value (each pane in a multi-agent combo), unless overridden per agent by the sandbox file below. The final agent command line is `sandy's own flags → SANDY_AGENT_ARGS (or the per-agent file) → command-line pass-through args`, so an explicit CLI arg still wins.
- **Agent-agnostic is a footgun for agent-specific flags.** Because every selected agent gets the same value, a flag only one agent understands **breaks the others**: a Claude-Code-only flag here makes a `SANDY_AGENT=codex` launch from the same workspace print codex's usage banner and exit, which reads like a sandy fault and is not one. Not hypothetical — sandy's own `.sandy/config` carrying `--dangerously-load-development-channels` (a Claude Code flag) failed the integration suite's codex section exactly this way. **Put agent-specific flags in `$SANDBOX_DIR/agent-args.<agent>`**, which is scoped to one agent by construction; reserve `SANDY_AGENT_ARGS` for flags every agent you run will accept.
- **Parsing (v1).** The value is **whitespace-split** into argv (`read -ra`), never `eval`'d, then each token is `printf %q`-quoted downstream like any pass-through arg. **Embedded spaces / quoted args are not supported in v1** — `SANDY_AGENT_ARGS=--msg "hello world"` becomes three tokens, not two. A quoting scheme is a possible follow-up.
- **Home.** Workspace `.sandy/config` is the intended home (these args are usually project-specific); host `~/.sandy/config` works too for user-global defaults, though a global home is the wrong scope for project-specific relative-path args.
- **Security tier.** Privileged — set freely from host `~/.sandy/config`, but from a **workspace** `.sandy/config` it triggers the standard per-workspace approval prompt (arbitrary agent flags from a committed config are a real attack surface: `--dangerously-skip-permissions`, a hostile `--mcp-config`, `--add-dir`-style escapes). Headless/non-TTY drops it, same as `SANDY_EXTRA_ENV`. Headless-mode flags (`-p`/`--print`/`--prompt`) are **dropped with a warning** — host-side headless detection runs before this injection, so a `-p` here would make the host launch interactive while the container went headless (a broken session); put those on the command line. Other mode flags (`--continue`, `--new`) still influence launch mode, so avoid them here too.

### Per-agent override: `$SANDBOX_DIR/agent-args.<agent>` (#210)

An operator can also drop a file at the **sandbox top level** — `$SANDBOX_DIR/agent-args.<agent>` (`agent-args.claude`, `agent-args.codex`, `agent-args.gemini`, `agent-args.opencode`, `agent-args.grok`; non-hidden, one per agent) — whose contents are extra CLI args for that one agent. This is the same capability `SANDY_AGENT_ARGS` gives, from a place a git repository cannot reach: a workspace `.sandy/config` **travels with the repository** (clone it elsewhere and the setting comes along), while sandbox state does not.

- **Top level, deliberately.** `$SANDBOX_DIR/claude` is mounted **RW** at `~/.claude`, so a file living there would be **agent-writable** — an agent could write its own launch flags, and an agent that can grant itself a flag can grant itself anything that flag allows. Nothing bind-mounts the sandbox top level (only subdirs plus the `:ro` session marker file), so the agent has no path to this file — the same guard `.handoff-enabled` relies on, asserted structurally by `run-tests.sh §106`.
- **No new tier, no approval prompt.** `$SANDBOX_DIR` lives under `$SANDY_HOME`, already the **privileged** config-source root. The file is privileged by construction of *where* it lives, exactly like the `.handoff-enabled` marker — an operator who can write into `$SANDY_HOME` already has privileged-tier trust.
- **Precedence: the sandbox file wins**, per agent, over a workspace/host `SANDY_AGENT_ARGS`. Sandy discards source attribution for `SANDY_AGENT_ARGS` at the approval step, so it cannot tell whether a surviving value came from workspace config, host config, or env — rather than guess or silently merge, sandy refuses the ambiguity: the file's tokens are used verbatim and a one-line notice always names which source won. Values are **never concatenated** — the value is whitespace-split with no quoting scheme, and merging two such values multiplies the ways that can go wrong.
- **Empty or whitespace-only = absent**, not an empty argument — the precedence predicate is "any surviving token after filtering," never a raw `[ -s ]` check on the file. A file containing only a dropped mode flag (`-p`) also behaves as absent. Newlines are whitespace too, so one argument per line works, and every line survives (not just the first).
- **Mode flags** (`-p`/`--print`/`--prompt`) are dropped with a warning naming the file, same rule as `SANDY_AGENT_ARGS`.
- **Per-pane isolation in a multi-agent combo is the point** — `agent-args.codex` never reaches the claude pane, even when both run at once in the same 2×2 grid. `sandy --remote` is covered too (it bypasses the normal per-pane dispatcher, so it prepends its own `SANDY_AGENT_ARGS_CLAUDE` tokens directly).
- **Files for an unselected agent** (e.g. `agent-args.codex` present in a claude-only launch) are silently ignored for that launch — only `--print-state` surfaces their presence, to avoid warning noise on every single-agent launch of a fleet-provisioned sandbox.
- **`--reset-sandbox` preserves** `agent-args.<agent>` files unconditionally, like `WORKSPACE.json` and `.handoff-enabled` — they are operator state, not agent-touched session state, and the Preserved: line names them (an "already minimal" sandbox holding only these plus `WORKSPACE.json` correctly reports nothing to reset). **`--remove-sandbox` destroys** them along with the rest of the sandbox and **names each one in the printed plan**, the same way it names `.handoff-enabled`.
- **`--print-state`** reports `agent_args_files` per sandbox — a fixed object with all five agent names as boolean keys, in **both** full and light mode (five `[ -f ]` builtins, zero extra spawns). It reports **file presence only**, explicitly not effective args: a workspace or host `SANDY_AGENT_ARGS` also supplies args for that agent, and `--print-state` does not read configs, so `false` does not mean "no extra args next launch" (same caveat as `handoff_enabled`). Additive; `schema_version` stays `1`.

Guarded by `run-tests.sh §106`.

## Workspace Mount Path

The workspace is mounted inside the container at a path that mirrors the host's `$HOME`-relative location. For example, if you run sandy from `~/dev/sandy`, the workspace appears at `/home/claude/dev/sandy` inside the container. If the workspace is outside `$HOME`, it falls back to mounting at the real host path. The container path is passed via the `SANDY_WORKSPACE` environment variable.

## Git Submodule Support

When launched from a git submodule, sandy detects the `.git` file (vs directory), resolves the relative gitdir path, and mounts both the worktree and gitdir at the correct container paths using the same `$HOME`-relative mapping to preserve the relative path relationship.

## SSH Agent Relay

Two modes controlled by `SANDY_SSH`:
- `token` (default) — uses `gh auth token` for HTTPS-based git auth
- `agent` — forwards the host SSH agent into the container
  - **Linux**: direct socket mount
  - **macOS**: host-side TCP relay via `socat` (preferred) or `python3` fallback; in-container relay via `socat`

## Language Environments

The base image ships with fixed versions of each toolchain: Python 3.13 (Debian trixie's default), Node.js 24, Go 1.26, Rust stable, and C/C++ (build-essential). `uv` is also pre-installed for Python version management.

### Persistent Package Installs

Packages installed via `pip install`, `npm install -g`, `go install`, `cargo install`, and `uv` persist across sessions. Each per-project sandbox has dedicated subdirectories that are bind-mounted into the container:

| Sandbox dir | Container mount | What it stores |
|---|---|---|
| `pip/` | `~/.pip-packages` | `PYTHONUSERBASE` — pip user installs (scripts + site-packages) |
| `uv/` | `~/.local/share/uv` | uv-managed Python versions |
| `npm-global/` | `~/.npm-global` | `npm install -g` packages |
| `go/` | `~/go` | `GOPATH` — `go install` binaries |
| `cargo/` | `~/.cargo` | `cargo install` binaries + registry cache |

These are per-project — packages installed in one project sandbox don't leak to another.

### Python Version Management

The base image includes a single system Python (whatever Debian trixie ships — currently 3.13). For projects that need a specific Python version, use `uv`:

```sh
uv python install 3.11
uv venv --python 3.11
source .venv/bin/activate
uv pip install -r requirements.txt
```

Downloaded Python versions persist in the `uv/` sandbox directory, so `uv python install` only downloads once per project sandbox.

Plain `pip install` also works — `PYTHONUSERBASE` and `pip.conf` (`user=true`) are set so installs go to the persistent `pip/` mount by default. Inside an activated virtualenv, pip correctly installs to the venv instead.

### Host Virtual Environments and Build Artifacts

The project directory is bind-mounted read-write into the container. This means `.venv/`, `node_modules/`, `target/`, and other build directories from the host are visible and writable inside the container.

**Python `.venv/`**: A host-created venv will work inside the container *if* the host and container have the same Python version at the same path (e.g. both have `/usr/bin/python3.12`). If versions differ, the venv's `bin/python` symlink and script shebangs will be broken. In that case, recreate the venv inside sandy: `uv venv --python 3.12 && uv pip install -r requirements.txt`.

**Node.js `node_modules/`**: Pure JavaScript packages work fine. Native addons (`.node` files) compiled on the host will work if the host is also Linux with compatible glibc. If you see `MODULE_NOT_FOUND` errors on native modules, run `npm rebuild` inside the container.

**Rust `target/`**: Incremental build artifacts from the host are reusable if both sides are Linux x86_64. Cross-platform (e.g. macOS host → Linux container) will trigger a full rebuild — Cargo handles this automatically.

**Go `vendor/`**: Pure source code, always works across environments.

### Automatic Environment Detection

On every session start, the entrypoint checks the workspace for common issues:

- **`.python-version`**: Auto-installs the specified Python version via `uv python install` (idempotent, persists).
- **Broken `.venv`**: If `.venv/bin/python` is a dead symlink (host/container Python mismatch), warns with the fix command.
- **Foreign native modules**: If `node_modules/` contains `.node` files compiled for a different platform (e.g. macOS → Linux), warns with `npm rebuild` as the fix.
- **Orphaned pip user-site**: If `PYTHONUSERBASE`'s `lib/python3.<minor>/` doesn't match the running system Python's minor version (e.g. after a base-image Python bump), warns with the old path and a reinstall/cleanup pointer.

### Gotchas

- **Read-only root filesystem**: The container runs with `--read-only`. System-wide installs (`apt-get install`, `pip install` without `--user`) will fail. Use the user-scoped mechanisms above, or `uv` for Python versions.
- **npm global vs local**: `npm install` (without `-g`) writes to `node_modules/` in the project directory (host-mounted, persists). `npm install -g` writes to the persistent `npm-global/` sandbox mount. Both survive across sessions.
- **Cargo symlinks**: The entrypoint symlinks system Rust toolchain binaries (`rustc`, `cargo`, etc.) into the persistent `~/.cargo/bin`. User-installed binaries (e.g. `cargo install ripgrep`) coexist alongside them.
- **PATH order**: `~/.local/bin` > `PYTHONUSERBASE/bin` > `npm-global/bin` > `GOPATH/bin` > `CARGO_HOME/bin` > system PATH. User installs always take precedence.
- **tmpfs size limit**: The home directory tmpfs is 2GB. Large build artifacts or many installed packages may hit this — but persistent mounts (pip, npm, go, cargo, uv) bypass the tmpfs entirely.

## Network Isolation Details

Per-instance Docker bridge networks are created with names keyed on PID (`sandy_net_$$`) to avoid races between concurrent sessions. On Linux, iptables DROP rules block RFC 1918 ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), link-local (`169.254.0.0/16`), and CGNAT/Tailscale (`100.64.0.0/10`), while allowing the container's own subnet. Rules are cleaned up on script exit.

**macOS limitation when the egress proxy is explicitly turned off (`SANDY_EGRESS_PROXY=0`).** (The default is `1` — permissive — so this applies only when a user opts out of the proxy.) Docker Desktop's VM does *not* provide LAN isolation. Containers can reach `host.docker.internal` (→ host gateway), the host's `localhost` services, and any device on the user's physical LAN (`192.168.x.x`, home router, NAS, printers, internal dashboards). Linux iptables DROP rules are not applied and cannot be applied from macOS. As defense-in-depth, sandy nullifies the Docker Desktop magic hostnames (`gateway.docker.internal`, `metadata.google.internal`, and — when `SANDY_SSH!=agent` — `host.docker.internal`) via `--add-host … :127.0.0.1`, but raw-IP access is unaffected. Sandy prints a launch warning banner on macOS announcing that network isolation is not active, and points at `SANDY_EGRESS_PROXY=1`. With the proxy off, treat macOS sandy as "process and filesystem isolation only; no network isolation."

## Egress Proxy (`SANDY_EGRESS_NO_ISOLATION` / `SANDY_EGRESS_STRICT`)

The egress proxy (milestone M2.7) is the cross-platform network-isolation mechanism that closes the macOS LAN/host-reach gap (finding F2) and works **identically on Linux and macOS** because it relies on Docker's `--internal` network routing, not on iptables.

**Two boolean knobs** set the posture (default **permissive**, i.e. both `0`); they are mutually exclusive:

- `SANDY_EGRESS_NO_ISOLATION=1` — **off** (below). **Weakening**, so from a workspace `.sandy/config` it is approval-gated (a committed repo config can't silently disable isolation).
- `SANDY_EGRESS_STRICT=1` — **strict** (below). **Strengthening**, so passive-safe from any source. Setting it `=0` to downgrade a host-configured strict is approval-gated from a workspace source.
- neither set → **permissive** (default).

**`SANDY_EGRESS_PROXY` is a deprecated back-compat alias** (`0`→`NO_ISOLATION=1`, `1`→permissive, `2`→`STRICT=1`); it emits a deprecation warning and its `=0` is approval-gated from a workspace source exactly like the new keys. (Pre-1.0 this single tri-state was a plain passive key — a committed `SANDY_EGRESS_PROXY=0` could disable isolation with no prompt; see the value-aware config-tier note above.)

The three postures:

- **off** (`SANDY_EGRESS_NO_ISOLATION=1`). Legacy behavior: Linux uses iptables RFC1918 DROPs; macOS has no network isolation (warning banner above). Opt-in only.
- `1` — **permissive** (**default**). The agent routes through a proxy sidecar that blocks only private/LAN/link-local/CGNAT/cloud-metadata destinations and allows all internet. Closes F2 with ~zero tool friction (any public host an agent needs just works). This is the **default-on posture for 1.0** — it gives Linux-parity LAN isolation on macOS without an allowlist to maintain.
- `2` — **strict**. The proxy denies everything except a built-in default allowlist (model providers, GitHub incl. SSH, npm/PyPI/crates/Go/Debian) plus `SANDY_ALLOW_HOSTS`. Closes F2 *and* exfil-to-arbitrary-internet, at the cost of failing closed on any un-listed host. (Strict does not stop exfil to an *allowlisted* host — a broker-style host-relay is POST_1.0.)

**Topology.** Two Docker networks are created per session: an `--internal` **sidecar** bridge that the agent joins (no route off the bridge — this is the isolation) and a normal **egress** bridge that only the dual-homed proxy container joins (its internet leg). The proxy is the sole path off the sidecar, so it is also the single policy chokepoint. The agent's resolver is pointed at the proxy (`--dns <proxy-ip>`); the proxy's DNS responder redirects permitted names to its own sidecar IP so traffic funnels through its listeners. The proxy gets a fixed IP (sandy picks the first non-overlapping `/24` so `--ip` is usable — the candidate pool is every `/24` in `10.200.0.0/16` and `10.201.0.0/16` plus two legacy `/24`s, ~512 in all, so the practical ceiling on concurrent proxy sessions is in the hundreds rather than the old hardcoded 4). Sandy **reaps its own orphaned networks eagerly at every launch** (in `ensure_network`, before allocating) and again as a fallback if every candidate still overlaps: `_sandy_reap_orphan_networks` removes any `sandy_net_*` (isolated bridge), `sandy_sidecar_*`, or `sandy_egress_*` whose owning PID (the trailing field of `sandy_<kind>_<pid>`) is dead **and** that has no attached container — so a live or mid-setup concurrent launch is never disturbed (the PID gate is what makes eager reaping concurrent-safe). This is the fix for the "all predefined address pools have been fully subnetted" failure that accumulates under repeated launch/close/relaunch cycles (e.g. sandy-ui). Guarded by `run-tests.sh §64`. iptables is **not** applied in proxy mode (the topology is the isolation, and RFC1918 DROPs would break the proxy's own `host.docker.internal` forward).

The proxy container is named **`sandy-proxy-<sandbox-name>`** (mirroring the agent container `sandy-<sandbox-name>`), so `docker ps` shows a proxy right next to its session and an orphan is traceable to the workspace that leaked it. The workspace mutex guarantees one session per workspace, so the name is unique among live sessions; a stale same-named proxy from a crashed run is force-removed before (re)launch (same pattern the agent container uses).

**Proxy self-heal on death (`--restart on-failure:5`).** The proxy is the agent's only route off the `--internal` sidecar, so a mid-session proxy death (crash, OOM, a Docker/OrbStack reap) would otherwise strand the agent — every request `FailedToOpenSocket` — until the next launch. The proxy launches with `--restart on-failure:5` so the daemon resurrects it; because the sidecar leg is pinned with a fixed `--ip`, the restarted container comes back on the **same address** and the agent's `--dns`/route stay valid, so it recovers without a session restart. Bounded to 5 so a genuinely broken (crash-looping) proxy still gives up and is caught by the readiness gate. `cleanup()` force-removes the proxy regardless of policy, so there's no zombie on exit. **Readiness gate (#37):** the proxy image bakes a Docker `HEALTHCHECK` that re-invokes the binary as `sandy-proxy -healthcheck` (scratch has no shell — the binary *is* the probe), which dials its own `:443`/`:80`/`:3128` TCP listeners and issues one DNS query on `:53`. The launch gate polls `.State.Health.Status` and proceeds only on `healthy`, so it waits for the listeners to actually **bind** rather than for the process to merely start — closing the transient "connection refused" window where the agent's first request raced an un-bound listener (the old gate polled bare `.State.Running`, which flips true before `net.Listen`). It falls back to the legacy `.State.Running` gate when `.State.Health` is absent (an older HEALTHCHECK-less cached image still launches), and a non-zero `RestartCount` short-circuits the poll and is surfaced as a crash-loop warning. This is distinct from — and complementary to — the atomic teardown below: restart-policy handles the proxy dying under a *live* agent; teardown handles the agent outliving a *killed session*.

**Diagnosing a proxy death.** Two mechanisms answer "why did the proxy die." (1) Sandy streams the proxy's logs to `$SANDBOX_DIR/proxy.log` (background `docker logs -f`, reaped in `cleanup()`) — this **survives** the `docker rm -f` that wipes `docker logs`, and `cleanup()` appends the container's final `docker inspect` state so an OOM (`oom=true`, exit 137) is distinguishable from a crash (non-zero exit + stack) or external kill. (2) The proxy binary wraps every per-connection goroutine (`transparent`/`connect`/`forward`) in a panic-recovering `guard()` (`proxy/guard.go`): an unrecovered panic in any goroutine crashes the whole Go process, and those handlers parse untrusted wire bytes (TLS ClientHello / HTTP Host), so without it one malformed connection would take the proxy down. `guard()` `recover()`s, logs the panic value + stack (which then lands in the persisted log), and drops just that connection — mirroring what `net/http`'s Server does per request. So a panic is now both *survived* and *recorded*. Guards: `run-tests.sh §57`, `proxy/guard_test.go`.

**Atomic agent+proxy teardown (prevents the stranded-agent failure).** `cleanup()` force-removes the **agent container first**, then the proxy and networks. This matters because the agent runs `docker run --rm` in the *foreground* but the container's lifetime belongs to the daemon, not the `docker run` client: if that client is killed without the container stopping (closed terminal, killed session, dropped SSH, SIGHUP), the daemon keeps the agent running. Were `cleanup()` to remove only the proxy + egress route (as it did before this fix), the still-running agent would be left **stranded on a routeless `--internal` sidecar** — every API request failing with `FailedToOpenSocket`, with no recovery until the next launch (`docker ps` shows the tell: an `sandy-<sandbox>` agent `Up` with no matching `sandy-proxy-<sandbox>`). The orphan-on-client-kill is old, but the egress-proxy default (0.14.0) turned it from a harmless orphan (which still had a working bridge + internet) into a fatal one. Removing the agent in `cleanup()` makes the two teardowns atomic and also lets the sidecar `network rm` succeed instead of leaking the subnet. Regression-guarded by `run-tests.sh §55`.

**Proxy listeners** (Go binary, `golang`→`scratch` image, `--read-only --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 128 --memory 256m`): DNS (UDP 53, redirect/deny, refuses HTTPS/SVCB records to keep SNI readable), transparent `:443` (SNI demux, TLS never terminated), transparent `:80` (Host demux), CONNECT `:3128` (for git-over-SSH), and an optional local-LLM forward. Permissive mode resolves-then-checks the destination, which also defeats DNS rebinding (a name resolving public+private dials only the public IP; all-private is refused). The proxy never terminates TLS, never logs payload, never caches.

**Proxy hardening + connection bound (HF-incident Issue 2).** The proxy is the dual-homed bridge whose compromise reproduces the incident, so it is hardened at least as much as the agent it protects: `no-new-privileges` (matches the agent), `--pids-limit 128`, and `--memory 256m`. Not `--user` — the binary binds privileged ports (:53/:80/:443), so a non-root uid would need `CAP_NET_BIND_SERVICE` re-added or an unprivileged-port sysctl, reopening a capability on an otherwise cap-dropped, read-only, single-static-binary scratch image for marginal gain (evaluated, declined). Independently, all three accept loops (transparent/CONNECT/forward, previously three identical `for { Accept(); go guard }` bodies) now share a single `acceptLoop` (`proxy/accept.go`) that acquires a slot from a `maxConns`-capacity semaphore **before** `Accept`, so a connection storm (self-inflicted or injected) applies backpressure at the kernel backlog rather than growing goroutines/memory without bound — the `--memory` cap is then a backstop, not the enforcer. Guards: `proxy/accept_test.go`, `run-tests.sh §50` (run-flag assertions).

**Non-TCP transports (the proxy is TCP-only — by design).** The proxy speaks only TCP (DNS/53, 443, 80, CONNECT). It deliberately does **not** proxy UDP/QUIC/ICMP, because it doesn't need to: the `--internal` network is the backstop, and `--internal` is an **L3, protocol-agnostic** drop (a `FORWARD`-chain DROP on the bridge, no `MASQUERADE`). So all non-TCP egress off the sidecar is dropped before it reaches the proxy — raw UDP, **QUIC/HTTP-3 over UDP/443** (which would otherwise bypass the SNI-reading TCP proxy), ICMP, and IPv6 (the networks are `--ipv6=false`). Non-TCP **fails closed**: QUIC to an allowed host can't reach the proxy's (TCP) listeners and the client falls back to TCP-through-proxy; raw UDP/DNS to an external resolver is dropped (so no DNS tunnel). **Verified on macOS Docker Desktop 2026-06-11** (UDP-to-public-resolver, UDP/443, all blocked; no IPv6 route) and guarded by `test/spike/macos-internal-network-spike.sh` (A1d) + a Linux check in `run-integration-tests.sh` (§13b). A future refactor must not make the proxy the *only* egress mechanism without re-adding a non-TCP block, or this invariant regresses.

**Posture introspection.** The resolved egress posture is forwarded into the container as **`SANDY_EGRESS_MODE`** (`off` | `permissive` | `strict`) so in-container tooling, tests, and the agent can read their own isolation level. It is informational only — the isolation is applied by the network topology at launch, so changing the env var inside the container has no effect. (`SANDY_PROXY_IP` is also present when the proxy is on, used by the ssh `ProxyCommand`.)

**`SANDY_ALLOW_HOSTS`** (privileged-tier): comma-separated extra allowlist entries (exact host, `*.suffix` wildcard, or `host:port` for CONNECT/SSH), appended to the default set. In strict mode these are the only hosts reachable beyond defaults; in permissive mode they are LAN-exceptions reachable *despite* the private-IP block (e.g. an internal registry, or `host.docker.internal:<port>` for a local LLM). Privileged tier so a committed workspace config can't silently widen reach without the approval prompt.

**Egress telemetry — `SANDY_EGRESS_LOG` (HF-incident Issue 4).** The proxy is the single chokepoint every hostname the agent reaches passes through, but by default it logs **denials only** (`proxy/transparent.go`, `proxy/connect.go` — "no per-connection spam"), so `proxy.log` can answer "what was blocked" and never "what did the agent actually reach this session" — the first question after a suspected prompt injection or a leaked-token scare. `SANDY_EGRESS_LOG` (passive-safe — it only *adds* visibility; `0`|`1`|`summary`, default `0`) turns on the allow side: the launcher writes `"egress_log":true` into the proxy config, and the proxy's `egressLogger` (`proxy/egresslog.go`) logs each **distinct** allowed `host:port` **once** (deduped by a mutex-guarded set, so a chatty agent can't turn the log into a gigabyte — the goal is the *set* of destinations, not a firehose). At session end `cleanup()` rolls `proxy.log` into a green summary: *N distinct hosts reached, M denials*, the host list, and a pointer to the full log. `1` keeps the per-connection allow lines in `proxy.log`; `summary` is documented as "prefer the end-of-session rollup" (functionally the same proxy behavior in v1 — the proxy must record allows either way for the summary to have data). This is **not** a privacy regression: hostnames are metadata sandy already sees, TLS is never terminated, no payload is touched, and the log stays in `$SANDBOX_DIR`. Guards: `proxy/egresslog_test.go` (dedup/disabled/nil), `run-tests.sh §50` (config gate + summary wiring).

**SSH-agent interaction.** Under `--internal`, git-over-SSH tunnels through the proxy's CONNECT listener — the entrypoint injects a `Host * ProxyCommand socat - PROXY:<proxy-ip>:%h:%p,proxyport=3128` into `~/.ssh/config`. On Linux the SSH-agent socket is a direct bind mount, so agent signing keeps working. On macOS the agent socket relies on a host TCP relay that the sidecar blocks, so agent *signing* is unavailable in proxy mode (git-over-SSH still works); sandy warns and suggests `SANDY_SSH=token` (HTTPS through the transparent `:443` path) for a fully-supported path.

**Local LLM.** With the proxy on, `SANDY_LOCAL_LLM_HOST` is served by the proxy's forward listener (not an iptables hole): the agent reaches `host.docker.internal:<port>`, the proxy DNS points that name at itself, and the forward listener relays to the real host. `host.docker.internal` is auto-allowlisted in strict mode and mapped for the proxy container on Linux.

## Protected Files

Certain sensitive files and directories in the workspace are mounted read-only inside the container to prevent modification by the agent. This blocks shell config injection, git hook injection, IDE config tampering, language-toolchain hijacking, CI pipeline escapes, and git filter-driver injection.

**Protected files**: `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile`, `.gitconfig`, `.ripgreprc`, `.mcp.json`, `.envrc`, `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml`, `.claude/settings.json`, `.claude/settings.local.json`

**Protected git files** (only mounted when present on host): `.git/config`, `.gitmodules`, `.git/packed-refs`. (`.git/HEAD` is deliberately **not** here as of 1.5.0 (#80) — it's left read-write so `git switch`/`checkout` work in-container; a symref is not an RCE vector, and a HEAD left on an unexpected branch is caught by the session-end notice.)

If `core.hooksPath` redirects git hooks to a non-default directory *inside* the workspace (e.g. `.githooks/`), sandy resolves it (`_sandy_extra_hooks_dir`) and mounts the **configured** hooks path `:ro` — it canonicalizes (`pwd -P`) only to verify containment, but locks the path git actually consults (not the resolved target) so a *symlinked* hooksPath can't be swapped for a fresh writable dir. Closes the gap where `.git/hooks/` is protected but hooks run from elsewhere. A `core.hooksPath` pointing outside the workspace, at the workspace root, or at an already-protected dir is left alone.

The `:ro` mount is **existence-gated**: it only covers a hooks dir present at launch. The *create-fresh* case — `core.hooksPath` set but the dir absent at launch, so an agent creates `.githooks/pre-commit` in-session — has no mount to catch it, so it is covered by **session-end detection** instead (sandbox-escape eval Issue F): `_sandy_configured_hooks_rel` resolves the configured hooks path *existence-independently* (unlike `_sandy_extra_hooks_dir`), the launch snapshot records it only if it existed, and the exit sweep flags a newly-appeared hooks dir with content alongside the other auto-execution configs. Same containment rules (inside workspace, not root, no `..` escape, not an already-protected dir).

**Protected directories**: `.git/hooks/`, `.git/info/`, `.vscode/`, `.idea/`, `.github/workflows/`, `.circleci/`, `.devcontainer/`, `.claude/hooks/`, `.sandy/`

**Submodule gitdirs**: sandy walks `.git/modules/` (and the gitdir-side `modules/` for `--separate-git-dir` / worktree-of-submodule layouts) and mounts each submodule's `config`, `hooks/`, and `info/` read-only. Without this, a planted `post-checkout` hook in `.git/modules/<sub>/hooks/` would execute on the host the next time `git submodule update` or `git pull --recurse-submodules` ran (Critical escape, F1 in ISOLATION_STRESS.md).

**Sandbox-mounted directories**: `.claude/commands/`, `.claude/agents/`, `.claude/plugins/` — these are overlaid with writable sandbox copies so Claude can create and modify commands, agents, and plugins without touching the host. All three start empty; plugins are managed via `/plugin install`.

**Mount policy (hybrid, existence-gated).** Both files and dirs are existence-gated symmetrically: if the host has the path, sandy bind-mounts it `:ro` (kernel-level write prevention, no host-side stub because Docker is mounting over an existing target). If the host doesn't have the path, sandy adds no mount — the agent can create files there during the session. **This is a deliberate trade-off.** The previous always-mount-with-empty-fixture pattern for dirs left empty stub dirs all over the user's workspace every session, required heroic cleanup-on-exit logic, and caused user-visible weirdness during sessions (`ls`, file managers, IDE scanners all saw the stubs). For files the same approach was worse — 0-byte stubs broke `direnv`, polluted `git status`, and tripped every tool that checks for file presence. Existence-gated everything trades active prevention for absent paths in exchange for a clean workspace.

The replacement defense is **session-end detection**: sandy records which protected dirs **and files** existed at launch in `$SANDBOX_DIR/.protected-existed-at-launch`, and on session exit walks the same paths looking for new appearances. Any protected dir (with content) or protected file that didn't exist at launch is reported as a yellow warning with a type-aware remediation (`rm -rf dir/` or `rm -rf file`). This catches the case where an agent (via prompt injection, skill bug, or just a bad task) writes `.git/hooks/post-checkout`, `.github/workflows/ci.yml`, or an absent protected file like `.npmrc` / `.pre-commit-config.yaml` — the user sees the warning before they next run `git pull` / `git push` / `npm install` / commit and can decide whether the write was legitimate or needs to be reverted.

Detection-only is weaker than prevention. The threat window is "between session end and the user's first `git pull`/`git checkout`/`git push`/IDE-open." If the user does any of those without reading sandy's exit messages, the agent's payload can fire on the host. The trade-off is conscious: prevention required the workspace pollution, and the post-session warning is sufficient for the realistic threat model where the agent isn't an active attacker, just occasionally wrong.

Pre-existing empty stub dirs from older sandy versions are still auto-cleaned at launch under a 4-condition safety gate (workspace is a git repo, dir name matches the protected-dirs list exactly, dir is empty, dir isn't git-tracked) — that path is unchanged and handles one-shot migration for users upgrading.

Intentionally excluded from protection: package manifests (`Makefile`, `package.json`, `pyproject.toml`, `Cargo.toml`, etc.) — the agent legitimately edits these, and they are invoked explicitly by name rather than sourced on `cd` or filesystem scan.

**Long-term: `fanotify` FAN_OPEN_PERM.** The "right" answer is to use Linux's `fanotify` with permission events (FAN_OPEN_PERM / FAN_ACCESS_PERM) to intercept write attempts at the syscall level *before* they hit the filesystem. A small daemon (Python or C, ~80 lines) inside the container watches the protected paths; on each open-for-write the kernel suspends the syscall and asks userspace to allow/deny; sandy denies → caller gets `-EPERM`, no host artifact, ever. Properties:

- True prevention with no host pollution, even for absent paths
- Honest to the agent (real EPERM error, not silent failure or post-hoc cleanup)
- Works in containers on macOS Docker Desktop (the VM kernel is Linux 5.x with fanotify support)
- Requires `CAP_SYS_ADMIN` in the container's entrypoint phase (sandy currently drops all caps — would need to add it for setup, drop it again before the agent runs, or run the watcher in a separate restricted-cap process)
- Watcher process death = file I/O blocks until the kernel-side timeout fires; needs careful supervisor logic

This is on the roadmap but unscoped pending real evidence of detection-only being insufficient. The hybrid model above is the practical default until we see a case where post-session detection misses a real attack path.

**`SANDY_ALLOW_WORKFLOW_EDIT`** (passive-safe): set to `1` in `.sandy/config` to remove `.github/workflows/` from the protection list for that project. Useful when the agent is doing legitimate CI work. Default is off — workflows are dangerous because the escape fires on `git push`, long after the session ends.

Protected files/directories are overlaid as read-only bind mounts at container launch. The host filesystem is unaffected.

### Persistent symlink approval (1.0-rc1)

Dangerous symlinks (absolute links, or relative links that escape the workspace via `..`) are surfaced to the user at launch. On first encounter sandy prints a y/N prompt listing each link and its target; on approval the set is persisted to `$SANDBOX_DIR/.sandy-approved-symlinks.list` (one `link<TAB>target` per line).

On subsequent launches:

- **Identical or reduced set** → proceed silently (symlink deletions update the list).
- **New escape present** → **hard error at launch**, naming the offending link(s), with remediation (`rm` the link, relaunch, re-approve). Sandy refuses to re-prompt — a y/N that fires every session can be trained past, whereas a hard error forces a deliberate action.

**First-encounter approvals are resolved on the CLIENT's tty, before the fork (#221).** Container bring-up happens inside the supervisor, whose stdin is `/dev/null`, so any approval encountered there is unanswerable — it fails closed and the user has no way to say yes. A workspace containing an escaping symlink therefore launched fine from a shell and failed under `--start`. The `SANDY_APPROVE_ONLY` pre-pass (originally added for passive-privileged config keys) now also resolves the **dangerous-symlink** approval: it runs far enough to know `$SANDBOX_DIR` — which is where the approval list lives — while still exiting before the workspace mutex, the bare-`sandy` busy-gate, and every image build. The stretch it newly traverses only computes; the one added side effect is the `mkdir -p "$SANDBOX_DIR"` that the launch a moment later performs anyway.

This fixes non-shell clients for free where they use a real pty: sandy-ui spawns `--start` through node-pty, so `[ -t 0 ]` holds and the prompt renders in its terminal. Genuinely non-TTY consumers (CI, scripted) still need `SANDY_AUTO_APPROVE_PRIVILEGED` or a pre-granted approval. A refusal in the pre-pass now stops `--start` with exit `6` rather than being swallowed by `|| true` and forking a supervisor certain to hit the same refusal.

**Non-interactive fail-close (daemon `--start`).** The first-encounter y/N is a `read` deep in the launch flow — but under `sandy --start` that flow runs in the non-TTY supervisor (stdin `/dev/null`), where a bare read consumes EOF, aborts with misleading "remove the symlinks" guidance, and leaves the `--start` client burning its full readiness timeout (a reported hang). So the prompt is gated on an interactive stdin (`[ -t 0 ]`): non-interactive → **fail closed** with the correct guidance ("launch `sandy` interactively once in this workspace to approve, then retry"), and the supervisor drops a `"$SANDY_DAEMON_LOG.fatal"` marker so the `--start` client fast-fails in ~1s instead of waiting out the timeout (its EXIT trap has already torn down the proxy/networks/lock). Same class as the passive-privileged approval's non-TTY fail-close. Guarded by `run-tests.sh §75`.

## Status Lines

Sandy shows two distinct status lines, at different scopes, because neither can do the other's job:

- **Outer tmux status bar** (`generate_tmux_conf()`, #42) — **launch/session-scoped**. Renders once per tmux redraw from env, not from anything Claude Code (or gemini/codex/opencode) knows about: egress posture (color-coded — green `★ strict`, cyan `★ permissive`, orange `★ no-net-iso` as a warning), agent(s) in this session, workspace/project name, attached-client count (`session_attached`), a `daemon`/`session` marker, and the clock. All of it reads live via tmux's `#{E:VAR}` interpolation against `SANDY_EGRESS_MODE`/`SANDY_AGENT`/`SANDY_PROJECT_NAME`/`SANDY_DAEMON` — the heredoc that generates `tmux.conf` is quoted, so nothing is baked in at generation time. Window-status (tab) rendering is blanked (`window-status-format ""` etc.) since sandy sessions are single/multi-*pane*, not multi-window.
- **Inner Claude Code `statusLine`** (`sandy-claude-statusline`, #67) — **live, per-request**. The outer tmux bar structurally cannot show what model is answering right now, what effort level, or current context-window usage — that's Claude Code's own state, fed to it fresh on every render via a JSON payload on stdin, not exposed as an env var. Sandy seeds `settings.json.statusLine` to run `/usr/local/bin/sandy-claude-statusline` (baked into the base image, all three seeding branches — Node/jq/last-resort — using an only-if-absent guard so a user's own `statusLine` is never clobbered). Output format: `<model>  ·  [effort: <level>  ·  ]<context%>% ctx`, e.g. `Opus 4.8  ·  effort: high  ·  42% ctx`; the effort segment is omitted when the model has none. Any empty/malformed/wrong-shape stdin falls back to a bare `sandy` line — the helper never errors the TUI.

## Terminal Notifications

Sandy's inner tmux is configured with `allow-passthrough on`, which forwards OSC escape sequences (9/99/777) from Claude Code through to the outer terminal. This enables notification features in terminals like cmux and iTerm2.

Host-side Claude Code hooks (`~/.claude/hooks/`) are mounted read-only into the container at `/home/claude/.claude/hooks/`. This allows hooks configured on the host (e.g., cmux notification hooks) to work inside sandy without duplication.

## Agent-layer tool-use audit (`SANDY_TOOL_AUDIT`, HF-incident Issue 6)

The Hugging Face post-mortem's loudest defender recommendation is *"instrument the agent harness itself, not just external observability … external controls operate on limited input and output, with no visibility into the agent itself"* (the EDR-vs-NDR analogy). Sandy is otherwise entirely the NDR side — it constrains the box and sees nothing of tool calls. `SANDY_TOOL_AUDIT=1` (passive-safe — it only *adds* visibility; default `0`) turns on the EDR side: sandy's `settings.json` seeder adds a `PreToolUse` hook pointing at `/usr/local/bin/sandy-tool-audit` (baked into the base image, Appendix A), which appends one `{ts, tool, args}` JSONL line per tool call to `~/.claude/tool-audit.jsonl` (persisting to the host sandbox). Pairs with Issue 4's egress record to answer "what did this session actually do" from both the network and the harness side; `cleanup()` prints a session-end pointer to the file.

The seed uses the **same only-if-absent guard** as the `statusLine` default (`if (!s.hooks.PreToolUse)`), so a user's own `PreToolUse` hook in `~/.claude/settings.json` is never clobbered. The helper **always exits 0** — a non-zero `PreToolUse` hook would *block* the tool call — and truncates `tool_input` to 200 chars so the log stays a trail, not a payload dump. **Two honest limits** (state them, don't oversell): (a) it is **Claude-Code-only** — codex/gemini/opencode have no equivalent `settings.json` hook seam sandy controls today, so this is coverage, not parity; (b) an audit hook running *inside* the box is **not tamper-proof against a determined agent** (adversary tier 3) — it is instrumentation for the *primary* wrong-but-not-evil adversary, which is exactly what the post-mortem asks for. Guards: `run-tests.sh §82`.
