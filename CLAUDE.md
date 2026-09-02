# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

This file is loaded into **every** session, so it holds the rules you must follow and the gotchas that cost real time. The long-form rationale behind them — rejected alternatives, incident records, probe results, verification-reality notes — lives in **`docs/DESIGN-NOTES.md`**. Read that before *changing* one of these decisions, or when a rule here looks arbitrary and you need to know what it is load-bearing for. Implementation-level detail (flags, schemas, generated files, launch assembly) lives in **`SPECIFICATION.md`** appendices A–E.

## What This Is

`sandy` — an isolated sibling for your coding agents. A self-contained bash launcher that runs Claude Code, Gemini CLI, OpenAI Codex CLI, OpenCode, Grok Build (or any combination side-by-side in tmux) in a Docker sandbox with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes.

- `sandy` — the single-file launcher, installed to `~/.local/bin/`. On first run it generates `Dockerfile.base`, `Dockerfile`, `entrypoint.sh`, and `tmux.conf` in `~/.sandy/`, builds the images, creates the per-project sandbox, applies network isolation, and launches via `docker run`.
- `install.sh` — `curl | bash` installer. It installs **only** the `sandy` script (this is why `--doctor` embeds `doctor.sh` rather than shelling out to a sibling file).

**Three-phase build**: `sandy-base` (OS, Node 24, Go 1.26, Rust stable, Python 3, C/C++, system tools) → `sandy-claude-code` (or the per-agent image) → optional per-project image from `.sandy/Dockerfile`. Each phase rebuilds only when its inputs change. The per-project `.sandy/Dockerfile` build is **approval-gated** and fails closed when non-interactive — its `RUN` commands execute on the host daemon with unfiltered network.

## Installation and Usage

```sh
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
LOCAL_INSTALL=./sandy ./install.sh   # from a clone
```

```sh
cd ~/my-project
sandy                        # interactive session
sandy -p "your prompt here"  # one-shot prompt
```

No `ANTHROPIC_API_KEY` required with Claude Max (OAuth) — credentials are seeded from `~/.claude/` on first run.

## Keeping Documentation in Sync

When modifying the `sandy` script, update `SPECIFICATION.md` to reflect any changes to behavior, flags, configuration, generated files, runtime parameters, JSON schemas, or platform-specific logic. Its five appendices must stay accurate:

- **A** Generated File Templates (Dockerfile, entrypoint.sh, user-setup.sh, tmux.conf)
- **B** Runtime Parameters (timeouts, limits, permissions, defaults, tool versions)
- **C** JSON Schemas (settings.json, access.json, .claude.json, credentials)
- **D** Platform-Specific Behavior (Linux/macOS divergence)
- **E** Container Launch Assembly (docker run flags, mounts, env vars)

Also update `README.md` and this file if user-facing behavior changes. Run `test/run-tests.sh` to verify test assertions still match.

### Generated artifacts — regenerate, never hand-edit

Three parts of the tree are generated from the `sandy` script and gated by `--check` in `test/run-tests.sh`:

```sh
test/regen-config-docs.sh [--check]   # the key-tier tables in CLAUDE.md + SPECIFICATION.md
test/regen-template.sh    [--check]   # templates/user-setup.sh.tmpl from the generate_user_setup() heredoc
test/regen-doctor.sh      [--check]   # doctor.sh from the _sandy_doctor_host() heredoc
```

- **Config tables** are generated from `sandy --print-schema`, whose source of truth is the `_sandy_key_metadata` heredoc. Adding/removing/retiering a key means: update `SANDY_PRIVILEGED_KEYS`/`SANDY_PASSIVE_KEYS`/`SANDY_ENV_ONLY_KEYS`, add the pipe-separated metadata row (`key|type|default|pattern|since|stability|description`), then run `regen-config-docs.sh`. Sentinels `<!-- BEGIN/END AUTOGEN:<name> -->` mark the rewritten regions; everything outside them is hand-maintained prose.
- **`templates/user-setup.sh.tmpl`** mirrors the container-side `user-setup.sh` heredoc so `shellcheck` can lint it as a real file (a heredoc string literal is unshellcheckable). The script stays single-file and `--upgrade`-compatible; the template is a derivative for review/lint only.
- **`doctor.sh`** mirrors the `_sandy_doctor_host()` heredoc so it stays curl-able and runnable standalone on a machine without sandy installed.

## Testing

Tests need Docker and built images, so they must run **on the host, not inside sandy** — Claude Code running inside sandy cannot reach Docker. **Ask the user to run the suites and share results.**

```sh
bash test/run-tests.sh              # pure-script tests (needs Docker + built images)
bash test/run-integration-tests.sh  # headless end-to-end (needs Docker + API keys)
```

`TESTING_PLAN.md` covers manual validation needing interactive TUI sessions.

**Acceptance harnesses run against an isolated `$SANDY_HOME`** (`test/lib-isolated-home.sh`), seeded with only the real home's build cache — because the build gate's first condition is `[ ! -f "$HASH_FILE" ]`, an unseeded home rebuilds every image `--no-cache --pull`. Isolation, not teardown, because a killed run still leaks: `--print-state` is the fleet API and **nothing marks a sandbox as a test artifact**, so leaked fixtures are indistinguishable from real ones (a downstream consumer once read 48 sandboxes of which 34 were fixtures). `SANDY_TEST_NO_ISOLATE=1` opts out. Guarded by `run-tests.sh §105`.

Integration knobs: `SANDY_INTEG_ONLY=7,13` / `SANDY_INTEG_SKIP=19,20,21` (exact-token match; SKIP wins), `SANDY_INTEG_NO_MODEL_PIN=1` (disable the default Haiku pin for claude smoke launches).

**Docker-runtime features are covered structurally in `run-tests.sh` and for real in maintainer-run acceptance scripts**, each also wired into `run-integration-tests.sh`: `acceptance-daemon.sh` (§19), `acceptance-update-sessions.sh` (§20), `acceptance-pane-topology.sh` (§21), `acceptance-handoff-dirs.sh` (§23), `acceptance-provision.sh` (§24).

**Write tests that assert the property, not the presence of a mechanism.** A check that greps for `flock -n 9` passes on code where the guard is dead; the dynamic singleton test that actually starts three relays does not. Mutation-test new guards.

### bash-3.2 / BSD portability lint (`test/lint-bash32.sh`)

CI is Ubuntu + bash 5 + GNU userland; the maintainer's machine is macOS + bash 3.2 + BSD. These constructs parse or expand **differently** there, so `bash -n` in CI passes and the break surfaces on one machine only — each in a way that does not announce itself:

| Code | Construct | How it failed here |
|---|---|---|
| `SRCSUB` | nested `source <(...)` inside `$( )` | bash 3.2 sources nothing → exit 127 → ERR trap aborted the run (§83) |
| `PYBACK` | backtick or `$(` inside a **double-quoted** `python3 -c "..."` body | bash expands it regardless of Python comment syntax — a `` `sandy` `` in a comment made the suite **execute the real sandy binary** (§68) |
| `APOSQ` | apostrophe in a comment inside a multi-line **single-quoted** program argument (`jq '...'`, `awk '...'`) | the apostrophe closes the string and the shell reinterprets the rest as code |
| `GREPM` | `grep -n … \| head` under `pipefail`, or a flag cluster whose numeric argument was split off before `-m` | grep dies on `EPIPE` (exit 2) and the ERR trap **aborts the suite mid-run** — a race, so it passes locally and fails in CI |
| `APOSCS` | apostrophe in a comment inside a multi-line `$( )` | bash 3.2 does not skip comments when scanning a command substitution → unterminated quote → **parse abort**, while the summary still printed "945 passed, 0 failed" (§86) |

Fixes: `SRCSUB` → extract-then-`eval`; `PYBACK` → a **quoted** heredoc (`python3 - arg <<'PY'`); `APOSCS`/`APOSQ` → reword the comment; `GREPM` → `grep -m1`.

```sh
bash test/lint-bash32.sh [--self-test|--list]
```

`run-tests.sh §89` asserts both that the tree is clean **and** that the detectors still fire on known-bad fixtures.

Also note (from real macOS runs): new test sections must be BSD/bash-3.2-safe or they pass CI and fail the maintainer — watch `\$`-literal-in-awk, `wc -l` leading whitespace, and empty-array expansion under `set -u`. When extracting a section to validate locally, replicate `set -euo pipefail` **and** the ERR trap, or the harness cannot see an unguarded non-zero exit.

## Git branch work inside sandy

`.git/HEAD` is **read-write** as of 1.5.0 (#80), so `git switch` / `git checkout` / `git checkout -b` work in-container — HEAD is a symref, not a host-code-execution vector. What stays `:ro` (anti-ref-spoofing / hook-injection): `.git/config`, `.gitmodules`, `.git/packed-refs`, `.git/hooks`, `.git/info`, submodule gitdirs. Consequences:

- `git commit`, `git reset`, `git switch`, `git checkout -b` — **work**.
- Repo-local `git config` writes — **fail** (`:ro`). The usual way to hit this is **`git push -u` / `--set-upstream`**, which reports `could not write config file .git/config: Device or resource busy` *after the push already succeeded* — it reads like a failed push and is not one. Use `git push origin <branch>:<branch>`.
- Deleting a **packed** ref, `git pack-refs`, `git gc` — **fail** (`:ro`). Loose-ref deletes still work.
- By a different mechanism (**protected workspace dirs**), **`git reset --hard` fails whenever the repo tracks a file under `.github/workflows/`** — `--hard` rewrites every tracked file, including ones it did not need to change. Use a **mixed reset** (`git reset <ref>`): it moves HEAD and the index and leaves the worktree alone.

**Session-end notice.** Because HEAD is writable, sandy snapshots the launch branch and prints a yellow notice if HEAD was left elsewhere (or detached), naming the `git switch` to restore.

**The HEAD-preserving pattern** is the way to land a PR from inside sandy — `main` is protected by a required-status-checks ruleset, so every change goes via PR + CI, never a direct push:

1. Edit and `git commit` on the current branch.
2. `git branch -f <feature> HEAD`
3. `git push origin <feature>`
4. `git reset --hard origin/main` (preserve uncommitted `.gitignore`/untracked changes across it)
5. `gh pr create --head <feature> --base main`

You can also `git switch -c <feature>` and work directly; just expect the session-end notice.

**Never run `tmux`, or `sandy --start|--stop|--attach`, from inside the sandy sandbox** — it shares the tmux server with the live session and kills it. Write Docker/tmux harnesses; have the user run them on the host.

## Versioning

`SANDY_VERSION` in the `sandy` script:

- **Release**: `X.Y.Z`. **Release candidate**: `X.Y.Z-rcN` (tagged as a GitHub pre-release; during an rc window no features, fixes fast-track to `-rc(N+1)`, a clean week graduates to final). **Post-release**: bump immediately to `X.Y.(Z+1)-dev`, or to `X.Y.Z-rc(N+1)-dev` after cutting an rc.
- `SANDY_COMMIT` holds the git short hash — empty in source, detected at runtime from a repo checkout, baked in by `install.sh` for local installs. Full string: `1.0.1-dev-a1b2c3d`.
- The update check compares only `SANDY_VERSION` via `_ver_lt()`, which **strips everything after the first `-`**, and uses `releases/latest` (skips pre-releases). So stable users are never nagged toward an rc, and rc users are not nagged when the same-numbered final ships — they upgrade with an explicit `sandy --upgrade`.

**1.x semver discipline**: `X.Y.(Z+1)` = fixes only; `X.(Y+1).0` = additive (new keys/flags, no retiering or renames); `2.0.0` = anything breaking the sandbox forward-compat promise, the introspection `schema_version: 1` contract, or config-key tier semantics.

## Per-project Configuration

`.sandy/config` in a project directory sets per-project defaults:

```sh
SANDY_SSH=agent
SANDY_MODEL=claude-sonnet-4-5-20250929
```

Parsed as plain `KEY=VALUE` lines (**not sourced** — no shell execution), validated against an allowlist.

### Config tiers

Four sources, in order: `$HOME/.sandy/config`, `$HOME/.sandy/.secrets`, `$WORK_DIR/.sandy/config`, `$WORK_DIR/.sandy/.secrets`. The first two are **privileged** (any key); the last two are **passive** (workspace-local, committable) and may set only a restricted subset freely.

**Precedence, top-down:** `--agent` flag > env var set before launch > workspace `.sandy/config` > host `~/.sandy/config` > default. (Sandy snapshots which keys are already in the env at startup and skips them during config loading.)

- **Privileged-only keys** — from a passive source these trigger a one-time per-workspace approval prompt showing the exact `KEY=VALUE` set:
  <!-- BEGIN AUTOGEN:privileged-key-list Run `test/regen-config-docs.sh` to update. -->
  `SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `SANDY_LOCAL_LLM_HOST`, `SANDY_ALLOW_HOSTS`, `SANDY_EXTRA_ENV`, `SANDY_AGENT_ARGS`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `SANDY_SCREENSHOT_DIR`, `SANDY_GEMINI_EXTENSIONS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`, `SANDY_HANDOFF_RELAY`
  <!-- END AUTOGEN:privileged-key-list -->

  A malicious committed `.sandy/config` could otherwise disable isolation or exfiltrate credentials. Approvals persist to `$SANDY_HOME/approvals/passive-<workspace-hash>.list` (first line a sha256 of the sorted set); any edit that changes a privileged key re-prompts. Revoke by deleting that file. **Headless (`-p`) and non-TTY stdin fail closed** — the keys are dropped with a pointer to launch interactively once.

  **CI escape hatch:** `SANDY_AUTO_APPROVE_PRIVILEGED=1` in the environment bypasses the prompt. Deliberately env-only — the passive allowlist does not include it, so a committed config cannot set it. Sandy's own test suites set it (the repo has its own `.sandy/.secrets`).

- **Passive-safe keys** (any source):
  <!-- BEGIN AUTOGEN:passive-key-list Run `test/regen-config-docs.sh` to update. -->
  `SANDY_AGENT`, `SANDY_MODEL`, `SANDY_TEAMMATE_MODE`, `SANDY_EFFORT`, `SANDY_CPUS`, `SANDY_MEM`, `SANDY_GPU`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS`, `SANDY_CHANNEL_TARGET_PANE`, `SANDY_VERBOSE`, `SANDY_VENV_OVERLAY`, `SANDY_EGRESS_PROXY`, `SANDY_EGRESS_NO_ISOLATION`, `SANDY_EGRESS_STRICT`, `SANDY_EGRESS_LOG`, `SANDY_ALLOW_WORKFLOW_EDIT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `GEMINI_MODEL`, `SANDY_GEMINI_AUTH`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI`, `CODEX_MODEL`, `SANDY_CODEX_AUTH`, `OPENCODE_MODEL`, `SANDY_OPENCODE_AUTH`, `GROK_MODEL`, `SANDY_GROK_AUTH`, `SANDY_TOOL_AUDIT`, `SANDY_CLAUDE_CONNECTORS`, `SANDY_SUSPICIOUS`, `SANDY_HANDOFF_DIRS`, `SANDY_CROSS_SESSION_INBOUND`
  <!-- END AUTOGEN:passive-key-list -->

- **Value-aware exceptions** — a few passive keys are not uniformly safe, because one value *weakens* the sandbox. `_sandy_passive_value_privileged()` routes those through the same approval prompt while leaving the strengthening values frictionless: ***a repo may make the sandbox tighter, never looser.*** Gated values: `SANDY_EGRESS_NO_ISOLATION=1`, `SANDY_EGRESS_STRICT=0`, `SANDY_EGRESS_PROXY=0`, `SANDY_ALLOW_WORKFLOW_EDIT=1`, `SANDY_CLAUDE_CONNECTORS=1`, `SANDY_SUSPICIOUS=0`, `SANDY_CROSS_SESSION_INBOUND=accept`. Guarded by `run-tests.sh §65`.

`SANDY_ALLOW_LAN_HOSTS` is additionally validated at use-site — world-open entries (`0.0.0.0/0`, `::/0`) are a hard error even from a privileged source.

## Agent Selection

```sh
SANDY_AGENT=grok                         # claude (default), gemini, codex, opencode, grok
SANDY_AGENT=claude,codex                 # any comma-separated combo (2–4; hard cap 4 — the layout is a 2x2 grid)
SANDY_AGENT=all                          # alias for claude,gemini,codex,opencode (grok is opt-in)
```

Single-agent modes use their own images (`sandy-claude-code`, `sandy-gemini-cli`, `sandy-codex`, `sandy-opencode`, `sandy-grok`); combos use `sandy-full`. Five selectable agents but a 2x2 grid, so a 5+ combo is a hard error. The old `both` alias was removed in v0.12.

Sandbox subdirs mount as: `claude/`→`~/.claude`, `gemini/`→`~/.gemini`, `codex/`→`~/.codex`, `grok/`→`~/.grok`, and OpenCode's `opencode/{config,share}`→`~/.config/opencode` + `~/.local/share/opencode`. v1 layouts with `settings.json` at the sandbox top level are auto-migrated.

**Credentials** (probe order; override with `SANDY_<AGENT>_AUTH=auto|api_key|oauth|adc`):

- **Gemini** — `GEMINI_API_KEY`, host `~/.gemini/tokens.json`, host gcloud ADC.
- **Codex** — `OPENAI_API_KEY` (materialized as an ephemeral `auth.json`, mounted `:ro`, because codex 0.139+ no longer reads the env var for first-party auth), then host `~/.codex/auth.json` (also `:ro` — prevents leakage back to the host and stale-token races; **in-session OAuth refresh therefore fails**, re-login in-container).
- **Grok** — authenticates headless from `XAI_API_KEY`, so there is **no auth file to materialize**; sandy just forwards the env var. The alternative is an interactive `grok login`, persisted in the rw `~/.grok` mount.
- **OpenCode** — provider-agnostic; sandy forwards whichever of `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`GEMINI_API_KEY`/… is set, and mounts host `auth.json` `:ro` when present.

**Launch specifics.** Gemini gets `GEMINI_SANDBOX=false`. Codex gets `--sandbox danger-full-access` plus `sandbox_mode` in `config.toml` (its Landlock sandbox does not nest in Docker; sandy provides the outer isolation), a seeded `[notice]` block, and a `trust_level = "trusted"` entry appended by `user-setup.sh`. Grok headless adds `--no-auto-update`.

**Headless (`-p`/`--print`/`--prompt`) translation**: claude → `--print`; codex → `codex exec --skip-git-repo-check`; opencode → `opencode run <prompt>`; grok → `-p` (Claude-shaped, positional prompt). `--continue`/`-c` is silently dropped for codex/opencode/grok. `exec`/`run` only produce 0/1 exit codes.

**OpenCode config seeding** resolves three states on sandbox creation: (1) host `~/.config/opencode/opencode.json` exists → seeded in; (2) no host config but `SANDY_LOCAL_LLM_HOST` set → sandy generates a starter config from a `/v1/models` probe pointing at `http://host.docker.internal:<port>/v1`; (3) neither → loud warning naming the three fixes, but the launch proceeds (opencode's built-in default model would otherwise fail confusingly).

**Local-LLM passthrough.** `SANDY_LOCAL_LLM_HOST=<ip>:<port>` opens exactly one narrow path through sandy's RFC-1918 block: format-validated, world-open IPs rejected, a single `iptables ACCEPT` for that host:port (plus `--add-host=host.docker.internal:host-gateway` on Linux). With the egress proxy on it is served by the proxy's forward listener instead. Orthogonal to `SANDY_ALLOW_HOSTS`.

**Feature support by agent**:

| Feature | `claude` | `gemini` | `codex` | `opencode` | `grok` | multi-agent |
|---|---|---|---|---|---|---|
| Skill packs | yes | — | — | — | — | yes (claude pane only) |
| Synthkit commands | slash commands (Markdown) | slash commands (TOML) | skills context (SKILL.md) | — | — | per agent |
| Channels (Telegram) | in-container plugin | host-side tmux relay | host-side tmux relay | host-side relay (untested) | host-side relay (untested) | host-side tmux relay |
| Channels (Discord) | yes | — | — | — | — | — |
| `--remote` | yes | — | — | — | — | — |
| Gemini extensions | — | yes | — | — | — | yes (when gemini is in the combo) |
| Local-LLM passthrough | — | — | — | yes | — | yes (when opencode is in the combo) |
| Provider choice via own config | — | — | — | yes | — | — |

The Telegram host-side relay (`$SANDY_HOME/channel-relay.sh`) is an agent-agnostic long-polling bridge injecting via `docker exec … tmux send-keys`; `SANDY_CHANNEL_TARGET_PANE=0|1|2` picks the pane.

**Pane identity: never assume `pane_index == spawn order`.** In the 4-agent grid the last split re-splits pane 0, and tmux inserts the new index *after* the pane it split — so `sandy.1` holds the **fourth** agent, `sandy.2` the second, `sandy.3` the third. The on-screen layout is still correct. Sandy sets a `@sandy_pane_agent` **tmux pane option** on every pane unconditionally; it drives the border label and is the robust identity source (a scrollback marker gets wiped when a live agent redraws, and `select-pane -T` is OSC-2-clobberable). Consequence: `SANDY_CHANNEL_TARGET_PANE=1|2|3` against a 4-agent combo does not reliably route to "the Nth agent in `SANDY_AGENT`" — a separate, unfixed gap.

## Per-project Sandboxes

Each project gets an isolated sandbox under `~/.sandy/sandboxes/`, named `<mnemonic>-<8-char-hash>`. The hash is over the workspace path canonicalized with `pwd -P` (resolves symlinks, folds case-collisions on APFS). Each launch writes `WORKSPACE.json` (canonical path, user-typed path when different, first/last launch timestamps and sandy versions) and warns when a sibling sandbox records the same workspace — manual cleanup only.

**`settings.json` is regenerated at `$SANDBOX_DIR/claude/settings.json` on every launch**, merge-preserving: the host copy is re-read so host edits propagate, but `enabledPlugins` survives from the previous session so `/plugin install` persists. The file is **rw** in-container (the stricter `:ro` sidecar broke plugin installs with EROFS). Sandy-managed keys are re-overwritten every launch: `extraKnownMarketplaces`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, `skipAutoPermissionPrompt`, `permissions.defaultMode`, cmux hooks. `skipAutoPermissionPrompt` suppresses 2.1.x's auto-mode offer and tracks `SANDY_SKIP_PERMISSIONS`; 2.1.x ships a migration that **deletes** that key whenever `defaultMode != "auto"` — re-seeding every launch is what makes it stick. As of 1.7.0 `teammateMode` is **not seeded at all** and `SANDY_TEAMMATE_MODE` is **empty by default** (set it to e.g. `tmux` to opt in).

That in-session mutability is what let Claude Code 2.1.232 overwrite the `bypassPermissions` pin with `"auto"` seconds into a run (#151). Sandy can only seed before `docker run`, so it snapshots the pinned mode at launch and prints a yellow **drift notice** at session end if it changed; it re-pins next launch regardless.

Credentials (`.credentials.json`) are read fresh from the host each launch and mounted **ephemerally** — never persisted to the sandbox.

### Sandbox version tracking and the 1.x forward-compat promise

Each sandbox records `.sandy_created_version` on creation and `.sandy_last_version` per launch. `_sandbox_compat_classify()` grades the created-version against `SANDY_SANDBOX_MIN_COMPAT` (currently `0.7.10`):

- **below the floor** → **hard error, sandy refuses to launch**, printing the recreation command
- **unknown/invalid** (pre-0.10.1, or unreadable) → warn only (fail-open on uncertainty, fail-closed on proof)
- **at/after** → silent

The current threshold is the workspace mount-path change (v0.7.10): sandboxes older than that carry cached `/workspace/...` paths in venvs and package caches that break silently. Fix: `rm -rf ~/.sandy/sandboxes/<name> && sandy --rebuild`.

**Promise: a sandbox created by any `1.x` sandy works with any later `1.x` sandy.** Therefore **within `1.x`, `SANDY_SANDBOX_MIN_COMPAT` must never advance above `1.0.0`** — a layout change that would break `1.x` sandboxes is a `2.0` change. Guarded by `run-tests.sh §51/§60` plus the frozen `test/fixtures/frozen-sandbox-1.0/` snapshot (read its README before "fixing" a §60 failure). A non-destructive migration utility is tracked in `docs/POST_1.0_IDEAS.md`.

### Workspace `.venv` overlay

A host `.venv/bin/python` symlinks to a host-only interpreter that is broken inside the Linux container, and a later `uv pip install` would recreate `.venv` and wipe its `site-packages`. So sandy bind-mounts a sandbox-owned overlay (`$SANDBOX_DIR/venv/`) over `$WORKSPACE/.venv`: the host venv is **shadowed, never modified**, and after sandy exits the host's `.venv/` is exactly as it was.

- The wanted Python version comes from `.python-version` (authoritative) else `pyvenv.cfg`, must match `^[0-9]+\.[0-9]+$`, and is passed as `SANDY_VENV_PYTHON_VERSION`.
- First launch materializes it (`uv python install`, then `uv venv --clear` — `--clear` is required because the bind-mount target always exists); you then run `uv sync` / `pip install` once. No in-container locking is needed — the workspace mutex guarantees exclusivity.
- Later launches skip straight to activation, and warn on a version drift rather than auto-recreating (which would silently nuke installed packages).
- A **symlinked** `.venv/` is skipped with an info message; non-standard names (`venv/`, `.venv-py311/`) are never overlaid.
- Opt out with `SANDY_VENV_OVERLAY=0`; the fallback is warn-only.

**Security residual when the overlay is off or skipped**: the venv then sits directly on the rw workspace mount, so an agent can modify an interpreter the host's IDE later executes during discovery. Sandy warns in both the overlay-off and symlinked-`.venv` branches. Non-standard names get no warning (they are not detected).

### Concurrent launches

One sandy per workspace. Launch takes a mutex (`mkdir` on `$SANDY_HOME/sandboxes/.<name>.lock`, atomic on every POSIX filesystem) and writes its PID. A second launch probes `kill -0`: alive → fail fast naming the pid; gone → auto-clear the stale lock and proceed. PID reuse can cause a false positive (user clears manually) — safer than a false negative that clobbers a live session. `--print-state` exposes `lock_holder_alive` per sandbox.

### Persistent package installs

| Sandbox dir | Container mount | What it stores |
|---|---|---|
| `pip/` | `~/.pip-packages` | `PYTHONUSERBASE` — pip user installs |
| `uv/` | `~/.local/share/uv` | uv-managed Python versions |
| `npm-global/` | `~/.npm-global` | `npm install -g` packages |
| `go/` | `~/go` | `GOPATH` — `go install` binaries |
| `cargo/` | `~/.cargo` | `cargo install` binaries + registry cache |

Per-project — nothing leaks between sandboxes.

### Language environment gotchas

Base image: Python 3.13 (Debian trixie), Node 24, Go 1.26, Rust stable, C/C++, plus `uv`.

- **Read-only root filesystem** (`--read-only`): `apt-get install` and non-`--user` `pip install` fail. Use the user-scoped mounts above, or `uv` for Python versions:

  ```sh
  uv python install 3.11 && uv venv --python 3.11 && source .venv/bin/activate
  ```

  Downloaded versions persist in the `uv/` mount, so this downloads once per sandbox. Plain `pip install` also works — `PYTHONUSERBASE` and `pip.conf` (`user=true`) send installs to the persistent `pip/` mount; inside an activated virtualenv pip correctly targets the venv instead. `npm install` (no `-g`) writes to the host-mounted `node_modules/`; `npm install -g` writes to the persistent `npm-global/` mount. Both survive.
- **PATH order**: `~/.local/bin` > `PYTHONUSERBASE/bin` > `npm-global/bin` > `GOPATH/bin` > `CARGO_HOME/bin` > system.
- **tmpfs home is 2GB** — the persistent mounts bypass it entirely.
- **Cargo**: the entrypoint symlinks system toolchain binaries into the persistent `~/.cargo/bin`; user-installed binaries coexist.
- **Host build artifacts** on the rw workspace mount: pure-JS `node_modules/` works, native `.node` addons need `npm rebuild` unless the host is compatible Linux; Rust `target/` is reusable only Linux→Linux (Cargo handles the rest); Go `vendor/` always works.
- **Automatic detection at session start** warns about: a broken `.venv` symlink, foreign native modules, an orphaned pip user-site after a base-image Python bump; and auto-installs `.python-version` via `uv python install`.

## Introspection Surface

Four machine-readable JSON flags run as **fast-path handlers** — they exit before Docker, image builds, and mutex acquisition, so they are cheap for UI frontends, CI, and non-interactive callers. Full field contract: **`SPEC_INTROSPECTION.md`**.

- **`--print-schema`** — static: version, config keys by tier (type, default, description), CLI flags, agents + credential probe orders, protected path lists, skill packs, `schema_version: 1`.
- **`--print-state`** — runtime: images, per-sandbox metadata, approvals, `docker_reachable`, running sandy containers. Reports `docker_reachable: false` gracefully when docker is absent. **Full mode only**: `size_bytes` (a `du -skx` walk — light mode always `null`, to stay in the light-mode poll budget), `image_stale`, `dangling_images`, `orphaned_containers`. Both modes: `host_id`/`host_id_source` (advisory, `uname -n` or `SANDY_HOST_ID`) for merging output across hosts, since sandbox names hash only the workspace path and collide across hosts.
- **`--validate-config PATH`** — classifies a file as privileged (`$SANDY_HOME/…`) or passive by path; reports errors, unknown keys, privileged-from-passive keys needing approval, and the approval file path. Exit 0 on success (including "approval pending"), 1 only for file-not-found / missing argument.
- **`--print-version`** — `{schema_version, version, commit, full_version}`. Exists because `--print-schema`'s own `sandy.version` is the payload a consumer would be caching (chicken-and-egg). **Cache on `full_version`, not `version`**: on a dev channel `version` stays `"1.7.0-dev"` across every commit, so a cache keyed on it never invalidates across exactly the upgrades that matter. `commit` is `""`, not `null`, when unknown. Pre-1.7.0 sandy forwards unrecognized flags to the agent rather than erroring, so confirm 1.7.0+ via `--version` first.

As of 1.7.0 all four carry a **stream contract**: exactly one JSON document on stdout, 0 bytes of stderr, even on JSON-shaped failures — the sole exception being no-argument `--validate-config` (0 bytes stdout, one `[sandy] ERROR:` line on stderr). Pinned by `run-tests.sh §92`/`§93`.

**`cli_flags` is hand-curated, not derived.** Any flag added to any parser must either gain a `cli_flags` entry or go on one of the three exception lists (sub-option, private/debug, forwarded-to-agent) in `run-tests.sh §91`, which statically diffs the two and fails on drift in either direction — and also ratchets each flag's own `--help` entry. (`--workspace` was accepted by every daemon-family parser since 1.1.0 but missing from `cli_flags` until 1.7.0.)

## Self-Attestation Marker

Every launch writes `$SANDBOX_DIR/sandy-session.json`, bind-mounted **read-only** at `/etc/sandy-session.json`. It is the single authoritative in-container signal that the agent is genuinely inside sandy and at what isolation level:

```json
{ "schema": 1, "sandy_version": "...", "egress_mode": "off|permissive|strict",
  "workspace": "...", "host_uid": 501, "host_gid": 20,
  "launched_at": "2026-06-11T12:00:00Z", "session_nonce": "<hex>",
  "effort": "high", "permission_mode": "bypassPermissions",
  "cross_session_inbound": "refuse", "handoff_relay": false, "cred_mode": "full" }
```

**Why it exists**: env vars are spoofable and the *absence* of a path proves nothing, so an in-container probe that distrusts env otherwise cannot tell sandy from a bare VM — a red-team run in sandy on macOS/OrbStack concluded it was *not* in sandy at all (uid 501, virtiofs mounts, and the documented `--cap-add` set all read as "ordinary VM"). Because the marker is `:ro`, a committed workspace config cannot forge it. **In-container tooling should assert on this file, not on uid/caps/env heuristics.**

Fields record what sandy **pinned**, which is not necessarily what is in effect now (see the settings.json drift note above): `effort` (or `null` when unpinned), `permission_mode`, `cross_session_inbound`, `handoff_relay` (bool), and `cred_mode` (`oauth-token|access-token-only|full|api-key|none` — the *worst* credential actually present, so a run's blast radius is provable after the fact).

**Tamper-evidence.** `session_nonce` is minted fresh per launch and forwarded out-of-band (printed host-side under `SANDY_VERBOSE=1`) so an external verifier can confirm the file matches the launch it expects. It is deliberately **not** exported as an env var — the read-only file is the trust root. An operator can pin it via `SANDY_SESSION_NONCE` (validated `^[A-Za-z0-9._-]{8,128}$`; invalid warns and falls back to auto-mint, never failing the launch). That knob is **env-only**, so a committed workspace config cannot pin it.

## Daemon Mode (`--start` / `--attach` / `--stop`)

Decouples a session's lifetime from the launching client. Additive — bare `sandy` is byte-unchanged; every daemon branch is gated on `SANDY_START`/`SANDY_ATTACH`/`SANDY_STOP`/`SANDY_DAEMON_SUPERVISOR`/container-side `SANDY_DAEMON`.

**Architecture — "the container is the daemon; a host-side supervisor owns the lock+helpers+trap."** `--start` forks a detached supervisor (`nohup … & disown` — deliberately *not* `setsid`, which is util-linux and absent on macOS) that re-execs sandy with `SANDY_DAEMON_SUPERVISOR=1`. It takes the workspace lock with its own PID, runs a **detached** container (`-d --restart unless-stopped --name sandy-<sandbox>`, and crucially **no `--rm`** — docker rejects it with `--restart`), spawns the helpers as its children, installs the cleanup trap, then blocks on a bounded-sleep loop (`while :; do sleep 300 & wait $!; done` — **not** `sleep infinity`, a GNU extension BSD sleep rejects instantly, which would drop the supervisor into its EXIT trap and tear down the fresh daemon; guarded by §70). Container-side, `SANDY_DAEMON=1` creates the tmux session detached and `exec tail -f /dev/null`.

**State = container labels** (not a state file — survives upgrades, cannot drift from docker): `sandy.daemon=true`, `sandy.workspace_path`, `sandy.session`, `sandy.started_at`, `sandy.daemon_pid`.

**D9 — container existence is the durable truth; the lock is the live-operation guard.** A running labeled container = "this session exists," *even with no supervisor* (after a reboot `--restart unless-stopped` resurrects the container but not the supervisor). So idempotency, the busy-check, and `--stop` all key off the container. **D6 refinement**: "container-as-truth" means a container with a **live inner session** — `--start` and bare `sandy` probe `docker exec … tmux has-session` (with a short mid-startup retry) and **reap a dead-session zombie via `"$0" --stop`** rather than wedging the user out.

**Decisions (the sandy-ui consumer contract):**

- **DEC-A — concurrent attach = last-wins** via `tmux attach -d` (displaced client exits `3`). Never plain `tmux attach` (mirroring is the one banned outcome).
- **DEC-B — bare `sandy` over a live daemon session = error-with-hint, exit `1`.**
- **DEC-C — exit codes.** `--attach`: `0` session ended while attached, `3` clean detach, `4` no such session, `5` attach failed. `--stop`: `0` stopped, `4` no such session, `5` teardown failed. `--start`: `0` ready, `6` refused before launch (an approval could not be granted — user-actionable in one step), `7` crash-looping, `8` timed out waiting for the inner session, `1` unclassified. Post-attach, `5` is reserved for failure to *establish* the attach; once `tmux attach` returns the outcome is only `3` or `0` — including the window where the container is up but the inner session has ended, which maps to `0` so consumers stop sticky-reconnecting a dying session.
- **No exit code observed is NOT a verdict (#157).** Sandy discards `tmux attach`'s own status and re-derives the answer by probing live state. If sandy is killed by a signal — commonly `SIGHUP` on pty teardown when an editor closes a terminal — that probe **never runs** and the parent sees `code === null`. That means *the decision procedure did not execute*; it does not mean the session failed and must not be mapped onto `5` (which `--attach` never emits anyway — both `exit 5` sites are in `--stop`). Reconcile against `--print-state`, or just re-run `--attach`, which returns `4` if the session is genuinely gone.

`--start` refuses headless (a one-shot under `--restart unless-stopped` would restart-loop). `--stop` signals a live supervisor (`kill -TERM`) so its own trap releases the lock; a dead supervisor (D9 reboot) means `--stop` tears down container/networks directly and reaps the provably-stale lock.

**Daemon-log polish**: under `SANDY_DAEMON_SUPERVISOR=1` sandy forces ANSI colors on (the supervisor has no TTY but streams to the `--start` client) and quiets the base build with `-q`. Interactive behavior is unchanged.

## Maintenance family

### Exit-code rule (C1)

Shared by `--gc`, `--reset-sandbox`, `--remove-sandbox`, `--stop-all`, `--update-sessions`, `--provision`, `--doctor`, and any future member: **refusal is exit `1` when the goal state is UNMET; skip is exit `0` when it is ALREADY MET.** `--reset-sandbox` exits `1` when a live lock blocks it (the sandbox was not reset); `--provision` exits `0` when a live session already satisfies it. The distinction is whether the command's stated goal holds at the end, not whether it did work.

All members share the same confirmation discipline: print the plan → nothing-to-do exits `0` immediately → `--dry-run` exits `0` before any confirm → `--yes` skips the prompt → a TTY without it gets y/N from `/dev/tty` → **non-TTY without `--yes` errors and exits 1** (cron must opt in explicitly).

### The commands

- **`--gc [--dry-run] [--yes]`** — global reclaim of five resource kinds in order (containers → networks → project images → skills images → dangling images): dead-owner containers, orphaned networks (delegated to `_sandy_reap_orphan_networks`, so `--gc` and `--prune-orphans` can never drift), orphaned `sandy-project-*` and `sandy-skills*` images, and dangling `<none>` images. A before/after re-count reports what actually freed. **Agent-vs-proxy is decided by image, never by name prefix** — a workspace basename of `proxy` produces an agent container literally named `sandy-proxy-<hash>`. A running daemon agent is reaped only when `tmux has-session` actually **fails** (retried 5×/1s); a live session is never touched regardless of supervisor-pid liveness. A proxy is judged purely by its paired agent's verdict — judging it by its own lock would strand a live agent on a routeless sidecar. Scoped to sandy's own images via the `sandy.managed=1` build label (pre-1.3.0 images lack it and are invisible to the dangling lister; the gap closes as images rebuild).
- **`--stop-all [--dry-run] [--yes]`** — the tested emergency shutdown path. Enumerates `sandy.daemon=true` containers and invokes `"$0" --stop --workspace <path>` **serially**, reusing the hardened per-session teardown verbatim rather than duplicating lifecycle surface.
- **`--update-sessions [--dry-run] [--yes] [--idle-for N] [--rebuild]`** — daemon mode makes launches rare, so a session can sit for days on a stale image. Per session it runs `cd <workspace> && "$0" --build-only` (**DEC-U1**: the orchestrator never guesses the image stack — each workspace's own build resolves it), compares running image id vs. current (`_sandy_image_stale`, the same helper `--print-state` uses), optionally applies an idle gate (a failed activity probe counts as ACTIVE — never restart what you cannot prove idle), then rolling-restarts serially via `"$0" --stop` + `SANDY_UPDATE_RESTART=1 "$0" --start` (**DEC-U2**), relying on the child's exit code (**DEC-U8**). `--dry-run` still builds (side-effect-free) so the plan reflects a real comparison. The supervisor stamps `sandy.updated_at` when it sees `SANDY_UPDATE_RESTART` (**DEC-U3**) — the sandy-ui discriminator between "restarted for an image update" and "user restarted it".
- **`--reset-sandbox [--workspace P] [--keep-approvals] [--dry-run] [--yes]`** — filesystem-only (no Docker, no config load, no mutex). Rebuilds one project's sandbox from known-good: destroys everything in the sandbox dir **except `WORKSPACE.json`**, `.handoff-enabled`, `agent-args.<agent>` files, and (with `--keep-approvals`) the approved-symlinks list. Refuses while a live workspace lock is held. Exists because the container is immutable-ish but the **sandbox is not** — `pip/uv/npm-global/go/cargo` bins sit on PATH and `.claude/plugins` persists into every later session, so a poisoned session can carry over.
- **`--remove-sandbox [--workspace P | --sandbox NAME | --orphans] [--dry-run] [--yes]`** — permanently deletes a whole sandbox directory, preserving **nothing**. Three mutually exclusive selectors (more than one → exit 1). Workspace mode requires the directory to exist — deliberately no fallback to hashing an unresolved literal path, which would be a second, weaker resolution path on an `rm -rf`. `--sandbox NAME` is validated as a single path segment (no `/`, no leading `.`, no `..`, `[A-Za-z0-9._-]` only). `--orphans` uses a conservative predicate: `WORKSPACE.json` exists **and** `workspace_path` non-empty **and** `[ ! -e "$workspace_path" ]` — a legacy sandbox with no marker is never an orphan. Also reaps the sibling lock dir and the per-workspace approval files (keyed on the **16-char** hash of the canonical path — *not* the 8-char hash the directory name uses). Safety is layered: one trusted resolution path per selector, input validation, a **containment assert immediately before every `rm -rf`**, the live-lock refusal, and a best-effort running-container guard using one batched `docker ps` with **exact whole-line** name matching (docker absent → fail-open, since working without Docker is the point).
  **Why not folded into `--gc`**: `--gc`'s safety envelope rests on "a false-positive reap costs a rebuild, not data loss"; sandbox dirs hold non-reproducible state. Users already cron `--gc --yes`, and adding deletion would silently change what an already-given `--yes` does.
  **Two residuals**: a workspace on a slow/unreachable network mount can block the `[ -d ]` check, and a merely *unmounted* workspace reads identically to a deleted one. Mitigation is procedural — **do not cron `--remove-sandbox --orphans --yes` on a host with removable or intermittently mounted media.**
- **`--provision [--workspace P] [--dry-run] [--yes]`** — creates a sandbox non-interactively **via the real launch path**: `SANDY_PROVISION=1 "$0" --start` then `"$0" --stop` (DEC-U2 composition; needs Docker, unlike the filesystem-only members). Deliberately **not** a flag that manufactures the directories — hand-created state that no container ever mounted *looks wired and is not*, and a second code path would be free to drift. Completion = `--start` 0 then `--stop` 0; `--stop` 4 after a successful start is also success (the launch already completed), `--stop` 5 is a failure. Two liveness guards (workspace lock, then a running daemon container per D9) make it a **safe no-op, exit 0** against a live session; it is always re-runnable and never skipped merely because the directory exists. TOCTOU: it mints a random `SANDY_PROVISION_ID` per run (separate from the session nonce, which is the attestation trust root) and the supervisor stamps it as `sandy.provision_id`, so both reads prove *ownership*, not mere stability — second-granularity timestamps collided in a fleet loop, and `date %N` is GNU-only so sub-second precision would be worse on macOS.
  **Consumer note**: exit `0` attests to *sandy's* goal (the sandbox is provisioned), not necessarily yours — verify the artifact you care about. Against a container started before handoff creation became unconditional (1.7.0), `--provision` correctly exits 0 and no handoff pair appears.
- **`--doctor [--fix] [--yes]`** — global preflight diagnostics in two sections. **HOST** runs the embedded `doctor.sh` body (bash/git/curl/docker, PATH, recommendations, credential detection, install status) — sandy's only **required**-failure source. **RUNTIME** reuses sandy's own predicates verbatim (`_sandy_image_stale`, the `--gc` orphan listers, the launch path's stale-lock predicate, `--remove-sandbox`'s orphan predicate); **every RUNTIME finding is a warning**, never a required failure. **Exit contract: `0` iff every required HOST check passes; `1` otherwise. Warnings never affect the exit code.** `--fix` is deliberately narrow — exactly two remediations, both delegated to existing code: clear a stale workspace lock whose pid is provably dead, and reap orphaned networks. **Nothing else**; the orphaned-sandbox count stays read-only always (an unmounted volume reads as "gone"). `--yes` without `--fix` is a **hard error**, not silently inert — a CI job that lost the `--fix` token must not quietly run read-only and report success.
  **Hazard**: the HOST body contains `sandy --version | head -1` — under `--doctor` that is a recursive self-exec, safe only because it runs in a **child shell with no `pipefail`**, so the early `head` produces an inert `EPIPE`. `_sandy_doctor_host()` therefore pipes the heredoc to a fresh `bash` rather than `source`/`eval`-ing it into sandy's `set -euo pipefail` shell, and the dispatcher captures its status with `|| rc=$?` (a bare nonzero return under `set -e` would abort before RUNTIME ran).

## Auto-update and image freshness

Each launch compares the installed Claude Code version against the latest release; if newer, the image is rebuilt `--no-cache`. Inside the container `DISABLE_AUTOUPDATER=1` prevents self-updates against the read-only filesystem.

**No image is built when the resources a build needs are unreachable (#218).** The version check and the build pull from *different* endpoints, and **partial reachability is the normal failure mode** — captive portals and in-flight wifi routinely allow one CDN and block another, so a successful update check proves nothing about a rebuild. Observed in flight: the check reached `storage.googleapis.com`, set `NEEDS_BUILD=true`, and the forced rebuild died at `apt-get update` (exit 100), aborting the launch under `set -e` on exactly the network where the already-built local image was most wanted — and re-dying on every retry.

So **every** build site (base, proxy, agent, both skill-pack layers, per-project) passes through `_sandy_build_allowed`, which probes the actual build dependencies (`deb.debian.org`, `registry.npmjs.org`) rather than general connectivity. Unreachable: keep the existing image and defer; **no** existing image: fail immediately with an accurate message rather than after a multi-minute apt timeout naming the wrong cause. The probe is lazy and memoized. The agent build additionally tolerates a build that fails *despite* the probe passing (the probe is host-side, `docker build` runs in Docker's VM) when a usable image exists — the hash file is only written on success, so the rebuild retries next launch. Hash-change and missing-image builds still fail hard. A deferred refresh is reported at session end so the CVE posture does not erode silently. Guarded by §107.

**Predecessor-image GC (#36).** A same-tag rebuild leaves the old id untagged and dangling forever, so sandy captures the id before each base/proxy/agent rebuild and best-effort `docker rmi`s the predecessor after a *successful* one. No `-f`, so it no-ops while the old id is still referenced; `--gc` sweeps whatever slips past.

**Proxy image freshness.** The agent image auto-rebuilds on a new agent version, but the proxy image only rebuilt when its git ref changed — so between releases the TLS/HTTP/CONNECT I/O of the security-critical component froze while the agent beside it self-updated weekly. `generate_dockerfile_proxy()` now writes a **monthly freshness epoch** (`date -u +%Y-%m`) into `Dockerfile.proxy`, so its hash moves monthly and triggers a rebuild **with `--pull`** (`--no-cache` alone rebuilt the binary but never re-pulled the base). **Keeping the pin on a supported Go minor is what makes this work at all**: `golang:1.24-bookworm` delivered 12 patch releases, then Go 1.24 left the support window and the monthly `--pull` re-resolved to an unchanged digest. The pin is now `golang:1.26-trixie`. `--print-state` full mode reports `proxy_image_created`. Guarded by §49.

### Wrapped-agent CVE watch

Sandy wraps four third-party agents at **floating-latest** (`npm install -g @anthropic-ai/claude-code | @google/gemini-cli | @openai/codex | opencode-ai`). Pillar's "Week of Sandbox Escapes" hit three of the four, so a wrapped-agent CVE is a realistic event. Sandy's boundary never *relies* on the agent being un-compromised, but a vulnerable agent widens the in-box blast radius.

- **Auto-patch is the default posture**: floating-latest plus the per-launch check means a patched release arrives on the next launch. No reproducibility, low patch latency — the right trade for a security wrapper. Force with `sandy --rebuild`.
- Each generated agent Dockerfile writes the resolved version to `/opt/<agent>/.version`, so the running image's agent versions are auditable in-container.
- **Advisories to watch**: `anthropics/claude-code`, `google-gemini/gemini-cli`, `openai/codex`, `sst/opencode` releases + GitHub Security Advisories; `npm audit`/OSV for transitives.
- **Responding**: patched upstream → `sandy --rebuild`. Bad release → temporarily pin `npm install -g <pkg>@<good-version>` in the generated Dockerfile, rebuild, unpin later. There is no in-agent allowlist sandy depends on, so the response is always "change what's installed."
- **Deferred** (`docs/POST_1.0_IDEAS.md`): a `SANDY_<AGENT>_MIN_VERSION` enforcement floor and surfacing `/opt/<agent>/.version` in `--print-state` — disproportionate while floating-latest already auto-patches.

## Network Isolation and the Egress Proxy

Per-instance Docker bridge networks are keyed on PID (`sandy_net_$$`) to avoid races. On Linux, iptables DROP rules block RFC 1918, link-local (`169.254.0.0/16`), and CGNAT/Tailscale (`100.64.0.0/10`) while allowing the container's own subnet; rules are cleaned up on exit.

**macOS, proxy off only.** Docker Desktop's VM provides no LAN isolation and iptables cannot be applied from macOS: containers reach `host.docker.internal`, host `localhost` services, and the whole physical LAN. Sandy nullifies the magic hostnames (`gateway.docker.internal`, `metadata.google.internal`, and `host.docker.internal` when `SANDY_SSH!=agent`) via `--add-host … :127.0.0.1`, but raw-IP access is unaffected, and it prints a warning banner. **With the proxy off, treat macOS sandy as process and filesystem isolation only.**

The egress proxy closes that gap and works **identically on Linux and macOS** because it relies on Docker's `--internal` network routing, not iptables.

**Three postures**, set by two mutually exclusive booleans (default **permissive**, both `0`):

- `SANDY_EGRESS_NO_ISOLATION=1` → **off** (legacy: Linux iptables, macOS nothing). *Weakening* → approval-gated from a workspace source.
- neither set → **permissive** (default). Blocks only private/LAN/link-local/CGNAT/cloud-metadata destinations; all internet allowed. Linux-parity LAN isolation on macOS with ~zero tool friction and no allowlist to maintain.
- `SANDY_EGRESS_STRICT=1` → **strict**. Denies everything except a built-in allowlist (model providers, GitHub incl. SSH, npm/PyPI/crates/Go/Debian) plus `SANDY_ALLOW_HOSTS`. *Strengthening* → passive-safe; setting it `=0` to downgrade a host-set strict is approval-gated.

`SANDY_EGRESS_PROXY` is a **deprecated alias** (`0`→no-isolation, `1`→permissive, `2`→strict) that warns and is approval-gated the same way.

**Topology.** Two networks per session: an `--internal` **sidecar** bridge the agent joins (no route off it — this is the isolation) and an **egress** bridge only the dual-homed proxy joins. The proxy is the sole path off the sidecar and therefore the single policy chokepoint; the agent's resolver points at it (`--dns <proxy-ip>`) and its DNS responder redirects permitted names to its own sidecar IP. The proxy takes a fixed IP from ~512 candidate `/24`s across `10.200.0.0/16`+`10.201.0.0/16`. **Sandy reaps its own orphaned networks eagerly at every launch** (`_sandy_reap_orphan_networks`: any `sandy_net_*`/`sandy_sidecar_*`/`sandy_egress_*` whose trailing PID is dead **and** which has no attached container — the PID gate is what makes eager reaping concurrent-safe). This fixes the "all predefined address pools have been fully subnetted" failure that accumulates under repeated launch/relaunch cycles. iptables is **not** applied in proxy mode (the topology is the isolation, and RFC1918 DROPs would break the proxy's own forward).

**Listeners** (Go binary, `scratch` image, `--read-only --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 128 --memory 256m`): DNS (UDP 53, refuses HTTPS/SVCB records to keep SNI readable), transparent `:443` (SNI demux, TLS never terminated), transparent `:80` (Host demux), CONNECT `:3128` (git-over-SSH), and an optional local-LLM forward. Permissive mode resolves-then-checks the destination, which also defeats DNS rebinding. The proxy never terminates TLS, never logs payload, never caches. All three accept loops share one `acceptLoop` that takes a `maxConns` semaphore slot **before** `Accept`, so a connection storm applies backpressure at the kernel backlog rather than growing goroutines unbounded.

**Non-TCP is dropped by `--internal`, not by the proxy — and that is by design.** `--internal` is an L3, protocol-agnostic FORWARD-chain DROP with no MASQUERADE, so raw UDP, **QUIC/HTTP-3 over UDP/443** (which would otherwise bypass the SNI-reading TCP proxy), ICMP, and IPv6 (networks are `--ipv6=false`) never reach the proxy and fail closed. Verified on macOS Docker Desktop and guarded by `test/spike/macos-internal-network-spike.sh` (A1d) + `run-integration-tests.sh §13b`. **A future refactor must not make the proxy the only egress mechanism without re-adding a non-TCP block.**

**Resilience.** The proxy runs `--restart on-failure:5` so a mid-session death is resurrected on the **same** fixed IP, keeping the agent's `--dns`/route valid. The launch gate polls `.State.Health.Status` against a baked `HEALTHCHECK` that re-invokes the binary as `sandy-proxy -healthcheck` (scratch has no shell — the binary *is* the probe), so it waits for listeners to actually **bind** rather than for the process to start; it falls back to `.State.Running` for older cached images, and surfaces a non-zero `RestartCount` as a crash-loop warning.

**Atomic agent+proxy teardown.** `cleanup()` force-removes the **agent first**, then proxy and networks. `docker run --rm` in the foreground does not own the container's lifetime — the daemon does — so a killed client (closed terminal, dropped SSH, SIGHUP) leaves the agent running. Removing only the proxy would strand it on a **routeless `--internal` sidecar**, every request failing `FailedToOpenSocket` with no recovery until the next launch (`docker ps` tell: an `sandy-<sandbox>` Up with no matching `sandy-proxy-<sandbox>`). Regression-guarded by §55.

**Diagnosing a proxy death.** Sandy streams proxy logs to `$SANDBOX_DIR/proxy.log` (survives the `docker rm -f` that wipes `docker logs`) and appends the final `docker inspect` state, so an OOM (`oom=true`, exit 137) is distinguishable from a crash or an external kill. Every per-connection goroutine is wrapped in a panic-recovering `guard()` (`proxy/guard.go`) — those handlers parse untrusted wire bytes, and an unrecovered panic in any goroutine crashes the whole Go process, so one malformed connection would otherwise take the proxy down.

**Knobs.** `SANDY_ALLOW_HOSTS` (privileged) appends allowlist entries (exact host, `*.suffix`, or `host:port` for CONNECT/SSH) — in strict mode the only hosts beyond defaults; in permissive mode LAN-exceptions reachable *despite* the private-IP block. `SANDY_EGRESS_LOG` (passive-safe: `0|1|summary`, default `0`) turns on the allow side, logging each **distinct** allowed `host:port` once (deduped, so a chatty agent cannot produce a gigabyte) and rolling `proxy.log` into a session-end summary — because by default the proxy logs denials only, so it could answer "what was blocked" and never "what did the agent reach", which is the first question after a suspected injection.

**Posture introspection**: the resolved posture is forwarded as `SANDY_EGRESS_MODE` (`off|permissive|strict`), informational only — the isolation is applied by the topology at launch, so changing the env var in-container does nothing. `SANDY_PROXY_IP` is present when the proxy is on.

**SSH interaction.** Under `--internal`, git-over-SSH tunnels through CONNECT (the entrypoint injects `Host * ProxyCommand socat - PROXY:<proxy-ip>:%h:%p,proxyport=3128`). On Linux the agent socket is a direct bind mount so signing keeps working; on **macOS** the agent socket relies on a host TCP relay the sidecar blocks, so agent *signing* is unavailable in proxy mode — sandy warns and suggests `SANDY_SSH=token`.

**`SANDY_SSH` modes**: `token` (default, `gh auth token` over HTTPS) or `agent` (Linux: direct socket mount; macOS: host-side `socat`/`python3` TCP relay plus an in-container `socat` relay).

## Protected Files

Sensitive workspace paths are bind-mounted read-only in-container, blocking shell-config injection, git hook injection, IDE config tampering, toolchain hijacking, CI pipeline escapes, and git filter-driver injection. The host filesystem is unaffected.

**Files**: `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile`, `.gitconfig`, `.ripgreprc`, `.mcp.json`, `.envrc`, `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml`, `.claude/settings.json`, `.claude/settings.local.json`

**Git files** (when present): `.git/config`, `.gitmodules`, `.git/packed-refs`. `.git/HEAD` is deliberately **not** protected as of 1.5.0 — see "Git branch work" above.

**Directories**: `.git/hooks/`, `.git/info/`, `.vscode/`, `.idea/`, `.github/workflows/`, `.circleci/`, `.devcontainer/`, `.claude/hooks/`, `.sandy/`

**Submodule gitdirs**: sandy walks `.git/modules/` (and the gitdir-side `modules/`) and mounts each submodule's `config`, `hooks/`, `info/` `:ro` — without this a planted `post-checkout` would execute on the host at the next `git submodule update`.

**`core.hooksPath`**: if it redirects hooks inside the workspace, sandy mounts the **configured** path `:ro` — canonicalizing only to verify containment, but locking the path git actually consults, so a *symlinked* hooksPath cannot be swapped for a fresh writable dir. A hooksPath outside the workspace, at its root, or already protected is left alone.

**Sandbox-mounted (writable overlays)**: `.claude/commands/`, `.claude/agents/`, `.claude/plugins/` — so Claude can create commands/agents/plugins without touching the host.

**Mount policy is existence-gated, symmetrically for files and dirs.** Host has the path → `:ro` bind mount (kernel-level, no host stub). Host lacks it → no mount, and the agent can create it during the session. This is a deliberate trade: the previous always-mount-with-fixture pattern left stub dirs all over the workspace every session, needed heroic cleanup, and was visible to `ls`/file managers/IDE scanners; for files it was worse — 0-byte stubs broke `direnv`, polluted `git status`, and tripped every presence check.

The replacement is **session-end detection**: sandy records which protected files and dirs existed at launch in `$SANDBOX_DIR/.protected-existed-at-launch` and walks the same paths at exit, reporting any new appearance as a yellow warning with a type-aware remediation. This covers the create-fresh cases the mounts cannot — including a `core.hooksPath` dir that did not exist at launch (`_sandy_configured_hooks_rel` resolves it existence-independently, with the same containment rules).

**Detection is weaker than prevention.** The window is "between session end and the user's next `git pull`/`checkout`/`push`/IDE-open"; a user who ignores the exit messages can still have a payload fire on the host. Conscious trade-off — prevention required the workspace pollution, and post-session warning suits the realistic threat model where the agent is wrong, not adversarial. Pre-existing empty stub dirs from older versions are still auto-cleaned at launch under a 4-condition gate (git repo, exact name match, empty, not git-tracked).

Intentionally **not** protected: package manifests (`Makefile`, `package.json`, `pyproject.toml`, `Cargo.toml`) — the agent legitimately edits these, and they are invoked by name rather than sourced on `cd` or filesystem scan.

**`SANDY_ALLOW_WORKFLOW_EDIT=1`** removes `.github/workflows/` from the list for a project (useful for legitimate CI work). Default off — a workflow escape fires on `git push`, long after the session ends.

**Long-term direction**: `fanotify` FAN_OPEN_PERM would give true prevention with no host pollution even for absent paths (real EPERM, works on Docker Desktop's Linux VM) but needs `CAP_SYS_ADMIN` during setup and careful supervisor logic. On the roadmap, unscoped pending evidence that detection-only is insufficient.

### Persistent symlink approval

Dangerous symlinks (absolute, or relative escapes via `..`) are surfaced at launch. First encounter prints a y/N listing each link and target; approval persists to `$SANDBOX_DIR/.sandy-approved-symlinks.list`. Afterwards: identical-or-reduced set → silent; **a new escape → hard error at launch**, naming the links, with remediation. Sandy refuses to re-prompt — a y/N that fires every session can be trained past; a hard error forces a deliberate action.

**Approvals resolve on the CLIENT's tty, before the fork (#221).** Container bring-up happens in the supervisor, whose stdin is `/dev/null`, so an approval encountered there is unanswerable — a workspace with an escaping symlink launched fine from a shell and failed under `--start`. The `SANDY_APPROVE_ONLY` pre-pass now resolves the dangerous-symlink approval too: it runs far enough to know `$SANDBOX_DIR` (where the list lives) while still exiting before the mutex, the busy-gate, and every image build; its one added side effect is a `mkdir -p "$SANDBOX_DIR"` the launch performs moments later anyway. A refusal stops `--start` with exit `6` instead of forking a supervisor certain to hit the same refusal. This fixes pty-based clients for free (sandy-ui spawns through node-pty, so `[ -t 0 ]` holds); genuinely non-TTY consumers still need `SANDY_AUTO_APPROVE_PRIVILEGED` or a pre-granted approval, and fail closed with the correct guidance plus a `.fatal` marker so the `--start` client fast-fails in ~1s rather than burning its readiness timeout.

## Security knobs

Each of these is documented at length in `docs/DESIGN-NOTES.md`; the security-critical ones also have dedicated documents under `docs/security/`.

### claude.ai account connectors (`SANDY_CLAUDE_CONNECTORS`, #129)

The Claude OAuth token sandy mounts is **account-scoped**, so every claude.ai account connector the user has ever enabled (Gmail, Drive, …) was silently reachable from **every** sandbox — ambient authority crossing the per-project boundary sandy exists to draw. Found in the field. **Connectors are suppressed by default**; `SANDY_CLAUDE_CONNECTORS=1` exposes them for one instance.

The mechanism is Claude Code's `disableClaudeAiConnectors`, seeded as a **managed** key, always overwritten **in both directions** — because its resolution is *any-source-true-wins*, so an inherited `true` from the host's settings would silently defeat the opt-in. Seeded in all three settings branches (node/jq/no-tool): a security default that varies by which tools happen to be installed is not a default. Tier is value-aware (`=1` is approval-gated from a workspace). **Two honest limits**: it gates **auto-fetched** connectors only (an explicit `--mcp-config` server still follows the normal MCP trust flow), and it is **Claude-only**. Defense in depth: `claudeAiMcpEverConnected` is stripped from the `.claude.json` seed regardless. Guarded by §110.

### Suspicious workspaces (`SANDY_SUSPICIOUS`, #130)

The mounted `.credentials.json` carries the **refresh token** — permanent renewable account access until manually revoked — and permissive-mode allowlists (pypi, github) are plausible exfil channels. `SANDY_SUSPICIOUS=1` is the hardened posture for a workspace you distrust:

- **Refresh token stripped** before mounting, so an exfiltrated copy dies at `expiresAt`. The strip is **verified after the rewrite** and **fails closed** — on any error, *no* credentials file is mounted rather than an unstripped one. Trade-off: in-session refresh stops working; relaunch or `/login`.
- **Disposable-key mode**: with `ANTHROPIC_API_KEY` set and no long-lived token, the OAuth file is not mounted at all.
- **Connectors forced off** (overriding an approved `=1`) and **egress defaults to strict**; an explicit egress choice still wins but is named loudly.

Passive-safe to turn **on** from a repo (a repo may declare itself suspicious); `=0` from a workspace is approval-gated. **Honest limits**: a long-lived `CLAUDE_CODE_OAUTH_TOKEN` is *not* shrunk (recorded honestly and warned about), it is Claude-only, and the access token stays exfiltrable for its remaining TTL. Real prevention is #121 (credential broker). Guarded by §112.

### Agent-layer tool-use audit (`SANDY_TOOL_AUDIT`)

Sandy is otherwise entirely the NDR side — it constrains the box and sees nothing of tool calls. `SANDY_TOOL_AUDIT=1` (passive-safe, default `0`) adds the EDR side: a `PreToolUse` hook running `/usr/local/bin/sandy-tool-audit`, appending one `{ts, tool, args}` JSONL line per call to `~/.claude/tool-audit.jsonl`. The seed uses the **same only-if-absent guard** as `statusLine`, so a user's own hook is never clobbered; the helper **always exits 0** (a non-zero `PreToolUse` would *block* the call) and truncates `tool_input` to 200 chars. **Two limits**: Claude-Code-only, and an audit hook running *inside* the box is not tamper-proof against a determined agent — it is instrumentation for the wrong-but-not-evil adversary. Guarded by §82.

### Cross-session inbound (`SANDY_CROSS_SESSION_INBOUND`, 1.10.0, experimental)

Maps onto Claude Code's receive-side `crossSessionInbound`, using its own values verbatim: `accept` (delivered with no prompt), `hold` (interactive approval, `[verified pid N]` attribution), `refuse` (sender sees "not accepting").

**Conditional default — load-bearing.** Unset resolves to `accept` iff `SANDY_HANDOFF_RELAY` is configured **and the relay will actually be started this launch**, else `refuse`. A relay needs `accept` to deliver; a workspace with no relay gets no open receive surface — and neither does a launch whose relay will not run. An explicit value always wins.

**Placement — measured, and it is two files.** A live probe against 2.1.251 found `accept` written to *either* workspace settings file is a **no-op**, byte-identical to absence: those files are tighten-only (`hold`/`refuse` DO apply). The only placements that deliver `accept` are Claude Code's **userSettings** and `--settings`. So sandy writes the same resolved value into both, every launch:

1. `$SANDBOX_DIR/claude/settings.json` (the container's `~/.claude/settings.json`) — the seam that makes `accept` deliver. RW in-container, so a compromised in-session agent could flip its own pin until the next launch (documented residual).
2. `$WORK_DIR/.claude/settings.local.json` — `:ro` in-container, where `hold`/`refuse` take effect and win over the userSettings copy. Writing `accept` here is a delivery no-op but overwrites any stale `hold`/`refuse` sandy wrote earlier, so the two files can never disagree because of sandy's own history.

Both writes are merge-preserving and idempotent, via node → jq → literal-match fallback; a file that is not a JSON object is left untouched with a warning. The workspace write runs before the `:ro` mount loop and the launch snapshot. Sandy **never** writes the host's `~/.claude/settings.json`.

**Two side effects, stated rather than hidden.** `$WORK_DIR/.claude/settings.local.json` persists on the **host**, so a later plain `claude` in that directory inherits whatever sandy resolved (tighten-only, so not new surface, but a real change outside any sandbox; `rm` it to opt out). And because that write populates `.claude/` before the empty-dir bookkeeping runs, a workspace that had no `.claude/` now keeps one permanently once claude is selected.

**Tier: value-aware.** `hold`/`refuse` are passive-safe and measured to be **real gates** — decided before the sender's in-band attestation is read, so a sender cannot talk past a configured value. `accept` from a workspace is approval-gated.

**Claude-only.** Nothing is written when claude is not in `SANDY_AGENT`. Full threat model, residuals, and the probe record: `docs/security/CROSS_SESSION_INBOUND.md`. Guarded by §114.

### Handoff directories (`SANDY_HANDOFF_DIRS`) and relay (`SANDY_HANDOFF_RELAY`)

`SANDY_HANDOFF_DIRS=1` (passive-safe, default `0`) mounts `$SANDBOX_DIR/handoff/outbox` rw at `~/.handoff/outbox` and `handoff/inbox` **`:ro`** at `~/.handoff/inbox`. The mount flag is the actual boundary — the container process runs as the host uid and owns both, so against a plain rw mount an in-container `chmod` would succeed (`chown` would not; the agent runs unprivileged via gosu with an empty capability set).

**Operator-side enable**: a `$SANDBOX_DIR/.handoff-enabled` marker file (contents ignored) ORs with the config key. It exists because a workspace `.sandy/config` **travels with the repository** — clone it elsewhere and the pair is enabled on a sandbox nobody decided about. The marker is per-machine, lives in state a repo cannot carry, and makes fleet enrollment 15 `touch`es instead of 15 git-repo edits. It is at the sandbox **top level, specifically not under `claude/`** (which is mounted rw at `~/.claude`, so a marker there would be one the *agent* could create for itself). Nothing bind-mounts the sandbox top level; §97 asserts that.

**Directory presence is deliberately NOT a trigger** — a stray `mkdir`, a restored backup, or an `rsync -a` would otherwise silently open a channel. The host directories are created on **every** launch as of 1.7.0, which makes *presence carries no information* true by **construction** rather than convention. Unmounted they are inert.

**Residual, stated rather than glossed**: `handoff/outbox` **persists across sessions**, so a committed passive `SANDY_HANDOFF_DIRS=1` lets a repo stage content today that a relay could deliver the day an operator approves one. That does not justify a privileged tier (the edge is on the relay key), but it imposes a requirement: **a relay should quarantine or ignore outbox content predating its own first run.** `--reset-sandbox` preserves `.handoff-enabled` (enrollment is operator state) but destroys `handoff/`.

`--print-state` reports `handoff_enabled` — the **marker only**, so `false` does not mean "off next launch" (a workspace key also enables it, and `--print-state` does not read workspace configs). Guarded by §86 and `test/acceptance-handoff-dirs.sh` (§23).

**`SANDY_HANDOFF_RELAY=<path>`** (privileged) is the mechanism that drains and fills those directories; sandy does not need to know what it does, only how it runs. It **implies `SANDY_HANDOFF_DIRS=1`** and mounts a third rw dir at `~/.handoff/relay` (state + `supervisor.log`).

- **Container-level, not a session child.** Started by `user-setup.sh` before the tmux session — a sibling of the tmux server, never a pane, never in any agent's ancestry. That out-of-ancestry position is exactly why it needs `crossSessionInbound` to deliver at all (`selfSent` would bypass the setting, but would also mean the relay dies with its session).
- **Singleton, restart-on-death.** `flock -n` on a tmpfs lock guarantees at most one supervisor loop; the lock fd is closed for the relay child (`9>&-`) so killing the loop releases it rather than stranding an orphaned holder. Backoff 1s doubling to 60s, reset after a run over 60s, never gives up. **What it does not guarantee**: an orphaned relay — `kill -9` of the loop releases the lock by design and the next start runs a second relay beside it. A relay needing exactly-once should take its own lock under `~/.handoff/relay/`.
- **A configured relay that cannot start FAILS THE LAUNCH (criterion 7)** — deliberately not the "degrade to a warning" posture, because the warning would leave the receive surface open (`accept`) with nothing delivering. Two detection points: **host-side**, sandy maps the path back to the host where it can (workspace-relative → `$WORK_DIR/<rel>`; absolute under `$SANDY_WORKSPACE/` → `$WORK_DIR/<rest>`) and exits 1 before `docker run`; **in-container**, for what the host cannot see (image-only path, unmounted `~/.handoff/relay`, no `flock`), it logs `ERROR:` and `exit 1`s so the container dies before any tmux session exists (`--start` reports crash-looping, exit 7). The `flock` check precedes the backgrounded subshell — inside it, `exit 1` would kill only the subshell. The `~/.handoff` collision is the same hard error. Note the ordering: the host-side path check runs **before** the skip decision below, so a broken path errors even on a launch that would not have started the relay.
- **Two deliberate skips, not failures (criterion 8)**: headless (`-p`) and **`sandy --remote`** (no tmux session to target, and a supervisor that never gives up would restart every 60s for the container's life). The host **unsets the key** with `SANDY_HANDOFF_RELAY not started (<reason>); crossSessionInbound will default to refuse`, so the default resolves to `refuse` and the marker records `handoff_relay: false`; the `SANDY_HANDOFF_DIRS=1` implication is kept. The in-container call site is gated on both conditions as belt-and-suspenders.
- **Path validation** (host-side): absolute or workspace-relative; rejects whitespace, shell metacharacters, and any `..`/`.`/empty segment.
- **Env contract**: `SANDY_HANDOFF_INBOX`/`_OUTBOX`/`_RELAY_STATE`. Honestly — they are exported in `user-setup.sh`'s own shell, so they also reach the tmux server and every pane, and the relay inherits the full container env including `CLAUDE_CODE_OAUTH_TOKEN` if present.
- **Session discovery**: `/usr/local/bin/sandy-handoff-sessions` emits `agent<TAB>pane_index<TAB>pane_pid<TAB>agent_pid<TAB>socket<TAB>keyfile` per live agent in `SANDY_AGENT` order, via the `@sandy_pane_agent` pane option. **It only enumerates; it does not pick** — a single-target relay should treat more than one `claude` row as an error it reports upstream, not silently take the first.
- **Daemon-mode lifetime**: the relay outlives individual sessions until the container is recreated; there is no in-container reaper. The mitigation is cadence, not detection — `sandy --update-sessions --yes` on a 24-hour cron. That bounds an *instance*, not a compromised *source*.

Marker field: `handoff_relay` — given criteria 7 and 8, `true` means the relay was started or the session never came up. Guarded by §114 and `acceptance-handoff-dirs.sh` Phase E.

## Forwarding env vars and agent args

### `SANDY_EXTRA_ENV`

Comma-separated env-var **names** to forward for user-installed MCP servers or in-container tooling sandy has no opinion on:

```sh
SANDY_EXTRA_ENV=HA_TOKEN,LINEAR_API_KEY   # ~/.sandy/config (privileged)
HA_TOKEN=ey...                            # ~/.sandy/.secrets, or the shell env
```

Value resolution: `env > workspace/.sandy/.secrets > workspace/.sandy/config > ~/.sandy/.secrets > ~/.sandy/config`. Env wins absolutely; among files workspace beats host, and within a tier `.secrets` beats `config`.

**The security boundary is on the names, not the values** — `SANDY_EXTRA_ENV` is privileged, so a workspace setting it triggers the approval prompt; once `HA_TOKEN` is approved the value may come from anywhere. Names must match `[A-Z_][A-Z0-9_]*`; names matching a sandy-recognized key are skipped (they have their own typed path); a listed name with no value warns but does not fail the launch.

### `SANDY_AGENT_ARGS`

Fixed extra CLI flags for the underlying agent on **every** launch — including `sandy -p`, `--start`, and programmatic callers like sandy-ui, which a shell wrapper cannot cover.

```sh
SANDY_AGENT_ARGS=--mcp-config .mcp.custom.json --some-experimental-flag value
```

- Resolved into per-agent env channels the container-side dispatcher prepends to each pane's command, so **by default every selected agent gets the same value**. Final order: sandy's own flags → `SANDY_AGENT_ARGS` (or the per-agent file) → command-line pass-through args, so an explicit CLI arg still wins.
- **Agent-agnostic is a footgun for agent-specific flags**: a Claude-Code-only flag here makes a `SANDY_AGENT=codex` launch print codex's usage banner and exit, which reads like a sandy fault and is not one. Not hypothetical — sandy's own `.sandy/config` failed the integration suite's codex section exactly this way. Put agent-specific flags in the per-agent file below.
- **Parsing (v1)**: whitespace-split into argv (`read -ra`), never `eval`'d, then `printf %q`-quoted downstream. **Embedded spaces / quoted args are not supported.**
- **Privileged tier** — arbitrary agent flags from a committed config are a real attack surface (`--dangerously-skip-permissions`, a hostile `--mcp-config`, `--add-dir` escapes). Headless/non-TTY drops it. **Headless-mode flags (`-p`/`--print`/`--prompt`) are dropped with a warning** — host-side headless detection runs before this injection, so a `-p` here would make the host launch interactive while the container went headless. Avoid `--continue`/`--new` here too.

### Per-agent override: `$SANDBOX_DIR/agent-args.<agent>`

The same capability from a place a git repository cannot reach (`agent-args.claude`, `.codex`, `.gemini`, `.opencode`, `.grok`).

- **Top level, deliberately** — `$SANDBOX_DIR/claude` is mounted rw at `~/.claude`, so a file there would be **agent-writable**, and an agent that can grant itself a flag can grant itself anything that flag allows. Asserted structurally by §106.
- **No new tier, no prompt**: `$SANDY_HOME` is already the privileged config root, so the file is privileged by construction of *where it lives* — like `.handoff-enabled`.
- **The sandbox file wins**, per agent, over `SANDY_AGENT_ARGS`. Sandy discards source attribution at the approval step, so it cannot tell where a surviving value came from; rather than guess or merge, it refuses the ambiguity — the file's tokens are used verbatim and a notice names the winning source. Values are **never concatenated**.
- **Empty or whitespace-only = absent** (the predicate is "any surviving token after filtering", never `[ -s ]`). Newlines are whitespace, so one argument per line works and every line survives. Mode flags are dropped with a warning naming the file.
- Per-pane isolation is the point: `agent-args.codex` never reaches the claude pane. `sandy --remote` is covered too. Files for an unselected agent are silently ignored (only `--print-state` surfaces them, via `agent_args_files` — presence only, not effective args). `--reset-sandbox` preserves them; `--remove-sandbox` names each in the plan and destroys them.

## Skill Packs

Optional Docker layers baking curated skill collections into the container. Not included by default.

```sh
SANDY_SKILL_PACKS=gstack
```

| Pack | Description | Source |
|------|-------------|--------|
| `gstack` | 28 Claude Code skills (QA, review, ship, browse, …) + headless Chromium | [garrytan/gstack](https://github.com/garrytan/gstack) |

Two build phases sit between the agent image and the per-project image: **2.5a** (`sandy-skills-base-{pack}`) installs heavy, rarely-changing deps (Playwright, Chromium) and rebuilds only when its Dockerfile changes; **2.5b** (`sandy-skills-{pack}`) fetches the pinned source and builds, rebuilding on a new version but fast because Chromium is already cached. At startup `user-setup.sh` symlinks `/opt/skills/{pack}/` into `~/.claude/skills/` and adds pack `bin/` dirs to PATH.

**Version resolution** happens per launch, with no hardcoded pin: GitHub releases API (latest non-draft/non-prerelease matching the pack's tag prefix, 5s timeout) → GitHub commits API → local cache `~/.sandy/.skill_version_{pack}` → the `SKILL_PACK_VERSIONS` fallback array. A new version regenerates `Dockerfile.skills`, changing its hash and triggering only the 2.5b rebuild.

**gstack state** lives at `<workspace>/.gstack/` on the host (workspace-scoped, beside `.git/`), auto-created at launch, with a one-line warning if it is not gitignored. Pre-0.12 sandy used `$SANDBOX_DIR/gstack/`; the first launch after upgrading `cp -a`s it over and renames the legacy dir to `gstack.migrated/` (manual cleanup once confirmed).

**Adding a pack**: entries in `SKILL_PACK_NAMES`, `SKILL_PACK_REPOS`, `SKILL_PACK_VERSIONS`, `SKILL_PACK_TAG_PREFIXES`, plus a build recipe case in `generate_skill_pack_dockerfiles()`.

## Workspace mounts and misc

**Workspace mount path**: mounted at a path mirroring the host's `$HOME`-relative location — `~/dev/sandy` → `/home/claude/dev/sandy`. Outside `$HOME` it falls back to the real host path. Passed as `SANDY_WORKSPACE`.

**Git submodules**: sandy detects the `.git` file (vs directory), resolves the relative gitdir, and mounts both worktree and gitdir at the correct container paths using the same mapping to preserve the relative relationship.

**Screenshots / `/ss`**: `SANDY_SCREENSHOT_DIR=<host-path>` (privileged) mounts a host screenshot folder `:ro` at `/home/claude/screenshots`, exposed as `$SANDY_SCREENSHOTS_PATH`, and generates a per-agent `/ss` surface at sandbox setup (claude: `~/.claude/commands/ss.md`; gemini: `~/.gemini/commands/ss.toml`; codex: a description-matched skill; opencode: manual). All are powered by `/usr/local/bin/sandy-ss-paths`, callable from any agent's bash escape. Validation rejects shell metacharacters and overly-broad targets (literal `$HOME`, `/`); a non-existent directory is warn-and-skip, so Docker never auto-creates an empty stub on the host. No default — unset disables the feature entirely.

**Status lines** — two, at different scopes because neither can do the other's job. The **outer tmux bar** is launch/session-scoped, rendering live from env via `#{E:VAR}` (egress posture color-coded, agents, project, attached-client count, daemon/session marker, clock); window-status is blanked since sandy sessions are multi-*pane*. The **inner Claude Code `statusLine`** is live and per-request — model, effort, context% — which the outer bar structurally cannot show, since that is Claude Code's own state fed on stdin per render. Sandy seeds it to `/usr/local/bin/sandy-claude-statusline` in all three seeding branches with an **only-if-absent guard**, and the helper falls back to a bare `sandy` line on any malformed input rather than erroring the TUI.

**Terminal notifications**: inner tmux sets `allow-passthrough on`, forwarding OSC 9/99/777 from Claude Code to the outer terminal (cmux, iTerm2). Host-side `~/.claude/hooks/` is mounted `:ro` into the container so host-configured hooks work without duplication.
