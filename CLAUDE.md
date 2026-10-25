# CLAUDE.md

`sandy` is a single-file bash launcher that runs coding agents (Claude Code, Gemini CLI, Codex, OpenCode, Grok, Mirror, or a 2–4 agent combo in tmux) inside a Docker sandbox with filesystem and network isolation, resource limits, and per-project credential sandboxes.

This file holds the rules and the gotchas that have cost real time. Look elsewhere for detail:

- **`SPECIFICATION.md`**: behavior, flags, and appendices A–E (generated files, runtime parameters, JSON schemas, platform differences, `docker run` assembly).
- **`SPEC_INTROSPECTION.md`**: the `--print-schema` / `--print-state` / `--validate-config` / `--print-version` contract and the list of known consumers.
- **`docs/DESIGN-NOTES.md`**: long-form rationale, incident records, probe results, and the full pre-trim CLAUDE.md. Read it before you *change* a decision here, or when a rule looks arbitrary.
- **`docs/security/`**, **`docs/design/`**, **`decisions/`**: threat models, the feature-manifest design, and dated decision records.
- **`docs/guide/`**: user docs. README is only the front page.

## Layout

- `sandy`: the launcher, installed to `~/.local/bin/`. On first run it generates `Dockerfile.base`, `Dockerfile`, `entrypoint.sh`, and `tmux.conf` in `~/.sandy/`, builds images, creates the per-project sandbox under `~/.sandy/sandboxes/<basename>-<sha8>`, applies network isolation, and runs the container.
- `install.sh`: the `curl | bash` installer. It installs **only** `sandy`, so anything sandy needs at runtime (e.g. `doctor.sh`) must be embedded in the script.
- `proxy/`: the Go egress proxy (sidecar).
- Build chain: `sandy-base` → per-agent image (`sandy-full` for combos) → optional skill-pack layers → optional per-project `.sandy/Dockerfile` (approval-gated).

## Rules for changing sandy

**Keep docs in sync.** A change to behavior, flags, config, generated files, runtime parameters, JSON schemas, or platform logic updates `SPECIFICATION.md`, including the relevant appendix. User-facing changes also update `docs/guide/`. A new key or flag needs a row in `docs/guide/configuration.md` (§119 checks this). Update this file only when a rule or gotcha changes.

**Regenerate generated files. Never hand-edit them.** `test/run-tests.sh` checks each with `--check`:

```sh
test/regen-config-docs.sh   # key-tier lists below + SPECIFICATION.md tables, from `sandy --print-schema`
test/regen-template.sh      # templates/user-setup.sh.tmpl, from the generate_user_setup() heredoc
test/regen-doctor.sh        # doctor.sh, from the _sandy_doctor_host() heredoc
```

To add or retier a config key: update `SANDY_PRIVILEGED_KEYS` / `SANDY_PASSIVE_KEYS` / `SANDY_ENV_ONLY_KEYS`, add a `key|type|default|pattern|since|stability|description` row to the `_sandy_key_metadata` heredoc, then run `regen-config-docs.sh`.

**`cli_flags` in `--print-schema` is hand-curated.** A new flag needs a `cli_flags` entry or a place on one of §91's exception lists, plus its own `--help` entry.

**Consumer boundary: sandy code and docs never name a consumer's protocol.** A mechanism that one consumer asks for must have a name, cardinality, and defaults that would make sense to a second, unrelated consumer. Otherwise it belongs in that consumer's feature payload. Provenance ("requested in #132") is fine. Justifying a mechanism's shape by one consumer's needs is not. §174 greps for two known leaks; the real test is the second-consumer question.

## Security invariants

These rules each exist because breaking them shipped a real hole. Keep them when touching nearby code.

- **Quote at the sink.** Any value interpolated into an agent command string goes through `printf %q`, because the sink is `bash -c`, not an argv array. Do this even for host-validated values. Quote list-valued keys per token. (§128)
- **A repo may tighten the sandbox, never loosen it.** Workspace `.sandy/config` is passive. Privileged keys, and weakening *values* of passive keys (`_sandy_passive_value_privileged`), require the one-time approval prompt. Headless and non-TTY launches fail closed. A new value that loosens anything must be added to that gate. (§65, §155)
- **Never write through a link the workspace or agent planted.** Host-side writes into the workspace or the rw sandbox dirs walk the path from the anchor and refuse or remove symlinks. Use `mktemp` + `mv`. Never `mkdir -p` as a detector, and never "canonicalize then write". (§129, §169)
- **The host never replaces a file a container has used.** Any host-side writer into an agent home writes a staged copy with `_sandy_stage_begin` / `_sandy_stage_commit`, and `user-setup.sh` renames it into place. Container-only inputs go under a fresh `$SANDBOX_DIR/launch/<id>/`. (§190; reason: virtiofs stale-length reads, see DESIGN-NOTES)
- **At most one credential per agent reaches the container.** Example: OAuth present means `ANTHROPIC_API_KEY` is suppressed unless `SANDY_<AGENT>_AUTH` says otherwise. A second credential silently changes billing or parks the agent on a modal. (§117, §194)
- **A daemon session must never come up inert.** Under `--start`, the supervisor, headless, or non-TTY stdin, nobody can answer a prompt. If the agent would open a login, theme picker, API-key modal, or trust dialog, either seed past it or refuse with the `.fatal` marker (client exits `6` in ~1s). Never report "ready" for a session parked on a dialog. (§122, §125)
- **Approvals resolve on the client's tty, before the supervisor forks** (`SANDY_APPROVE_ONLY` pre-pass). `SANDY_AUTO_APPROVE_PRIVILEGED` covers config keys and the Dockerfile gate. It deliberately does *not* cover the dangerous-symlink gate. (§162, §183)
- **Allowlists, not blocklists**, for anything that exposes host material (e.g. `SANDY_SSH_KEYS`: the mount itself is the exposure). (§132)
- **Fail loudly.** A silent no-op that looks like the mechanism working (an unmatched allowlist entry, a dropped duplicate flag, a skipped feature) gets a warning that names the cause.
- Everything sandy emits as data is UTC (`date -u` or epoch). (§163)

## Compatibility and versioning

- `SANDY_VERSION`: `X.Y.Z`, `X.Y.Z-rcN`, then bump to `X.Y.(Z+1)-dev` right after release. Semver: patch = fixes; minor = additive; major = anything that breaks sandbox forward-compat, the introspection `schema_version` contract, or key-tier semantics.
- **Removal needs an announcement first.** An entry may be added to README's `## Deprecated` table only in an `X.0.0` (the one written exception: a consumer-shaped surface whose every known consumer has already migrated, see DESIGN-NOTES). Only listed things may be removed, in a later minor. An entry may be *withdrawn* in any release. (§138)
- A removed config key → hard error naming the replacement. A removed mechanism → launch warning, then error. **A removed emitted introspection field → bump `schema_version`** (currently `4`), which may happen in a minor. Any `schema_version` change ships in an rc first, with an issue opened in each known consumer's repo.
- **Sandbox forward-compat:** a sandbox created by any `X.y` works with any later `X.y`. `SANDY_SANDBOX_MIN_COMPAT` (currently `2.0.0`) never moves above `X.0.0` within a major. Recreate old sandboxes with `sandy --reset-sandbox --workspace P --keep-history`, never `rm -rf`. (§51, §60, frozen fixture)
- Stable published contracts: the `--print-state` / `--print-schema` fields, the session marker `/etc/sandy-session.json`, the pane-identity contract (session `sandy`, pane option `@sandy_pane_agent`, `SANDY_AGENT` spawn order; §171), daemon exit codes, and the host-side path contract (agent-home mapping, feature mount destinations, daemon labels). Everything else under `$SANDY_HOME` is private.
- In the marker and `--print-state`, `null` means *unknown* and must never be used for "not applicable". `agents: null` does not mean `claude`. (§127, §177)

## Config tiers

Sources, highest precedence first: `--agent` flag > env set before launch > workspace `.sandy/config`/`.secrets` > host `~/.sandy/config`/`.secrets` > default. Files are parsed as `KEY=VALUE` and never sourced.

- **Privileged-only keys** (from a workspace source they trigger the approval prompt):
  <!-- BEGIN AUTOGEN:privileged-key-list Run `test/regen-config-docs.sh` to update. -->
  `SANDY_SSH`, `SANDY_SSH_KEYS`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `SANDY_LOCAL_LLM_HOST`, `SANDY_ALLOW_HOSTS`, `SANDY_EXTRA_ENV`, `SANDY_AGENT_ARGS`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `REFLECTION_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `SANDY_SCREENSHOT_DIR`, `SANDY_GEMINI_EXTENSIONS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`, `SANDY_HANDOFF_RELAY`, `ANTHROPIC_PROFILE`
  <!-- END AUTOGEN:privileged-key-list -->
- **Passive-safe keys** (any source; some values are still gated, see above):
  <!-- BEGIN AUTOGEN:passive-key-list Run `test/regen-config-docs.sh` to update. -->
  `SANDY_AGENT`, `SANDY_MODEL`, `SANDY_TEAMMATE_MODE`, `SANDY_EFFORT`, `SANDY_CPUS`, `SANDY_MEM`, `SANDY_GPU`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS`, `SANDY_CHANNEL_TARGET_PANE`, `SANDY_VERBOSE`, `SANDY_VENV_OVERLAY`, `SANDY_EGRESS`, `SANDY_EGRESS_PROXY`, `SANDY_EGRESS_NO_ISOLATION`, `SANDY_EGRESS_STRICT`, `SANDY_EGRESS_LOG`, `SANDY_ALLOW_WORKFLOW_EDIT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_SUBAGENT_MODEL`, `GEMINI_MODEL`, `SANDY_GEMINI_AUTH`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI`, `CODEX_MODEL`, `SANDY_CODEX_AUTH`, `OPENCODE_MODEL`, `SANDY_OPENCODE_AUTH`, `GROK_MODEL`, `SANDY_GROK_AUTH`, `MIRROR_MODEL`, `SANDY_CLAUDE_AUTH`, `SANDY_TOOL_AUDIT`, `SANDY_CLAUDE_USAGE`, `SANDY_CLAUDE_ACTIVITY`, `SANDY_CODEX_ACTIVITY`, `SANDY_CLAUDE_CONNECTORS`, `SANDY_SUSPICIOUS`, `SANDY_CROSS_SESSION_INBOUND`, `SANDY_RELAY`, `SANDY_OFFLINE`, `SANDY_GH_ACCOUNT`
  <!-- END AUTOGEN:passive-key-list -->

## Testing

The host groups run with isolated HOME/TMPDIR and Docker/tmux blockers; they are safe inside Sandy. Container, proxy, and keyed integration groups have separate dependencies. Run real Docker/tmux tests **on the host, not inside Sandy**:

```sh
bash test/run-tests.sh --host-only  # harness + production contracts + host checks
bash test/run-tests.sh --only container  # real launcher/entrypoint; Docker host only
bash test/run-tests.sh --only proxy  # Go race tests
bash test/run-tests.sh              # all five groups; Docker host only
bash test/run-integration-tests.sh  # headless end-to-end (API keys); SANDY_INTEG_ONLY / SANDY_INTEG_SKIP
bash test/lint-bash32.sh            # bash-3.2 / BSD portability lint (also run by §89)
```

Acceptance harnesses (`test/acceptance-*.sh`) run against an isolated `$SANDY_HOME` (`test/lib-isolated-home.sh`). Fixtures in a real home look exactly like real sandboxes. `docs/TESTING_PLAN.md` covers manual TUI checks.

The integration runner also isolates `$SANDY_HOME`, seeding only the build cache. It discovers credential environment variables and the original `$SANDY_HOME/.secrets` before isolation, and preserves `$HOME` for OAuth discovery. Host features, config, approvals, and sandboxes are not imported. The OpenCode smoke project selects a model for an available API key (an explicit `OPENCODE_MODEL` wins); its Google configuration references `GEMINI_API_KEY` without copying the secret into the project. Answer checks strip terminal controls but still require a successful exit and the requested answer; provider errors and timeouts alone cannot count as success.

Use `--only harness,contracts` for focused feedback and `--list` for groups. Both runners write logs under the ignored workspace `.test_output/`, keeping at most three runs; `.test_output/latest/` points to the newest. `--log-dir PATH` overrides the main suite's log root; `SANDY_INTEG_LOG_DIR` overrides the integration log root, with the same rotation. CI uses `--require-tools` so a missing declared dependency is a failure. A group with skipped checks is reported as partial, not fully passed. Section numbers in the legacy host suite remain stable for incident references; removed sections point to their replacements.

The main runner labels each group and prints individual Python test names and outcomes. Full failure tracebacks are always logged; `--verbose` also prints them to the terminal. Automated groups and production-contract probes receive `/dev/null` on stdin, so running from a terminal cannot turn a refusal test into an approval prompt.

How to write tests here:

- **Assert the property, not the presence of a mechanism.** Run the thing and check the outcome, then mutation-test the guard: break it in a temp copy and confirm the check fails. Also confirm the probe actually ran, since `set -u` has silently killed probe subshells and made checks pass vacuously.
- **Don't anchor a JSON assertion on a field's neighbours** (`"name":"X"[^}]*"relay"…`). It breaks once someone inserts a nested object between them. Use one sandbox per fixture `$SANDY_HOME`, or slice the object with `awk` `index`/`substr` written on one line. (§88b ratchets this.)
- New sections must survive `set -euo pipefail` plus the ERR trap.

## Portability: CI is Linux/bash 5, the maintainer is macOS/bash 3.2/BSD

Host-side shell must work on both. Container-side code (heredoc bodies, `user-setup.sh`) runs on Linux. `test/lint-bash32.sh` catches these. Each has broken a real macOS run while CI stayed green:

| Code | Don't | Do |
|---|---|---|
| `SRCSUB` | `source <(...)` nested in `$( )` | extract, then `eval` |
| `VARMB` | `$name` directly followed by a non-ASCII char (`"$host…"`) | `${name}…` |
| `PYBACK` | backtick or `$(` inside `python3 -c "..."` | quoted heredoc: `python3 - <<'PY'` |
| `APOSQ` / `APOSCS` | an apostrophe in a comment inside a multi-line `'...'` argument or `$( )` | reword the comment |
| `CASESUB` | a `case` pattern inside a multi-line `$( )` | hoist it, or use the `(pattern)` form |
| `GREPM` | `grep … \| head` under `pipefail` | `grep -m1` |
| `GNUBIN` | `timeout`, `sha256sum`, `realpath`, `date -d`, `grep -P`, `stat -c`, `sed -i` without a suffix, `xargs -r`, `find -printf`, `sleep infinity`, `\|` in a `sed` BRE | a BSD fallback, `shasum -a 256`, `sed -E`, `sed -i ''`, a poll loop |

Other macOS traps: `mktemp -d` returns a symlinked path, so canonicalize it (`D="$(cd "$(mktemp -d)" && pwd -P)"`); `wc -l` pads its output with leading spaces; an empty array under `set -u` is an error; there is no `setsid`. Container-side code outside a heredoc needs `# lint-bash32: allow GNUBIN`.

## Working inside sandy (you probably are)

- **Never run `tmux`, `docker`, or `sandy --start|--stop|--attach` here.** They share the live session's tmux server and kill it. Write a harness and have the user run it on the host.
- `.git/HEAD` is writable, so commit, switch, and `checkout -b` work. `.git/config`, `packed-refs`, `hooks/`, and `info/` are `:ro`, so:
  - `git push -u` reports a config-write error *after a successful push*. Use `git push origin <branch>:<branch>`.
  - `git reset --hard` fails when `.github/workflows/` is tracked (protected dir). Use a mixed `git reset <ref>`.
  - `git gc`, `pack-refs`, and deleting packed refs fail.
- `main` is protected, so every change goes through a PR. The HEAD-preserving pattern: commit → `git branch -f <feature> HEAD` → `git push origin <feature>` → `git reset origin/main` → `gh pr create --head <feature> --base main`.
- Protected workspace paths (shell rc files, `.git/hooks`, `.github/workflows/`, `.vscode/`, `.sandy/`, `.claude/settings*.json`, …) are read-only in-container when they exist on the host. The full list is in SPECIFICATION.md.

## Subsystem pointers

Read the referenced section before editing these areas. Each carries non-obvious constraints.

| Area | Where | Key constraint |
|---|---|---|
| Agent credentials and auth modes | SPEC §11, DESIGN-NOTES "Agent Selection" | probe order per agent; one-credential rule; codex in-container login is `--device-auth` |
| Claude `settings.json` seeding | SPEC §4, C.2, E.13a | regenerated every launch, merge-preserving; managed keys forced in all three branches (node/jq/no-tool) |
| Named Claude sessions (`.sandy/sessions/`) | SPEC §12, `decisions/2026-10-12-named-claude-sessions.md` | one flag-less `--bg --resume` per session; the pane never runs `--continue` |
| Daemon mode | `docs/guide/daemon.md`, SPEC §12 | the container is the daemon; labels are the state; exit codes are a consumer contract; `--init` reaps zombies |
| Maintenance commands (`--gc`, `--reset-sandbox`, `--remove-sandbox`, `--rsync[-from]`, `--provision`, `--doctor`, …) | SPEC §1 "Maintenance Flags" | exit `1` when the goal is unmet, `0` when already met; plan → `--dry-run` → `--yes`; non-TTY without `--yes` errors |
| Egress proxy and network | `docs/guide/network.md`, SPEC §8 | the `--internal` network drops non-TCP, so the proxy must never become the only egress control; agent is removed before proxy at teardown; a host-written file mounted into the proxy must be `chmod 0644` (it reads through the other bits, §207) |
| Features (`$SANDY_HOME/features/*/feature.json`) | `docs/design/FEATURE-MANIFEST.md` | strict parse or refuse; unknown keys refuse the manifest; both projectors byte-identical (§135) |
| Cross-session inbound | `docs/security/CROSS_SESSION_INBOUND.md` | sandy's explicit write is load-bearing; written to both settings files; re-measure on Claude Code bumps |
| Image builds and freshness | SPEC §5, §17 | every build goes through `_sandy_build_allowed`; agent version files must be non-empty |
| `--rsync` / `--rsync-from` | SPEC §1 "Maintenance Flags" | rename dir + history + `.claude.json` key + `WORKSPACE.json` for the destination; shared helpers in both directions |
