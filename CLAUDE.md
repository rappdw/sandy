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

Since Claude Code running inside sandy cannot access Docker, running tests requires the user to execute them manually on the host. When making changes to the `sandy` script or tests, ask the user to run the test suite and share the results.

See `TESTING_PLAN.md` for manual validation steps that require interactive TUI sessions.

## Introspection Surface

Sandy exposes three machine-readable JSON flags that run as **fast-path handlers** — they exit before Docker, image builds, and workspace mutex acquisition, so they're cheap to call from UI frontends, CI, and non-interactive contexts:

- `--print-schema` — static schema: sandy version, config keys by tier (with type, default, description), CLI flags, agents + credential probe orders, protected path lists, skill packs, schema compatibility declaration (`schema_version: 1`).
- `--print-state` — runtime state: installed images, per-sandbox metadata, approval files, `docker_reachable`, running sandy containers (filtered by image name prefix). Gracefully reports `docker_reachable: false` when docker is absent.
- `--validate-config PATH` — parses a config file, classifies it by path as privileged (`$SANDY_HOME/…`) or passive (anywhere else), and reports errors, unknown keys, privileged-from-passive keys that require approval, and the target approval file path. Exit 0 on success (including "approval pending"), 1 only for file-not-found or missing-argument.

See `SPEC_INTROSPECTION.md` for the stability contract and field-by-field JSON schema. When adding a new config key to `SANDY_PRIVILEGED_KEYS`, `SANDY_PASSIVE_KEYS`, or `SANDY_ENV_ONLY_KEYS` in the sandy script, also add a row to the `_sandy_key_metadata` heredoc (pipe-separated `key|type|default|pattern|description`) so it appears in `--print-schema` output, then run `test/regen-config-docs.sh` to propagate the change into the `SPECIFICATION.md` and `CLAUDE.md` config tables.

## Self-Attestation Marker

On every launch (all egress modes), sandy writes `$SANDBOX_DIR/sandy-session.json` and bind-mounts it **read-only** at `/etc/sandy-session.json` inside the container. It is the single authoritative, in-container signal that the agent is genuinely running inside sandy and at what isolation level:

```json
{ "schema": 1, "sandy_version": "...", "egress_mode": "off|permissive|strict",
  "workspace": "...", "host_uid": 501, "host_gid": 20,
  "launched_at": "2026-06-11T12:00:00Z", "session_nonce": "<hex>" }
```

**Why it exists.** Env vars (`SANDY_EGRESS_MODE`, `SANDY_WORKSPACE`) are spoofable and the *absence* of a path proves nothing, so an in-container probe that distrusts env vars otherwise cannot tell a sandy container apart from the bare host VM — the `sandy-isolation-test` red-team hit exactly this, running in sandy `=0` on macOS/OrbStack but concluding it was not in sandy at all (uid `501`, OrbStack `mac` virtiofs mounts, and `CapBnd` retaining sandy's documented `--cap-add` set all read as "ordinary VM" without an anchor). Because the marker is a `:ro` bind mount, a committed workspace config cannot forge it.

**Tamper-evidence.** `session_nonce` is freshly generated each launch (`openssl rand`, falling back to `/dev/urandom`) and forwarded out-of-band: it is printed host-side under `SANDY_VERBOSE=1` so an external verifier (a test harness, CI) can confirm the file's nonce matches the launch it expects. The nonce is deliberately **not** exported as an env var — the read-only file is the trust root, env is not. In-container tooling should assert on this file, not on uid/caps/env heuristics (which is what misfired in the red-team run). The launcher writes the file at the same point it forwards `SANDY_EGRESS_MODE` (Appendix E); the JSON schema is in Appendix C.

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
  `SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `SANDY_LOCAL_LLM_HOST`, `SANDY_ALLOW_HOSTS`, `SANDY_EXTRA_ENV`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `SANDY_SCREENSHOT_DIR`, `SANDY_GEMINI_EXTENSIONS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`
  <!-- END AUTOGEN:privileged-key-list -->

  These would let a malicious `.sandy/config` committed to a repo disable isolation or exfiltrate credentials, so sandy collects them, prints the exact `KEY=VALUE` set, and asks for explicit approval before honoring them. Approvals are persisted to `$SANDY_HOME/approvals/passive-<workspace-hash>.list` (first line is a sha256 of the sorted `KEY=VALUE` set). Subsequent launches with the same set are silent; any edit to `.sandy/config` that changes a privileged key re-prompts. Revoke with `rm $SANDY_HOME/approvals/passive-<hash>.list`. Headless mode (`-p`/`--print`/`--prompt`) and non-TTY stdin fail closed — the keys are dropped with a pointer to "launch sandy interactively once from this directory to approve."

  **CI / test harness escape hatch:** set `SANDY_AUTO_APPROVE_PRIVILEGED=1` in the environment (not in any config file) to bypass the prompt entirely and export all collected passive privileged keys in-memory. This is intentionally env-only — the passive config allowlist does not include `SANDY_AUTO_APPROVE_PRIVILEGED`, so a committed `.sandy/config` cannot set it. Only a trusted shell or test harness can. Sandy's own `test/run-tests.sh` and `test/run-integration-tests.sh` set this because they run from the sandy repo directory, which has its own `.sandy/.secrets` with `GEMINI_API_KEY`.

- **Passive-safe keys** (allowed from any source):
  <!-- BEGIN AUTOGEN:passive-key-list Run `test/regen-config-docs.sh` to update. -->
  `SANDY_AGENT`, `SANDY_MODEL`, `SANDY_CPUS`, `SANDY_MEM`, `SANDY_GPU`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS`, `SANDY_CHANNEL_TARGET_PANE`, `SANDY_VERBOSE`, `SANDY_VENV_OVERLAY`, `SANDY_EGRESS_PROXY`, `SANDY_EGRESS_NO_ISOLATION`, `SANDY_EGRESS_STRICT`, `SANDY_ALLOW_WORKFLOW_EDIT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `GEMINI_MODEL`, `SANDY_GEMINI_AUTH`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI`, `CODEX_MODEL`, `SANDY_CODEX_AUTH`, `OPENCODE_MODEL`, `SANDY_OPENCODE_AUTH`
  <!-- END AUTOGEN:passive-key-list -->

- **Value-aware exceptions** (passive for values that *strengthen* isolation, approval-gated for values that *weaken* it): a few passive keys are not uniformly safe from a committed `.sandy/config` because one of their values lowers the sandbox's protection. `_sandy_passive_value_privileged()` routes those weakening values through the same per-workspace approval prompt as a privileged key, while leaving the strengthening/neutral values frictionless — *"a repo may make the sandbox tighter, never looser."* The gated values are: `SANDY_EGRESS_NO_ISOLATION=1` (proxy off), `SANDY_EGRESS_STRICT=0` (downgrade a host-set strict), `SANDY_EGRESS_PROXY=0` (deprecated alias for proxy-off), and `SANDY_ALLOW_WORKFLOW_EDIT=1` (drops `.github/workflows/` protection). This closes the hole where a committed workspace config could silently disable network isolation (threat-model adversary #2) — on macOS with the proxy off that is *total* loss of network isolation. Guarded by `run-tests.sh §65`.

Additionally, `SANDY_ALLOW_LAN_HOSTS` is validated at use-site to reject world-open entries (`0.0.0.0/0`, `::/0`) with a hard error at launch — even when set from a privileged source.

## Agent Selection

Sandy supports Claude Code (default), Gemini CLI, OpenAI Codex CLI, OpenCode (sst/opencode), or **any combination side-by-side in multi-pane tmux**, selectable per-project via `SANDY_AGENT` in `.sandy/config`:

```sh
SANDY_AGENT=gemini                      # single agent: claude (default), gemini, codex, opencode
SANDY_AGENT=claude,codex                # any comma-separated combo (2–4 agents)
SANDY_AGENT=claude,gemini,codex,opencode # all four in a 4-pane layout
SANDY_AGENT=all                         # alias for claude,gemini,codex,opencode
```

Single-agent modes use their own Docker images (`sandy-claude-code`, `sandy-gemini-cli`, `sandy-codex`, `sandy-opencode`); multi-agent combos use `sandy-full` (which includes all four agents). All share the common `sandy-base`. Gemini CLI, Codex CLI, and OpenCode are installed via `npm install -g @google/gemini-cli`, `npm install -g @openai/codex`, and `npm install -g opencode-ai` respectively. Gemini launches with `GEMINI_SANDBOX=false`; Codex launches with `--sandbox danger-full-access` plus `sandbox_mode = "danger-full-access"` in its `config.toml` (belt-and-suspenders — codex's Landlock sandbox does not nest cleanly in Docker, and sandy already provides whole-session isolation). The sandbox directory has sibling `claude/`, `gemini/`, `codex/`, and `opencode/` subdirs. The first three mount at `~/.claude`, `~/.gemini`, and `~/.codex`; OpenCode straddles two XDG paths and uses `opencode/{config,share}` mounting at `~/.config/opencode` and `~/.local/share/opencode` respectively. v1 layouts with `settings.json` at the sandbox top level are auto-migrated on launch.

**Gemini credentials** are probed in this order (override via `SANDY_GEMINI_AUTH=auto|api_key|oauth|adc`): `GEMINI_API_KEY` env var, host `~/.gemini/tokens.json` (copied ephemerally), host `~/.config/gcloud/application_default_credentials.json` (Google ADC / Vertex AI).

**Codex credentials** are probed in this order (override via `SANDY_CODEX_AUTH=auto|api_key|oauth`): `OPENAI_API_KEY` env var (materialized as an ephemeral `auth.json` mounted **read-only** — codex 0.139+ no longer reads the env var for first-party auth, so sandy writes what `codex login --with-api-key` would write), host `~/.codex/auth.json` (copied ephemerally and mounted **read-only** — prevents token leakage back to host and prevents stale-token races). Because `auth.json` is mounted read-only, in-session OAuth refresh will fail — users must re-login inside the container if the token expires. On first launch, sandy seeds `~/.codex/config.toml` with `model = "gpt-5.5"`, `sandbox_mode = "danger-full-access"`, and a full `[notice]` block to suppress all first-run prompts; a `[projects."$SANDY_WORKSPACE"] trust_level = "trusted"` entry is appended at session start by `user-setup.sh` (it needs the container-side workspace path).

**OpenCode credentials** are provider-agnostic — opencode reads `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY`, etc. natively from the env, and sandy forwards whichever the user has set. The OAuth path mounts host `~/.local/share/opencode/auth.json` read-only when present (override the probe with `SANDY_OPENCODE_AUTH=auto|api_key|oauth`). OpenCode's flexibility is what makes the **local-LLM passthrough** below useful — point the config at a local Ollama/vLLM endpoint and pair with `SANDY_LOCAL_LLM_HOST`.

**OpenCode config seeding.** Provider/model selection lives in `~/.config/opencode/opencode.json`. On every new sandbox creation sandy resolves three input states in order:

1. **Host config exists** at `~/.config/opencode/opencode.json` → sandy seeds it into the sandbox. Subsequent in-container edits persist via the bind mount; host-side changes are picked up on the next sandbox creation.
2. **No host config but `SANDY_LOCAL_LLM_HOST` is set** → sandy auto-generates a starter `opencode.json` from a `curl http://${SANDY_LOCAL_LLM_HOST}/v1/models` probe (jq if available, regex fallback otherwise). The generated config defines a `local` provider via `@ai-sdk/openai-compatible` pointing at `http://host.docker.internal:<port>/v1`, registers the served model id, and pins it as the default. To customize, copy the generated file to `~/.config/opencode/opencode.json` — the next sandbox creation will then prefer the host file (state 1).
3. **Neither** → opencode would silently fall back to its built-in default model (currently `gemini-3-pro-preview`), which fails confusingly on first request without `GOOGLE_GENERATIVE_AI_API_KEY`. Sandy warns loudly at launch with the three possible fixes (set an API key, write the config, or set `SANDY_LOCAL_LLM_HOST`) but proceeds — opencode may still succeed if the user has another auth path the warning didn't anticipate.

**Local-LLM passthrough.** Sandy normally blocks all RFC 1918 (LAN) traffic. To let an in-container agent (typically OpenCode) reach a local LLM server on the Docker host without disabling that posture, set `SANDY_LOCAL_LLM_HOST=<ip>:<port>` (e.g. `127.0.0.1:11434` for Ollama). Sandy validates the format, rejects world-open IPs (`0.0.0.0`, `::`) and out-of-range ports, then inserts a single `iptables ACCEPT` rule limited to that exact `host:port` against the Docker bridge gateway. On Linux it also adds `--add-host=host.docker.internal:host-gateway` so the hostname resolves (Docker Desktop does this automatically on macOS, but Linux daemons require explicit mapping). Tweak the user's `~/.config/opencode/opencode.json` to set the provider's `baseURL` to `http://host.docker.internal:<port>/v1`. Macros and `SANDY_ALLOW_LAN_HOSTS` remain orthogonal — `SANDY_LOCAL_LLM_HOST` is a single narrow opening for the localhost LLM use-case, not a general LAN unblock.

**Feature support by agent**:

| Feature | `claude` | `gemini` | `codex` | `opencode` | multi-agent |
|---|---|---|---|---|---|
| Skill packs | yes | — | — | — | yes (claude pane only) |
| Synthkit commands | yes (slash commands, Markdown) | yes (slash commands, TOML in `~/.gemini/commands/`) | yes (skills context, SKILL.md in `~/.codex/skills/`) | — (v0) | per agent |
| Channels (Telegram) | in-container plugin | host-side tmux relay | host-side tmux relay | host-side tmux relay (untested in v0) | host-side tmux relay |
| Channels (Discord) | yes | — | — | — | — |
| `--remote` | yes | — | — | — | — |
| Gemini extensions (`SANDY_GEMINI_EXTENSIONS`) | — | yes | — | — | yes (when gemini is in the combo) |
| Local-LLM passthrough (`SANDY_LOCAL_LLM_HOST`) | — | — | — | yes | yes (when opencode is in the combo) |
| Provider choice via own config | — | — | — | yes | — |

Codex headless mode (`-p` / `--print` / `--prompt`) translates to `codex exec --skip-git-repo-check` — the prompt is passed as a positional arg, not a flag, and the trust/git-repo gate is skipped (codex 0.139+ refuses `exec` outside a trusted dir or git repo; sandy provides the outer isolation). OpenCode headless mirrors that pattern: `opencode run <prompt>`. Both `exec` and `run` only support `0`/`1` exit codes (no nuanced codes like Claude's `--print`). `--continue` / `-c` is silently dropped for both (neither has a headless continuation flag). Multi-agent combos use comma-separated syntax (e.g., `claude,codex`); `all` is an alias for `claude,gemini,codex,opencode`. The old `both` alias was removed in `v0.12` — sandy now errors out with a pointer to the comma-separated syntax.

The Telegram host-side relay (`$SANDY_HOME/channel-relay.sh`) is an agent-agnostic long-polling bridge that injects messages into the container's tmux session via `docker exec ... tmux send-keys`. In multi-agent mode, `SANDY_CHANNEL_TARGET_PANE=0|1|2` selects which pane receives messages (default `0` = first pane in `SANDY_AGENT`).

## Per-project Sandboxes

Each project directory gets its own isolated `~/.claude` sandbox under `~/.sandy/sandboxes/`, named with a mnemonic prefix and hash (e.g. `myproject-a1b2c3d4`). The hash is over the workspace path canonicalized via `pwd -P` (resolves symlinks and folds case-collisions on case-insensitive filesystems like default macOS APFS), so `cd et` and `cd ET` from the same parent directory produce the same sandbox. Each launch writes `$SANDBOX_DIR/WORKSPACE.json` (non-hidden, visible in plain `ls`) recording the canonical workspace path, the user-typed path (when different — i.e. case-collision or symlink), first/last launch timestamps, and first/last sandy versions. On launch, sandy scans sibling sandboxes for matching `workspace_path` (with a legacy heuristic for sandboxes pre-dating the marker) and warns when duplicates are found — manual cleanup only, no auto-merge. `.claude.json` is seeded from the host's `~/.claude/` on first run. `settings.json` is regenerated on **every launch** at `$SANDBOX_DIR/claude/settings.json` (inside the rw sandbox mount) with merge-preserving semantics: sandy re-reads the host copy every launch so host-side edits propagate, but preserves `enabledPlugins` from the previous sandbox session so `/plugin install` survives across launches. The file is rw inside the container — the stricter `:ro` sidecar approach from pre-0.11.3 broke plugin installs with EROFS, so it was reverted. The trade-off: the agent *can* mutate its own settings within a session, but the sandy-managed keys (`extraKnownMarketplaces`, `teammateMode`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, `permissions.defaultMode`, cmux hooks) are re-overwritten every launch. Credentials (`.credentials.json`) are read fresh from the host each launch and mounted ephemerally — never persisted to the sandbox.

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

**Non-standard venv names** (`venv/`, `.venv-py311/`, etc.) are not overlaid — only the standard `.venv/` is. The fallback warn-only path still applies to any dangling `.venv/bin/python` symlink in those layouts.

**Host venv is never touched.** The overlay is a shadow — the host filesystem is untouched by sandy. After sandy exits, the host's `.venv/` is exactly as it was before.

**Concurrent launches.** Only one sandy may run against a given workspace at a time. On launch, sandy takes a workspace mutex (`mkdir` on `$SANDY_HOME/sandboxes/.<name>.lock`, which is atomic on every POSIX filesystem and needs no external dependency) and writes its PID into `$LOCK/pid`. A second launch against the same workspace reads that PID and probes liveness via `kill -0`: if the holding process is still running, sandy fails fast with a clear error naming the pid; if the PID is gone (e.g. after a `kill -9` or OOM), sandy auto-clears the stale lock and proceeds. PID reuse is theoretically possible — if the OS recycled the PID to an unrelated process, `kill -0` says "alive" and sandy errors out (false positive); the user clears manually. That's the safer default than a false negative that clobbers an active session. The introspection surface (`sandy --print-state`) reports `lock_holder_alive: true|false|null` per sandbox so external tools can see the same view. Two agents editing the same codebase would step on each other's edits anyway — use separate workspaces for parallel work.

## Daemon Mode (`--start` / `--attach` / `--stop`, milestone 1.1.0, #17)

Decouples a session's lifetime from the launching client, so a session survives a closed terminal / VSCode quit and can be reattached later. Additive: bare `sandy` is byte-unchanged (every daemon branch is gated on `SANDY_START` / `SANDY_ATTACH` / `SANDY_STOP` / `SANDY_DAEMON_SUPERVISOR` / the container-side `SANDY_DAEMON`).

**Architecture — "the container is the daemon; a host-side supervisor owns the lock+helpers+trap."** `sandy --start` forks a detached **supervisor** (`nohup … & disown` — deliberately *not* `setsid`, which is util-linux and absent on macOS, daemon-mode's primary platform) which re-execs sandy with `SANDY_DAEMON_SUPERVISOR=1`. The supervisor acquires the workspace lock with *its own* PID (keeping the #14 PID-owned lock model), builds `RUN_FLAGS` with a **detached** container (`-d --restart unless-stopped --name sandy-<sandbox>`, and crucially **no `--rm`** — docker rejects `--rm` with `--restart`; removal is done by `cleanup()`/`--stop`), spawns the helper processes (SSH/channel relays, egress proxy + its `docker logs -f` streamer) as its children, installs the normal cleanup trap, then blocks on a bounded-sleep wait loop (`while :; do sleep 300 & wait $!; done` — NOT `sleep infinity`, a GNU coreutils extension that BSD/macOS sleep rejects with an instant usage error, which would drop the supervisor straight into its EXIT trap and tear the fresh daemon down; guarded by `run-tests.sh §70`). Container-side, when `SANDY_DAEMON=1` the entrypoint creates the tmux session detached and `exec tail -f /dev/null` instead of `tmux attach`. The `--start` client streams the supervisor log and exits `0` only once `docker exec <c> tmux has-session -t sandy` succeeds.

**State = container labels** (not a state file — survives sandy upgrades, can't drift from docker): `sandy.daemon=true`, `sandy.workspace_path`, `sandy.session=<sandbox-name>`, `sandy.started_at`, `sandy.daemon_pid=<supervisor pid>`.

**D9 — container existence is the durable source of truth; the lock is the live-operation guard.** A running labeled daemon container = "this session exists," *even with no supervisor* (after a reboot, `--restart unless-stopped` resurrects the container on the same fixed proxy IP but the supervisor does not come back). So idempotency (`--start`), the busy-check (bare `sandy`, `--attach`), and `--stop` all key off the **container**, not lock/supervisor liveness. `--start` refuses headless (`-p`/`--print`/`--prompt`) — a one-shot under `--restart unless-stopped` would restart-loop.

**Decisions (documented for the `sandy-ui` consumer contract):**
- **DEC-A — concurrent attach = last-wins** via `tmux attach -d` (a second client cleanly displaces the first; the displaced client exits `3`). Never plain `tmux attach` (that mirrors — the one banned outcome).
- **DEC-B — bare `sandy` over a live daemon session = error-with-hint + exit `1`** (points at `--attach` / `--stop`); keyed off the container label so a supervisor-less rebooted session is respected, not clobbered.
- **DEC-C — exit codes.** `--attach`: `0` = session ended while attached, `3` = clean detach (session lives), `4` = no such session, `5` = attach failed. `--stop`: `0` = stopped, `4` = no such session, `5` = teardown failed. A client attached when `--stop` runs elsewhere sees the container vanish → exits `0`.

**`--stop` interplay with the #14 lock:** if the supervisor PID is alive, `--stop` signals it (`kill -TERM`) so the supervisor's *own* trap releases the lock (nothing else ever removes a live-owned lock). If the supervisor is dead (D9 reboot case), `--stop` tears the container/networks down directly and reaps the now-stale lock (whose holder PID is provably dead). This is the only unavoidable cleanup duplication, bounded to container+network+lock.

**Introspection:** `--print-schema` `cli_flags` includes `--start`/`--attach`/`--stop` (a consumer feature-detects daemon support on their presence). Each `--print-state` `running_containers[]` entry carries `sandbox` (the `sandboxes[].name` join key), `daemon` (bool), and `attached_clients` (int|null tmux client count). All additive — `schema_version` stays `1`.

**Verification reality:** daemon-mode is a Docker-runtime feature; the automated suite covers static/structural/introspection contract only. The end-to-end container lifecycle (survival across abrupt client kill, helper reparenting, `--stop` teardown) is a host gate — `test/acceptance-daemon.sh` runs the full scenario and must pass on a real Docker host before release.

## Architecture

- **Three-phase Docker build**: A `sandy-base` image contains the OS, toolchains (Node.js 22, Go 1.24, Rust stable, Python 3, C/C++), and system tools. A `sandy-claude-code` image layers Claude Code on top. An optional per-project image (from `.sandy/Dockerfile`) layers project-specific tools on top of that. Each phase only rebuilds when its inputs change.
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

On each launch, sandy checks for newer Claude Code versions by comparing the installed version against the latest release. If an update is available, the image is rebuilt with `--no-cache`. Inside the container, `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates against the read-only filesystem.

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

The base image ships with fixed versions of each toolchain: Python 3 (Debian bookworm's default), Node.js 22, Go 1.24, Rust stable, and C/C++ (build-essential). `uv` is also pre-installed for Python version management.

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

The base image includes a single system Python (whatever Debian bookworm ships). For projects that need a specific Python version, use `uv`:

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

**Proxy self-heal on death (`--restart on-failure:5`).** The proxy is the agent's only route off the `--internal` sidecar, so a mid-session proxy death (crash, OOM, a Docker/OrbStack reap) would otherwise strand the agent — every request `FailedToOpenSocket` — until the next launch. The proxy launches with `--restart on-failure:5` so the daemon resurrects it; because the sidecar leg is pinned with a fixed `--ip`, the restarted container comes back on the **same address** and the agent's `--dns`/route stay valid, so it recovers without a session restart. Bounded to 5 so a genuinely broken (crash-looping) proxy still gives up and is caught by the readiness gate. `cleanup()` force-removes the proxy regardless of policy, so there's no zombie on exit. The readiness gate polls `.State.Running` (rather than a single instantaneous check) so it catches a start-then-die proxy and tolerates a transient mid-restart read; a non-zero `RestartCount` after startup is surfaced as a crash-loop warning. This is distinct from — and complementary to — the atomic teardown below: restart-policy handles the proxy dying under a *live* agent; teardown handles the agent outliving a *killed session*.

**Diagnosing a proxy death.** Two mechanisms answer "why did the proxy die." (1) Sandy streams the proxy's logs to `$SANDBOX_DIR/proxy.log` (background `docker logs -f`, reaped in `cleanup()`) — this **survives** the `docker rm -f` that wipes `docker logs`, and `cleanup()` appends the container's final `docker inspect` state so an OOM (`oom=true`, exit 137) is distinguishable from a crash (non-zero exit + stack) or external kill. (2) The proxy binary wraps every per-connection goroutine (`transparent`/`connect`/`forward`) in a panic-recovering `guard()` (`proxy/guard.go`): an unrecovered panic in any goroutine crashes the whole Go process, and those handlers parse untrusted wire bytes (TLS ClientHello / HTTP Host), so without it one malformed connection would take the proxy down. `guard()` `recover()`s, logs the panic value + stack (which then lands in the persisted log), and drops just that connection — mirroring what `net/http`'s Server does per request. So a panic is now both *survived* and *recorded*. Guards: `run-tests.sh §57`, `proxy/guard_test.go`.

**Atomic agent+proxy teardown (prevents the stranded-agent failure).** `cleanup()` force-removes the **agent container first**, then the proxy and networks. This matters because the agent runs `docker run --rm` in the *foreground* but the container's lifetime belongs to the daemon, not the `docker run` client: if that client is killed without the container stopping (closed terminal, killed session, dropped SSH, SIGHUP), the daemon keeps the agent running. Were `cleanup()` to remove only the proxy + egress route (as it did before this fix), the still-running agent would be left **stranded on a routeless `--internal` sidecar** — every API request failing with `FailedToOpenSocket`, with no recovery until the next launch (`docker ps` shows the tell: an `sandy-<sandbox>` agent `Up` with no matching `sandy-proxy-<sandbox>`). The orphan-on-client-kill is old, but the egress-proxy default (0.14.0) turned it from a harmless orphan (which still had a working bridge + internet) into a fatal one. Removing the agent in `cleanup()` makes the two teardowns atomic and also lets the sidecar `network rm` succeed instead of leaking the subnet. Regression-guarded by `run-tests.sh §55`.

**Proxy listeners** (Go binary, `golang`→`scratch` image, `--read-only --cap-drop ALL`): DNS (UDP 53, redirect/deny, refuses HTTPS/SVCB records to keep SNI readable), transparent `:443` (SNI demux, TLS never terminated), transparent `:80` (Host demux), CONNECT `:3128` (for git-over-SSH), and an optional local-LLM forward. Permissive mode resolves-then-checks the destination, which also defeats DNS rebinding (a name resolving public+private dials only the public IP; all-private is refused). The proxy never terminates TLS, never logs payload, never caches.

**Non-TCP transports (the proxy is TCP-only — by design).** The proxy speaks only TCP (DNS/53, 443, 80, CONNECT). It deliberately does **not** proxy UDP/QUIC/ICMP, because it doesn't need to: the `--internal` network is the backstop, and `--internal` is an **L3, protocol-agnostic** drop (a `FORWARD`-chain DROP on the bridge, no `MASQUERADE`). So all non-TCP egress off the sidecar is dropped before it reaches the proxy — raw UDP, **QUIC/HTTP-3 over UDP/443** (which would otherwise bypass the SNI-reading TCP proxy), ICMP, and IPv6 (the networks are `--ipv6=false`). Non-TCP **fails closed**: QUIC to an allowed host can't reach the proxy's (TCP) listeners and the client falls back to TCP-through-proxy; raw UDP/DNS to an external resolver is dropped (so no DNS tunnel). **Verified on macOS Docker Desktop 2026-06-11** (UDP-to-public-resolver, UDP/443, all blocked; no IPv6 route) and guarded by `test/spike/macos-internal-network-spike.sh` (A1d) + a Linux check in `run-integration-tests.sh` (§13b). A future refactor must not make the proxy the *only* egress mechanism without re-adding a non-TCP block, or this invariant regresses.

**Posture introspection.** The resolved egress posture is forwarded into the container as **`SANDY_EGRESS_MODE`** (`off` | `permissive` | `strict`) so in-container tooling, tests, and the agent can read their own isolation level. It is informational only — the isolation is applied by the network topology at launch, so changing the env var inside the container has no effect. (`SANDY_PROXY_IP` is also present when the proxy is on, used by the ssh `ProxyCommand`.)

**`SANDY_ALLOW_HOSTS`** (privileged-tier): comma-separated extra allowlist entries (exact host, `*.suffix` wildcard, or `host:port` for CONNECT/SSH), appended to the default set. In strict mode these are the only hosts reachable beyond defaults; in permissive mode they are LAN-exceptions reachable *despite* the private-IP block (e.g. an internal registry, or `host.docker.internal:<port>` for a local LLM). Privileged tier so a committed workspace config can't silently widen reach without the approval prompt.

**SSH-agent interaction.** Under `--internal`, git-over-SSH tunnels through the proxy's CONNECT listener — the entrypoint injects a `Host * ProxyCommand socat - PROXY:<proxy-ip>:%h:%p,proxyport=3128` into `~/.ssh/config`. On Linux the SSH-agent socket is a direct bind mount, so agent signing keeps working. On macOS the agent socket relies on a host TCP relay that the sidecar blocks, so agent *signing* is unavailable in proxy mode (git-over-SSH still works); sandy warns and suggests `SANDY_SSH=token` (HTTPS through the transparent `:443` path) for a fully-supported path.

**Local LLM.** With the proxy on, `SANDY_LOCAL_LLM_HOST` is served by the proxy's forward listener (not an iptables hole): the agent reaches `host.docker.internal:<port>`, the proxy DNS points that name at itself, and the forward listener relays to the real host. `host.docker.internal` is auto-allowlisted in strict mode and mapped for the proxy container on Linux.

## Protected Files

Certain sensitive files and directories in the workspace are mounted read-only inside the container to prevent modification by the agent. This blocks shell config injection, git hook injection, IDE config tampering, language-toolchain hijacking, CI pipeline escapes, and git filter-driver injection.

**Protected files**: `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile`, `.gitconfig`, `.ripgreprc`, `.mcp.json`, `.envrc`, `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml`

**Protected git files** (only mounted when present on host): `.git/config`, `.gitmodules`, `.git/HEAD`, `.git/packed-refs`

**Protected directories**: `.git/hooks/`, `.git/info/`, `.vscode/`, `.idea/`, `.github/workflows/`, `.circleci/`, `.devcontainer/`

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

## Terminal Notifications

Sandy's inner tmux is configured with `allow-passthrough on`, which forwards OSC escape sequences (9/99/777) from Claude Code through to the outer terminal. This enables notification features in terminals like cmux and iTerm2.

Host-side Claude Code hooks (`~/.claude/hooks/`) are mounted read-only into the container at `/home/claude/.claude/hooks/`. This allows hooks configured on the host (e.g., cmux notification hooks) to work inside sandy without duplication.
