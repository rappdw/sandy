# Sandy Specification

**Version**: 1.0.0-rc1
**Date**: 2026-07-02
**Source**: ~6,100-line bash script (`sandy`), installer (`install.sh`), egress proxy (`proxy/`, Go), test suites (`test/run-tests.sh`, `test/run-integration-tests.sh`)

Sandy is a self-contained command that runs an AI coding agent (Claude Code, Gemini CLI, OpenAI Codex CLI, OpenCode, or any comma-separated multi-agent combo) in a Docker container with filesystem isolation, network isolation, resource limits, and per-project credential sandboxes. One script, one command, zero configuration required.

### Supported Agents

| `SANDY_AGENT` | Image | Description |
|---|---|---|
| `claude` (default) | `sandy-claude-code` | Claude Code — full feature support (channels, skill packs, synthkit, remote-control) |
| `gemini` | `sandy-gemini-cli` | Gemini CLI — Google OAuth / ADC / Vertex AI / API key auth |
| `codex` | `sandy-codex` | OpenAI Codex CLI — `OPENAI_API_KEY` (materialized as an ephemeral read-only `auth.json`) or ChatGPT OAuth (seeded into the rw sandbox so an in-container `codex login` persists) |
| `opencode` | `sandy-opencode` | OpenCode (sst/opencode) — provider-agnostic; reads `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GEMINI_API_KEY` natively, plus optional OAuth from `~/.local/share/opencode/auth.json`. Local-LLM passthrough via `SANDY_LOCAL_LLM_HOST`. |
| `grok` | `sandy-grok` | Grok Build (xAI) — installed from `x.ai/cli/install.sh` (prebuilt binary, relocated to `/usr/local/bin`); authenticates headless from `XAI_API_KEY` (or an in-container `grok login` OAuth session in `~/.grok`). Model via `GROK_MODEL` (`-m`, default `grok-4.5`). Not in the `all` alias. |
| `<a>,<b>[,<c>[,<d>]]` (e.g. `claude,gemini`, `claude,codex`, `claude,gemini,codex,opencode`) | `sandy-full` | Multi-agent combo — one tmux pane per agent, in the order listed |
| `all` | `sandy-full` | Alias for `claude,gemini,codex,opencode` — all four agents in a 4-pane tmux session |

The previous `both` alias (= `claude,gemini`) was removed in `v0.12`. Using it now exits with an error pointing at the comma-separated syntax.

---

## Table of Contents

1. [Command-Line Interface](#1-command-line-interface)
2. [Configuration System](#2-configuration-system)
3. [Versioning](#3-versioning)
4. [Per-Project Sandboxes](#4-per-project-sandboxes)
5. [Docker Image Build Pipeline](#5-docker-image-build-pipeline)
6. [Skill Pack System](#6-skill-pack-system)
7. [Container Runtime](#7-container-runtime)
8. [Network Isolation](#8-network-isolation)
9. [Protected Files](#9-protected-files)
10. [SSH Agent Relay](#10-ssh-agent-relay)
11. [Credential Management](#11-credential-management)
12. [Session Management](#12-session-management)
13. [Workspace Path Mapping](#13-workspace-path-mapping)
14. [Environment Detection](#14-environment-detection)
15. [Plugin Marketplace Management](#15-plugin-marketplace-management)
16. [Channel Integration](#16-channel-integration)
17. [Auto-Update](#17-auto-update)
18. [Security Model](#18-security-model)
19. [Test Suite](#19-test-suite)
20. [Installation](#20-installation)
21. [File Inventory](#21-file-inventory)

**Appendices (Implementation Detail)**

- A. [Generated File Templates](#appendix-a-generated-file-templates)
- B. [Runtime Parameters](#appendix-b-runtime-parameters)
- C. [JSON Schemas](#appendix-c-json-schemas)
- D. [Platform-Specific Behavior](#appendix-d-platform-specific-behavior)
- E. [Container Launch Assembly](#appendix-e-container-launch-assembly)

---

## 1. Command-Line Interface

### Usage Modes

```
sandy                          # Interactive session (resume last or start new)
sandy -p "prompt"              # One-shot prompt (no interactive session)
sandy --new                    # Force fresh session
sandy --resume                 # Open session picker (forwarded to claude)
sandy --remote                 # Remote-control server mode (headless)
```

### Administrative Flags

| Flag | Behavior |
|---|---|
| `--agent A[,B,…]` | Select agent(s) for this launch (`claude`, `gemini`, `codex`, `opencode`, comma-combos, or `all`). Highest-precedence source for `SANDY_AGENT` — beats env var and both config tiers |
| `--rebuild` | Force rebuild all Docker images |
| `--build-only` | Build images and exit (for CI/prewarming) |
| `--upgrade` | Self-update sandy from GitHub |
| `--version` / `-v` | Print version string (e.g. `1.0.1-dev-a1b2c3d`). **Guaranteed format as of 1.7.0 (#159):** stdout is exactly `sandy <full_version>`, byte-for-byte identical to `--print-version`'s `full_version` field — this is a test-pinned identity (`test/run-tests.sh` §93(2)), and the safe way for a consumer to detect "sandy 1.7.0+" before calling `--print-version` (which pre-1.7.0 sandy would silently forward to the agent instead of rejecting). |
| `--help` | Show help text |
| `--print-protected-paths` | List protected files/dirs as `file:`/`dir:` lines (test-harness surface; see §9) |

### Maintenance Flags

Same pre-preflight family as the introspection flags below — these run before config load, mutex acquisition, or any image build, needing only a reachable Docker daemon. Human-readable stdout (action verbs), not introspection JSON.

| Flag | Behavior |
|---|---|
| `--prune-orphans` | Reap orphaned `sandy_*` networks (dead-owner, no attached container) and exit. Exit 0 (including "found none"), 1 only if Docker is unreachable. |
| `--gc [--dry-run] [--yes]` | One-shot global reclaim (#36, milestone 1.3.0): dead-owner `sandy-*`/`sandy-proxy-*` containers, orphaned `sandy_*` networks (delegates to the same lister/reaper `--prune-orphans` uses — one gate, no drift), orphaned per-project images (`sandy-project-<x>`), orphaned skill-pack images (`sandy-skills(-base)?-<x>`), and dangling sandy images (`<none>:<none>` scoped via the `sandy.managed=1` build label). Prints a plan, then: nothing to reclaim → exit 0; `--dry-run` → prints the plan and exits 0 before any confirm; `--yes` skips the interactive y/N; a TTY without `--yes` is prompted; non-TTY without `--yes` errors and exits 1. Reap order: containers → networks → project images → skills images → dangling images last. Exit 0 on success, 1 if Docker is unreachable or an unrecognized sub-argument was given. See "Unified Resource Reclaim (`sandy --gc`, #36)" in §5 for the container-liveness predicate and provenance-label details. |
| `--reset-sandbox [--workspace PATH \| --all] [--keep-history \| --purge-history] [--keep-approvals] [--dry-run] [--yes]` | (HF-incident Issue 5) **Filesystem-only** — no Docker, no config load, no mutex acquisition. Rebuilds ONE project's sandbox from a known-good skeleton: resolves the target workspace (default cwd) via the same `pwd -P` → `basename-<8-char-sha256>` scheme the launch path uses, refuses while a live session holds the workspace mutex, prints a plan (each persistent entry with its `du -sh` size), then destroys everything in the sandbox dir EXCEPT `WORKSPACE.json` (lineage, always preserved), `agent-args.<agent>` files, — with `--keep-approvals` — the approved-symlinks list, and — with `--keep-history` — `claude/projects/` (emptying `claude/` around it). `--keep-history` keeps **only** `claude/projects/`: with it, the plan also lists under *NOT kept by --keep-history* every destroyed entry that is not one of sandy's own regenerable caches/launch bookkeeping (the rest of `claude/`, other agents' homes, anything a host-side tool keeps in the sandbox), derived from what is present rather than from a list of consumer directory names (#333, 2.4.0); a dry run with the history question unanswered shows the same list; the next launch re-materializes `pip/uv/npm/go/cargo` + agent state from scratch. `--dry-run`/`--yes`/non-TTY discipline matches `--gc`. Exit 0 on success, 1 on a live-lock refusal, a nonexistent workspace, or non-TTY without `--yes`. |
| `--remove-sandbox [--workspace PATH \| --sandbox NAME \| --orphans] [--dry-run] [--yes]` | (#178) **Filesystem-only** (a reachable Docker is used only as a best-effort container-liveness guard; absent Docker fails open). Permanently DELETES a sandbox directory — preserves NOTHING, including `WORKSPACE.json`, unlike `--reset-sandbox`. Three mutually exclusive selectors: default/`--workspace PATH` (workspace must still exist; identical resolution to `--reset-sandbox`), `--sandbox NAME` (targets a sandbox whose workspace is already gone; validated as a single safe path segment), `--orphans` (every sandbox whose recorded `workspace_path` no longer exists — conservative predicate, see CLAUDE.md). More than one selector is an error. Also reaps the sibling lock dir and the per-workspace approval files, including the `.sandy/`-created-by-a-session record (keyed on the 16-char workspace-path hash, distinct from the sandbox name's 8-char hash). Refuses/skips on a live workspace lock or a live `sandy-<name>`/`sandy-proxy-<name>` container (exact match) — single-target modes hard-error, `--orphans` skips and continues. `--dry-run`/`--yes`/non-TTY discipline matches `--gc`. Exit 0 on success (including "nothing to remove"), 1 on an invalid `--sandbox` name, two selectors, a nonexistent target, a live-lock/container refusal in single-target mode, or non-TTY without `--yes`. See "`--remove-sandbox`" in CLAUDE.md. |
| `--rsync <dest_host> [--workspace PATH] [--dest-workspace PATH] [--dest-sandy-home PATH] [--dry-run] [--yes]` | (#374) **Filesystem-only**; needs `ssh` and `rsync` on both ends. **Copies** this workspace's sandbox to `dest_host` (source untouched) under the name the destination computes from its own canonical workspace path, which defaults to the same path relative to `$HOME` (override `--dest-workspace`; `~` is expanded on the destination) and must already exist there. The destination `SANDY_HOME` is `${SANDY_HOME:-$HOME/.sandy}` as seen by a non-interactive `ssh` shell (override `--dest-sandy-home`). Rewritten for the destination: `WORKSPACE.json` (`sandbox_name`, `workspace_path`; lineage kept), the sibling `<name>.claude.json` (renamed, and its `projects` key moved to the new container path via node, else jq, else copied unchanged with a warning), and `claude/projects/<dir>` (renamed when the container path changes, using Claude Code's rule `replace(/[^a-zA-Z0-9]/g,"-")`; a non-ASCII path without node is copied unrenamed and reported). Not copied: `sandy-session.json`, `gemini-system-settings.json`, `relay-state/`, `feature-state/`, `agent-args-composed/`, `proxy.log`, `.protected-existed-at-launch`, `claude/sessions/`. Skipped: `venv/` when the container path changes; `cargo/ go/ npm-global/ pip/ uv/ venv/` when `uname -m` differs (`aarch64`≡`arm64`, `amd64`≡`x86_64`). Credential-bearing files (matched by name under `codex/ grok/ gemini/ opencode/`, plus a non-empty `claude/.credentials.json`) are copied and listed in the plan. Refuses (exit 1): a live workspace lock or running `sandy-<name>` container (under `--dry-run` the plan still prints, followed by a warning that a real run would refuse); an existing sandbox or `.claude.json` of that name on the destination; a missing destination workspace; a workspace outside `$HOME` without `--dest-workspace`; a host starting with `-` or outside `[A-Za-z0-9._@-]`; a destination `SANDY_HOME` outside `^/[A-Za-z0-9._/@+-]+$`; a destination sandy whose major is below the sandbox's created major; non-TTY without `--yes`. `--dry-run` prints the plan and exits 0. Exit 0 only after the copy re-verifies on the destination. See "`--rsync`" in CLAUDE.md. |
| `--rsync-from <src_host> [--workspace PATH] [--src-workspace PATH] [--src-sandy-home PATH] [--dry-run] [--yes]` | (#409) The reverse of `--rsync`, run on the machine that wants the copy: **pulls** `src_host`'s sandbox for this workspace, using only outbound `ssh`/`rsync` from here. The local workspace (`--workspace`, else `$PWD`) must exist here; the source defaults to the same path relative to `$HOME` on the remote (`--src-workspace`; `~` expanded there), and the source `SANDY_HOME` to `${SANDY_HOME:-$HOME/.sandy}` in a non-interactive `ssh` shell (`--src-sandy-home`). Two `ssh` round trips: the first resolves the remote paths, and the name is computed **here** from the remote canonical path. The second reports what is there (existence, `.claude.json`, `.sandy_created_version`, a live lock pid or running `sandy-<name>` container, the history count, credential files by name, size). The same rewrites as `--rsync`, computed for **this** host: the directory is named for this host's canonical path; `WORKSPACE.json` is rewritten with its lineage kept; `.claude.json` gets its `projects` key moved; `claude/projects/<dir>` is renamed when the container path changes. The never-copied list, the architecture skip and the credential patterns are shared with `--rsync` (`_SANDY_RSY_NEVER`, `_SANDY_RSY_ARCH_DIRS`, `_SANDY_RSY_CRED_*`). The copy is fetched into a hidden `$SANDY_HOME/sandboxes/.rsync-from.<name>.<pid>` directory, rewritten there, and renamed into place only after every transfer succeeded (the EXIT trap removes it otherwise), so a failed pull installs nothing. Refuses (exit 1): a live lock pid or running container for the source on the remote (under `--dry-run` the plan still prints, then says a real run would refuse); a sandbox or `.claude.json` of that name **here** (checked again right before the rename); a missing source workspace or sandbox on the remote; a workspace outside `$HOME` without `--src-workspace`; a host starting with `-` or outside `[A-Za-z0-9._@-]`; a source `SANDY_HOME` outside `^/[A-Za-z0-9._/@+-]+$`; a sandbox created by a newer sandy major than this one; non-TTY without `--yes`. `--dry-run` prints the plan and exits 0. Exit 0 only after the local copy verifies. Guarded by `run-tests.sh` §187. |
| `--doctor [--fix] [--yes]` | (#124) Standalone host + runtime readiness check. Two sections: HOST runs the embedded `doctor.sh` body (see "sandy --doctor" in CLAUDE.md for the heredoc-mirror mechanism); RUNTIME reuses sandy's own predicates verbatim — running-container image staleness (`_sandy_image_stale`), proxy image age, orphaned Docker resources (networks/containers/project images/skills images/dangling images — the same DEC-4b listers `--gc` uses), workspace-lock sanity, and a read-only orphaned-sandbox count (never remediated here — see `--remove-sandbox --orphans`). Every RUNTIME finding is a warning; the exit code comes entirely from HOST's required checks (git, curl, docker). `--fix` applies exactly two remediations — removing provably-dead stale workspace locks (the launch path's own predicate and remover, `_sandy_lock_state`/`_sandy_lock_reap_stale` — re-checked at removal time, so a lock re-taken since the listing is never deleted; #158) and reaping orphaned networks via the existing `_sandy_reap_orphan_networks` — never a sandbox, image, or container. `--yes` without `--fix` is an error (exit 1): a CI job that meant `--fix --yes` and dropped `--fix` must not silently run read-only and report success. With `--fix` and something to fix: a TTY without `--yes` is prompted; non-TTY without `--yes` errors and exits 1, mutating nothing. Exit 0 iff every required HOST check passes (warnings, from either section, never fail it); 1 otherwise. Docker is checked, not required, to invoke this flag — an absent Docker is itself a required HOST failure. |

### Introspection Flags (machine-readable JSON)

All introspection flags are **fast-path handlers**: they run before image builds, sandbox setup, mutex acquisition, and docker availability checks, and exit immediately without side effects. This makes them safe to call from non-privileged UI processes, CI tooling, and headless contexts. Output is single-line JSON on stdout with `schema_version: 4`.

| Flag | Behavior |
|---|---|
| `--print-schema` | Emit the static sandy schema: version, config keys (by tier with type/default/description), CLI flags, agents and their credential probe orders, protected path lists, skill packs, the feature-manifest **input** contract (`manifest.top_level_keys` / `manifest.mount_keys`, 2.1.0/#348; `manifest.receives_values`, 2.4.0/#380), schema compatibility declaration. Always exits 0. |
| `--print-state` | Emit runtime state: `sandy_home`, installed sandy images, per-sandbox metadata (`.sandy_created_version`, `.sandy_last_version`, size if cheaply obtainable), approval files (one per workspace hash), `docker_reachable` (bool), running sandy containers (filtered by image name prefix), `orphan_networks` (int, reap-eligible `sandy_*` network count), and — **full mode only** (#36, milestone 1.3.0) — `dangling_images` and `orphaned_containers` (ints; `null` in light mode even when real orphans exist, mirroring `image_stale`'s full-mode-only convention). When Docker is unreachable, `docker_reachable: false`, `running_containers: null`, `orphan_networks: null`, `dangling_images: null`, `orphaned_containers: null`. Always exits 0. |
| `--validate-config PATH` | Parse a config file, classify it as privileged (path under `$SANDY_HOME/`) or passive (anywhere else), and emit `{schema_version, path, source_tier, errors[], warnings[], unknown_keys[], privileged_keys_requiring_approval[], approval_status, approval_file_path}`. Exits 1 if the file does not exist or the flag was called with no argument; exits 0 otherwise (a "pending" approval is not an error — it's the normal state before first interactive approval). |
| `--print-version` | (1.7.0, #159) Emit `{schema_version, version, commit, full_version}` — a standalone version probe so a consumer (e.g. sandy-ui) can detect sandy's version without the chicken-and-egg of reading it out of `--print-schema`'s own payload. `commit` is `""` (not `null`) when unknown, matching `--print-schema`'s `sandy.commit` convention; both are computed by the shared `_sandy_commit_hash()` helper. `full_version` — not `version` — is the stable cache key: `version` alone stays unchanged (e.g. `"1.7.0-dev"`) across every commit on the dev/rc channel until the numbered release ships. Always exits 0. **Not recognized by pre-1.7.0 sandy** — the main parser forwards unknown flags to the wrapped agent rather than erroring, so probe with `--version` first (guaranteed `sandy <full_version>` format, safe on every version) and only call `--print-version` once that confirms 1.7.0+. |

See `SPEC_INTROSPECTION.md` for field-by-field documentation and the stability contract (additive changes within schema_version=4, breaking changes bump the version).

### Verbosity Flags

| Flag | Effect |
|---|---|
| `-v` | Show startup section headers, pause on exit |
| `-vv` | Add bash trace to `user-setup.sh` |
| `-vvv` | Also trace `entrypoint.sh` and show docker run flags |

### Argument Forwarding

All unrecognized arguments (including `-p "prompt"`, `--resume`, `--continue`) are forwarded to the `claude` binary inside the container.

### Flag Parsing

Flags are parsed with a `while [ $# -gt 0 ]` loop with `shift`. Sandy's flags are consumed; everything else is collected into `REMAINING_ARGS` and forwarded to `claude`.

---

## 2. Configuration System

### Load Order

1. `$SANDY_HOME/config` — user-level defaults (typically `~/.sandy/config`) — **privileged tier**
2. `$SANDY_HOME/.secrets` — user-level credentials — **privileged tier**
3. `.sandy/config` — per-project overrides — **passive tier**
4. `.sandy/.secrets` — per-project credentials — **passive tier**

Later files override earlier values, subject to tier restrictions below.

### Parser

The config parser does **not** use `source`. It reads lines via `grep -E '^[A-Z_]+=.+'`, strips leading/trailing single and double quotes from values (in order: double then single), validates the key against a tier-specific allowlist, and exports only recognized keys. Lines not matching the grep pattern are silently ignored — this includes comments (`#`), blank lines, and lowercase keys. If the config file is unreadable or missing, loading silently succeeds.

**Env-var precedence.** Before any `_load_sandy_config` call, sandy snapshots which keys are already set in the process environment (`_sandy_snapshot_env_keys` populates `_SANDY_ENV_SET_KEYS`). The loader checks every key against the snapshot and skips the export if the key was env-set. This guarantees env-var precedence: `SANDY_AGENT=codex sandy ...` and shell-level `export` win over both privileged (host) and passive (workspace) config files. Without the snapshot the first config load would export values that the second load would see as "already set," collapsing the workspace-overrides-host semantic. Final precedence: `--agent` CLI flag > env var > workspace passive > host privileged > sandy default.

### Config Tiers (1.0-rc1)

Each call to `_load_sandy_config` takes a `tier` argument (`privileged` or `passive`). Privileged-tier sources may set any recognized key immediately. Passive-tier sources (the two workspace files) may set **passive-safe** keys immediately; any privileged-only key found in a passive source is **collected** into `_PASSIVE_PRIVILEGED_PENDING` rather than exported. After both passive sources load, `_resolve_passive_privileged_approval()` runs: it hashes the sorted `KEY=VALUE` set, checks `$SANDY_HOME/approvals/passive-<wd-hash>.list` (first line is the sha256 of the approved set), and either (a) silently exports if the hash matches, (b) prompts `y/N` on `/dev/tty` the first time with the exact KEY=VALUE list plus a rationale about repo-committed configs, or (c) fails closed in non-interactive mode (`_sandy_is_headless=true` or non-TTY stdin) with a pointer to "launch sandy interactively from this directory to approve." On approval, the file is written with the hash, a `# workspace:` comment, a `# approved:` timestamp, and the sorted KEY=VALUE lines, mode 600. Any edit to the workspace config that adds, removes, or changes a privileged key invalidates the hash and re-prompts on the next launch. Revocation is `rm` of the approval file. This prevents a malicious `.sandy/config` committed to a repo from disabling isolation, forwarding an SSH agent, or exfiltrating credentials without a deliberate, workspace-scoped user opt-in.

**CI / test-harness escape hatch**: `SANDY_AUTO_APPROVE_PRIVILEGED=1` in the process environment bypasses the prompt and exports the pending keys in-memory without writing an approval file. It bypasses the per-project `.sandy/Dockerfile` gate (§5) the same way, and deliberately does **not** bypass the dangerous-symlink gate (Appendix E.1a). This is intentionally env-only — `SANDY_AUTO_APPROVE_PRIVILEGED` is not in the passive allowlist, so a committed `.sandy/config` cannot set it. Sandy's own `test/run-tests.sh` and `test/run-integration-tests.sh` set this flag at the top of each harness so the suites can run from the sandy repo directory (which carries a real `GEMINI_API_KEY` in `.sandy/.secrets` for integration testing) without blocking on stdin.

**Privileged-only keys** (allowed only from `$SANDY_HOME/config` and `$SANDY_HOME/.secrets`):
<!-- BEGIN AUTOGEN:privileged-key-list Run `test/regen-config-docs.sh` to update. -->
`SANDY_SSH`, `SANDY_SSH_KEYS`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, `SANDY_LOCAL_LLM_HOST`, `SANDY_ALLOW_HOSTS`, `SANDY_EXTRA_ENV`, `SANDY_AGENT_ARGS`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GEMINI_API_KEY`, `OPENAI_API_KEY`, `XAI_API_KEY`, `GOOGLE_API_KEY`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `SANDY_SCREENSHOT_DIR`, `SANDY_GEMINI_EXTENSIONS`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`, `SANDY_HANDOFF_RELAY`, `ANTHROPIC_PROFILE`
<!-- END AUTOGEN:privileged-key-list -->

**Passive-safe keys** (allowed from any source):
<!-- BEGIN AUTOGEN:passive-key-list Run `test/regen-config-docs.sh` to update. -->
`SANDY_AGENT`, `SANDY_MODEL`, `SANDY_TEAMMATE_MODE`, `SANDY_EFFORT`, `SANDY_CPUS`, `SANDY_MEM`, `SANDY_GPU`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS`, `SANDY_CHANNEL_TARGET_PANE`, `SANDY_VERBOSE`, `SANDY_VENV_OVERLAY`, `SANDY_EGRESS`, `SANDY_EGRESS_PROXY`, `SANDY_EGRESS_NO_ISOLATION`, `SANDY_EGRESS_STRICT`, `SANDY_EGRESS_LOG`, `SANDY_ALLOW_WORKFLOW_EDIT`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_SUBAGENT_MODEL`, `GEMINI_MODEL`, `SANDY_GEMINI_AUTH`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_GENAI_USE_VERTEXAI`, `CODEX_MODEL`, `SANDY_CODEX_AUTH`, `OPENCODE_MODEL`, `SANDY_OPENCODE_AUTH`, `GROK_MODEL`, `SANDY_GROK_AUTH`, `SANDY_CLAUDE_AUTH`, `SANDY_TOOL_AUDIT`, `SANDY_CLAUDE_CONNECTORS`, `SANDY_SUSPICIOUS`, `SANDY_CROSS_SESSION_INBOUND`, `SANDY_RELAY`, `SANDY_OFFLINE`
<!-- END AUTOGEN:passive-key-list -->

### `SANDY_ALLOW_LAN_HOSTS` Sanity Check

After all config sources are loaded, `SANDY_ALLOW_LAN_HOSTS` (if set) is split on `,` and each entry is validated. Any entry matching `0.0.0.0/0` or `::/0` causes a hard error (`exit 1`) with a clear message. This check runs even against privileged-tier values — a user-level config with a world-open allowlist is almost always a mistake, and the launch refusal prevents silent negation of LAN isolation.

### Allowlisted Variables

The table below is generated from `sandy --print-schema` (the `_sandy_key_metadata` heredoc in the sandy script is the source of truth). Run `test/regen-config-docs.sh` after editing, adding, or retiering a key — `test/run-tests.sh` asserts the blocks are in sync.

<!-- BEGIN AUTOGEN:config-keys-table Run `test/regen-config-docs.sh` to update. -->
| Variable | Tier | Default | Since | Stability | Description |
|---|---|---|---|---|---|
| `SANDY_SSH` | privileged | `token` | 0.1.0 | stable | SSH auth mode: 'token' uses gh CLI (HTTPS); 'agent' forwards the host SSH agent. |
| `SANDY_SSH_KEYS` | privileged | unset | 1.14.0 | stable | Comma-separated FILENAMES under ~/.ssh that may be staged into the container, in ANY SANDY_SSH mode. Default empty = no private key material is staged at all. Only these files, plus config, known_hosts and *.pub, reach the container; everything else in ~/.ssh stays on the host. A name matching no file is warned about rather than silently ignored. Forced empty by SANDY_SUSPICIOUS=1. |
| `SANDY_SKIP_PERMISSIONS` | privileged | `true` | 0.1.0 | stable | Skip Claude Code's in-session permission prompts (default: true). |
| `SANDY_ALLOW_NO_ISOLATION` | privileged | `0` | 0.1.0 | stable | Allow launch when iptables rules cannot be applied (Linux only). |
| `SANDY_ALLOW_LAN_HOSTS` | privileged | unset | 0.7.9 | stable | Comma-separated IPs/CIDRs to allow through LAN isolation. World-open entries rejected. |
| `SANDY_LOCAL_LLM_HOST` | privileged | unset | 0.12.0 | stable | Single host:port (e.g. '127.0.0.1:11434') to allow through LAN isolation, typically for a local LLM. With the egress proxy on (default) the proxy's forward listener relays host.docker.internal:<port> to the host; with the proxy off (=0, Linux) it inserts one iptables ACCEPT and maps host.docker.internal. |
| `SANDY_ALLOW_HOSTS` | privileged | unset | 0.14.0 | stable | Comma-separated extra egress-proxy allowlist entries (exact host, '*.suffix' wildcard, or 'host:port' for CONNECT/SSH). Appended to the built-in default allowlist. In strict mode (SANDY_EGRESS_PROXY=2) these are the only hosts reachable beyond defaults; in permissive mode (=1) they are LAN-exceptions reachable despite the private-IP block. Privileged tier so workspace config requires approval. |
| `SANDY_EXTRA_ENV` | privileged | unset | 0.12.0 | stable | Comma-separated env-var names to forward into the container (e.g. 'HA_TOKEN,FOO_API_KEY'). The name lists COMPOSE (2.4.0): the effective list is the union of the host lists, any approved workspace list, and an env-set list (env ADDS, it does not replace), deduplicated in that order. Values resolve env > workspace .sandy/.secrets > workspace .sandy/config > ~/.sandy/.secrets > ~/.sandy/config. The privileged tier gates the NAME list (workspace config setting SANDY_EXTRA_ENV itself requires approval); once approved, values may come from any source. |
| `SANDY_AGENT_ARGS` | privileged | unset | 1.3.0 | stable | Extra command-line arguments appended to the agent command (claude/codex/gemini/opencode) on EVERY launch — bare sandy, headless -p, the --start daemon, and sandy-ui alike. Whitespace-split into argv (no embedded-space/quoting support in v1) and forwarded through the same per-agent translation as command-line pass-through args, ordered AFTER sandy's own flags and BEFORE any command-line args. Privileged tier: free from host ~/.sandy/config, but from a workspace .sandy/config it triggers the per-workspace approval prompt (headless/non-TTY drops it). Never eval'd. Typical use: a fixed --mcp-config <path> or project feature flags. Applies to every selected agent (each pane in a multi-agent combo) unless overridden per agent by an operator file $SANDBOX_DIR/agent-args.<agent> (sandbox top level, agent-unwritable, privileged by location — no prompt); when both are present the sandbox file wins for that agent, values are never merged, and sandy prints a one-line notice. |
| `ANTHROPIC_API_KEY` | privileged | unset | 0.1.0 | stable | Anthropic API key for Claude Code. Not required when using Claude Max OAuth. |
| `CLAUDE_CODE_OAUTH_TOKEN` | privileged | unset | 0.7.0 | stable | Claude Code OAuth token (alternative to ANTHROPIC_API_KEY). |
| `GEMINI_API_KEY` | privileged | unset | 0.9.0 | stable | Google API key for Gemini CLI. |
| `OPENAI_API_KEY` | privileged | unset | 0.10.0 | stable | OpenAI API key for Codex CLI. |
| `XAI_API_KEY` | privileged | unset | 1.5.0 | stable | xAI API key for Grok Build (docs.x.ai). Enables fully-headless auth (resolution: model.api_key > env_key > session token > XAI_API_KEY); alternative is an interactive 'grok login' OAuth session inside the container. |
| `GOOGLE_API_KEY` | privileged | unset | 0.9.0 | stable | Google API key for Vertex AI / ADC. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | privileged | unset | 0.1.0 | experimental | Enable Claude Code experimental agent-teams feature. |
| `SANDY_SCREENSHOT_DIR` | privileged | unset | 0.12.0 | stable | Host directory containing screenshots; mounted read-only at /home/sandy/screenshots and exposed as $SANDY_SCREENSHOTS_PATH inside the container. Enables /ss skill across agents. |
| `SANDY_GEMINI_EXTENSIONS` | privileged | unset | 0.9.0 | stable | Comma-separated Gemini extensions to enable. |
| `TELEGRAM_BOT_TOKEN` | privileged | unset | 0.7.6 | stable | Telegram bot token for the channel relay. |
| `TELEGRAM_ALLOWED_SENDERS` | privileged | unset | 0.7.6 | stable | Comma-separated Telegram user IDs allowed to send messages. |
| `DISCORD_BOT_TOKEN` | privileged | unset | 0.7.6 | stable | Discord bot token for the channel relay. |
| `DISCORD_ALLOWED_SENDERS` | privileged | unset | 0.7.6 | stable | Comma-separated Discord user IDs allowed to send messages. |
| `SANDY_HANDOFF_RELAY` | privileged | unset | 1.10.0 | deprecated | REMOVED AS A CONFIGURATION KEY in 2.2.0 (#354) -- setting it from the environment or any config file is a HARD ERROR naming the replacement (declare the executable as an 'entry' in a feature manifest). The INTERNAL CHANNEL it later served -- carrying the relay-designated entry's path from host to container-side supervisor -- was itself removed in 2.6.0 (#382, decisions 4-5): the host now passes every adopted entry to the container only via SANDY_FEATURE_ENTRIES (internal, no metadata row; see 'feature_entries' below), and no entry is designated any more -- every entry is supervised and reported identically. What an entry gets: a container-level process (a sibling of the tmux server, not a pane, not a child of any agent session), started once per container by user-setup.sh before the tmux session exists (never in headless -p runs, never under --remote, never under --provision), held to one instance by flock, restarted on death with exponential backoff (1s doubling to 60s, reset after a 60s+ run), never given up on. Every entry's state (.state, supervisor.log) lives at its own $SANDBOX_DIR/feature-state/<feature>, mounted rw at /opt/sandy/feature-state/<feature> and exported to that entry's own process as SANDY_FEATURE_STATE -- an entry reads its own directory from that variable rather than constructing the path, uniform across every entry. Env contract: SANDY_FEATURE_STATE, SANDY_AGENT, SANDY_WORKSPACE. An entry that cannot start FAILS THE LAUNCH, never warn-and-proceed: missing or not executable, its state dir not mounted, or no flock (user-setup.sh exits 1, the container dies, --start reports crash-looping/exit 7) -- one shared 5s startup window covers every entry at once. DOCUMENTED EXCEPTION: a stale image predating per-feature entries (a deferred build per #218, or any other image built before the sandy.feature_entries=1 Dockerfile label existed) knows only the removed SANDY_HANDOFF_RELAY channel and so starts NONE of the entries -- sandy warns at launch, naming every one, and --print-state reports them all as state absent. There is no runtime toggle to stop them: SANDY_RELAY is a HARD ERROR as of 2.6.0 (see its own row below) with no per-feature replacement, so every adopted entry always runs. Reported in /etc/sandy-session.json as feature_entries.<feature>.{path} -- schema_version 4 (2.6.0, #382, decisions 1-2): relay{} itself, and its two companions relay_alias and disabled_by, are gone from both the marker and --print-state -- and live in --print-state as feature_entries.<feature>.state (every entry, identically). In daemon mode an entry (and anything else planted at the uid) outlives sessions until the container is recreated -- run sandy --update-sessions --yes on a 24h cron. |
| `ANTHROPIC_PROFILE` | privileged | unset | 1.11.0 | experimental | Privileged. Name of the Anthropic Console profile to use when SANDY_CLAUDE_AUTH=profile (overrides the host active_config); forwarded into the container so Claude Code selects it explicitly (its /status shows the Profile row as profile-explicit). Privileged on purpose: it chooses WHICH profile's token enters the box, and a profile logged in with --scope org:admin carries organization-wide access, so a committed .sandy/config must not be able to select it. Ignored with a notice unless SANDY_CLAUDE_AUTH=profile. |
| `SANDY_AGENT` | passive | `claude` | 0.9.0 | stable | Agent(s) to launch. Comma-separated (e.g. 'claude,codex'). 'all' = 'claude,gemini,codex,opencode'. |
| `SANDY_MODEL` | passive | `claude-opus-5` | 0.1.0 | stable | Model ID for the Claude agent. |
| `SANDY_TEAMMATE_MODE` | passive | unset | 1.7.0 | stable | Value passed to 'claude --teammate-mode' (claude only). Empty by default, so sandy does NOT pass the flag and Claude Code uses its own default. Set e.g. 'tmux' to opt in; 'off' or 'none' are also treated as omit. Passive-safe (teammate mode does not affect isolation). Sandy does not seed teammateMode into settings.json either — this flag governs the session, and a host settings.json value is left untouched. |
| `SANDY_EFFORT` | passive | unset | 1.6.0 | stable | Reasoning effort for claude, (2.4.0) codex, and (2.7.0) grok and gemini. Claude: 'claude --effort <level>'; levels are model-dependent and an unsupported level falls back to the highest supported at or below it. Codex: '-c model_reasoning_effort=<level>', each sandy level mapped to its exact codex namesake (max -> max, codex's top non-delegating level; never ultra, which adds multi-agent delegation); whether a codex model offers the level is codex's catalog's business. Grok: '--reasoning-effort <level>' (alias --effort; a top-level option, so TUI and headless alike), low/medium/high/xhigh passed as-is and max CLAMPED to xhigh with a launch notice, because grok rejects max outright. Gemini (no flag): a sandy-generated, read-only system settings file named by GEMINI_CLI_SYSTEM_SETTINGS_PATH, holding only modelConfigs.customOverrides -- Gemini 3 thinkingLevel LOW for low and HIGH otherwise, Gemini 2.5 thinkingBudget 1024/8192/24576 for low/medium/high-and-above; it outranks user and workspace gemini settings and shadows a user's own modelConfigs.customOverrides while set. Empty leaves each agent's own default. Ignored, with a notice, for a launch with none of claude, codex, grok or gemini (opencode has no effort surface sandy drives). Passive-safe (effort does not affect isolation). Recorded in sandy-session.json as the sandy-level value. |
| `SANDY_CPUS` | passive | unset | 0.1.0 | stable | CPU limit for container (default: auto-detected). |
| `SANDY_MEM` | passive | unset | 0.1.0 | stable | Memory limit for container (e.g. '8g'; default: auto-detected). |
| `SANDY_GPU` | passive | unset | 0.7.5 | stable | GPU passthrough: 'all', or device IDs like '0' / '0,1'. |
| `SANDY_SKILL_PACKS` | passive | unset | 0.7.10 | stable | Comma-separated skill pack names (e.g. 'gstack'). |
| `SANDY_CHANNELS` | passive | unset | 0.7.6 | stable | Comma-separated channel names (e.g. 'telegram,discord'). |
| `SANDY_CHANNEL_TARGET_PANE` | passive | `0` | 0.9.0 | stable | Which agent's pane receives Telegram host-relay messages in multi-agent mode: a 0-based position in SANDY_AGENT (0 = first agent, up to 3), resolved to the pane tagged with that agent -- not a raw tmux pane index, which differs from spawn order in the 2x2 grid. |
| `SANDY_VERBOSE` | passive | `0` | 0.8.0 | stable | Verbosity (0=quiet, 1=verbose, 2=debug, 3=full trace). |
| `SANDY_VENV_OVERLAY` | passive | `1` | 0.10.0 | stable | Bind-mount a sandbox-owned .venv over the workspace's .venv inside the container. |
| `SANDY_EGRESS` | passive | `permissive` | 2.0.0 | stable | Egress posture, ONE key as of 2.0.0. off = proxy off (legacy: Linux iptables only, NO network isolation on macOS). permissive (default) = proxy on, blocking private/LAN/link-local/CGNAT/cloud-metadata destinations while allowing the internet. strict = proxy on with an allowlist only (model providers, GitHub, npm, PyPI, crates, Go, Debian) plus SANDY_ALLOW_HOSTS. Replaces a three-way choice encoded as TWO MUTUALLY EXCLUSIVE BOOLEANS (SANDY_EGRESS_NO_ISOLATION, SANDY_EGRESS_STRICT) plus a deprecated tri-state whose 0/1/2 were opaque (SANDY_EGRESS_PROXY) -- all three still work, are listed in README's Deprecated section, and are IGNORED WITH A NOTICE when this key is set (never merged; the winner is named). Value-aware tier: only strict is passive-safe. off and permissive are approval-gated from a workspace .sandy/config, exactly as SANDY_EGRESS_NO_ISOLATION=1 and SANDY_EGRESS_STRICT=0 are -- a workspace value outranks the host config for the same key, so an ungated permissive would silently downgrade a host that chose strict (#371, fixed in 2.4.0; 2.0.0-2.3.x gated only off). Like STRICT=0 it prompts even where the host is already permissive. SANDY_SUSPICIOUS=1 still defaults the posture to strict; an explicit choice wins and a weaker one is named loudly. |
| `SANDY_EGRESS_PROXY` | passive | `1` | 0.14.0 | stable | DEPRECATED — use SANDY_EGRESS=off,permissive,strict. Kept as a back-compat alias: 0->NO_ISOLATION=1 (off), 1->permissive (default), 2->STRICT=1 (strict). From a workspace .sandy/config, =0 (off) and =1 (permissive: a downgrade of a host-set =2) are approval-gated, matching SANDY_EGRESS; only =2 is free (#371). |
| `SANDY_EGRESS_NO_ISOLATION` | passive | `0` | 1.0.0 | stable | Turn the egress proxy OFF — legacy path (Linux iptables-only; NO network isolation on macOS). WEAKENS isolation, so from a workspace .sandy/config it is quarantined to the per-workspace approval prompt (a committed config cannot silently disable isolation). Mutually exclusive with SANDY_EGRESS_STRICT. Default 0 (proxy on). |
| `SANDY_EGRESS_STRICT` | passive | `0` | 1.0.0 | stable | Run the egress proxy in strict mode (allow only the built-in default allowlist + SANDY_ALLOW_HOSTS; deny all other internet). STRENGTHENS isolation, so =1 is passive-safe from any source; =0 (downgrading a host-configured strict) is approval-gated from a workspace source. Mutually exclusive with SANDY_EGRESS_NO_ISOLATION. Default 0 (permissive). |
| `SANDY_EGRESS_LOG` | passive | `0` | 1.4.0 | stable | Log which hosts the agent's egress actually reached (HF-incident Issue 4). The proxy logs each DISTINCT allowed host:port once (deduped) to proxy.log; at session end sandy prints an egress summary (distinct hosts reached + denial count). 0=off (deny-only, the pre-1.4 behavior); 1=per-connection allow lines + session-end summary; summary=session-end summary only (the proxy still records allows to build it). Passive-safe: it only ADDS visibility. Hostnames only — TLS is never terminated, no payload; the log stays in $SANDBOX_DIR. |
| `SANDY_ALLOW_WORKFLOW_EDIT` | passive | `0` | 0.11.1 | stable | Remove .github/workflows from the read-only protection list. |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | passive | `128000` | 0.6.0 | stable | Max output tokens per Claude response. |
| `CLAUDE_CODE_SUBAGENT_MODEL` | passive | unset | 1.11.0 | stable | Model ID for Claude Code SUBAGENTS -- the parallel researchers a skill fans out. Subagents do NOT inherit the orchestrator model, so unset they run on their own default tier: a session pinned to a gated model (e.g. claude-mythos-5-1) silently does its fan-out work on a different one, with nothing in the transcript saying so. Passive-safe: a model ID is not a capability and can only select a model the session credential is already entitled to. |
| `GEMINI_MODEL` | passive | unset | 0.9.0 | stable | Gemini model override. |
| `SANDY_GEMINI_AUTH` | passive | `auto` | 0.9.0 | stable | Gemini credential probe strategy. |
| `GOOGLE_CLOUD_PROJECT` | passive | unset | 0.9.0 | stable | Google Cloud project for Vertex AI. |
| `GOOGLE_CLOUD_LOCATION` | passive | unset | 0.9.0 | stable | Google Cloud location for Vertex AI. |
| `GOOGLE_GENAI_USE_VERTEXAI` | passive | unset | 0.9.0 | stable | Use Vertex AI backend for Gemini. |
| `CODEX_MODEL` | passive | unset | 0.10.0 | stable | Codex model override. |
| `SANDY_CODEX_AUTH` | passive | `auto` | 0.10.0 | stable | Codex credential probe strategy. |
| `OPENCODE_MODEL` | passive | unset | 0.12.0 | stable | OpenCode model override (provider/model format, e.g. 'anthropic/claude-sonnet-4'). |
| `SANDY_OPENCODE_AUTH` | passive | `auto` | 0.12.0 | stable | OpenCode credential probe strategy. |
| `GROK_MODEL` | passive | unset | 1.5.0 | stable | Grok Build model override (passed as -m; default grok-4.5). |
| `SANDY_GROK_AUTH` | passive | `auto` | 1.5.0 | stable | Grok Build credential probe strategy. |
| `SANDY_CLAUDE_AUTH` | passive | `auto` | 1.10.0 | stable | Claude Code credential selection. auto (default): a long-lived CLAUDE_CODE_OAUTH_TOKEN wins, else the host OAuth credentials file is mounted and ANTHROPIC_API_KEY is SUPPRESSED (Claude Code resolves an env key ahead of the account credentials, so forwarding both either bills per-use or parks the session on the custom-API-key startup modal). api_key: forward ANTHROPIC_API_KEY and do NOT mount OAuth credentials -- a revocable project key instead of the account refresh token, and the only way to choose per-use billing on a host that has OAuth. oauth: mount OAuth and never forward the API key. profile (1.11.0): use an Anthropic Console profile written by `ant auth login` (the Claude Platform CLI) -- the ONLY way to reach a workspace-bound entitlement such as Claude Mythos. Sandy copies just the selected profile (ANTHROPIC_PROFILE, else the host active_config, else default) from $ANTHROPIC_CONFIG_DIR (default ~/.config/anthropic) into an ephemeral rw mount at ~/.config/anthropic and withholds the OAuth credentials file, CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY, because Claude Code ranks a user_oauth profile BELOW a /login credential and below every env credential -- measured on 2.1.263. Never probed by auto. Value-aware tier: api_key, profile and auto are passive-safe (each REDUCES what is in the container), while oauth from a workspace is approval-gated because it forces the account-scoped credential in even when a revocable key is available. |
| `SANDY_TOOL_AUDIT` | passive | `0` | 1.4.0 | stable | Seed a Claude Code PreToolUse audit hook (HF-incident Issue 6) that appends {ts,tool,args} JSONL to ~/.claude/tool-audit.jsonl for per-session tool-use telemetry — instrumenting the agent harness itself, not just the box. Only-if-absent: a user's own PreToolUse hook is never clobbered. Passive-safe (only ADDS visibility). Claude-only (no equivalent seam for codex/gemini/opencode). Not tamper-proof against a determined agent (runs in-box) — telemetry for the primary wrong-but-not-evil adversary. Default 0 (off). |
| `SANDY_CLAUDE_CONNECTORS` | passive | `0` | 1.9.0 | stable | Expose the claude.ai ACCOUNT connectors (Gmail, Google Drive, ...) inside the sandbox (#129). Default 0 = SUPPRESSED. The OAuth token sandy mounts is account-scoped, so without this every connector the user ever enabled on claude.ai was reachable from EVERY sandbox -- including untrusted-repo sessions, with no extra prompt -- which is ambient authority crossing the per-project boundary sandy exists to draw. Implemented by seeding Claude Code's disableClaudeAiConnectors as a MANAGED settings.json key (always overwritten, both directions): Claude resolves it true-in-ANY-settings-scope-wins, so writing false is not enough to expose them -- an inherited true from the host settings.json would win. VALUE-AWARE TIER: 0 is passive-safe wherever it is set, but =1 WEAKENS the sandbox, so a workspace .sandy/config setting it triggers the per-workspace approval prompt like SANDY_EGRESS_NO_ISOLATION=1. Claude-only (the account-connector rider is a Claude Code phenomenon); gates AUTO-FETCHED connectors only -- a server passed explicitly via --mcp-config still follows the normal MCP trust flow. |
| `SANDY_SUSPICIOUS` | passive | `0` | 1.9.0 | experimental | Hardened-credential posture for a workspace you actively distrust (#130) -- the pre-broker slice of #121. When 1: (a) the mounted Claude .credentials.json is REWRITTEN to drop claudeAiOauth.refreshToken, so an exfiltrated copy is worth only the remaining access-token lifetime (hours) instead of permanent renewable account access; the strip is verified after the rewrite and FAILS CLOSED -- if it cannot be performed or verified, no credentials file is mounted at all; (b) if ANTHROPIC_API_KEY is set and no long-lived CLAUDE_CODE_OAUTH_TOKEN is, the API key is used and OAuth credentials are not mounted (clean, instantly-revocable compartmentalization); (c) claude.ai account connectors are forced off, overriding an approved SANDY_CLAUDE_CONNECTORS=1; (d) egress DEFAULTS to strict -- an explicit egress setting still wins but is named loudly. Since 1.12.0 this also covers SANDY_CLAUDE_AUTH=profile (#252): the ephemeral copy of the Console profile has its refresh_token stripped (the host profile is never touched) and cred_mode becomes profile-access-only; a strip that cannot be performed or verified mounts NO profile at all. The resolved posture is recorded as cred_mode in /etc/sandy-session.json so a run protection level is provable after the fact. Passive-safe to turn ON from a committed .sandy/config (a repo may make itself tighter); =0 from a workspace is approval-gated (never looser). HONEST LIMITS: in-session token refresh stops working once the access token expires (rerun sandy or /login -- acceptable for a deliberately short suspicious session); a long-lived CLAUDE_CODE_OAUTH_TOKEN is NOT shrunk by this (recorded honestly as cred_mode oauth-token, with a warning); Claude-only for the credential specifics; real prevention (token never in-container) is #121. |
| `SANDY_CROSS_SESSION_INBOUND` | passive | unset | 1.10.0 | experimental | Claude-only. Pins Claude Code crossSessionInbound (accept = deliver messages from other sessions on this container without a prompt; hold = queue for approval; refuse = drop with a sender-visible status) by writing the SAME resolved value into TWO places every launch, merge-preserving and idempotent: the sandbox's own claude/settings.json (mounted RW as the container's ~/.claude/settings.json, i.e. Claude Code userSettings) and the WORKSPACE project file .claude/settings.local.json (mounted :ro). This split is measured, not assumed, against Claude Code 2.1.251: accept only takes effect when present in userSettings (workspace-file accept alone is a no-op there); hold/refuse are honored from either, and the workspace file's copy is tighten-only so it cannot be loosened by a stale accept and still wins over userSettings when a repo hand-edits it stricter. Never writes ~/.claude/settings.json on the HOST. Default is CONDITIONAL, which is why the schema default is empty, and as of 2.4.0 (#380) it is keyed on a DECLARED NEED rather than on any entry: accept iff a SELECTED feature manifest declares `"receives": ["cross_session"]` AND this is not a headless (-p), --remote or --provision run (none of those leave a session for anything to deliver into), else refuse. An entry alone, with no feature declaring the need, resolves refuse. (Pre-2.6.0 sandy also accepted on the strength of a feature entry alone -- announced for removal in README's Deprecated table in 2.5.0 (#382) and removed in 2.6.0; see CLAUDE.md "Cross-session inbound".) A declared need is independent of whether any entry process runs at all -- `receives` is its own, separate, privileged statement of what a feature needs to receive, decoupled from whether that feature ships an `entry`. Value-aware tier: hold and refuse are passive-safe wherever set; accept set via a workspace .sandy/config is approval-gated (it lets any process at the workspace uid inside the container inject a turn) -- unchanged, whichever default path resolved it. Residual: the userSettings target is RW in-container (required for /plugin install), so unlike the :ro workspace copy it is agent-mutable mid-session; sandy resets it on the next launch, not mid-session. Recorded in /etc/sandy-session.json as cross_session_inbound, with cross_session_inbound_source (one of explicit, feature:<name> or default) naming WHY. See docs/security/CROSS_SESSION_INBOUND.md. |
| `SANDY_RELAY` | passive | unset | 1.11.0 | deprecated | REMOVED in 2.6.0 (#382) after its 2.5.0 announcement: setting it from ANY source (environment, host config or a workspace .sandy/config), to any value, is a HARD ERROR naming the replacement -- add the sandbox to a feature manifest's "sandboxes": {"exclude": [...]}. There is deliberately no per-feature off switch and no replacement key. The key stays in the passive tier only so the loader recognizes it and fails rather than silently ignoring it as unknown. |
| `SANDY_OFFLINE` | passive | `0` | 2.4.0 | stable | Offline mode (#219): skip the lookups a launch makes only to learn whether something NEWER exists -- the per-agent version checks (a hit forces a --no-cache agent rebuild), skill-pack version resolution from GitHub (falls back to the local cache, then the built-in pin), and sandy's own release nag. Builds that are REQUIRED still run: a missing image or a changed Dockerfile builds through the build-reachability gate and fails there as it always has. For a known-bad network (in-flight wifi, captive portal) or an air-gapped host, where the checks cost latency and a detected update would force a rebuild that cannot succeed. The one-shot CLI form is --no-update-check, which wins over this key. Passive-safe: it defers the auto-patch pickup the wrapped-agent CVE posture relies on, but only until the next launch without it -- equivalent to not relaunching -- and it is never silent: one line at launch, one at session end, and 'offline': true in /etc/sandy-session.json. Default 0. |
| `SANDY_AUTO_APPROVE_PRIVILEGED` | env-only | unset | 0.11.2 | internal | Bypass TWO of the three launch approval gates: the passive-privileged config-key prompt AND the per-project .sandy/Dockerfile build prompt (an unreviewed project image then builds, running its RUN commands on the host docker daemon with unfiltered network). It does NOT bypass the dangerous-symlink gate, deliberately: that gate is built so no approval of a new escaping symlink can happen without a deliberate human act (a new escape is a hard error, never a re-prompt), and a blanket bypass would silently mount every future escape read-write. Env-only, so a committed config cannot set it. Intended for CI / test harnesses only. |
| `SANDY_DEBUG_CLEANUP` | env-only | unset | 0.11.4 | internal | Print session-stub cleanup diagnostics on exit. |
| `SANDY_HOST_ID` | env-only | unset | 1.8.0 | stable | Operator override for the host_id reported by --print-state (#179), advisory identity for multi-host fleet aggregation (sandbox names hash only the workspace path, so the same path on two hosts collides). ENV-ONLY -- a committed .sandy/config can never set it, which would otherwise forge the identity of whatever machine the repo is cloned onto. Default is uname -n (host_id_source: hostname); a valid override reports host_id_source: env. Invalid or empty values are silently ignored and fall back to uname -n -- no warning, ever, since --print-state guarantees 0 bytes of stderr. |
<!-- END AUTOGEN:config-keys-table -->

### Model Validation

`SANDY_MODEL` is validated against `^[a-zA-Z0-9._-]+$` to prevent injection.

---

## 3. Versioning

### Version Variables

- **`SANDY_VERSION`**: `X.Y.Z` for releases, `X.Y.(Z+1)-dev` for post-release development
- **`SANDY_COMMIT`**: Empty in source; baked in by `install.sh` for local installs; detected from git at runtime if empty

### Full Version String

`sandy_full_version()` produces strings like `0.7.11-dev-a1b2c3d` by combining `SANDY_VERSION` and the commit hash.

### Update Check

Compares only `SANDY_VERSION` (not hash) against GitHub release tags via `https://api.github.com/repos/rappdw/sandy/releases/latest`. Result cached in `~/.sandy/.update_check` with 24-hour TTL.

---

## 4. Per-Project Sandboxes

### Naming

Each project directory gets a sandbox at `~/.sandy/sandboxes/<NAME>-<HASH>/`:
- `<NAME>`: Sanitized `basename` of project directory (alphanumeric, dots, hyphens)
- `<HASH>`: First 8 characters of SHA256 of the **canonicalized** project path (via `pwd -P` — resolves symlinks and folds case-collisions on case-insensitive filesystems)

Each launch also writes `$SANDBOX_DIR/WORKSPACE.json` (non-hidden) — a structured forensic record of which workspace the sandbox belongs to. Fields:

```json
{
  "schema_version": 1,
  "sandbox_name": "myproject-a1b2c3d4",
  "workspace_path": "/Users/dan/dev/myproject",
  "workspace_path_uncanonicalized": "/Users/dan/dev/MyProject",  // optional
  "first_seen_at": "2026-04-26T17:33:01Z",
  "last_seen_at": "2026-04-27T09:14:22Z",
  "sandy_version_first": "0.11.5-dev",
  "sandy_version_last": "0.12.0-dev"
}
```

`workspace_path_uncanonicalized` is present only when the user's typed `pwd` differs from the canonical `pwd -P` (a case-collision or symlinked alias) — useful when diagnosing why two sandboxes ended up with overlapping state. `first_seen_at` is preserved across launches; the `_last` fields refresh on every launch.

On launch, sandy scans sibling sandbox directories: any whose `workspace_path` field matches the current `WORK_DIR` is reported as a likely duplicate via `warn`. For legacy sandboxes lacking `WORKSPACE.json` entirely, sandy falls back to a heuristic: case-insensitive `<NAME>` match with a different `<HASH>`. Detection is read-only — sandy never auto-merges sandbox state, since accumulated settings/plugins/package caches make manual review the right call.

### Host-side path contract (stable, 2.7.0, #386)

Host-side tools (fleet adapters, UIs, dashboards) need some way to find what runs inside a sandbox. This section is the **only** part of the sandbox directory they may depend on. Everything else under `$SANDY_HOME` is private and may change in any release (see "Directory Layout" below). Stable here means the same as for the "Pane-identity contract" in §12: renaming or removing any of these facts is a breaking change, governed by README's `## Deprecated` table (announced in an `X.0.0`, removed no earlier than a later `X.Y.0`).

**Find a sandbox from `--print-state`, never by constructing its path.** Every path below is relative to that sandbox's `sandboxes[].path`. The slug, the hash and `$SANDY_HOME`'s own layout are not part of the contract. "A consumer constructs a path sandy owns" has broken three times already (#248, #345, #353), which is why this contract publishes as few paths as possible.

**1. Agent home mapping.** Each selected agent's home directory inside the container is a bind mount of one directory in the sandbox. Anything an in-container process writes under that home is therefore readable on the host at the mapped path.

| host (under `sandboxes[].path`) | container | mounted when |
|---|---|---|
| `claude/` | `~/.claude/` | `claude` is among the launch's agents |
| `gemini/` | `~/.gemini/` | `gemini` is among them |
| `codex/` | `~/.codex/` | `codex` is among them |
| `grok/` | `~/.grok/` | `grok` is among them |
| `opencode/config/` | `~/.config/opencode/` | `opencode` is among them |
| `opencode/share/` | `~/.local/share/opencode/` | `opencode` is among them |

Sandy promises the **mapping, not the contents**. Files Claude Code, another agent or a third-party daemon writes there belong to their writer. The files sandy itself seeds there (for example `claude/settings.json`) are not part of this contract; read what sandy resolved from `--print-state` instead (`cross_session_inbound`, `agent_args`). The container home is `/home/sandy` (2.0.0). Pinned by `run-tests.sh` §177(1), which runs the real mount assembly for each agent alone and asserts these pairs exactly.

**2. Feature mount destinations.** A feature manifest's mount `name` determines its container path (FEATURE-MANIFEST.md D5):
- `payload` → `/opt/sandy/features/<feature>` (read-only by default);
- `.` → `~/.<feature>/`;
- `<name>` → `~/.<feature>/<name>`.

A supervised entry's own state directory is `/opt/sandy/feature-state/<feature>`, exported to that entry as `SANDY_FEATURE_STATE`. An entry reads the variable; it never constructs the path.

**3. Daemon container labels.** A daemon-mode agent container carries:

| label | value |
|---|---|
| `sandy.daemon` | `true` |
| `sandy.workspace_path` | the canonical workspace path |
| `sandy.session` | the sandbox name (`sandboxes[].name`) |
| `sandy.started_at` | UTC launch time |
| `sandy.daemon_pid` | the host supervisor's pid |
| `sandy.updated_at` | UTC time, present only on a restart made by `--update-sessions` |

Other `sandy.*` labels (`sandy.managed`, `sandy.provision_id`, `sandy.provisioned_at`, the image labels `sandy.feature_entries`, `sandy.proxy_src` and `sandy.proxy_epoch`) are internal; the proxy's two are published through `--print-state` as `proxy_image_src`/`proxy_image_epoch`.

**Also a contract, but documented elsewhere:**
- the in-container session marker at `/etc/sandy-session.json` (its host copy is private; use `--print-state`);
- the pane-identity contract (§12);
- the `--print-state` document itself (`SPEC_INTROSPECTION.md`).

### Directory Layout

**Private.** This tree describes the current implementation, for maintainers and debugging. Only the paths in "Host-side path contract" above are stable; everything else here may move, be renamed or disappear in any release. A host tool that needs a value from one of these files should get it from `--print-state`; if `--print-state` doesn't carry it, ask for a field, not a path.

```
~/.sandy/sandboxes/
├── <name>-<hash>/                 # one per workspace; <name>-<hash> is sandboxes[].name
│   ├── claude/                    # CONTRACT → ~/.claude (settings.json, projects/, plugins/, hooks/, …)
│   │                              #   .claude.json: Claude Code's global config (CLAUDE_CONFIG_DIR, #400);
│   │                              #   an operator MCP server block goes here
│   │                              #   sessions/<pid>.json|.key: Claude Code's live-session registry; every
│   │                              #   launch prunes these once no container can exist (#407)
│   ├── gemini/                    # CONTRACT → ~/.gemini
│   ├── codex/                     # CONTRACT → ~/.codex (config.toml, auth.json when seeded)
│   ├── grok/                      # CONTRACT → ~/.grok
│   ├── opencode/
│   │   ├── config/                # CONTRACT → ~/.config/opencode
│   │   └── share/                 # CONTRACT → ~/.local/share/opencode
│   ├── pip/                       # → ~/.pip-packages (PYTHONUSERBASE)
│   ├── uv/                        # → ~/.local/share/uv
│   ├── npm-global/                # → ~/.npm-global
│   ├── go/                        # → ~/go (GOPATH)
│   ├── cargo/                     # → ~/.cargo
│   ├── venv/                      # → <workspace>/.venv overlay (when the workspace has a .venv/)
│   ├── feature-state/<feature>/   # → /opt/sandy/feature-state/<feature> (rw), one per adopted entry
│   ├── agent-args-composed/       # → /opt/sandy/agent-args (ro), merged agent_args files (#363)
│   ├── workspace-*/               # writable overlays: .claude/commands|agents|plugins, gemini commands
│   ├── agent-args.<agent>         # operator per-agent args (privileged by location)
│   ├── sandy-session.json         # host copy of /etc/sandy-session.json (read it via --print-state)
│   ├── gemini-system-settings.json # → /etc/sandy-gemini/effort.json (ro), only with gemini + SANDY_EFFORT (B.10)
│   ├── WORKSPACE.json             # workspace lineage (see "Naming")
│   ├── proxy.log, sandy-proxy.json # egress proxy log and state (when the proxy is on)
│   ├── .sandy_created_version     # version tracking (see CLAUDE.md "Sandbox version tracking")
│   ├── .sandy_last_version
│   ├── .sandy-approved-symlinks.list, .protected-existed-at-launch, .head-at-launch,
│   │   .claude-perm-mode-at-launch, .project_build_hash, …   # launch bookkeeping
│   └── .v1-backup/                # only on a sandbox migrated from the v1 layout
├── <name>-<hash>.claude.json      # LEGACY (≤2.6.x): moved into <name>-<hash>/claude/.claude.json at the next launch (#400)
└── .<name>-<hash>.lock/           # the per-workspace launch mutex
```

**Legacy leftovers.** Older sandboxes may still carry directories that no current launch creates:
- `relay-state/` (2.2.0–2.5.x): removed at the next launch, with one info line.
- `handoff/` (≤2.1.x): inert; `--reset-sandbox` destroys it.
- `relay-bin/` (≤2.1.x): a leftover entry is a hard error naming the manifest `entry`.
- `features/` (1.15.x): never read.
- `gstack/` becomes `gstack.migrated/` on the first 0.12+ launch.

**Layout migration (v1 → v1.5)**: On each launch, sandy detects the v1 layout marker (`settings.json` at the sandbox top level with no `claude/` subdir) and moves Claude-owned entries into `claude/`. Idempotent; pre-existing pkg-persistence and workspace-* directories are untouched.

### Seeding

Whenever `claude` is in `SANDY_AGENT`, sandy regenerates `<NAME>/claude/settings.json` **on every launch** (not just first run). As of 0.11.3 this is a plain rw file inside the sandbox mount — the pre-0.11.3 `:ro` sidecar overlay was reverted because it broke `/plugin install` with EROFS. The steps are:

1. Base: read host `~/.claude/settings.json` (or start from `{}` if absent).
2. Overlay: read the previous sandbox `<NAME>/claude/settings.json` (if it exists) and preserve `enabledPlugins` from it onto the base, so plugin installs survive across launches.
3. Merge sandy-required defaults (`spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, `skipAutoPermissionPrompt`) if not already present. `skipAutoPermissionPrompt` suppresses the 2.1.x auto-mode default offer and tracks `SANDY_SKIP_PERMISSIONS`. **`teammateMode` is deliberately NOT seeded** (1.7.0): the `--teammate-mode` CLI flag governs the session, so seeding the file too only created a second, divergable source of truth. `SANDY_TEAMMATE_MODE` is also empty by default, so sandy passes no `--teammate-mode` flag at all unless a user opts in; a host `settings.json` value is left untouched. When `SANDY_SKIP_PERMISSIONS=true` (the default), also set `permissions.defaultMode = "bypassPermissions"` (overwrite, not merge — toggling `SANDY_SKIP_PERMISSIONS` between launches reliably propagates). When `SANDY_SKIP_PERMISSIONS=false`, the key is removed if previously sandy-set. `permissions.disableBypassPermissionsMode` (host policy) is left alone.
4. Merge `extraKnownMarketplaces` entries for `claude-plugins-official` and `sandy-plugins`; scrub deprecated entries (`thinkkit`, `ait`, `pka-skills`).
5. Write the merged result back to `<NAME>/claude/settings.json`.
6. (First run only) Copy host `~/.claude.json` → sandbox `<NAME>/claude/.claude.json`, stripping the `projects` key. Before that, a pre-2.7 sibling `<NAME>.claude.json` is moved in (#400).
7. (First run only) Copy host `~/.claude/statsig/` → sandbox `claude/statsig/` (refreshed on every launch from a separate "always-refresh statsig" block).
8. (First run only) Create all persistent subdirectories.

At container launch, `<NAME>/claude` is bind-mounted rw at `/home/sandy/.claude` — there is no child `:ro` overlay on `settings.json`. The agent can write to it (required for `/plugin install`), but sandy-managed keys are re-overwritten on the next launch.

**Consequence:** host-side edits to `~/.claude/settings.json` are picked up automatically on the next sandy launch, and the sandy-managed keys are always re-derived. Agent-owned state (`enabledPlugins`) is preserved across launches. The trade-off vs a strict reset: the agent can modify its own settings mid-session, and those modifications (to keys sandy doesn't manage) persist into the next session as well — the merge overlays rather than wipes.

Whenever `gemini` is in `SANDY_AGENT`, sandy creates `gemini/` and its `commands/`, `extensions/`, `tmp/` subdirs. Gemini settings.json is not seeded from the host (Gemini has no direct host-settings equivalent for sandy to copy).

For `SANDY_AGENT=codex`, sandy creates `codex/` and seeds `codex/config.toml` (first run only; the top-level `sandbox_mode` is then value-checked and repaired on every launch — see C.7b) with:

```toml
model = "gpt-5.5"
sandbox_mode = "danger-full-access"

[notice]
hide_full_access_warning = true
hide_gpt5_1_migration_prompt = true
"hide_gpt-5.1-codex-max_migration_prompt" = true
hide_rate_limit_model_nudge = true
hide_world_writable_warning = true
```

The `model = "gpt-5.5"` line sets a stable default model; users can override via `CODEX_MODEL` env var. The `sandbox_mode = "danger-full-access"` line is required — codex's Landlock sandbox does not nest cleanly inside sandy's Docker container. Sandy provides the outer isolation, and the CLI is additionally invoked with `--sandbox danger-full-access` as belt-and-suspenders in `build_codex_cmd`. The `[notice]` block suppresses first-run prompts; all five documented keys are seeded even if codex adds more over time.

**One-shot model migration**: existing sandboxes seeded with the old default (`model = "gpt-5.4"`) are auto-bumped to `gpt-5.5` on next launch. The migration matches the exact previous default line — any user-customized model (anything other than `"gpt-5.4"`) is preserved untouched.

The `[projects."<workspace>"] trust_level = "trusted"` entry is **appended at session start by `user-setup.sh`** (not at host-time) because it needs the container-side `$SANDY_WORKSPACE` path. Re-launches are idempotent: the entry is only appended if a matching line is not already present.

### OpenCode Config Seeding

When `opencode` is in `SANDY_AGENT`, sandy creates `opencode/config/` and `opencode/share/` (mounted at `~/.config/opencode` and `~/.local/share/opencode` inside the container respectively). The seed logic for `opencode/config/opencode.json` runs whenever that file is missing in the sandbox and resolves three input states:

1. **Host config exists** at `$HOME/.config/opencode/opencode.json` → `cp` it into the sandbox. Preferred path; the user's explicit provider/model preferences win.

2. **No host config but `SANDY_LOCAL_LLM_HOST` is set** → auto-generate. Sandy probes `http://${SANDY_LOCAL_LLM_HOST}/v1/models` (3-second timeout, host-side `curl`) for the served model id, prefers `jq` for JSON parsing and falls back to a `grep`/`sed` regex extracting the first `"id":"…"`. If the probe yields a model id, sandy writes a single-provider, single-model `opencode.json` using the `@ai-sdk/openai-compatible` SDK package, with `baseURL` set to `http://host.docker.internal:<port>/v1`, the model id registered, and `"model": "local/<model-id>"` pinned as the default. The model id may contain slashes (e.g. `RedHatAI/gemma-4-31B-it-FP8-block`); opencode parses `provider/model` on the first slash, so `local/<model-id>` works regardless. If the probe fails, sandy emits a warning and proceeds without writing a config.

3. **Neither** → opencode would silently fall back to its built-in default model (currently `gemini-3-pro-preview`), which fails on first request without `GOOGLE_GENERATIVE_AI_API_KEY`. Sandy emits a `warn`-level banner enumerating the three resolutions: export an API key, write the host config, or set `SANDY_LOCAL_LLM_HOST`. Launch proceeds — the user may have an out-of-band auth path the warning didn't anticipate.

The auto-generated config is sandbox-scoped only — sandy never writes to `$HOME/.config/opencode/`. To customize, the user copies the generated file to `$HOME/.config/opencode/opencode.json`, after which the next sandbox creation will prefer state 1.

---

## 5. Docker Image Build Pipeline

Sandy generates all Dockerfiles, entrypoint scripts, and config files at runtime in `$SANDY_HOME/`. Each phase has content-hash-based caching — images only rebuild when their inputs change.

### Phase 1: Base Image (`sandy-base`)

**Dockerfile**: `Dockerfile.base`
**Rebuild trigger**: Content hash of Dockerfile.base changes, or `--rebuild` flag

Contents:
- **OS**: Debian trixie-slim
- **System tools**: build-essential, git, git-lfs, jq, ripgrep, socat, tmux, curl, cmake, openssh-client, less, pkg-config, gosu
- **GitHub CLI**: `gh`
- **Node.js 24 LTS**: Via NodeSource
- **Go 1.26**: Multi-arch binary from go.dev (latest 1.26.x resolved at build time)
- **Rust stable**: Via rustup (installed to `/usr/local/rustup` and `/usr/local/cargo`)
- **Bun**: Via `curl https://bun.sh/install`
- **uv**: Via `curl https://astral.sh/uv/install.sh` (installed to `/usr/local/bin`)
- **Python 3**: Debian system Python + python3-venv
- **Libraries**: libcairo2, libgdk-pixbuf-2.0-0, libpango-1.0-0, libssl-dev, ncurses-term
- **User**: `claude` (UID 1001, shell `/bin/bash`)

### Phase 2: Claude Code Image (`sandy-claude-code`)

**Dockerfile**: `Dockerfile`
**Rebuild trigger**: Content hash of (Dockerfile + entrypoint.sh + user-setup.sh + tmux.conf) changes, base image rebuilt, Claude Code version update, or `--rebuild` flag

Contents:
- `FROM sandy-base`
- Claude Code: Native binary installed via `curl https://claude.ai/install.sh`, relocated to `/usr/local/bin/claude` and `/opt/claude-code`
- synthkit dependencies: libpango1.0-dev, libcairo2-dev, libgdk-pixbuf-2.0-dev (WeasyPrint needs these)
- synthkit: Installed via `UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install synthkit`
- `COPY`: entrypoint.sh, user-setup.sh, tmux.conf
- Claude Code version cached at `/opt/claude-code/.version`

### Phase 2 (alt): Gemini CLI Image (`sandy-gemini-cli`)

**Dockerfile**: `Dockerfile.gemini`
**Rebuild trigger**: Content hash changes, base image rebuilt, or `--rebuild` flag

`FROM sandy-base` + `npm install -g @google/gemini-cli` + synthkit. Used only when `SANDY_AGENT=gemini`.

### Phase 2 (alt): Codex CLI Image (`sandy-codex`)

**Dockerfile**: `Dockerfile.codex`
**Rebuild trigger**: Content hash changes, base image rebuilt, Codex CLI version update detected, or `--rebuild` flag

Contents:
- `FROM sandy-base`
- Codex CLI: `npm install -g @openai/codex` (ships a prebuilt Rust binary per platform; Node is only the install vehicle)
- Version cached at `/opt/codex/.version`
- synthkit deps (libpango/cairo/gdk-pixbuf) + synthkit itself (so `md2pdf`, `md2doc`, `md2html`, `md2email` are on PATH)
- `COPY`: entrypoint.sh, user-setup.sh, tmux.conf

Used only when `SANDY_AGENT=codex`. The update check hits `https://api.github.com/repos/openai/codex/releases/latest` (not `/releases`) — upstream flags stable releases there, so sandy inherits their judgment rather than inventing a prerelease filter. The tag name `rust-vX.Y.Z` is stripped with `sed -E 's/.*"rust-v?([0-9][^"]*)"$/\1/'`. On parse failure the check returns no-update (stale but working).

### Phase 2 (alt): OpenCode Image (`sandy-opencode`)

**Dockerfile**: `Dockerfile.opencode`
**Rebuild trigger**: Content hash changes, base image rebuilt, OpenCode version update detected, or `--rebuild` flag

Contents:
- `FROM sandy-base`
- OpenCode: `npm install -g opencode-ai` (the `opencode-ai` package ships per-platform binaries via `optionalDependencies` plus a postinstall script that selects the right one)
- Version cached at `/opt/opencode/.version`
- synthkit deps (libpango/cairo/gdk-pixbuf) + synthkit itself (so `md2pdf`, `md2doc`, `md2html`, `md2email` are on PATH; OpenCode does not yet auto-discover skills, but synthkit is useful as a general-purpose toolkit in the session)
- `COPY`: entrypoint.sh, user-setup.sh, tmux.conf

Used only when `SANDY_AGENT=opencode`. The update check hits `https://registry.npmjs.org/opencode-ai/latest` and parses `"version":"X.Y.Z"` with the same `sed -E 's/.*"([^"]+)"$/\1/'` shape as the gemini check.

### Phase 2.5a: Skill Pack Base Image (`sandy-skills-base-<pack>`)

**Dockerfile**: `Dockerfile.skills-base`
**Rebuild trigger**: Content hash changes, or Phase 2 image rebuilt
**Only generated when**: `SANDY_SKILL_PACKS` is set and a pack requires heavy base dependencies

Contents (for gstack):
- `FROM sandy-claude-code`
- Playwright installed via npm
- Chromium browser installed via `npx playwright install chromium`
- System deps for Chromium via `npx playwright install-deps chromium`

This image changes rarely (only when Playwright version changes) and caches the ~400MB Chromium download.

### Phase 2.5b: Skill Pack Code Image (`sandy-skills-<pack>`)

**Dockerfile**: `Dockerfile.skills`
**Rebuild trigger**: Content hash changes (new version SHA in download URL), base skills image rebuilt, or Phase 2 image rebuilt

Contents (for gstack):
- `FROM sandy-skills-base-<pack>`
- Download gstack source tarball at pinned version/SHA
- `bun install` + `bun run build`
- Make `bin/*` executable

This image rebuilds whenever a new commit is detected on the skill pack repo (fast, since Chromium is cached in the base).

### Phase 3: Per-Project Image (optional, `sandy-project-<name>-<hash>`)

**Dockerfile**: `.sandy/Dockerfile` in project directory
**Rebuild trigger**: Content hash changes, any upstream image rebuilt
**Build context**: a **staged copy** of `.sandy/` holding exactly the files the approval hashed — every regular file except the top-level `config` and `.secrets` (2.7.0, #295)

User-provided Dockerfile must declare `ARG BASE_IMAGE` and use `FROM ${BASE_IMAGE}`. Sandy invokes `docker build --build-arg BASE_IMAGE=<IMAGE_NAME> -t sandy-project-<name>-<hash> -f <stage>/Dockerfile <stage>` where `<IMAGE_NAME>` is the most-derived image from the build chain (skills image if skill packs enabled, otherwise `sandy-claude-code`) and `<stage>` is a `mktemp -d` directory under `$TMPDIR`, removed after the build.

**The staged context (`_sandy_stage_project_context`, 2.7.0, #295).** `_sandy_context_hash DIR --list` is the one enumeration: the approval hashes that list and the stage copies that list, so the reviewed file set and the file set docker is sent are the same by construction. Before this, docker was handed the raw `.sandy/` dir, so `config` and `.secrets` — excluded from the hash as sandy's own settings — were still **sent**, and a `COPY .secrets` baked the workspace's credentials into an image layer; they are now never staged, so such a `COPY` fails the build. The exclusions are the **top-level** `config`/`.secrets` only (the old `! -name config` also skipped a nested helper of that name, which docker sent and a `RUN` could execute while edits to it never re-prompted — such a file now counts, so a workspace that has one re-prompts once). Regular files only: a symlink is neither hashed nor staged. Staging **refuses** (the launch exits 1, nothing left in `$TMPDIR`) when `.sandy/Dockerfile` is itself a symlink (its content was never part of any approval), when a file cannot be copied, or when the staged set does not hash to the value the gate judged (`_SANDY_DF_HASH`) — a context edited between the review and the build is not built.

**Per-workspace approval gate (`_sandy_project_dockerfile_approved`, HF-incident Issue 7).** Building `.sandy/Dockerfile` runs its `RUN` commands on the **host** docker daemon with **unfiltered network** (the build predates and bypasses the egress proxy) and takes all of `.sandy/` as context — so an agent that writes `$WORKSPACE/.sandy/Dockerfile` in one session would get host code-execution on the next launch. Before building, sandy gates on explicit per-workspace approval: a sha256 of the whole build context (`_sandy_context_hash`: every regular file in `.sandy/` except the top-level `config` and `.secrets`) is checked against `$SANDY_HOME/approvals/dockerfile-<workspace-hash>.list` (same machinery/format as the passive-privileged config gate). An unchanged, already-approved Dockerfile proceeds silently; a **new or edited** one prints the Dockerfile and a warning and prompts `y/N` on an interactive TTY. **Fail-closed when non-interactive** (`_sandy_is_headless` or no tty): sandy skips the project build entirely and runs the **base** agent image, with a pointer to approve interactively — so a committed/agent-written Dockerfile can never build unattended (in CI, `--start`, or sandy-ui). `SANDY_AUTO_APPROVE_PRIVILEGED=1` (env-only, same as the config gate) bypasses the prompt for trusted test harnesses. **Under `--start` the prompt is answered on the client's tty** by the `SANDY_APPROVE_ONLY` pre-pass (2.4.0, #296; Appendix E.1a) before the supervisor forks, so a project image can be approved in daemon mode; declining there means "use the base image", exactly as a foreground `N` does. Approval persists per workspace; any Dockerfile edit re-prompts; revoke with `rm` of the approval file. The `.sandy/` directory is additionally in the protected-dirs list (§9), so an existing one is `:ro` in-session — but only an **existing** one: the mount is existence-gated, so a session that started without `.sandy/` can create one (reported at session end as a newly-appeared protected path, and recorded so the next approval prompt says the context was created by a sandy session — see below), and the approval hash is what keeps a planted Dockerfile from building unreviewed (#295).

**Prompt provenance and reading rule (2.4.0, #295 items 4-5).** Before the listing the prompt states which case applies, from the approval file alone: absent → `PROVENANCE: NO prior approval for this workspace` (with the note that a session starting without `.sandy/` can create one); present with a different first line → `PROVENANCE: the build context CHANGED since you approved it on <date>`, the date read from the file's `# approved:` line (`an unrecorded date` when missing). It then prints one reading rule: a `RUN` line that fetches and installs from a package registry is expected; one that pipes a URL to a shell, writes outside the image, or reads from the build context is what deserves attention.

**A `.sandy/` created by a session is flagged at the next approval (2.7.0, #295 item 3).** Maintainer decision (option C): `.sandy/` stays existence-gated like every other protected directory (always-mounting it `:ro` would bring back the workspace stubs the gate removed), and a session's *creation* of it is recorded instead. `_sandy_note_session_created_sandy_dir SNAPSHOT BY` writes `$SANDY_HOME/approvals/dockerfile-<wd16>.session-created` (mode 600) when `$WORK_DIR/.sandy` is a non-empty directory and `.sandy` is absent from `SNAPSHOT` (`$SANDBOX_DIR/.protected-existed-at-launch`, §9). Format: line 1 the `_sandy_context_hash` of `.sandy/` at that moment, then `# workspace: <path>`, `# recorded: <UTC ISO-8601>`, `# by: session-end|next-launch`. The location is chosen so neither actor it describes can forge or delete it: not under the workspace (a repository or the rw workspace bind) and not under `$SANDBOX_DIR` (whose subdirectories are mounted into the container); it sits beside the approval it qualifies, keyed on the same 16-char workspace hash. Two writers:
- **`session-end`** — `cleanup()`'s session-end sweep (§9), which also runs in the daemon supervisor's own cleanup on `--stop`. The yellow "Protected paths appeared" warning is followed by a line saying the next launch that would build `.sandy/Dockerfile` will flag it, naming the record.
- **`next-launch`** — a session whose cleanup never ran (SIGKILL, a reboot under `--restart unless-stopped`, a `--stop` that found the supervisor dead) leaves its snapshot behind. The gate reads it before the launch's stale-snapshot sweep deletes it, so the creation is still recorded (the date is when it was noticed). In the `--start` pre-pass against a still-live session the same read records what that session has created so far, which is also true.

In the gate, the order is: (1) an approval matching the current hash returns `0` as before — if a record exists it is removed **with a message** (the content was reviewed; this covers a session that recreated bytes the operator had approved, and the supervisor meeting a record its own pre-pass just approved); (2) the `next-launch` read above; (3) the `SANDY_AUTO_APPROVE_PRIVILEGED` bypass, which leaves a record in place (nobody reviewed anything). The record is then the **highest-priority** provenance line: `PROVENANCE: this build context was CREATED BY A SANDY SESSION (recorded <date>)`, a direction to review it as agent-written, then either `byte-for-byte what that session left behind` (record hash = current hash) or `CHANGED since that session ended` (an edit does not make the rest of it the operator's), plus the earlier approval date if one exists for other content. It replaces the `NO prior approval` / `CHANGED since you approved it` lines. **Cleared only by**: answering `y` (the approval file gains a `# provenance: created by a sandy session (recorded <date>); approved after review` line and sandy prints that the flag is cleared), content matching an approval (case 1), or `--remove-sandbox` (which reaps it with the approval file). Declining, or an unanswerable headless prompt, keeps it. The `--start` pre-pass calls the same gate, so it prints the same line on the client tty. Not surfaced in `--print-state` (`dockerfile_approvals` globs `*.list` only). Guarded by `run-tests.sh` §182.

**The review shows the whole Dockerfile (2.7.0, #295).** It prints `.sandy/Dockerfile, all <N> lines:` and then every line, control characters stripped — never a prefix. It used to stop at line 200 with a `(truncated — review the full file)` note while the approval covered every byte, so anything below the fold (a `COPY .secrets`, a `RUN curl … | sh`) was approved unseen. Showing everything was chosen over refusing long files, which would need its own override, i.e. a second way to approve; an operator who will not read it answers N. Every other staged file is named (`+ build-context file (contents not shown): <path>`), and when the workspace has `config` or `.secrets` the prompt says they are not part of the approval and not sent to the build.

**Reachability probe scope (#295 item 6).** The project build passes through `_sandy_build_allowed` like every other build site, but that probe covers only sandy's own build hosts (`deb.debian.org`, `registry.npmjs.org`). A project layer's own download hosts are not probed — sandy cannot derive them from an arbitrary Dockerfile — so a build can fail after the gate passes. The project `docker build` is therefore run under `|| rc=$?`: on failure sandy prints the build's exit code and that scope note, then exits with the build's own status (the launch still fails, as it did under `set -e`).

### Build Hash Caching

Each phase stores its content hash in `$SANDY_HOME/`:

| File | Phase |
|---|---|
| `.base_build_hash` | Phase 1 |
| `.build_hash` | Phase 2 (claude) |
| `.build_hash_gemini` | Phase 2 (gemini) |
| `.build_hash_codex` | Phase 2 (codex) |
| `.build_hash_both` | Phase 2 (claude+gemini) |
| `.skills_base_build_hash` | Phase 2.5a |
| `.skills_build_hash` | Phase 2.5b |
| `<sandbox>/.project_build_hash` | Phase 3 |

A phase rebuilds if: hash differs from stored, upstream phase was rebuilt, Docker image doesn't exist locally, or `--rebuild` flag is set.

**The two skills hashes additionally fold in their parent image id (2.1.0, #294).** "Upstream phase was rebuilt" only covers a rebuild in *this* launch; a parent rebuilt in an earlier one left the skills images stale forever, so they kept launching with a `user-setup.sh` and `entrypoint.sh` from whenever they were last built — in the field, one predating the relay supervisor entirely, which made a configured relay silently never start. `_sandy_parent_image_id` reads the `FROM` line out of the generated Dockerfile (`Dockerfile.skills` is `FROM` the base image when a pack needs one, `FROM sandy-claude-code` when none does) and returns `absent` when docker cannot resolve it — never an empty string, which would hash identically to a missing parent.

### Unified Resource Reclaim (`sandy --gc`, #36, milestone 1.3.0)

**Provenance label.** Every `docker build` sandy runs — all six sites: base, proxy, agent (final), skills-base, skills (final), per-project — stamps `--label sandy.managed=1`. This is the scoping filter `sandy --gc`'s three image listers use so a dangling `<none>:<none>` image left by an unrelated tool's build churn is never mistaken for sandy's own. **Retroactive gap:** images built by a pre-1.3.0 sandy lack the label and are invisible to the dangling-image lister; the gap closes naturally as images get rebuilt going forward (predecessor-image GC, above, still reclaims those one-off via `_sandy_prune_old_image`). **Proxy identity labels (2.7.0, #299).** The proxy build additionally stamps `--label sandy.proxy_src=<id>` and `--label sandy.proxy_epoch=<YYYY-MM>`. Both values are set inside `generate_dockerfile_proxy()` from the very values it writes into `Dockerfile.proxy` as `# proxy-src:`/`# freshness-epoch:` comments, so a label can never disagree with the build input that produced it: `<id>` is `sha256:<content hash of proxy/>` on the local-checkout path and `git:<ref>` on the clone path. A sidecar container inherits them from the image. `--print-state` full mode reports them as `proxy_image_src`/`proxy_image_epoch` (`null` for an image built before them). **Launch-time identity check (2.7.0, #299).** When the proxy is on and this launch did not build the proxy image (up to date by hash, or its rebuild deferred by the #218 reachability gate — also where `SANDY_OFFLINE=1` lands), `_sandy_proxy_identity_check` reads both labels in one `docker image inspect -f '{{with .Config.Labels}}…{{end}}' sandy-proxy` (empty or `<no value>` = missing) and compares them with the values this launch's `generate_dockerfile_proxy()` computed, before `start_proxy_sidecar` runs the image. On any difference it prints one yellow warning naming what differs (source and/or epoch, old vs expected, or "carries no identity labels"), that the proxy is the egress policy chokepoint, and the fix (`sandy --rebuild` after reconnecting; under `SANDY_OFFLINE=1` also naming it), records it for the session-end deferred-refresh notice (#218), which repeats it on its own line, and **proceeds — it never refuses** (maintainer decision, consistent with #218/#219) and always returns 0. A match is silent. An image the same launch just built is not re-inspected (it carries these values by construction), an image docker cannot inspect is left to the build gate, and none of the introspection fast paths runs it. The runtime/digest half of #299's preflight is folded into #127/#245. The running agent container (`RUN_FLAGS`) and the proxy sidecar (`proxy_run`) also carry an analogous `--label sandy.managed=true` — additive future-proofing, not (yet) the operative container-liveness predicate below.

**Container-liveness predicate.** `--gc`'s dead-owner-container lister (`_sandy_dead_owner_containers_list`) reuses the daemon-mode D6/D9 rule verbatim: *the container is truth only with a LIVE inner tmux session.* One `docker ps -a --filter 'name=^/sandy-'` enumerates every candidate; classification is a **two-pass** walk over the captured output, because a proxy sidecar's liveness is a function of its *paired agent's* liveness, which is only known once every agent has been classified. Agent-vs-proxy is decided by **image**, never by name prefix — a workspace whose sanitized basename happens to be `proxy` produces a container literally named `sandy-proxy-<hash>` running a real agent image, and a name-prefix test would misclassify it as a proxy sidecar (a real pre-release regression, fixed before 1.3.0 shipped).

**Pass 1 — every AGENT container** (any recognized sandy image other than `sandy-proxy`: `sandy-base`, `sandy-claude-code`, `sandy-gemini-cli`, `sandy-codex`, `sandy-opencode`, `sandy-grok`, `sandy-full`, `sandy-project-*`, `sandy-skills*`; the image-name gate is best-effort and deliberately name-based rather than label-based so it works retroactively against containers a pre-1.3.0 sandy started):

1. **`sandy.daemon=true` labeled**: not running → dead, reap. Running → probe `docker exec -u "$(id -u)" <cid> tmux has-session -t sandy`, retried **5x with a 1s sleep** between attempts (mirroring `--start`'s own D6 idempotency retry) so a container whose supervisor hasn't created the tmux session yet isn't misread as a zombie mid-startup: success → **ALIVE, KEPT — never touch, regardless of `sandy.daemon_pid` liveness** (the D9 defense: a rebooted host can resurrect a `--restart unless-stopped` container on a dead supervisor pid while the session itself is healthy); failure (all 5 attempts) → zombie, reap. The retry is gated to the destructive reap path only (`_sandy_dead_owner_containers_list reap`) — `--print-state`'s `orphaned_containers` COUNT uses a single probe, since a momentarily-stale count is informational and a 5s stall per mid-startup container would defeat its cheap-poll budget.
2. **Not daemon-labeled** (a foreground/interactive agent container): SANDBOX_NAME is derived by stripping *only* the `sandy-` prefix (never `sandy-proxy-` — this branch only ever sees a real agent image). Not running → dead, reap. Running → check `$SANDY_HOME/sandboxes/.<name>.lock/pid`: missing/non-numeric/dead → dead-owner, reap; live pid → KEPT, skip. (Reuses the same `lock_holder_alive` liveness test `--print-state`/the #14 workspace mutex use.)

Every KEPT agent's sandbox name is recorded in a set for pass 2.

**Pass 2 — every PROXY container** (image `sandy-proxy`, named `sandy-proxy-<name>`): the proxy's *own* running state and lock file are **ignored** — its fate is decided purely by whether its paired agent (`sandy-<name>`) is in the pass-1 KEPT set. Paired agent KEPT → KEPT, skip. Paired agent absent, dead, or reaped → reap. This is deliberate: a daemon session's proxy never carries `sandy.daemon=true`, so judging it by its own lock file (which holds the *supervisor's* pid) would misjudge it dead the moment a live session's supervisor is SIGKILL/OOM-killed — reaping the proxy would then strand a perfectly healthy agent on a routeless `--internal` sidecar (the exact failure the atomic agent+proxy teardown in `cleanup()` exists to prevent). This was also a real pre-release regression, fixed before 1.3.0 shipped.

The dedicated reaper re-invokes the lister (with `reap` mode) at call time (not a cached earlier snapshot) immediately before each destructive `docker rm -f` — its own authoritative re-probe, since the operation is destructive.

**Image listers.** `_sandy_orphaned_project_images_list` candidates come from `docker images -f label=sandy.managed=1 --format '{{.Repository}}' | grep -E '^sandy-project-'`; the in-use set is a pure filesystem walk of `$SANDY_HOME/sandboxes/*/` recomputing `sandy-project-<basename>` lowercased — the identical transform Phase 3's build path applies, so it can never drift. `_sandy_orphaned_skills_images_list` candidates match `^sandy-skills(-base)?-`; the in-use set is built from **three** sources, all recomputing the suffix via the shared `_sandy_skill_pack_suffix()` helper (also used by both build call sites in Phase 2.5a/2.5b, extracted here to prevent drift): (1) `SANDY_SKILL_PACKS` already set in the `--gc` process's own environment; (2) host `$SANDY_HOME/config` (`~/.sandy/config`), consulted directly since `SANDY_SKILL_PACKS` is passive-safe and commonly set **once, globally** rather than per-workspace — without this source, a host-global default with no per-workspace override would see an empty in-use set and reap the actively-used skills images on every `--gc` run (a real pre-release regression, fixed before 1.3.0 shipped); (3) each sandbox's `WORKSPACE.json` for a still-existing `workspace_path`, greping that workspace's own `.sandy/config` for `SANDY_SKILL_PACKS=`. Sources 1 and 2 aren't tied to any one sandbox, so they only *widen* the in-use set, never narrow it. Known imprecision: a temporarily-unmounted workspace, an edited-but-not-yet-relaunched `.sandy/config`, or a host config sandy can't read for some other reason under-detects as orphaned — a read/parse failure on any of the three sources simply contributes nothing to the in-use set rather than crashing the lister. This residual imprecision is safe because skills/project images are reproducible artifacts — a false-positive reap costs a full skills-base (Chromium/bun) rebuild on the next launch that needs it, not data loss. `_sandy_dangling_images_list` is `docker images -f dangling=true -f label=sandy.managed=1 --format '{{.ID}}'` — no PID/liveness gate needed, since a dangling image is referenced by no tag and `docker rmi` without `-f` is itself the safety net for anything still referenced by a child image.

**Reap order:** containers → networks (delegates to `_sandy_reap_orphan_networks`/`_sandy_orphan_networks_list`, unchanged — one gate shared with `--prune-orphans`) → project images → skills images → dangling images last.

**Flow:** `sandy --gc [--dry-run] [--yes]` computes all five lists up front, prints a human-readable plan, then: nothing to reclaim → exit 0 immediately; `--dry-run` → prints the plan and exits 0 before any confirm step; otherwise `--yes` skips the interactive y/N, a TTY without it is prompted, and non-TTY without it errors "pass `--yes`" and exits 1. A before/after re-count (not the attempt count) drives the final "Reclaimed: N container(s), M network(s), P project image(s), Q skills image(s), R dangling image(s)." summary, so a resource that raced back to life between the plan and the reap isn't falsely claimed. `--dry-run`/`--yes` are parsed by `--gc`'s own trailing-argument loop (distinct locals, not the unrelated `SANDY_UPDATE_DRY_RUN`/`SANDY_UPDATE_YES` `--update-sessions` uses), since the main flag-parsing loop runs after this fast-path dispatch already exits.

`--prune-orphans` remains unchanged as a documented subset of `--gc` (both share the same network lister/reaper) — no deprecation.

---

## 6. Skill Pack System

### Registry

Four parallel arrays define available skill packs:

```bash
SKILL_PACK_NAMES=(gstack)
SKILL_PACK_REPOS=("https://github.com/garrytan/gstack")
SKILL_PACK_VERSIONS=("main")          # Fallback only
SKILL_PACK_TAG_PREFIXES=("")          # Empty = use commit SHA
```

### Version Resolution

On each launch, `skill_pack_resolve_versions()` runs for each enabled pack:

1. **GitHub releases API** (5-second timeout): If `tag_prefix` is set, fetch latest non-draft, non-prerelease tag matching the prefix
2. **GitHub commits API** (5-second timeout): If no releases or no prefix, fetch latest commit SHA on default branch (truncated to 12 chars)
3. **Local cache**: `~/.sandy/.skill_version_<pack>` stores last successfully resolved version
4. **Hardcoded fallback**: `SKILL_PACK_VERSIONS` array entry, used only on first run if GitHub is unreachable

The resolved version is embedded in the generated Dockerfile. A new version = different Dockerfile content = hash mismatch = rebuild triggered.

### Container Activation

At container startup, `user-setup.sh`:
1. Symlinks `/opt/skills/<pack>/` → `~/.claude/skills/<pack>`
2. Symlinks individual skill directories (those containing `SKILL.md`) into `~/.claude/skills/`
3. Adds `/opt/skills/<pack>/bin` to PATH
4. Sets `PLAYWRIGHT_BROWSERS_PATH=/opt/skills/gstack/.browsers`

### Workspace State (gstack)

When `gstack` is enabled, `~/.gstack/` inside the container is bind-mounted from `<workspace>/.gstack/` on the host (auto-created if missing). This makes gstack state workspace-scoped — visible alongside `.git/` and `.venv/`, persisted independently of the sandbox identity.

A one-shot migration runs on the first 0.12+ launch: if `$SANDBOX_DIR/gstack/` (the legacy location) has content but `<workspace>/.gstack/` is absent, sandy `cp -a`'s the contents to the workspace and renames the legacy dir to `gstack.migrated/` (left in place; manual cleanup after verification).

A launch-time nudge prints a warning when the workspace is a git repo and `.gstack/` is not gitignored. Detection prefers `git check-ignore` (so it honors `.git/info/exclude` and parent `.gitignore`s); falls back to a literal grep of the workspace's `.gitignore` when git is unavailable. The warning is informational only — sandy launches normally either way.

### Adding New Packs

Add entries to all four arrays (`SKILL_PACK_NAMES`, `SKILL_PACK_REPOS`, `SKILL_PACK_VERSIONS`, `SKILL_PACK_TAG_PREFIXES`) and add a build recipe case in `generate_skill_pack_dockerfiles()`.

---

## 7. Container Runtime

### Docker Run Flags

```
--rm -it
--name sandy-<SANDBOX_NAME>
--cpus <SANDY_CPUS>
--memory <SANDY_MEM>
--security-opt no-new-privileges:true
--cap-drop ALL
--cap-add SETUID --cap-add SETGID --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
--pids-limit 512
--init
--read-only
--tmpfs /tmp:exec,size=1G
--tmpfs /home/sandy:exec,size=2G,uid=1001,gid=1001
--network <NETWORK_NAME>
```

Optional: `--gpus <SANDY_GPU>` if GPU passthrough is enabled.

### Entrypoint Flow (Root Phase)

`entrypoint.sh` runs as root and performs:

1. Fix tmpfs home directory ownership to match host UID/GID
2. Seed `~/.ssh/known_hosts` from host mount
3. SSH agent relay setup (macOS: socat TCP→Unix relay; Linux: socket permissions fix)
4. Copy host SSH config from `/tmp/host-ssh` to `~/.ssh/` (dereferences symlinks, sets correct permissions)
5. Fix ownership of sandbox-backed persistent mount directories (pip, uv, npm, go, cargo). `~/.gstack/` is intentionally **not** chowned here — it's a workspace bind, so chown'ing inside the container would write through to the host workspace's ownership.
6. Symlink Claude Code binary and data dir into home
7. Create pip/pip3 wrapper scripts (auto-add `--user` when outside virtualenvs)
8. Drop privileges: `exec gosu $RUN_UID:$RUN_GID /usr/local/bin/user-setup.sh "$@"`

### User Setup Flow (User Phase)

`user-setup.sh` runs as the `claude` user:

1. Set environment variables (HOME, CARGO_HOME, GOPATH, NPM_CONFIG_PREFIX, PYTHONUSERBASE, PATH)
2. Symlink system Rust toolchain binaries into `~/.cargo/bin`
3. Activate skill packs (symlink into `~/.claude/skills/`)
4. Create synthkit slash commands (`/md2pdf`, `/md2doc`, `/md2html`, `/md2email`)
4a. Create `/ss` screenshot skill files when `SANDY_SCREENSHOTS_PATH` is set (claude `~/.claude/commands/ss.md`, gemini `~/.gemini/commands/ss.toml`, codex `~/.codex/skills/screenshot/SKILL.md`). All call `/usr/local/bin/sandy-ss-paths` internally. Opencode has no slash-command surface in v0; the helper is on PATH for manual invocation. See Appendix E.11a for the host-side mount + env-var pipeline.
5. Remap ANSI color 4 (dark blue → bright blue) for readability
6. Ensure the Claude projects dir for the workspace exists (`settings.json` itself is seeded/merged **host-side** before `docker run` — see §4 Seeding; moved out of user-setup in 0.11.3)
7. Configure git (safe.directory, user name/email)
8. Environment detection (.python-version, broken .venv, foreign native modules, git-lfs)
9. Git auth setup (token mode: URL rewriting + gh auth; agent mode: SSH config)
10. Plugin marketplace refresh (daily, or forced when channels configured)
11. Channel credential seeding (Telegram, Discord: write `.env` and `access.json`)
12. Launch Claude Code via tmux (or remote-control mode)

### UID/GID Remapping

If the host UID differs from the image default (1001), sandy generates custom `passwd` and `group` files with the host UID/GID and mounts them read-only. The entrypoint then uses `gosu` with the remapped UID/GID.

### Environment Variables Passed to Container

**Claude Code config**: `SANDY_WORKSPACE`, `SANDY_PROJECT_NAME`, `SANDY_SANDBOX_NAME` (the sandbox slug `<basename>-<sha8>`, 1.15.0/#303 — convenience only; the authoritative copy is `sandbox_name` in the `:ro` `/etc/sandy-session.json`), `SANDY_MODEL`, `SANDY_SKIP_PERMISSIONS`, `SANDY_NEW_SESSION`, `SANDY_REMOTE_CONTROL`, `SANDY_VERBOSE`, `SANDY_CHANNELS`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`

**Credentials**: `CLAUDE_CODE_OAUTH_TOKEN` (explicitly emptied if not set, to prevent host env leakage) and `ANTHROPIC_API_KEY` — but **at most one Claude key reaches the container**. Claude Code's own auth precedence resolves `ANTHROPIC_API_KEY` *ahead of* `CLAUDE_CODE_OAUTH_TOKEN`, so forwarding both would silently route to per-use API billing and bypass the OAuth/subscription path. To honor sandy's documented OAuth-first preference, when an OAuth token is configured sandy **suppresses `ANTHROPIC_API_KEY`** (forwarding only the token, with a launch warning). **The same suppression applies one level down**: when the host OAuth *credentials file* is being mounted this launch, `ANTHROPIC_API_KEY` is not forwarded either — Claude Code resolves an environment key ahead of the account credentials, so forwarding both either bills per-use or, if that key has never been approved in this sandbox's `.claude.json`, parks the session on Claude Code's custom-API-key startup modal. In daemon mode that modal is silent and severe: the container is up and `tmux has-session` succeeds, so `--start` returns `0` (ready) for a session that accepts cross-session messages, queues them, and never runs them because nothing is attached to answer the dialog. Under the default `SANDY_CLAUDE_AUTH=auto` the key is therefore forwarded only when **no** Claude OAuth credential reaches the container — including `SANDY_SUSPICIOUS` disposable-key mode and its fail-closed strip path, both of which clear the credential blob deliberately. Resolved order: `CLAUDE_CODE_OAUTH_TOKEN` → host credentials file → `ANTHROPIC_API_KEY`.

**`SANDY_CLAUDE_AUTH` (1.10.0) makes the choice explicit rather than inferred.** Suppression alone left no way to say *"use the API key for this workspace"* on a host that has OAuth: the only escape was `SANDY_SUSPICIOUS=1`, which also strips the refresh token, forces connectors off and defaults egress to strict — a hardening package, not a billing switch. Claude was also the only wrapped agent with no `SANDY_<AGENT>_AUTH` knob.

| value | credentials file | `CLAUDE_CODE_OAUTH_TOKEN` | `ANTHROPIC_API_KEY` |
|---|---|---|---|
| `auto` (default) | mounted when present | forwarded when set (wins) | forwarded **only** if neither OAuth form is present |
| `api_key` | **withheld** | **withheld** | forwarded — the only Claude credential in the container |
| `oauth` | mounted when present | forwarded when set | **never** forwarded |
| `profile` | **withheld** | **withheld** | **withheld** — the selected Anthropic Console profile (`ant auth login`) is copied to an ephemeral rw mount at `~/.config/anthropic` and is the only Claude credential present; `ANTHROPIC_PROFILE` (privileged) selects it, else the host `active_config`, else `default` |

`api_key` with no `ANTHROPIC_API_KEY` set warns and falls back to `auto` rather than silently leaving the session with the account credential it asked not to use; an unrecognized value warns and falls back to `auto`.

**Tier: value-aware.** `auto` and `api_key` are passive-safe — `api_key` strictly *reduces* what is in the container (a revocable project key instead of the account refresh token), which is the same reasoning as `SANDY_SUSPICIOUS`'s disposable-key mode. `oauth` from a workspace source is **approval-gated**: it forces the account-scoped credential in even when a revocable key is available, which is the weakening direction. Guarded by `run-tests.sh §117` and `§65`.

**Channel credentials**: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_SENDERS`, `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_SENDERS`

**Git**: `GIT_USER_NAME`, `GIT_USER_EMAIL`, `GIT_TOKEN`, `GH_ACCOUNTS`, `SANDY_SSH`, `SSH_RELAY_PORT`

**System**: `HOST_UID`, `HOST_GID`, `DISABLE_AUTOUPDATER=1`, `FORCE_AUTOUPDATE_PLUGINS=true`

### Resource Limits

- **CPU**: Auto-detected from `docker info` (number of CPUs), overridable via `SANDY_CPUS`
- **Memory**: Auto-detected as `available - 1GB` (minimum 2GB), overridable via `SANDY_MEM`
- **PIDs**: Hard limit of 512 processes
- **Tmpfs**: `/tmp` = 1GB, `/home/sandy` = 2GB (persistent mounts bypass tmpfs)

---

## 8. Network Isolation

### Linux

Per-instance Docker bridge networks are created with names keyed on PID (`sandy_net_$$`) to avoid races between concurrent sessions.

**iptables rules** inserted into the `DOCKER-USER` chain:

| Range | Purpose |
|---|---|
| `10.0.0.0/8` | Home/office LANs, VPNs |
| `172.16.0.0/12` | Docker internals, some LANs |
| `192.168.0.0/16` | Home/office LANs |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT, Tailscale |

The container's own subnet is allowed. Additional hosts/CIDRs can be allowed via `SANDY_ALLOW_LAN_HOSTS`. A single host:port to a local LLM listening on the Docker host can be allowed via `SANDY_LOCAL_LLM_HOST` (see below).

**Rule insertion order** (rules evaluated top-to-bottom):
1. Allow container's own subnet (inserted last, evaluated first)
2. Allow `host.docker.internal:<port>` for `SANDY_LOCAL_LLM_HOST` (tcp, dst = bridge gateway, dport = configured port)
3. Allow specific LAN hosts (if `SANDY_ALLOW_LAN_HOSTS` set)
4. DROP all private ranges

**Cleanup**: Rules and network removed on exit via trap handler.

**Fail-closed**: If `iptables` is not available, sandy aborts unless `SANDY_ALLOW_NO_ISOLATION=1`. **Verified, not assumed (2.4.0, #299)**: the DROP inserts are `|| true`, and a chain that is readable can still refuse an insert (nft-backend mismatch, a sudo policy allowing `-L` but not `-I`, a malformed range), so after inserting sandy re-checks each DROP with `sudo iptables -C DOCKER-USER -i $BRIDGE -d <range> -j DROP`. The first one missing refuses the launch, naming the range (with the `.fatal` marker, so a `--start` client fails in ~1s); under `SANDY_ALLOW_NO_ISOLATION=1` it warns that isolation is **incomplete** instead. "Network isolation rules applied." is printed only when every DROP is present. The ACCEPT rules are not verified: they are holes, and a missing hole fails closed on its own.

### `SANDY_LOCAL_LLM_HOST` — local LLM passthrough

`SANDY_LOCAL_LLM_HOST=<ip>:<port>` (e.g. `127.0.0.1:11434` for Ollama) lets an in-container agent reach a local LLM server running on the Docker host without disabling sandy's broader LAN-isolation posture.

**Validation** (post-config-load, before agent resolve):
- Format: `^[^[:space:]]+:[0-9]+$` — must be `host:port`. Bare IPs are rejected.
- Host portion: `0.0.0.0`, `::`, and empty rejected (world-open).
- Port: integer in `1..65535`.

**Linux behavior**:
- `ensure_network` captures `CONTAINER_GATEWAY` (the bridge gateway IP, equivalent to `host.docker.internal`) from `docker network inspect`.
- `apply_network_isolation` inserts a single `iptables -I DOCKER-USER -i $BRIDGE -p tcp -d $CONTAINER_GATEWAY --dport $PORT -j ACCEPT` rule. The destination is the gateway IP — opencode (or the user's CLI) connects to `host.docker.internal:<port>`, which Linux Docker resolves to the gateway.
- `RUN_FLAGS` adds `--add-host=host.docker.internal:host-gateway` (Linux Docker does NOT auto-resolve this hostname; without the explicit map, the container can't reach the gateway by name).
- `cleanup_network_isolation` removes the rule on exit.

**macOS behavior**: Docker Desktop already auto-resolves `host.docker.internal`. Sandy normally nullifies the hostname (mapping to `127.0.0.1`) when `SANDY_SSH != agent`; setting `SANDY_LOCAL_LLM_HOST` suppresses that nullification. Macros LAN isolation is not active on macOS regardless (see below), so no iptables rule is added.

**Container-side**: `SANDY_LOCAL_LLM_HOST` is forwarded into the container via `-e` so the agent / user shell can introspect the configured target.

### macOS

**Network isolation is NOT active on macOS when the egress proxy is explicitly turned off (`SANDY_EGRESS_PROXY=0`).** (The default is `1` — permissive — so this applies only when a user opts out.) Docker Desktop's VM does *not* provide LAN isolation. Containers can reach `host.docker.internal` (→ host gateway), the host's `localhost` services, and any device on the user's physical LAN (`192.168.x.x`, home router, NAS, printers, internal dashboards). Linux iptables DROP rules do not apply and cannot be applied from macOS. (Stress test April 2026 opened a live TCP connection to host SSHD and read its banner — see `ISOLATION_STRESS.md` finding F2.) **Setting `SANDY_EGRESS_PROXY=1` (or `=2`) applies real isolation on macOS** — see "Egress Proxy" below.

**Launch warning**: On non-Linux hosts with the proxy off, `apply_network_isolation` prints a warning banner informing the user that network isolation is not active and pointing at `SANDY_EGRESS=permissive|strict` (it named the deprecated `SANDY_EGRESS_PROXY=1/2` before 2.4.0). In proxy mode `apply_network_isolation` is not called (the `--internal` topology is the isolation), so no banner fires.

**Defense-in-depth (`--add-host`)**: sandy appends the following flags to `RUN_FLAGS` on macOS to nullify Docker Desktop's magic hostnames:

| Hostname | Mapped to | Condition |
|---|---|---|
| `gateway.docker.internal` | `127.0.0.1` | always |
| `metadata.google.internal` | `127.0.0.1` | always |
| `host.docker.internal` | `127.0.0.1` | only when `SANDY_SSH != agent` |

When `SANDY_SSH=agent`, `host.docker.internal` is *not* nullified because sandy's own in-container SSH agent relay (`socat … TCP:host.docker.internal:$SSH_RELAY_PORT`) depends on that hostname reaching the host. In that mode, sandy emits an extra warn line noting the exception.

This is defense-in-depth, not a fix — with the proxy off, raw-IP access (`curl http://192.168.1.1`) is unaffected. The fix is the egress proxy (`SANDY_EGRESS=permissive|strict`, below — on by default), which applies uniform isolation on both platforms.

### Egress Proxy (`SANDY_EGRESS`, M2.7; one key since 2.0.0)

`SANDY_EGRESS=off|permissive|strict` (default `permissive`) routes the agent through a `sandy-proxy` sidecar on a Docker `--internal` network unless it is `off`. Because it relies on `--internal` routing rather than iptables, it is the **only** network isolation that works on macOS, and behaves identically on both platforms. **Value-aware tiering**: from a workspace source, a *strengthening* value is passive-safe but a *weakening* value is quarantined to the per-workspace approval prompt (`_sandy_passive_value_privileged`), so a committed `.sandy/config` cannot silently disable or downgrade isolation.

| Setting | Mode (`mode` field in proxy config) | Egress policy | Workspace-config tiering |
|---|---|---|---|
| `SANDY_EGRESS=permissive` *(or unset)* | `permissive` (default) | Block private/LAN/link-local/CGNAT/`169.254.169.254` metadata and well-known DoH resolvers (below); allow all other internet. Resolve-then-check also defeats DNS rebinding. | **approval-gated** (downgrades a host-set strict, #371) |
| `SANDY_EGRESS=strict` | `strict` | Deny all except the built-in default allowlist + `SANDY_ALLOW_HOSTS`; fail closed. | passive-safe (strengthens) |
| `SANDY_EGRESS=off` | — (proxy off) | Linux: legacy iptables. macOS: none. | approval-gated (weakens) |

**Why `permissive` is gated (#371, 2.4.0).** A workspace source outranks the host config for the same key, so an ungated `SANDY_EGRESS=permissive` in a committed `.sandy/config` would override a host `SANDY_EGRESS=strict` with no prompt. 2.0.0–2.3.x gated only `off`, dropping the downgrade case that `SANDY_EGRESS_STRICT=0` had always gated. The gate classifies the **value**, not the delta against the privileged sources, so it also prompts where the host is already permissive (a harmless no-op prompt, the same trade `STRICT=0` makes). Non-interactive and headless launches fail closed: the key is dropped and the host posture stands. Guarded by `run-tests.sh §155` (effective posture, real loader + approval resolver) and `§139(13)`.

**DNS-over-HTTPS resolvers (#154, 2.4.0).** In permissive mode `Policy.Egress` refuses a built-in list of well-known DoH provider names (`proxy/doh.go`: `dns.google`, `dns.google.com`, `cloudflare-dns.com` and its subdomains, `one.one.one.one`, `dns.quad9.net`/`dns9`–`dns12`, `doh.opendns.com`, `dns.nextdns.io`, `doh.cleanbrowsing.org`, AdGuard, `doh.dns.sb`, `dns.mullvad.net`, Control D, `dns0.eu`, AliDNS, `doh.pub`, …). An entry matches itself and any subdomain; every entry is resolver infrastructure in its entirety, never a parent domain that also hosts ordinary sites. The check sits on the one decision point every path reaches — transparent `:443` (SNI), `:80` (Host) and CONNECT (any port, so DoT via CONNECT to a listed name on `:853` too) — and a denial is logged `sandy-proxy: deny … (known DNS-over-HTTPS resolver blocked in permissive mode …)` like any other, so it counts in the session-end egress summary. The DNS responder deliberately still answers the name: it logs nothing, so an NXDOMAIN would make the attempt vanish from `proxy.log`. **The allowlist is consulted first**, so `SANDY_ALLOW_HOSTS` (exact, wildcard or `host:port`) re-allows a listed provider; there is no separate key. **Strict mode is unchanged**: a resolver that is not allowlisted is already denied (`not in allowlist`). Why only this: on the `--internal` sidecar UDP (DoH over QUIC/HTTP-3, DoT over UDP) is dropped at L3 and an agent dialing a resolver IP directly has no route, so a *named* resolver reached through the proxy is what remained. **Limits**: the list is enumerable, not complete — an unlisted or self-hosted provider is not covered, nor is an IP-literal resolver reached through the proxy's own paths (`CONNECT 1.1.1.1:443`, where a public IP is allowed). It raises the cost of lazy DNS-policy bypass; strict mode is the real fix. Guarded by the proxy's Go tests (`doh_test.go`, run by `run-tests.sh §58`).

**Deprecated keys** (still honored, listed in README's `## Deprecated`): the 1.x booleans `SANDY_EGRESS_NO_ISOLATION=1` (= `off`) and `SANDY_EGRESS_STRICT=1|0` (= `strict`|`permissive`, mutually exclusive with `NO_ISOLATION=1` — both set is a hard error), and the older alias `SANDY_EGRESS_PROXY` (`0`→off, `1`→permissive, `2`→strict). `SANDY_EGRESS` is **translated** into the two internal booleans, so everything downstream branches on one representation; when it is set it **wins** and every deprecated value is ignored with a notice naming it (never merged). Their weakening values are gated from a workspace: `NO_ISOLATION=1`, `STRICT=0`, `PROXY=0`, and — since #371 — `PROXY=1` (a downgrade of a host-set `PROXY=2`). Pre-1.0 `SANDY_EGRESS_PROXY` was a plain passive tri-state — a committed `SANDY_EGRESS_PROXY=0` could disable isolation with no prompt (fixed in the 1.0 rc window; guarded by `run-tests.sh §65`).

The launcher normalizes the value once into `_SANDY_PROXY_ON` (bool) and `_SANDY_PROXY_MODE` (`permissive`/`strict`).

**Topology** (`ensure_proxy_networks` / `start_proxy_sidecar`):
- Two per-session networks: `sandy_sidecar_$$` (`--internal`, agent + proxy) and `sandy_egress_$$` (normal bridge, proxy only). The agent's `NETWORK_NAME` is the sidecar.
- The sidecar is created with an explicit `--subnet`/`--gateway` (first non-overlapping `/24`) so the proxy can be pinned to a fixed `--ip` (`<subnet>.2`). The candidate pool (`_sandy_proxy_subnet_candidates`) is **every `/24` in `10.200.0.0/16` and `10.201.0.0/16`** (512 subnets) plus two legacy `/24`s (`172.31.250.0/24`, `192.168.231.0/24`) — so the practical ceiling on concurrent proxy-mode sessions is in the hundreds (was a hardcoded 4-entry list capping at four). If every candidate overlaps, `ensure_proxy_networks` first calls `_sandy_reap_orphan_proxy_networks` — which removes any `sandy_sidecar_*`/`sandy_egress_*` network with **no attached container** (an orphan left by a SIGKILL'd/OOM'd/closed-terminal session that couldn't run its cleanup trap; live sessions are never touched) — then retries once. Only if that still fails is it a hard launch error.
- The proxy container is named **`sandy-proxy-${SANDBOX_NAME}`** (mirrors the agent container `sandy-${SANDBOX_NAME}`), making an orphan traceable to its workspace in `docker ps`. The workspace mutex ⇒ one session per workspace ⇒ the name is unique among live sessions; a stale same-named proxy is `docker rm -f`'d before (re)launch (same as the agent container at §E).
- **`--update-sessions` judges the sidecar too (2.7.0, #299).** Its enumeration keys on `sandy.daemon=true`, which only the agent container carries, so the sidecar used to be invisible to it: a proxy image refreshed on its own (the monthly freshness epoch, a `proxy/` source change) left every live daemon session on the old sidecar. `_sandy_update_proxy_stale` now resolves `sandy-proxy-<sandy.session>` with a typed, exact `docker inspect --type container`, accepts it only when its `.Config.Image` is `sandy-proxy` (agent-vs-proxy by image, never by name — a workspace named `proxy` has an *agent* called `sandy-proxy-<hash>`), and runs the same `_sandy_image_stale` the agent check uses. Either half stale ⇒ restart; the plan's reason is `stale` when the agent moved (the restart recreates the sidecar with it) and `proxy stale` when only the sidecar did. A session with no sidecar (egress `off`) is judged on the agent alone. The per-session `--build-only` refresh runs the proxy build phase, so the sidecar is compared against a freshly built image.
- The proxy runs `--read-only --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 128 --memory 256m --restart on-failure:5` (HF-incident Issue 2 — hardened at least as much as the agent it protects; `--user` declined because the binary binds privileged ports on a scratch image), with `/etc/sandy-proxy.json` bind-mounted read-only from `$SANDBOX_DIR/sandy-proxy.json`. In-proxy, all accept loops share `acceptLoop` (`proxy/accept.go`), which bounds concurrent connections at `maxConns` via a semaphore acquired before `Accept`, so a connection storm is bounded by backpressure rather than by the `--memory` OOM-killer. After start, it is connected to the egress network with the fixed sidecar `--ip`. **Restart policy:** the proxy is the agent's only route off the `--internal` sidecar, so a mid-session proxy death (crash/OOM/reap) would otherwise strand the agent (every request `FailedToOpenSocket`) until the next launch. `--restart on-failure:5` lets the daemon resurrect it on the **same fixed `--ip`**, so the agent self-heals without a session restart; bounded to 5 so a genuinely broken proxy still gives up. `cleanup()` force-removes it regardless of policy (no zombie). **Readiness gate (#37):** the proxy image bakes a Docker `HEALTHCHECK` (`--interval=1s --start-period=0s --timeout=2s --retries=3`) that re-invokes the binary as `sandy-proxy -healthcheck` — scratch has no shell, so the binary *is* the probe; it dials its own `:443`/`:80`/`:3128` TCP listeners (loopback, valid before the sidecar `--ip` attach) and issues one DNS query on `:53` (UDP has no `Accept`, so a bind is proven by a real reply — NXDOMAIN counts). The launch gate polls `.State.Health.Status` (up to ~15 s) and proceeds only on `healthy`, so it waits for the listeners to **bind**, not merely for the process to start (the pre-#37 gate polled bare `.State.Running`, which flips true before `net.Listen`, leaving a transient "connection refused" window on the agent's first request). It falls back to the legacy `.State.Running` gate when `.State.Health` is absent (`{{if .State.Health}}…{{else}}none{{end}}` — an older HEALTHCHECK-less cached image still launches), fails fast (dumping `docker logs`) if it never comes up, and a non-zero `.RestartCount` short-circuits the poll and is surfaced as a crash-loop warning (a clean proxy never exits). Regressions: `run-tests.sh §56` (legacy self-heal), `§78` (HEALTHCHECK wiring), `proxy/healthcheck_test.go` (probe logic).
- **Death diagnostics.** Two mechanisms make a proxy death root-causable. (1) **Persistent log:** after the readiness gate, sandy streams `docker logs -f "$PROXY_CONTAINER"` to `$SANDBOX_DIR/proxy.log` in the background (PID `PROXY_LOG_PID`, reaped in `cleanup()`), truncated per launch. This survives the `docker rm -f` that erases `docker logs`, so a guard() panic stack, deny lines, and restart boundaries persist; `cleanup()` appends the container's final `docker inspect` state (`exit`/`oom`/`restarts`/`status`/`finished`) so an OOM (`oom=true`, exit 137) is distinguishable from a panic (non-zero exit + stack) or an external kill. (2) **Panic recovery in the proxy binary:** an unrecovered panic in any goroutine crashes the whole Go process, and the proxy runs one goroutine per connection over untrusted wire bytes (TLS ClientHello / HTTP Host). Each per-connection handler (`transparent`, `connect`, `forward`) is wrapped in `guard()` (`proxy/guard.go`), which `recover()`s and logs the panic value + `debug.Stack()` instead of letting one malformed connection take down the agent's only egress route. Regression: `run-tests.sh §57` + `proxy/guard_test.go`.
- Config JSON: `{"mode", "proxy_ip", "allow":[…], "local_llm"?}`. `allow` = built-in defaults + validated `SANDY_ALLOW_HOSTS` (+ `host.docker.internal` when a local LLM is set).
- Agent `RUN_FLAGS`: `--network <sidecar>` + `--dns <proxy_ip>` + `-e SANDY_PROXY_IP=<ip>` + `-e SANDY_EGRESS_MODE=<off|permissive|strict>` (the resolved posture, forwarded for in-container introspection — informational only; note `SANDY_EGRESS_MODE` is forwarded in **all** modes including `off`, not just proxy mode — see E.16). The per-OS magic-hostname `--add-host` block is bypassed in proxy mode (all resolution goes through the proxy DNS). `apply_network_isolation` (iptables) is skipped.
- `cleanup()` removes the **agent container first** (`docker rm -f "$CONTAINER_NAME"`), then the proxy container, then the egress network, then the sidecar. Removing the agent first is load-bearing in proxy mode: the agent runs `docker run --rm` in the foreground, but the container's lifetime belongs to the daemon, not the `docker run` client — so if that client is killed without the container stopping (closed terminal, killed session, dropped SSH, SIGHUP), the daemon keeps the agent running. Without the explicit agent removal, the rest of `cleanup()` would tear down the proxy and egress route, **stranding the agent** on a routeless `--internal` sidecar (every API request fails `FailedToOpenSocket` until the next launch). It also lets the sidecar `network rm` succeed instead of failing on the still-attached orphan (which would leak the subnet). Guarded with `${CONTAINER_NAME:-}` because the trap is armed before that var is assigned. Regression: `run-tests.sh §55`.

**Non-TCP backstop (proxy is TCP-only by design).** The proxy speaks only TCP; it does not proxy UDP/QUIC/ICMP. The `--internal` network is the protocol-agnostic backstop — an L3 `FORWARD` drop with no `MASQUERADE` — so *all* non-TCP egress off the sidecar is dropped before reaching the proxy: raw UDP, QUIC/HTTP-3 over UDP/443 (which would otherwise bypass SNI inspection; it fails closed and clients fall back to TCP-through-proxy), ICMP, and IPv6 (networks are `--ipv6=false`, no v6 route). Verified on macOS Docker Desktop 2026-06-11 and guarded by `test/spike/macos-internal-network-spike.sh` (A1d) and `run-integration-tests.sh` §13b (Linux). **Invariant:** if the proxy ever becomes the *only* egress mechanism (e.g. retiring iptables), a non-TCP block must be re-added or this protection regresses.

**Default allowlist**: `api.anthropic.com`/`*.anthropic.com`, `api.openai.com`/`*.openai.com`, `*.googleapis.com`/`accounts.google.com`/`oauth2.googleapis.com`, GitHub (`github.com`, `github.com:22`, `api.github.com`, `codeload.github.com`, `*.githubusercontent.com`, `ssh.github.com:22`), npm (`registry.npmjs.org`, `*.npmjs.org`), PyPI (`pypi.org`, `files.pythonhosted.org`), crates (`crates.io`, `static.crates.io`, `index.crates.io`), Go (`proxy.golang.org`, `sum.golang.org`, `*.golang.org`), Debian (`deb.debian.org`, `security.debian.org`).

**ssh `ProxyCommand`**: in proxy mode the entrypoint prepends `Host *\n  ProxyCommand socat - PROXY:<proxy-ip>:%h:%p,proxyport=3128` to `~/.ssh/config`, tunneling git-over-SSH through the proxy CONNECT listener. On Linux the SSH-agent socket is a direct bind mount and signing works; on macOS the agent socket relay can't cross `--internal`, so signing is unavailable under the proxy (git-over-SSH still works) — sandy warns and recommends `SANDY_SSH=token`.

**Local LLM**: `SANDY_LOCAL_LLM_HOST` is served by the proxy's forward listener (the `local_llm` config field), not an iptables hole. The proxy is given `--add-host host.docker.internal:host-gateway` on Linux.

---

## 9. Protected Files

Certain files and directories in the workspace are overlaid at container launch to prevent modification. The lists of protected paths are emitted by three helper functions defined at the top of the `sandy` script (`_sandy_protected_files`, `_sandy_protected_git_files`, `_sandy_protected_dirs`). The test harness reads the same lists via `sandy --print-protected-paths` — single source of truth.

### Read-Only Bind Mounts

**Files (existence-gated — only mounted when present on host):**

| Path | Threat mitigated |
|---|---|
| `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile` | Shell config injection (aliases, PATH hijacking, env poisoning) |
| `.gitconfig` | Credential helper injection, alias hijacking |
| `.ripgreprc` | Search config injection |
| `.mcp.json` | MCP server config tampering |
| `.envrc` | `direnv` auto-sourcing on `cd` |
| `.tool-versions` | asdf toolchain version hijacking |
| `.mise.toml` | mise toolchain hijacking |
| `.nvmrc`, `.node-version` | Node version manager hijacking |
| `.python-version` | pyenv / uv auto-install hijacking |
| `.ruby-version` | rbenv/chruby hijacking |
| `.npmrc`, `.yarnrc`, `.yarnrc.yml` | npm/yarn registry hijacking, auth-token exfiltration |
| `.pypirc` | Python package index auth-token exfiltration |
| `.netrc` | HTTP credential exfiltration (curl/git/wget) |
| `.pre-commit-config.yaml` | pre-commit hook injection |
| `.claude/settings.json`, `.claude/settings.local.json` | Claude Code project-settings `hooks` injection later executed by a **host-side** Claude Code run on the same workspace (trust-handoff; cf. Cursor CVE-2026-48124). `settings.local.json` is normally writable — `:ro` here means in-session edits to a pre-existing one won't persist. As of 1.10.0, when `claude` is in `SANDY_AGENT`, sandy itself **creates** `.claude/settings.local.json` before this mount (if absent) to write the `SANDY_CROSS_SESSION_INBOUND` pin (§C.2a) — the file becomes existence-gated-and-present on essentially every claude launch, so it is `:ro` in-container immediately after being written. |

**Git-tree files (existence-gated — only mounted when present on host):**

| Path | Threat mitigated |
|---|---|
| `.git/config` | Remote path manipulation, `core.fsmonitor` injection, `core.hooksPath` redirect |
| `.gitmodules` | Submodule URL hijacking |
| `.git/packed-refs` | Bulk ref spoofing / `git gc` repack |

`.git/HEAD` is intentionally left read-write as of 1.5.0 (#80) so `git switch`/`checkout`/`checkout -b` work inside the container — a symref is not a host-code-execution vector. A HEAD left on an unexpected branch at session end is surfaced by a yellow notice (detection-not-prevention, mirroring the protected-dirs hybrid).

**Directories (existence-gated — mounted read-only when present on host):**

| Path | Threat mitigated |
|---|---|
| `.git/hooks/` | Pre-commit, post-checkout, push hook injection |
| `.git/info/` | `.git/info/attributes` filter-driver injection (arbitrary-command on checkout/add) |
| `.vscode/`, `.idea/` | IDE task/launch config injection |
| `.circleci/` | CircleCI pipeline escape |
| `.devcontainer/` | Devcontainer auto-open escape |
| `.sandy/` | sandy's own control dir (`Dockerfile`, `config`, `.secrets`) — `:ro` so the agent can't modify build inputs mid-session (HF-incident Issue 7; pairs with the `.sandy/Dockerfile` build approval gate, §5 Phase 3) |
| `.claude/hooks/` | Claude Code hook-script injection later executed by a **host-side** Claude Code run on the same workspace (trust-handoff). Distinct from the `commands/agents/plugins` overlay, which is writable-in-sandbox by design. |
| `.github/workflows/` | GitHub Actions pipeline escape on `git push`. Omitted from the list when `SANDY_ALLOW_WORKFLOW_EDIT=1`. |

**Submodule gitdirs (recursive walk):**

`_protect_submodule_gitdirs` walks `$WORK_DIR/.git/modules/` (plus, for `--separate-git-dir` / worktree-of-submodule layouts, `$GITDIR_HOST/modules/`) up to `maxdepth 6`, matches `-type f -name config`, and for each submodule directory mounts:

- `<submodule>/config` → read-only
- `<submodule>/hooks/` → read-only (only if present on host)
- `<submodule>/info/` → read-only (only if present on host)

This uses `while read -r -d ''` and shell-side `dirname` to avoid GNU-only `find -printf '%h\0'` — portable across macOS/BSD and GNU `find`.

**Non-default git hooks (`core.hooksPath`).** `.git/hooks/` is protected, but a repo (or the user's global git config) can redirect hooks elsewhere via `core.hooksPath` (e.g. `core.hooksPath = .githooks`). `_sandy_extra_hooks_dir` resolves the effective value at launch (`git -C "$WORK_DIR" config --path --get core.hooksPath`, so git's own tilde-expansion applies) and, when it resolves to a directory **inside the workspace** that is neither the default `.git/hooks` nor the workspace root, mounts it `:ro` (existence-gated at the call site). It canonicalizes (`pwd -P`) *only* to run the containment check — a hooks dir resolving outside the workspace, or the workspace root itself, is rejected — but mounts the path git actually **consults** (the configured value for a relative hooksPath), not the resolved target. Mounting the target would `:ro` the real directory while leaving a *symlinked* hooksPath (`.githooks -> real`) writable in the rw workspace: an agent could `rm .githooks && mkdir .githooks && write a hook`, redirecting host git into a fresh unprotected dir. Locking the configured path instead makes it a `:ro` mount point the agent cannot swap. A hooksPath that resolves onto a directory already in the static protected-dirs list is skipped (a duplicate `-v` would make Docker refuse to launch). This complements the `.git/config` `:ro` mount, which blocks *injecting* a new `core.hooksPath`; this handles a *pre-existing* one (Pillar "Week of Sandbox Escapes" #4 variant). **Create-fresh case (now covered — sandbox-escape eval Issue F):** hooksPath set but its directory absent at launch is existence-gated to no `:ro` mount, so it is caught by **session-end detection** instead. `_sandy_configured_hooks_rel` resolves the configured hooks path *existence-independently* (unlike `_sandy_extra_hooks_dir`, which requires the dir to exist for the mount); the launch snapshot records it only if it existed, and the exit sweep flags a newly-appeared hooks dir with content. Standing rule this reinforces: never gate a trust decision on a filename/path pattern without a symlink/indirection check (also applies to a symlinked `.git` or an external `GIT_DIR`).

**Mount policy (hybrid, existence-gated symmetric model)**: both files and directories are existence-gated. If the host has the path, sandy bind-mounts it `:ro` (kernel-level write prevention, no host-side artifact because Docker is mounting over an existing target). If the host doesn't have the path, sandy adds no mount — the agent can write there during the session, and detection runs on session exit.

The earlier "always-mount with empty fixture" pattern for directories left empty stub dirs on the host workspace every session, required heroic cleanup-on-exit and pre-existing-debris preflight logic, and produced user-visible weirdness (file managers, IDE scanners, `ls`, ripgrep all saw the stubs during sessions). For files the same approach was strictly worse — 0-byte stubs broke direnv, polluted `git status`, and tripped every tool that checks for file presence. The 0.13 cleanup unifies both behaviors on the existence-gated model.

**Session-end detection (replacement defense for absent paths).** Sandy snapshots which protected dirs **and files** existed at launch into `$SANDBOX_DIR/.protected-existed-at-launch` (one path per line), plus the configured `core.hooksPath` target if it existed. On session exit, `cleanup()` walks `_sandy_protected_dirs`, `_sandy_protected_files`, and the resolved `core.hooksPath` target (`_sandy_configured_hooks_rel`) again; for each path that's now a non-empty directory (or, for files, present) but wasn't in the launch snapshot, it emits a yellow warning naming the path and showing the `rm -rf` remediation. When the newly-appeared path is `.sandy/` it also writes `$SANDY_HOME/approvals/dockerfile-<wd16>.session-created` and says the next `.sandy/Dockerfile` approval will be flagged as created by a sandy session (2.7.0, #295 item 3; §5). No automatic deletion — we don't know whether the agent's write was legitimate (the user may have asked for `.vscode/settings.json`) or a prompt injection, so we surface it and let the user decide.

This is *detection*, not *prevention*. The threat window is "between session end and the user's next operation that auto-executes those paths" (`git pull` for hooks, `git push` for CI workflows, opening the project in VS Code/JetBrains for IDE configs). The trade-off is conscious: prevention required the workspace pollution that drove the redesign. For the realistic threat model (agent occasionally wrong via injection or skill bug; user attentive enough to read launch/exit messages), detection is sufficient.

**Permission-mode drift notice (#151).** The same detection-not-prevention shape applies to `settings.json`'s writable `permissions.defaultMode`: Claude Code 2.1.232 has been observed overwriting sandy's `bypassPermissions` pin with `"auto"` via an in-container write ~13s after launch, and since sandy only writes the file host-side *before* `docker run`, it cannot see that write as it happens. At session end, `cleanup()` compares the launch baseline (`$SANDBOX_DIR/.claude-perm-mode-at-launch`, §C.2) against the current mode (re-extracted from `settings.json` via the same `_sandy_settings_default_mode()` helper) and prints a yellow notice — pointing at issue #151 — if they differ, gated so a mode that was never pinned (`"none"`) never fires the warning (that case is Claude Code's own default write, not an override of sandy's pin, and would otherwise be alarm fatigue on every `SANDY_SKIP_PERMISSIONS=false` session). Informational only: sandy re-pins the mode on every launch regardless, so the drift is at most a mid-session surprise, not a persistent one.

**Long-term direction: `fanotify` with `FAN_OPEN_PERM`.** The "right" answer is to intercept write attempts at the syscall level before they hit the filesystem. A small container-side watcher daemon registers `FAN_OPEN_PERM` / `FAN_ACCESS_PERM` on the protected paths; the kernel suspends each open-for-write until the userspace handler responds; sandy returns `FAN_DENY` → caller gets `-EPERM`, no host artifact ever produced. Properties:

- True prevention with no host pollution, even for absent paths
- Honest to the agent (real `-EPERM`, not silent failure or post-hoc cleanup)
- Works in containers on macOS Docker Desktop (the VM kernel is Linux 5.x with fanotify support)
- Requires `CAP_SYS_ADMIN` for fanotify setup; sandy currently `--cap-drop ALL`, so an entrypoint-phase grant + drop-before-agent-runs is needed
- Watcher death blocks all watched-path I/O until a kernel-side timeout — needs supervisor + restart

Estimated implementation: 80-120 lines of Python or C, plus integration into the entrypoint. On the roadmap, unscoped until/unless detection-only proves insufficient against a real attack path.

**Stub cleanup preflight (legacy)**. Workspaces touched by pre-0.13 sandy may still have empty stub dirs left over. On launch, sandy walks `_sandy_protected_dirs` and `rmdir`s any that are empty. In a git repo it additionally requires the dir isn't git-tracked. Name-match against the small protected-dirs list + the empty check is a sufficient safety bar; the git-tracked exclusion is an additional guard in repos. Under `SANDY_DEBUG_CLEANUP=1`, the trap prints the number of stubs processed plus any `rmdir` failures with errno messages. The session-scoped stub-tracking file (`$SANDBOX_DIR/.session-created-stubs`) is still used for the `.claude/{commands,agents,plugins}` and `.gemini/{extensions,commands}` sandbox overlays (which legitimately need stub creation for the writable-overlay pattern). The protected-dirs path no longer contributes to it.

**Stub cleanup preflight (files)**: sandy scans the workspace on launch for 0-byte files matching the protected-files list that are untracked by git. If any are found (typically leftover stubs from a workspace that ran a pre-0.11.2 always-mount build), sandy prints a one-shot `rm` remediation command. File stubs are not auto-removed — a 0-byte file could be intentional, and the git-untracked heuristic is only a best-effort safety check. Directory stubs *are* auto-removed (see above) because the name-match + empty gate is stronger.

**Intentionally excluded** from the protected list: package manifests (`Makefile`, `justfile`, `package.json`, `pyproject.toml`, `setup.py`, `Cargo.toml`, `build.rs`). The agent legitimately edits these as project source, and they are invoked explicitly by name rather than sourced on `cd` or filesystem scan.

### Writable Sandbox Overlays

| Workspace path | Sandbox source | Behavior |
|---|---|---|
| `.claude/commands/` | `workspace-commands/` | Starts empty; Claude can create/modify freely |
| `.claude/agents/` | `workspace-agents/` | Starts empty; Claude can create/modify freely |
| `.claude/plugins/` | `workspace-plugins/` | Starts empty; managed via `/plugin install` |

Host content at these paths is hidden (not visible inside container). Changes persist in the sandbox across sessions. No changes to host filesystem.

### Symlink Protection

Before container launch, sandy scans the workspace (up to 8 levels deep, skipping `node_modules/`, `.venv*/`, `.git/`) for symlinks pointing outside the project directory. If any are found, sandy consults the persisted approval list at `<NAME>/.sandy-approved-symlinks.list` before proceeding:

- **First launch (no approval list):** the user is prompted (`Proceed anyway? [y/N]`). On `y`, sandy writes the current set to `.sandy-approved-symlinks.list` and proceeds. On anything else, sandy aborts.
- **Identical or reduced set:** proceed silently. Removed entries are pruned from the list silently (deletion of a symlink is always benign).
- **New entry present:** hard error. Sandy names the new symlink in the error message and refuses to start. There is no second-chance prompt — the rationale is that a y/N prompt can be trained past ("I'll click yes again"), but a hard error forces an explicit user action to reapprove (delete the symlink and relaunch, or `rm <NAME>/.sandy-approved-symlinks.list` to clear the persisted set and re-prompt).

When the user accepts, sandy automatically mounts each symlink target into the container so the symlinks resolve correctly:
- **Absolute symlinks** (`data -> /home/user/shared/data`): Target is mounted at the raw symlink path (the literal path the OS looks up inside the container).
- **Relative symlinks** (`data -> ../../shared/data`): Target is mounted at its `$HOME`-relative container path, which is where the relative traversal lands from the container's workspace location.

Duplicate targets are deduplicated by container mount path.

---

## 10. SSH Agent Relay

### Token Mode (default, `SANDY_SSH=token`)

1. Query `gh auth token` on host for the active account's token (`GIT_TOKEN`)
2. Enumerate all authenticated accounts via `gh auth status`, collect each account's token via `gh auth token --user <account>`
3. Pass `GIT_TOKEN` to container (used for git URL rewriting)
4. Pass `GH_ACCOUNTS` to container as comma-separated `user:token` pairs (e.g. `user1:tok1,user2:tok2`)
5. In container: configure `git config --global url."https://oauth2:<TOKEN>@github.com/".insteadOf "git@github.com:"` (token mode only)
6. In container: authenticate `gh` CLI with all accounts from `GH_ACCOUNTS` (works in both token and agent modes)

Multi-account support: Users with multiple GitHub accounts (e.g. personal + enterprise) authenticated via `gh auth login` will have all accounts available inside the container. The `gh` CLI can then access repos from any authenticated account.

Fallback: If `gh auth token` fails, warn that git push/pull may not work.

### Agent Mode (`SANDY_SSH=agent`)

**Linux**: Direct socket mount. Host `SSH_AUTH_SOCK` socket mounted at `/tmp/ssh-agent.sock` inside container.

**macOS**: Two-hop relay.
1. **Host side**: `socat TCP-LISTEN:<PORT>,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:<SSH_AUTH_SOCK>`
2. **Container side** (in entrypoint): `socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,mode=0600,uid=$RUN_UID TCP:host.docker.internal:<PORT>`
3. Wait for socket to appear (retry loop, 50 attempts x 0.1s)

**SSH config**: Host `~/.ssh/` is mounted read-only at `/tmp/host-ssh`. The entrypoint copies each file (dereferencing symlinks, skipping dangling ones) to `~/.ssh/` with correct ownership and permissions (600 for keys, 644 for `.pub`/`config`/`known_hosts`).

---

## 11. Credential Management

### Priority Order

1. **Long-lived token** (`CLAUDE_CODE_OAUTH_TOKEN`): Valid 1 year, generated via `claude setup-token`. Recommended for headless servers. When set, this handles regular API calls; the credential file is still loaded alongside it (without token-refresh logic) so that cloud features like `/ultrareview` have access to the full OAuth credential object. **When the token is set, sandy does not forward `ANTHROPIC_API_KEY`** (Claude Code would resolve the API key ahead of the token and bill per-use) — a warning fires if both are configured.
2. **OAuth credentials**: From host `~/.claude/.credentials.json` (or macOS Keychain). Token expiry checked; refresh attempted on macOS via `claude auth login`.
3. **Fallback**: Skip credential setup; user directed to `/login` inside session.

### Token Expiry Check

`token_needs_refresh()` checks if `claudeAiOauth.expiresAt` is within 5 minutes of current time. Uses Node.js (preferred) or Python 3 (fallback) for timestamp comparison.

### Ephemeral Credential Loading

Credentials are loaded into a temporary file, mounted into the container at `~/.claude/.credentials.json`, and discarded on exit. They are never persisted in the sandbox.

### OAuth Token Isolation

`CLAUDE_CODE_OAUTH_TOKEN` is explicitly set to empty string in the container's environment when not configured, preventing accidental leakage from the host environment.

### Gemini Credentials (whenever `gemini` is in `SANDY_AGENT`)

Sandy's `load_gemini_credentials()` tries the following sources, controlled by `SANDY_GEMINI_AUTH` (`auto` | `api_key` | `oauth` | `adc`):

| Mode | Source | Container mount / env |
|---|---|---|
| `api_key` | `GEMINI_API_KEY` env var on host | Forwarded via `-e GEMINI_API_KEY=…` |
| `oauth` | Host `~/.gemini/oauth_creds.json` (Gemini CLI ≥0.30), falling back to legacy `~/.gemini/tokens.json` | Ephemeral copy of whichever was found, mounted at the same filename under `/home/sandy/.gemini/` **read-only** (1.0-rc1) |
| `adc` | `~/.config/gcloud/application_default_credentials.json` | Mounted read-only + `GOOGLE_APPLICATION_CREDENTIALS` env var |

In `auto` mode, all three are probed; a warning is emitted if none are found. OAuth tokens are copied to a tmpdir each launch and discarded on exit (same pattern as Claude credentials). Gemini's OAuth refresh is handled inside the CLI itself, so sandy does not run a refresh check.

> **`oauth` free-tier is deprecated upstream (issue #21).** Google retired the free-tier `gemini-cli` OAuth login ("Gemini Code Assist for individuals") in mid-2026; a session using it fails at Google's tier check with `IneligibleTierError` regardless of sandy (sandy loads/forwards the creds correctly — the CLI's own `:ro`-mount refresh-write also EROFS-errors, but the tier error is fatal first). The `oauth` path remains wired for any still-valid refreshing tier, but `api_key` / `adc` (Vertex) are the recommended paths. See also the deferred rw-ephemeral-copy idea in `docs/POST_1.0_IDEAS.md`.

Vertex AI routing is enabled by setting `GOOGLE_GENAI_USE_VERTEXAI=true` with `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_LOCATION`; all three are forwarded into the container when set.

**Note**: `gemini auth` (browser OAuth) must be run **on the host** — the container is headless and cannot open a browser.

### Codex Credentials (`SANDY_AGENT=codex`)

Sandy's `load_codex_credentials()` tries the following sources, controlled by `SANDY_CODEX_AUTH` (`auto` | `api_key` | `oauth`):

| Mode | Source | Container mount / env |
|---|---|---|
| `api_key` | `OPENAI_API_KEY` env var on host | Materialized as an ephemeral `auth.json` (`{"OPENAI_API_KEY":"…"}` — what `codex login --with-api-key` writes) mounted at `/home/sandy/.codex/auth.json` **read-only**; the env var is also forwarded via `-e OPENAI_API_KEY=…` for other in-container tooling |
| `oauth` | `$SANDBOX_DIR/codex/auth.json` if present and non-empty, else host `~/.codex/auth.json` | The host copy is **seeded into the sandbox** (`$SANDBOX_DIR/codex/auth.json`, mode 600) and reached through the existing **read-write** `~/.codex` mount — no `:ro` overlay, so an in-container `codex login` can write and persist. The host file is only ever read |

In `auto` mode (default), `OPENAI_API_KEY` wins if set; otherwise this sandbox's own `auth.json` is used if present and non-empty; otherwise the host's is seeded in; otherwise a warning is emitted. The api_key path materializes a file (rather than relying on env passthrough) because codex 0.139+ no longer reads `OPENAI_API_KEY` from the environment for first-party auth — requests go out with no Authorization header at all and fail with 401 "Missing bearer or basic authentication in header".

**The OAuth credential is seeded, not overlaid.** Until 1.10.x the host's `auth.json` was copied to a temp dir and bind-mounted **read-only** over `/home/sandy/.codex/auth.json`. That made `codex login`, `codex logout` and in-session token refresh fail with `Read-only file system (os error 30)` inside the container — while this document, `CLAUDE.md` and sandy's own comments all told the user to re-login *inside the container*, which that configuration makes impossible. The `:ro` was also not providing its two stated properties: the mount source was already an ephemeral **copy** that `cleanup()` removes, so an in-container write could neither reach the host's file nor race it.

Sandy now copies the host's `auth.json` into `$SANDBOX_DIR/codex/auth.json` (mode 600) on first use and lets the agent reach it through the ordinary read-write `~/.codex` mount. An in-container login therefore works and **persists for that sandbox**, and on later launches the sandbox's own copy takes precedence over the host's — without that precedence every relaunch would overwrite a fresh login with the host's stale token. The host file is only ever read; nothing is copied back. `sandy --reset-sandbox` discards the sandbox copy, after which the host's is seeded again.

**The api_key path keeps the read-only overlay.** Its `auth.json` is synthesized from `OPENAI_API_KEY`, which is re-supplied on every launch, so there is nothing an in-container write could usefully persist — and keeping it read-only stops the agent substituting a credential of its own mid-session. In-container `codex login` is consequently still refused on that path; the launch line says so and names the two ways out (unset the key, or set `SANDY_CODEX_AUTH=oauth`).

**In-container login: use `codex login --device-auth`.** The plain `codex login` starts a **local** callback server (`DEFAULT_ISSUER = https://auth.openai.com`, `DEFAULT_PORT = 1455`, fallback `1457`) and expects the browser to redirect to `http://localhost:<port>`. Inside sandy that can never complete: the port is bound in the *container*, so a browser on the host redirects to the *host's* localhost, and under the egress proxy the agent sits on an `--internal` sidecar with no inbound path at all. Codex itself names the fix in that flow's own output — *"On a remote or headless machine? Use `codex login --device-auth` instead."*

The device flow has no callback and binds no port: codex prints a URL (`<issuer>/codex/device`) and a user code, you open it on any machine, and codex **polls** for the token. It therefore works unchanged in the sandbox, and — since the OAuth path is seeded read-write rather than overlaid `:ro` (above) — the resulting `auth.json` persists in `$SANDBOX_DIR/codex/` and wins over the host copy on later launches.

```sh
# workspace .sandy/config, or simply leave OPENAI_API_KEY unset:
SANDY_CODEX_AUTH=oauth
# then, inside the container:
codex login --device-auth
```

**Precondition, and it is the usual trip-up:** with `OPENAI_API_KEY` set, `auto` selects the **api_key** path, whose `auth.json` is a read-only overlay — `codex login` is refused there by design (previous paragraph). Unset the key or pin `SANDY_CODEX_AUTH=oauth`.

**Egress**: the device flow is outbound-only to `auth.openai.com`, already covered by the `*.openai.com` entry in `SANDY_DEFAULT_ALLOW_HOSTS`, so it works in **strict** mode with no added host. (`chatgpt.com` is *not* in the default allowlist — irrelevant to the device flow, but a candidate if some other codex sign-in path is ever needed.)

**Provenance**: the flag, the issuer, and the port were read from the codex source (`codex-rs/cli/src/main.rs`, `codex-rs/login/src/{server,device_code_auth}.rs`) at `main`, not from a pinned release — sandy tracks codex at floating-latest, so confirm with `codex login --help` if a build ever disagrees.

---

## 12. Session Management

### Tmux Integration

Sandy wraps Claude Code in a tmux session:
- **Session name**: `sandy` (fixed)
- **Window name**: `sandy: <PROJECT_NAME>`
- **Auto-resume**: If session files (`.jsonl`) exist in `~/.claude/projects/<WORKSPACE_KEY>/` and no overriding flags (`--new`, `-p`, `--resume`, `--continue`), sandy automatically adds `--continue` to resume the last session. `WORKSPACE_KEY` is the container workspace path with all `/` replaced by `-` (e.g., `/home/sandy/dev/sandy` → `-home-claude-dev-sandy`)
- **Fallback**: If `--continue` fails (stale session), retry without it

### Tmux Configuration

- History: 10,000 lines
- Mouse support enabled
- 256-color + RGB
- Escape time: 0ms
- OSC passthrough: `allow-passthrough on` (enables terminal notifications and clipboard)
- OSC 52 clipboard support for mouse selections
- Status bar: launch/session-scoped info bar — egress posture (color-coded), agent, workspace, attached-client count, daemon marker, clock (see Appendix A.7 for the exact `#{E:}` env-driven format; see also "Status Lines" in CLAUDE.md for the split with Claude Code's own live statusLine)

### Multi-Agent Mode (comma-separated `SANDY_AGENT`)

When `SANDY_AGENT` contains more than one agent (e.g. `claude,gemini`, `claude,codex`, `claude,gemini,codex,opencode`, or the alias `all`), the user-setup script creates a tmux session with one pane per agent, in the order listed. Layouts, by on-screen position: 2 agents → side-by-side; 3 agents → left half + top-right + bottom-right; 4 agents → 2×2 grid, agent1 top-left, agent2 top-right, agent3 bottom-right, agent4 bottom-left. **This is the visual layout, not the `pane_index` order** — see "Pane-identity contract" immediately below for the mapping between the two. The launch logic is factored into per-agent helpers (`build_claude_cmd()`, `build_gemini_cmd()`, `build_codex_cmd()`, `build_opencode_cmd()`, `build_grok_cmd()`) so single-agent and multi-agent paths share the same command construction. Each pane is an independent process; exiting one leaves the others running.

The previous `both` alias (= `claude,gemini`) was removed in `v0.12` once the comma-separated syntax supported every combination. Using it now exits early with an error message pointing at the new syntax.

### Pane-identity contract (stable, 2.4.0, #378)

Anything inside the container that needs to know which pane runs which agent depends on four facts. Sandy shipped its own in-image consumer of them, `/usr/local/bin/sandy-handoff-sessions`, through 2.5.x; it was removed in 2.6.0 (#382, decision 7), and the four facts are what an external consumer now builds its own copy of such a helper on. As of 2.4.0 these are a **published, stable contract**: renaming or removing any of them is a breaking change governed by README's `## Deprecated` table (announced in an `X.0.0`, removed no earlier than a later `X.Y.0` — see "Versioning" in CLAUDE.md), not a free refactor. As of 2.4.0, fact 2 covers single-agent panes too — sandy tags the sole pane of a single-agent session, not just multi-agent panes — and (through 2.5.x) the helper's own untagged-pane fallback narrowed to match: an untagged pane counted as `$SANDY_AGENT` only when `SANDY_AGENT` named exactly one agent AND the session had exactly one pane (the only shape a pre-2.4.0 single-agent sandy could have produced); any other untagged pane was skipped rather than guessed. A consumer's own copy should apply the same rule.

| # | Fact | Detail |
|---|---|---|
| 1 | Session name | The tmux session is always the literal `sandy`, one window, in both single-agent and multi-agent mode. |
| 2 | `@sandy_pane_agent` tmux pane option | `@sandy_pane_agent` is set, by pane id, on every pane sandy creates, in both single-agent and multi-agent mode (2.4.0+). A pane without it was not created by sandy: a user split, or a pane an agent opened (e.g. an agent-teams teammate). Sandy before 2.4.0 set it in multi-agent mode only. |
| 3 | `SANDY_AGENT` order = spawn order | The comma-separated list, in-container, is in the order panes were created — the same order `agents` reports in the session marker (`/etc/sandy-session.json`) and in `--print-state`. |
| 4 | `pane_index` ≠ spawn order, in the 4-agent grid | The fourth split re-splits pane 0 (`split-window -v -t sandy.0`), and tmux inserts the new pane's index immediately after the one it split. The on-screen layout is unaffected; only the index numbering is: |

| `pane_index` | on-screen position | spawn order |
|---|---|---|
| 0 | top-left | agent 1 |
| 1 | bottom-left | agent 4 |
| 2 | top-right | agent 2 |
| 3 | bottom-right | agent 3 |

For 2- and 3-agent layouts `pane_index` and spawn order coincide; the trap is specific to the fourth pane of the 2×2 grid.

**Read identity from the option, never from `pane_index`, a scrollback marker, or the pane title.** `pane_index` is wrong for the reason above; a scrollback marker is wiped the moment a real credentialed agent redraws or clears its pane; `select-pane -T` (the pane title) is OSC-2-clobberable by anything running inside the pane. `@sandy_pane_agent` is the identity source which the agent's redraws and OSC-2 title writes do not touch, and it binds correctly regardless of the pane-index shuffle.

**Not a security boundary.** A process inside the session can rewrite or clear the option (`tmux set-option -p`). The worst it can do is stop delivery within its own sandbox: a consumer's helper reports an ambiguous target, or delivery waits. It can never redirect delivery elsewhere.

A property test pins this contract in `test/run-tests.sh` §171: a fixture where the option disagrees with `pane_index`-as-spawn-order must still yield the correct agent per row, and the real 4-agent mapping table above is asserted directly. `test/host-check-pane-tag.sh` (host-only, live tmux, not wired into any automated suite) additionally proves the single-agent daemon and foreground launch forms actually tag their pane against a real tmux server.

### Codex Headless Translation (`SANDY_AGENT=codex`)

`build_codex_cmd()` inspects the positional args for `-p`/`--print`/`--prompt`. If present, it emits `codex exec --sandbox danger-full-access --skip-git-repo-check <prompt>` (interactive becomes headless); otherwise `codex --sandbox danger-full-access` (TUI). `--skip-git-repo-check` is required because codex 0.139+ refuses `exec` outside a trusted directory / git repo ("Not inside a trusted directory and --skip-git-repo-check was not specified"); sandy provides the outer isolation, so the gate is redundant and would break headless runs from non-git workspaces. Interactive mode omits the flag — the `[projects."…"] trust_level = "trusted"` entry in `config.toml` covers the TUI path. The sandy `-p`/`--print`/`--prompt` flags are dropped and the remaining arg is passed as the positional prompt, because `codex exec` takes the prompt as a positional argument, not a flag. `--continue`/`-c` is silently dropped (codex has `codex resume` but no headless `--continue` equivalent — matches the gemini behavior).

`codex exec` uses only exit codes 0 (success) and 1 (failure). Sandy does not attempt to emulate Claude's richer exit-code semantics (no tool-denied, no context-exhausted signals) for codex. `--sandbox danger-full-access` on the CLI is belt-and-suspenders alongside the `sandbox_mode` in `config.toml`; do not remove either.

### Remote Control Mode

With `--remote`: no tmux wrapper, launches `claude remote-control --name "sandy: <PROJECT_NAME>"`. Browser/phone can connect to control the session.

**Only supported with `SANDY_AGENT=claude`.** Gemini CLI has no native WebSocket/daemon mode, codex's `mcp-server`/`app-server` modes don't map cleanly to Claude's session-based `--remote` contract, and OpenCode has no equivalent yet; `--remote` with any other value — `gemini`, `codex`, `opencode`, or any multi-agent combo — exits with an error. Tracked as a future enhancement pending upstream support.

### Terminal Notifications

Sandy passes through OSC escape sequences (9/99/777) from Claude Code to the outer terminal. When running inside cmux (detected via `CMUX_WORKSPACE_ID`), sandy auto-installs a notification hook that emits OSC 777 sequences.

Host-side hooks (`~/.claude/hooks/`) are mounted read-only into the container. Host hooks take precedence over auto-setup.

---

## 13. Workspace Path Mapping

The workspace is mounted inside the container at a path that mirrors the host's `$HOME`-relative location:

```
If host path starts with $HOME:
    container path = /home/sandy/<relative-to-HOME>
Else:
    container path = host path (fallback for paths outside $HOME)
```

For example, `~/dev/sandy` on the host becomes `/home/sandy/dev/sandy` inside the container. This preserves the relative path relationship needed for git submodules.

### Git Submodule Support

When `.git` is a file (submodule), sandy:
1. Reads the relative gitdir path from the `.git` file
2. Resolves absolute host path for both worktree and gitdir
3. Computes container paths using the same `$HOME`-relative mapping
4. Mounts both at the correct container paths, preserving the relative relationship

---

## 14. Environment Detection

On every session start, `user-setup.sh` checks the workspace:

### `.python-version`

If present, auto-installs the specified Python version via `uv python install` (idempotent, persists in sandbox's `uv/` directory).

### Broken `.venv`

If `.venv/bin/python` is a broken symlink (host/container Python version mismatch):
- Extracts version from symlink target
- Auto-installs matching version via `uv python install`
- Warns user with fix command

### Foreign Native Modules

Scans `node_modules/` for `.node` files. If they're not ELF binaries (e.g., Mach-O from macOS host), warns with `npm rebuild` as the fix.

### Orphaned pip user-site

`PYTHONUSERBASE` (the persistent `pip/` sandbox mount, `~/.pip-packages`) stores `pip install --user` packages under `lib/python3.<minor>/site-packages`. A base-image system-Python bump (e.g. 3.11 → 3.13 with the trixie move) leaves an older `lib/python3.<minor>/` tree on disk but invisible to the new interpreter. Warn-only: for each `lib/python3.*` dir under `$PYTHONUSERBASE` whose minor version doesn't match the running `python3`'s, prints the stale path and a reinstall/`rm -rf` pointer. Never fails the session.

### Git LFS

If workspace is a git repo and `.gitattributes` contains `filter=lfs` (checked up to 3 levels deep), runs `git lfs install` (idempotent).

---

## 15. Plugin Marketplace Management

### Configured Marketplaces

Sandy configures three plugin marketplaces in `settings.json` via `extraKnownMarketplaces`:

| Name | Source |
|---|---|
| `claude-plugins-official` | `{ source: "github", repo: "anthropics/claude-plugins-official" }` |
| `sandy-plugins` | `{ source: "github", repo: "rappdw/sandy-plugins" }` |

The marketplace entries are merged into `$SANDBOX_DIR/claude/settings.json` host-side on every launch, next to the other sandy defaults (see §4 Seeding and §C.2). The merge happens before the container launches — as of 0.11.3 the settings file is rw inside the container (the pre-0.11.3 `:ro` sidecar broke `/plugin install`), so the marketplace merge could in principle live in `user-setup.sh`, but keeping it host-side avoids duplicating the node/jq/fallback triple across entrypoints.

### Deprecated Marketplace Removal

The `thinkkit`, `ait`, and `pka-skills` marketplaces are automatically removed on startup if present (same host-side merge block).

### Refresh Logic

- Marketplace catalogs refreshed daily (24-hour cache via `~/.claude/plugins/.marketplace_updated` timestamp)
- Force refresh when channels are configured (channel plugins may need installing)
- Runs `claude plugin marketplace update` for each marketplace

### Built-in Slash Commands (synthkit)

If synthkit is installed, `user-setup.sh` creates four slash commands in `~/.claude/commands/` (Claude, Markdown), `~/.gemini/commands/` (Gemini, TOML), and/or `~/.codex/skills/<name>/SKILL.md` (Codex, Markdown with YAML frontmatter). OpenCode does not yet have synthkit auto-discovery in v0.13 — `md2pdf`/`md2doc`/`md2html`/`md2email` are still on `PATH` inside the `sandy-opencode` image, but no commands or skill files are created for OpenCode automatically.
- `/md2pdf` — Convert markdown to PDF
- `/md2doc` — Convert markdown to Word (.docx)
- `/md2html` — Convert markdown to HTML
- `/md2email` — Convert markdown to email HTML (clipboard)

For Gemini, the TOML files use `description` and `prompt` fields; the prompt embeds `!{md2pdf {{args}}}` shell execution and `{{args}}` argument substitution per Gemini's command format.

For Codex, skills are drop-in directories: `~/.codex/skills/<name>/SKILL.md`. The file **requires YAML frontmatter** with `name` and `description` keys delimited by `---`, followed by the skill body. Sandy writes one directory per tool (`md2pdf/`, `md2doc/`, `md2html/`, `md2email/`). Codex discovers these on launch and exposes them via `/skills`.

### Gemini Extensions (`SANDY_GEMINI_EXTENSIONS`)

When set, `user-setup.sh` iterates comma-separated URLs/local paths and runs `gemini extensions install <url>` for each, skipping any extension that already exists in `~/.gemini/extensions/`. Extensions persist across sessions via the `gemini/extensions/` sandbox mount.

---

## 16. Channel Integration

Sandy supports Claude Code channels (Telegram, Discord) via two distinct paths:

1. **In-container plugin path** (`SANDY_AGENT=claude` only) — auto-installs the Claude channel plugin from the marketplace and seeds credentials into `~/.claude/channels/`.
2. **Host-side tmux-inject relay** (any other `SANDY_AGENT` value — single `gemini`/`codex` or any multi-agent combo) — agent-agnostic, runs on the host and injects messages into the container's tmux session via `docker exec ... tmux send-keys`.

**Support matrix**:

| Channel | `claude` | `gemini` | `codex` | `opencode` | multi-agent |
|---|---|---|---|---|---|
| Telegram | in-container plugin | host relay | host relay | host relay (untested in v0.13) | host relay |
| Discord | in-container plugin | — | — | — | — |

### In-Container Plugin Setup (Claude)

For each configured channel:
1. Auto-install the channel plugin from the marketplace
2. Create `~/.claude/channels/<channel>/` directory
3. Write `.env` with bot token
4. Write `access.json` with either:
   - `"dmPolicy": "allowlist"` + populated `allowFrom` (if `ALLOWED_SENDERS` set)
   - `"dmPolicy": "pairing"` (if no allowlist, user pairs via `/telegram:access pair <code>`)

### Host-Side Channel Relay (Gemini / Codex / OpenCode / Multi-agent)

`$SANDY_HOME/channel-relay.sh` is a generated bash script that long-polls the Telegram Bot API (`getUpdates`), filters messages by `TELEGRAM_ALLOWED_SENDERS`, and injects them into the container tmux session via:

```
docker exec -u <host-uid> <CONTAINER_NAME> tmux send-keys -t sandy.<PANE> "<text>" Enter
```

`<PANE>` is resolved per message, not taken from `SANDY_CHANNEL_TARGET_PANE` verbatim (#65, 2.4.0). The launcher passes the resolved agent list as `SANDY_CHANNEL_AGENTS` (= `SANDY_AGENT` after alias expansion, in pane-spawn order); the relay maps N to the Nth agent name, then asks the container for `tmux list-panes -t sandy -F '#{pane_index} #{@sandy_pane_agent}'` and targets the pane whose tag carries that name. Raw `sandy.N` is wrong in the 4-agent 2x2 grid, where the last split re-splits pane 0 so `sandy.1` holds the **fourth** agent, `sandy.2` the second and `sandy.3` the third. Agent names are unique within a combo, so the match is unambiguous. When nothing matches (an image predating the tag, or a pre-2.4.0 single-agent session, whose pane was untagged — #378 tags it now) the relay falls back to raw `sandy.N`, where index and spawn order coincide.

The `-u "$(id -u)"` is required: `docker exec` defaults to the image user (root, since sandy sets no `USER`), but the in-container tmux server runs as the gosu-dropped host uid, so its socket lives at `/tmp/tmux-<uid>/`. Without `-u`, root can't see that socket and both `has-session` and `send-keys` silently fail — the host-side relay (gemini/codex/opencode channels) never delivers. (Claude channels use an in-container plugin and are unaffected.)

Launched as a background process before `docker run`, tracked via `CHANNEL_RELAY_PID`, and killed in the cleanup trap. The target pane is `SANDY_CHANNEL_TARGET_PANE=0|1|2|3` — a 0-based position in `SANDY_AGENT` (default `0` = the first agent listed, or the sole pane in single-agent mode), resolved to a pane as above. The launch line names the resolved agent; a value naming no agent in the combo warns.

**Scope**: Telegram only in v0.9.0; Discord via relay is deferred. The relay is stateless — no chat threading, no attachment support, no edit-message reactions. For rich features, use the claude plugin path.

### Multiple Channels

Both Telegram and Discord can be enabled simultaneously with `SANDY_AGENT=claude`:
```
SANDY_CHANNELS=plugin:telegram@claude-plugins-official plugin:discord@claude-plugins-official
```

With any non-`claude` value (single `gemini`/`codex`/`opencode` or any multi-agent combo), only Telegram is currently supported through the relay; `SANDY_CHANNELS=discord` exits with an error.

---

## 17. Auto-Update

### Claude Code Updates

On each launch, sandy checks the installed Claude Code version (cached at `/opt/claude-code/.version`) against the latest release. If an update is available, the Phase 2 image is rebuilt with `--no-cache`. Inside the container, `DISABLE_AUTOUPDATER=1` prevents Claude Code from attempting self-updates against the read-only filesystem.

### Gemini / Codex Updates

For `SANDY_AGENT=gemini`, `_check_gemini_update` compares the in-image `gemini --version` against the npm registry's latest tag for `@google/gemini-cli`.

For `SANDY_AGENT=codex`, `_check_codex_update` compares the in-image `/opt/codex/.version` against `https://api.github.com/repos/openai/codex/releases/latest`. The tag format is `rust-vX.Y.Z`; sandy strips the prefix with `sed -E 's/.*"rust-v?([0-9][^"]*)"$/\1/'`. The `/releases/latest` endpoint returns only the release GitHub marks as "latest" (excludes prereleases by convention), so sandy inherits upstream's stable flagging instead of inventing its own policy — important because codex ships 30+ releases/month, most as prereleases. On parse failure the check returns no-update (stale but working, logged once).

### Sandy Self-Update

`sandy --upgrade` downloads the latest `sandy` script from GitHub and replaces the local copy. Includes pre-flight check for write permissions.

---

## 18. Security Model

### Container Hardening

| Control | Setting |
|---|---|
| Root filesystem | `--read-only` |
| User | Non-root (`sandy`, mapped to host UID) |
| Privilege escalation | `--security-opt no-new-privileges:true` |
| Capabilities | `--cap-drop ALL`, add back only SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER |
| Process limit | `--pids-limit 512` |
| Init / zombie reaping | `--init` (2.5.0, #392): Docker's `docker-init` is PID 1, reaps orphaned processes and forwards signals. Without it an orphan became a permanent zombie holding one of the 512 slots |
| Network | Per-instance isolated bridge, LAN blocked |
| Tmpfs | `/tmp` (1GB), `/home/sandy` (2GB) |

### Threat Mitigations

| Threat | Mitigation |
|---|---|
| File access outside workspace | Read-only root, bind-mount only workspace |
| LAN/internal network access | Egress proxy on an `--internal` network (default, both platforms); legacy iptables DROP rules when the proxy is off (`SANDY_EGRESS_PROXY=0`, Linux only — macOS has no isolation with the proxy off) |
| Shell config injection | `.bashrc`, `.zshrc`, etc. mounted read-only |
| Git hook injection | `.git/hooks/` mounted read-only |
| IDE config tampering | `.vscode/`, `.idea/` mounted read-only |
| Plugin state pollution of host | Sandbox overlay for `.claude/plugins/`; sandbox-local `settings.json` (host copy never written; `enabledPlugins` preserved per-sandbox since 0.11.3) |
| Symlink escape | Pre-launch scan with interactive prompt |
| OAuth token leakage | Ephemeral credentials, explicit env var blocking |
| Fork bomb | PID limit of 512 |
| Privilege escalation | `no-new-privileges`, capability dropping |

### Not Mitigated

- **DNS/outbound exfiltration**: In the default permissive mode (`SANDY_EGRESS_PROXY=1`), public internet is intentionally available — exfil to arbitrary public hosts is not blocked. Strict mode (`=2`) narrows egress to the default allowlist + `SANDY_ALLOW_HOSTS` (domain filtering), but does not stop exfil to an *allowlisted* host (host-relay broker is POST_1.0).
- **Data exfiltration via workspace files**: Workspace is read-write (by design).

---

## 19. Test Suite

**Location**: `test/run-tests.sh` (~4,300 lines, sections §1–§60) plus `test/run-integration-tests.sh` (~1,500 lines, headless end-to-end, needs Docker + API keys) and `proxy/*_test.go` (Go unit tests, run by §58)
**Prerequisites**: Docker, sandy images already built (run on the host, not inside sandy)
**Framework**: Custom bash test harness with `check`, `pass`, `fail` helpers

The category list below covers the founding sections and is not exhaustive — later sections (numbered through §60) are documented next to the features they guard (config tiers §, egress proxy §49–50 and §55–59, sandbox compat floor §51 and §60, OAuth-first auth §52, failure-mode guards §53, multi-agent matrix §54). The regen scripts (`test/regen-config-docs.sh --check`, `test/regen-template.sh --check`) run as part of the suite.

### Test Categories (founding sections)

**Toolchain availability** (8 tests): python3, node, go, rustc, cargo, uv, gcc, git

**Persistent packages** (3 tests): pip, npm -g, go install survive across sessions

**pip behavior** (2 tests): Installs to venv when active, `--user` when not; wrapper script creation

**PATH order** (1 test): `~/.local/bin` is first

**Read-only filesystem** (3 tests): Cannot write to `/usr`, can write to `/tmp` and home

**Dev environment detection** (3 tests): `.python-version` auto-install, broken `.venv` detection, foreign native module warning

**Sandbox isolation** (1 test): Packages don't leak between project sandboxes

**Protected files** (12 tests): Cannot write to `.bashrc`, `.zshrc`, `.git/hooks/`, `.git/config`, `.gitmodules`; sandbox overlays for commands/agents/plugins work correctly

**Git LFS** (2 tests): Available, auto-configured when `.gitattributes` has `filter=lfs`

**UID remapping** (2 tests): Container UID matches host, passwd overlay for non-default UID

**Config parser** (3 tests): Config loaded before SSH setup, doesn't use `source`, uses variable allowlist

**Container naming** (1 test): Name includes sandbox name

**Symlink protection** (3 tests): Detects escaping symlinks, ignores safe internal symlinks, runs before docker

**Terminal notifications** (6 tests): tmux passthrough, host hooks mounted, cmux detection/hook/dedup

**Skill packs** (14 tests): Registration, repo config, Dockerfile generation, build phases, user-setup activation


---

## 20. Installation

### `install.sh` Flow

1. **Preflight warnings** (non-blocking): Docker installed? Node.js installed? GitHub CLI authenticated?
2. **Create install directory**: Default `~/.local/bin`
3. **Download or copy**: If `LOCAL_INSTALL` env var set, copy local file; otherwise download from GitHub
4. **Bake commit hash**: If installing from a git repo, detect and bake `SANDY_COMMIT` into the script (BSD/GNU sed compatible)
5. **Set executable**: `chmod +x`
6. **PATH check**: Warn if `~/.local/bin` not in PATH, suggest shell-specific config

### First Run

1. Validate Docker installed
2. Generate build files in `$SANDY_HOME/`
3. Build Phase 1 (base) and Phase 2 (Claude Code) images (~15-25 min)
4. Build skill pack images if enabled (~5-10 min additional for Chromium)
5. Create sandbox directory structure and seed from host
6. Create Docker network and apply iptables rules
7. Load credentials
8. Launch container

### Subsequent Runs

1. Check image hashes — skip builds if unchanged (~0 sec)
2. Refresh statsig feature flags from host
3. Create network and iptables rules (~1 sec)
4. Load credentials
5. Launch container (~3-4 sec total startup)

---

## 21. File Inventory

### Repository Files

| File | Lines (at 1.0.0-rc1) | Purpose |
|---|---|---|
| `sandy` | ~6,100 | Main launcher script |
| `install.sh` | ~95 | Installer |
| `doctor.sh` | ~280 | Environment preflight / diagnosis. **Generated** (#124) from the `_sandy_doctor_host()` heredoc in `sandy` — `test/regen-doctor.sh` keeps it in sync; still byte-runnable standalone (`bash doctor.sh` / `curl \| bash`) and, once sandy is installed, invokable as `sandy --doctor` |
| `CLAUDE.md` | ~515 | Claude Code agent guidance |
| `README.md` | ~670 | User documentation |
| `RELEASE_NOTES.md` | ~1360 | **Frozen archive**, v0.6.0–v1.7.0. Not maintained — GitHub Releases is canonical for v1.8.0 onward. |
| `SPECIFICATION.md` | this file | Technical specification |
| `SPEC_INTROSPECTION.md` | — | Introspection JSON stability contract |
| `proxy/` | — | Egress proxy (Go: listeners, policy, DNS, guard + unit tests) |
| `templates/user-setup.sh.tmpl` | — | Shellcheck-lintable mirror of the user-setup heredoc |
| `test/run-tests.sh` | ~4,300 | Pure-script test suite (§1–§60) |
| `test/run-integration-tests.sh` | ~1,500 | Headless end-to-end suite (needs Docker + keys) |
| `test/fixtures/frozen-sandbox-1.0/` | — | Frozen 1.0 sandbox snapshot (forward-compat guard, §60) |
| `docs/` | — | Roadmap, post-1.0 ideas, testing plan, security docs |
| `examples/gpu/Dockerfile` | 40 | Per-project GPU Dockerfile example |
| `examples/quarto-typst/.sandy/Dockerfile` | 16 | Per-project Quarto+Typst example |
| `analysis/` | — | Security and architecture audit documents |
| `research/` | — | Feature analysis and design sketches |

Line counts are indicative, refreshed at release cuts — not maintained per-commit.

### Runtime-Generated Files (`$SANDY_HOME/`)

| File | Purpose |
|---|---|
| `Dockerfile.base` | Phase 1 base image definition |
| `Dockerfile` | Phase 2 Claude Code image definition |
| `Dockerfile.skills-base` | Phase 2.5a skill pack base definition |
| `Dockerfile.skills` | Phase 2.5b skill pack code definition |
| `entrypoint.sh` | Container root-phase entrypoint |
| `user-setup.sh` | Container user-phase setup script |
| `tmux.conf` | Tmux configuration |
| `passwd` / `group` | UID/GID remapping files (if needed) |
| `.base_build_hash` | Phase 1 content hash |
| `.build_hash` | Phase 2 content hash |
| `.skills_base_build_hash` | Phase 2.5a content hash |
| `.skills_build_hash` | Phase 2.5b content hash |
| `.update_check` | Cached update check result (24-hour TTL) |
| `.skill_version_<pack>` | Cached skill pack version |
| `Dockerfile.gemini` / `.codex` / `.opencode` / `.full` | Per-agent / multi-agent image definitions |
| `Dockerfile.proxy` | Egress proxy image definition |
| `channel-relay.sh` | Host-side Telegram relay (agent-agnostic tmux injection) |
| `approvals/` | Per-workspace approval files: `passive-<wd16>.list` (privileged config keys), `dockerfile-<wd16>.list` (`.sandy/Dockerfile`), and `dockerfile-<wd16>.session-created` (a session created `.sandy/`; §5, 2.7.0, #295) |
| `config` | User-level configuration |
| `.secrets` | User-level credentials |
| `sandboxes/` | Per-project sandbox directories |

---

## Appendix A: Generated File Templates

Sandy generates all build and runtime files as heredocs embedded in the script. Each function writes one or more files to `$SANDY_HOME/`. Variable expansion is noted for each template.

### A.1 Dockerfile.base (Phase 1)

**Generator**: `generate_dockerfile_base()` — quoted heredoc (`<<'DOCKERFILE_BASE'`), no variable expansion.

```dockerfile
FROM debian:trixie-slim

# Some Docker Desktop versions prevent the _apt user from reading the
# temp files apt stages for gpgv, producing spurious "invalid signature"
# errors on apt-get update. Run gpgv as root to sidestep the sandbox.
RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99-no-sandbox

# System tools + C/C++ toolchain
RUN apt-get update && apt-get install -y \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    git \
    git-lfs \
    gosu \
    jq \
    less \
    libcairo2 \
    libgdk-pixbuf-2.0-0 \
    libpango-1.0-0 \
    libssl-dev \
    ncurses-term \
    openssh-client \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    socat \
    tmux \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 24 LTS via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Go (arch-aware). GO_VERSION pins the minor line and is the offline fallback;
# each rebuild resolves the newest patch on that line from go.dev so base
# rebuilds pick up Go security fixes (same build-time-latest semantics as the
# Node/Rust/Bun/uv installs above). When this line leaves Go's 2-release
# support window, dl/?mode=json stops listing it and the fallback pin is used --
# bump GO_VERSION to the new supported minor at that point.
ARG GO_VERSION=1.26.5
RUN ARCH="$(dpkg --print-architecture)" \
    && GO_LATEST="$(curl -fsSL --max-time 10 'https://go.dev/dl/?mode=json' \
        | jq -r --arg m "go${GO_VERSION%.*}." \
            '.[].version | select(startswith($m))' \
        | sed 's/^go//' | sort -rV | head -1)" \
    && case "$GO_LATEST" in ''|*[!0-9.]*) GO_LATEST="" ;; esac \
    && curl -fsSL "https://go.dev/dl/go${GO_LATEST:-$GO_VERSION}.linux-${ARCH}.tar.gz" \
       | tar -C /usr/local -xz

# Rust stable (system-wide)
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable \
    && chmod -R a+rX /usr/local/rustup /usr/local/cargo

# Bun
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# uv — fast Python package/version manager
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/usr/local/bin sh

# sandy-ss-paths: agent-agnostic helper for the /ss screenshot skill.
# Lists newest N image paths from $SANDY_SCREENSHOTS_PATH (default 1).
RUN cat > /usr/local/bin/sandy-ss-paths <<'SS_HELPER' \
    && chmod +x /usr/local/bin/sandy-ss-paths
#!/bin/bash
# (body — see Appendix E.11a for the host-side mount that defines $SANDY_SCREENSHOTS_PATH)
SS_HELPER

# sandy-claude-statusline: Claude Code native statusLine command (#67).
# Reads the statusLine JSON payload on stdin, emits model/effort/context%.
RUN cat > /usr/local/bin/sandy-claude-statusline <<'STATUSLINE_HELPER' \
    && chmod +x /usr/local/bin/sandy-claude-statusline
#!/bin/bash
# (body — see Appendix C.2 for the seeding side and the output format)
STATUSLINE_HELPER

# sandy-tool-audit: PreToolUse audit hook (HF-incident Issue 6). Seeded into
# settings.json only when SANDY_TOOL_AUDIT=1; reads Claude Code's PreToolUse JSON
# on stdin and appends {ts,tool,args} JSONL to ~/.claude/tool-audit.jsonl. Always
# exits 0 (a non-zero PreToolUse hook would block the tool call).
RUN cat > /usr/local/bin/sandy-tool-audit <<'TOOL_AUDIT_HELPER' \
    && chmod +x /usr/local/bin/sandy-tool-audit
#!/bin/bash
# (body — jq-extracts tool_name + truncated tool_input, appends one JSONL line)
TOOL_AUDIT_HELPER

# User
RUN useradd -m -s /bin/bash -u 1001 claude

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH="/home/sandy/.local/bin:/usr/local/cargo/bin:/usr/local/go/bin:$PATH"
```

### A.2 Dockerfile (Phase 2)

**Generator**: `generate_dockerfile()` — unquoted heredoc (`<<DOCKERFILE`), expands `${BASE_IMAGE_NAME}`.

```dockerfile
FROM ${BASE_IMAGE_NAME}
# sandy.feature_entries (#381): every entry supported by this image's
# user-setup.sh/entrypoint.sh; a stale image predating this label knows only
# the removed SANDY_HANDOFF_RELAY channel, so it starts NONE of them, and
# sandy warns at launch naming every one (#382, 2.6.0).
LABEL sandy.feature_entries=1

RUN HOME=/home/sandy su -s /bin/bash sandy -c \
    "curl -fsSL https://claude.ai/install.sh | bash" \
 && cp -L /home/sandy/.local/bin/claude /usr/local/bin/claude \
 && mv /home/sandy/.local/share/claude /opt/claude-code \
 && { /usr/local/bin/claude --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' > /opt/claude-code/.version || true; }

# synthkit dependencies (WeasyPrint needs pango/cairo/gdk-pixbuf)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev \
 && rm -rf /var/lib/apt/lists/*

RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin \
    uv tool install --python-preference system synthkit

COPY tmux.conf /etc/tmux.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY user-setup.sh /usr/local/bin/user-setup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/user-setup.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Key details:
- Claude Code is installed as user `sandy`, then relocated to `/usr/local/bin/claude` (binary) and `/opt/claude-code` (data) so it survives the tmpfs overlay on `/home/sandy`.
- `UV_TOOL_DIR=/opt/uv-tools` ensures synthkit's venv goes to an accessible location (not `/root/`).
- Version is cached at `/opt/claude-code/.version` for update detection.

### A.2b Dockerfile.codex (Phase 2, alt)

**Generator**: `generate_dockerfile_codex()` — unquoted heredoc (`<<DOCKERFILE`), expands `${BASE_IMAGE_NAME}`.

```dockerfile
FROM ${BASE_IMAGE_NAME}
# sandy.feature_entries (#381): every entry supported by this image's
# user-setup.sh/entrypoint.sh; a stale image predating this label knows only
# the removed SANDY_HANDOFF_RELAY channel, so it starts NONE of them, and
# sandy warns at launch naming every one (#382, 2.6.0).
LABEL sandy.feature_entries=1
# Install Codex CLI as a global npm package. The @openai/codex package ships
# a prebuilt Rust binary per platform; Node is only the installation vehicle.
RUN npm install -g @openai/codex \
 && mkdir -p /opt/codex \
 && { codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' > /opt/codex/.version || true; }
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev \
 && rm -rf /var/lib/apt/lists/*
RUN UV_TOOL_DIR=/opt/uv-tools UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --python-preference system synthkit
COPY tmux.conf /etc/tmux.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY user-setup.sh /usr/local/bin/user-setup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/user-setup.sh
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

Key details:
- Version is cached at `/opt/codex/.version` for update detection.
- synthkit deps and synthkit itself are baked in so `md2pdf`/`md2doc`/`md2html`/`md2email` are on PATH regardless of whether Step 7's skill-seeding fires (e.g., if `synthkit` isn't installed at user-setup time).

### A.3 Dockerfile.skills-base (Phase 2.5a)

**Generator**: `generate_skill_pack_dockerfiles()` — mixed heredocs. Header is quoted (`<<'SKILLS_BASE_HEADER'`), gstack block is quoted (`<<'GSTACK_BASE_BLOCK'`). No variable expansion.

```dockerfile
FROM sandy-claude-code

# --- gstack base: Playwright + Chromium (rarely changes) ---
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/skills/gstack/.browsers

RUN mkdir -p /opt/skills/gstack \
 && cd /opt/skills/gstack \
 && npm init -y >/dev/null 2>&1 \
 && npm install playwright@latest --save >/dev/null 2>&1 \
 && npx playwright install-deps chromium \
 && npx playwright install chromium \
 && rm -rf node_modules package.json package-lock.json
```

Only generated when a pack requires heavy base dependencies (`needs_base=true`). The temporary npm project bootstraps Playwright just enough to install Chromium, then cleans up.

### A.4 Dockerfile.skills (Phase 2.5b)

**Generator**: `generate_skill_pack_dockerfiles()` — header uses unquoted heredoc (`<<SKILLS_HEADER`, expands `${skills_base_name}`), gstack block uses unquoted heredoc (`<<GSTACK_BLOCK`, expands `${repo}` and `${version}`).

```dockerfile
FROM sandy-skills-base-gstack

# --- gstack skill pack (${version}) ---
RUN mkdir -p /opt/skills/gstack \
 && curl -fsSL "${repo}/archive/${version}.tar.gz" \
    | tar -xz --strip-components=1 -C /opt/skills/gstack

RUN cd /opt/skills/gstack \
 && (bun install --frozen-lockfile 2>/dev/null || bun install) \
 && bun run build \
 && echo "${version}" > browse/dist/.version \
 && rm -rf node_modules/.cache

RUN chmod +x /opt/skills/gstack/bin/*
```

Image naming convention: `sandy-skills-base-<packs>` and `sandy-skills-<packs>` where `<packs>` is the sorted, lowercased, hyphen-joined pack list (e.g., `gstack`).

### A.5 entrypoint.sh

**Generator**: `generate_entrypoint()` — quoted heredoc (`<<'ENTRYPOINT'`), no variable expansion. Inner heredocs (`PIPWRAP`) also quoted.

The entrypoint runs as root and performs:

```bash
#!/bin/bash
# Verbose tracing at level 3+
if [ "${SANDY_VERBOSE:-0}" -ge 3 ]; then set -x; fi

# 0. Host timezone (#384): the host resolved TZ and checked its shape; only the
#    image knows whether the zone exists. No /usr/share/zoneinfo/$TZ and not a
#    POSIX rule string (^[A-Za-z]{3,}[+-]?[0-9]) -> print one line and `unset TZ`
#    (plain UTC), instead of letting glibc label UTC with a made-up abbreviation.

# UID/GID from host (default 1001)
RUN_UID="${HOST_UID:-1001}"
RUN_GID="${HOST_GID:-1001}"

# 1. Fix tmpfs ownership
chown "$RUN_UID:$RUN_GID" /home/sandy

# 2. Seed known_hosts
# Copies from /tmp/host-ssh-known_hosts if present
# Permissions: dir 700, file 644

# 3. SSH agent relay (if SANDY_SSH=agent)
#    macOS: socat UNIX-LISTEN → TCP:host.docker.internal:$SSH_RELAY_PORT
#    Wait: 50 attempts × 0.1s = 5s timeout for socket
#    Linux: chmod 600 + chown on mounted socket

# 4. Copy host SSH config
# From /tmp/host-ssh → ~/.ssh/ (cp -aL to dereference symlinks)
# Permissions: dir 700, keys 600, .pub/config/known_hosts 644

# 5. Fix persistent mount ownership
# Dirs: .pip-packages, .local/share/uv, .npm-global, go, .cargo, .gstack

# 6. Symlink Claude Code
# /usr/local/bin/claude → ~/.local/bin/claude
# /opt/claude-code → ~/.local/share/claude

# 7. pip/pip3 wrappers
# Auto-add --user when outside virtualenvs:
#   if [ -z "$VIRTUAL_ENV" ] && [ "${1:-}" = "install" ]; then
#       exec python3 -m pip install --user "$@"
#   fi

# 8. Drop privileges
exec gosu "$RUN_UID:$RUN_GID" /usr/local/bin/user-setup.sh "$@"
```

### A.6 user-setup.sh

**Generator**: `generate_user_setup()` — quoted heredoc (`<<'USERSETUP'`), no outer variable expansion. Inner heredocs for slash commands use quoted `<<'SKMD'`. Channel access.json uses both quoted and unquoted heredocs depending on mode.

Key implementation details not covered in the main spec:

**Settings.json**: user-setup.sh no longer merges `settings.json` — since 0.11.3 the merge-preserving regeneration happens **host-side** every launch (see §4 Seeding and Appendix C.2: host copy re-read, sandy-managed keys re-overwritten, `enabledPlugins` preserved from the previous session). Container-side, user-setup only ensures the Claude projects directory for the workspace exists (path-slug transform, required for `--continue` session lookup).

**ANSI color remap**: `printf "\033]4;4;rgb:61/8f/ff\033\\"` (dark blue → bright blue), restored on EXIT trap.

**Marketplace update cache**: Epoch timestamp written to `~/.claude/plugins/.marketplace_updated`. Stale after 86400 seconds (24 hours).

**Channel credential seeding** (`_seed_channel` function):
- Creates `~/.claude/channels/<chan>/` directory
- Writes `.env` (chmod 600) with `TOKEN_VAR=value`
- Writes `access.json` only if it doesn't already exist (preserves user edits)
- Allowlist computed by splitting comma-separated senders: `tr ',' '\n'` → awk to produce JSON array

**Claude Code launch**:
- Tmux mode (2.4.0+, #378): `tmux new-session -d -P -F '#{pane_id}' -s sandy -n "sandy: <project>" -- bash -c "<cmd>"`, capturing the new pane's id, then `tmux set-option -p -t <pane_id> @sandy_pane_agent "$SANDY_AGENT"` to tag it, then either `tmux attach -t sandy` (foreground) or `exec tail -f /dev/null` (daemon, session already detached). See "Pane-identity contract" in §12.
- Auto-continue: injects `--continue` if session files exist and no conflicting flags
- Fallback: `$CMD_WITH_CONTINUE || $CMD_WITHOUT_CONTINUE` (retries without `--continue` on failure)
- Remote mode: `claude remote-control --name "sandy: <project>"`

**Codex-specific user-setup additions**:
- Helper predicate `_sandy_has_codex() { [ "${SANDY_AGENT:-claude}" = "codex" ]; }` alongside `_sandy_has_claude` / `_sandy_has_gemini`.
- Synthkit seeding block (conditional on `command -v synthkit`) writes `~/.codex/skills/<name>/SKILL.md` with YAML frontmatter for `md2pdf`, `md2doc`, `md2html`, `md2email`.
- Trust-entry appending: after config.toml is in place, if `[projects."$SANDY_WORKSPACE"]` is not already present, append:
  ```toml
  [projects."<workspace>"]
  trust_level = "trusted"
  ```
  This must happen container-side because it needs the in-container workspace path.
- `build_codex_cmd()`: translates sandy's `-p`/`--print`/`--prompt` into `codex exec` with a positional prompt; drops `--continue`/`-c`; injects `--sandbox danger-full-access`, `--skip-git-repo-check` (headless only), optional `--model`, and (2.4.0, #116) `-c model_reasoning_effort=<level>` when `SANDY_EFFORT` is set (Appendix B.10).
- Launch dispatch: the `codex` case sits alongside `claude` and `gemini` in the per-agent dispatch; multi-agent combos iterate over the parsed `_SANDY_AGENTS` array and call each `build_*_cmd` in pane order.

**`/ss` screenshot-skill seeding**:
- Gated on `[ -n "${SANDY_SCREENSHOTS_PATH:-}" ]` — sandy only sets that env var when `SANDY_SCREENSHOT_DIR` was provided on the host and passed validation.
- For each enabled agent, writes the native skill format:
  - `_sandy_has_claude`: `~/.claude/commands/ss.md` (markdown frontmatter, `$ARGUMENTS` parsed inside `!\`bash\`` for an optional leading count).
  - `_sandy_has_gemini`: `~/.gemini/commands/ss.toml` (TOML, `{{args}}` parsed inside `!{bash}`).
  - `_sandy_has_codex`: `~/.codex/skills/screenshot/SKILL.md` (YAML frontmatter; codex matches by description).
- All three call `/usr/local/bin/sandy-ss-paths` (baked into Phase 1 base image — see Appendix A.1) to list newest N image paths.
- Opencode has no slash-command/skill surface in v0; the helper is on PATH for manual invocation in a prompt (e.g. `opencode "explain $(sandy-ss-paths 1)"`).

**Per-feature supervised entries** (`_sandy_supervise_entry` / `_sandy_await_entries` / `_sandy_start_entries`, 1.10.0, generalized 2.4.0 #381, every entry made IDENTICAL 2.6.0 #382 decisions 4-5): three functions defined in the heredoc immediately before `cd "$WORKSPACE"`. `_sandy_start_entries` is called once right after it and before the `_SANDY_IS_MULTI` branch — i.e. it precedes every `tmux new-session` call site (single/multi × foreground/daemon) by line order, and is itself gated on `[ "$_sandy_is_headless" != "true" ] && [ "${SANDY_REMOTE_CONTROL:-false}" != "true" ]` so `-p`/`--print`/`--prompt` runs and `sandy --remote` never start any entry (acceptance criterion 8 — under `--remote` there is no tmux session for an entry to target; the host side also clears the entries list in both cases, and under `--provision`, so the gate is belt-and-suspenders). `SANDY_FEATURE_ENTRIES` is the **only** internal channel now: the host sets it from the `entry` of each selected feature manifest (the one remaining producer — the `relay-bin/` slot and the operator key `SANDY_HANDOFF_RELAY` are hard errors, #354). `SANDY_HANDOFF_RELAY` as an internal channel, and `SANDY_RELAY_STATE`, were themselves removed in 2.6.0 (#382, decisions 4-5): neither is ever exported, read, or forwarded by any of this any more. `SANDY_RELAY` itself is gone as of 2.6.0 (#382, decision 3): setting it from any source is a hard error before this launch-assembly stage ever runs, so there is no longer a way to reach `_sandy_start_entries` with the capability suppressed — a selected feature's `entry` is unconditionally adopted. No-op (return 0) only when `SANDY_FEATURE_ENTRIES` is unset.

`_sandy_start_entries` resolves `SANDY_FEATURE_ENTRIES` — a space-separated `<feature>=<container-path>` list (D5 of #381). There is no legacy fallback any more: the pre-#382 back-compat path that treated a lone `SANDY_HANDOFF_RELAY` as a single entry when `SANDY_FEATURE_ENTRIES` was empty is gone, so an image whose host forwards only `SANDY_HANDOFF_RELAY` starts nothing (see the stale-image exception, below). Tokens are validated against `*[!A-Za-z0-9._/=-]*` before use. **Every entry is supervised identically**, with lock `~/.sandy-entry-<feature>.lock`, log prefix `[sandy-entry <feature>]`, and state dir `${SANDY_FEATURE_STATE_ROOT:-/opt/sandy/feature-state}/<feature>` — there is no longer a first-among-equals "relay-designated" entry with a different directory, lock name or log prefix.

For each entry, `_sandy_supervise_entry <label> <exe> <state_dir> <lock> <feature_state>` runs the same body every entry now shares: **a configured entry that cannot start fails the session (acceptance criterion 7)** — when the resolved path (absolute, or `$WORKSPACE/<relative>`) is not an executable file inside the container, when its state dir is not mounted, or when `flock` is not on `PATH`, the function logs one `sandy_err "…"` line (unconditional, not gated on `SANDY_VERBOSE`) and `exit 1`s — `user-setup.sh` is PID 1's command, so the container dies before any tmux session is created (foreground: `docker run` returns nonzero and sandy reports it; daemon: `--start` classifies the container as crash-looping, exit `7`, and dumps the container log tail). The `flock` check therefore runs **before** the subshell is forked, not inside it. The host-side path-shaped validation that used to duplicate part of this (metacharacters, `..`, existence-on-host for a workspace-relative or workspace-absolute `SANDY_HANDOFF_RELAY`) is gone along with the internal channel it validated: a manifest entry's path is already constrained at the source by `_sandy_fm_valid_relpath`/`_sandy_fm_valid_segment`, and the container's own token check above is what remains for `SANDY_FEATURE_ENTRIES`. The invariant this buys: any `feature_entries` member in `/etc/sandy-session.json` means that entry was started, or the session never came up (a stale image is the one documented exception, below).

On success `_sandy_supervise_entry` deletes any `.startup`/`.state` an earlier container left in the entry's state dir (the sandbox directory outlives the container), then forks a detached, `disown`ed subshell that (a) exports `SANDY_FEATURE_STATE` for **that process only** (never the parent shell or any pane) when a value was passed; (b) runs `set +e; trap - ERR; trap '' HUP` — user-setup.sh runs under `set -e` plus an ERR trap, and the loop must survive both a nonzero entry exit and a `HUP` from a closed terminal; (c) takes an exclusive `flock -n` on its own lock file (fd 9), logging "already running (lock held); not starting a second" and writing `already-running` to `.startup` if another instance holds it; (d) otherwise writes `state=started` to the fixed-size `<state_dir>/.state` (via a temp file and `mv`, so a reader never sees a torn file — this is what `--print-state`'s `feature_entries.<name>` reads) and loops forever: log `start`, run the entry with stdin `/dev/null`, fd 9 closed (`9>&-`, so the lock is held by the loop shell and not inherited by the entry's child — killing the loop alone releases it rather than stranding an orphaned holder) and stdout+stderr appended to `<state_dir>/supervisor.log`, record the first run's exit as `rc=<n>` in `.startup`, rewrite `.state` as `looping` with the restart count, last exit code and time, log `exit rc=<n> uptime=<s>s; restart in <b>s`, `sleep` for the current backoff, then double it (capped at 60, reset to 1 if the run stayed up more than 60s).

`_sandy_await_entries <state_dir>=<label> ...` is the **one shared** startup window (D9 of #381) covering every entry at once — N sequential 5s windows would add 5s per already-healthy long-running entry — polling each pending entry's `.startup` for up to 5s and dropping it from the pending set once it reports `already-running` or `rc=0`; the first entry to report a nonzero `rc=<n>` fails the whole session, naming that entry and its own `supervisor.log`. Later exits are a runtime loop, reported by `--print-state`, never a retroactive launch failure. Each state directory is mounted **rw** because the supervisor writes it, so the agent can write it too: `.state` and `supervisor.log` are diagnostics, never a trust signal. PID 1's fate differs by mode: foreground — user-setup is PID 1 and creates the tmux session detached, tags its pane, then runs (not `exec`s) `tmux attach -t sandy`, which blocks until the session ends and then returns so PID 1's own EXIT trap (the ANSI color-4 restore) still fires, so every loop is a child of PID 1 and dies with the container; daemon — PID 1 becomes `exec tail -f /dev/null`, so the loops (and any of the entries' own double-forked descendants) persist across in-container agent restarts, bounded only by container recreation.

`SANDY_FEATURE_STATE_ROOT` is an env-only test hook (no metadata row) overriding the `/opt/sandy/feature-state` root used to resolve an entry's state directory when it is not passed explicitly.

**Documented exception: a stale image (#381; wording updated 2.6.0 #382 decision 5).** "A configured entry that cannot start fails the session" (acceptance criterion 7, above) has one carve-out. Every generated agent Dockerfile carries `LABEL sandy.feature_entries=1` — inherited through `FROM` into per-project and skill-pack images — so the host can tell a current image from one built before per-feature entries existed (`docker image inspect -f '{{index .Config.Labels "sandy.feature_entries"}}'`; empty or the literal `<no value>` both count as lacking it). With **one or more** entries adopted and the image about to run lacking the label, sandy prints a launch-time `warn` naming **every** entry that will not start and pointing at `sandy --rebuild`; it does not refuse. With zero entries there is nothing a stale image would drop, so nothing is printed. A stale image's `user-setup.sh` only ever knew the removed `SANDY_HANDOFF_RELAY` channel (there is no legacy fallback left for it to fall into, per above), so it starts **none** of the entries — before 2.6.0 it started the one relay-designated entry and only warned about the rest; there is no longer a designated entry for it to fall back to. `--print-state`'s `feature_entries.<name>.state` reports every one of them `absent` for as long as that image is in use.

### A.7 tmux.conf

**Generator**: `generate_tmux_conf()` — quoted heredoc (`<<'TMUXCONF'`), no variable expansion.

```
set -g history-limit 10000
set -g mouse on
set -g default-terminal "tmux-256color"
set -as terminal-features ",tmux-256color:RGB"
set -as terminal-overrides ",*:U8=1"
set -sg escape-time 0

set -g pane-border-lines single
set -g pane-border-style "fg=colour240"
set -g pane-active-border-style "fg=colour51"
set -g pane-border-status top
set -g pane-border-format " #[fg=colour51]#{?@sandy_pane_agent,#{@sandy_pane_agent},#{window_name}}#[default] "

set -g status-position bottom
set -g status-style "bg=colour235,fg=colour248"
set -g status-left "#[fg=colour51,bold] sandy #[default]#[fg=colour248]·#[default] #{?#{==:#{E:SANDY_EGRESS_MODE},strict},#[fg=colour2]★ strict#[default],#{?#{==:#{E:SANDY_EGRESS_MODE},off},#[fg=colour208]★ no-net-iso#[default],#[fg=colour51]★ permissive#[default]}} #[fg=colour248]·#[default] #[fg=colour250]#{E:SANDY_AGENT}#[default] "
set -g status-left-length 70
set -g status-right "#[fg=colour250]#{E:SANDY_PROJECT_NAME}#[default] #[fg=colour248]·#[default] #[fg=colour250]#{session_attached} #{?#{==:#{session_attached},1},client,clients}#[default] #[fg=colour248]·#[default] #{?#{E:SANDY_DAEMON},#[fg=colour214]daemon#[default],#[fg=colour248]session#[default]} #[fg=colour248]·#[default] #[fg=colour248]%H:%M#[default] "
set -g status-right-length 80
set -g window-status-format ""
set -g window-status-current-format ""
set -g window-status-separator ""
set -g window-status-style "bg=colour235,fg=colour235"
set -g window-status-current-style "bg=colour235,fg=colour235"

set -g allow-passthrough on
set -g set-clipboard on
set -g focus-events on
setw -g aggressive-resize on

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5
```

The four `bind -r` lines are the only key bindings sandy adds (#161, 2.4.0);
everything else is tmux's defaults. They give `prefix` + `H`/`J`/`K`/`L` a
5-cell pane resize, repeatable within tmux's `repeat-time`. They exist because
tmux's stock resize keys do not work on macOS out of the box: `prefix` +
Ctrl-Arrow is taken by Mission Control at the system level, and `prefix` +
M-Arrow needs the terminal's Option-as-Meta setting. `L` shadows the stock
`prefix L` (`switch-client -l`, "last session"), which has nothing to switch to
in sandy's single session. Because `tmux.conf` is part of the agent image
hash (see Phase 2 "Rebuild trigger" above), changing it causes one image rebuild.

The status-left/status-right fields read runtime env at *display* time via
tmux's `#{E:VAR}` interpolation (not baked in at heredoc-generation time —
the heredoc is quoted, so nothing is substituted when the file is written).
`SANDY_EGRESS_MODE` drives the egress-posture segment, color-coded:
green (`colour2`) = strict, cyan (`colour51`) = permissive, orange
(`colour208`) = off/no-net-iso (a deliberate warning color — this posture
means no network isolation on macOS). `SANDY_AGENT`, `SANDY_PROJECT_NAME`,
and `SANDY_DAEMON` are forwarded container-side env vars (Appendix E);
`session_attached` is tmux's own built-in format variable, not env-derived.
The window-status lines are blanked (`""`) because sandy's tmux sessions are
single- or multi-pane within one window, not multi-window — a window list
in the status bar would be dead chrome. See CLAUDE.md "Status Lines" for how
this outer bar (launch/session-scoped) complements Claude Code's own native
`statusLine` (Appendix C.2, live per-request model/effort/context%).

---

## Appendix B: Runtime Parameters

All magic numbers, thresholds, timeouts, and limits used in the sandy script.

### B.1 Resource Limits

| Parameter | Value | Context |
|---|---|---|
| Container memory | `available_GB - 1`, min 2GB | Auto-detected from `docker info --format '{{.MemTotal}}'`, converted via `/1073741824`; falls back to `3g` if detection fails (4GB assumed − 1) |
| Container CPUs | All available (from `docker info --format '{{.NCPU}}'`) | Default 2 if detection fails |
| PID limit | 512 | `--pids-limit 512` |
| PID 1 | `docker-init` | `--init` (2.5.0, #392); the entrypoint chain and, in daemon mode, `tail -f /dev/null` run beneath it |
| tmpfs `/tmp` | 1 GB, exec | `--tmpfs /tmp:exec,size=1G` |
| tmpfs `/home/sandy` | 2 GB, exec | `--tmpfs /home/sandy:exec,size=2G,uid=1001,gid=1001` |
| tmux history | 10,000 lines | `set -g history-limit 10000` |

### B.2 Timeouts

| Operation | Timeout | Context |
|---|---|---|
| GitHub releases API | 5 seconds | `curl --max-time 5` in `skill_pack_latest_release()` |
| GitHub commits API | 5 seconds | `curl --max-time 5` in `skill_pack_latest_release()` |
| Sandy update check API | 3 seconds | `curl --max-time 3` in `sandy_check_update()` |
| Claude Code version check | 5 seconds | `curl --max-time 5` against Google Cloud Storage |
| SSH socket wait (macOS) | 5 seconds | 50 iterations × 0.1s sleep in entrypoint |
| OAuth token expiry buffer | 5 minutes | 300,000 ms buffer before `expiresAt` |

### B.2a Sandbox Compatibility

| Parameter | Value | Context |
|---|---|---|
| `SANDY_SANDBOX_MIN_COMPAT` | `0.7.10` | **Hard floor** on sandbox layout compatibility. A sandbox whose `.sandy_created_version` is *known and below* this is **refused at launch** (error + recreation command; sandy exits before `docker run`). Unknown/unreadable markers warn but launch. Classified by `_sandbox_compat_classify()`. **1.x forward-compat promise:** this must never advance above `1.0.0` within the `1.x` series (a breaking layout change is a `2.0` change). |
| `.sandy_created_version` | Written once on sandbox creation | Records the sandy version that created the sandbox. Missing on sandboxes created before 0.10.1. |
| `.sandy_last_version` | Refreshed every launch | Records the most-recent sandy version that touched the sandbox. |

### B.3 Cache TTLs

| Cache | TTL | File |
|---|---|---|
| Update check | 86,400 seconds (24 hours) | `$SANDY_HOME/.update_check` |
| Marketplace refresh | 86,400 seconds (24 hours) | `~/.claude/plugins/.marketplace_updated` |
| Skill pack version | Indefinite (refreshed each launch) | `$SANDY_HOME/.skill_version_<pack>` |

**Offline mode (`SANDY_OFFLINE=1` / `--no-update-check`, 2.4.0, #219)** suspends the three lookups these caches front, for one launch:

| Lookup | Normally | Offline |
|---|---|---|
| sandy release (`sandy_check_update`, `releases/latest`, 3s) | once per 24h, after config loading (moved there in 2.4.0 so a config-file `SANDY_OFFLINE` can suppress it; not run in the `SANDY_APPROVE_ONLY` pre-pass, whose `--start` supervisor runs it) | not run |
| agent version (`_check_<agent>_update`, 5s each) | every launch that needs no build; a hit forces a `--no-cache` agent rebuild | not run |
| skill-pack version (GitHub releases → commits, 5s each) | every launch with `SANDY_SKILL_PACKS` | not run; resolves from `.skill_version_<pack>`, else the `SKILL_PACK_VERSIONS` pin |

Builds that are **required** — a missing image, a changed Dockerfile/hash, a rebuilt base — still run through `_sandy_build_allowed`, and its no-image error names offline mode's boundary. Passive-safe (any config source, no approval): it defers the auto-patch pickup only until the next launch without it. Never silent: one `info` line at launch, a yellow line at session end, and `"offline": true` in the session marker (E.16a). The flag wins over any config value (applied after loading, like `--agent`) and is carried into the `--start` supervisor's re-exec argv. Values other than `0`/`1` are a hard error.

### B.4 File Permissions

| Path | Mode | Reason |
|---|---|---|
| `~/.ssh/` | 700 | SSH requires restrictive dir permissions |
| `~/.ssh/*` (private keys) | 600 | SSH refuses keys with group/other access |
| `~/.ssh/*.pub` | 644 | Public keys are non-sensitive |
| `~/.ssh/config` | 644 | SSH config readable |
| `~/.ssh/known_hosts` | 644 | Host fingerprints non-sensitive |
| SSH agent socket | 600 | Only owner should access agent |
| Channel `.env` files | 600 | Contains bot tokens |
| `.credentials.json` (ephemeral) | 600 | Contains OAuth tokens |
| `~/.config/anthropic/` (ephemeral, `SANDY_CLAUDE_AUTH=profile`) | 700 dir, 600 `credentials/*.json` | Exactly one Anthropic Console profile — never the host directory, which can hold an `org:admin` profile |
| pip/pip3 wrappers | +x | Must be executable |
| Skill pack `bin/*` | +x | Must be executable |
| cmux notification hook | +x | Must be executable |
| Rust/Cargo directories | a+rX | System-wide install, readable by all |

### B.5 Scan Depth Limits

| Scan | Max Depth | Excludes |
|---|---|---|
| Symlink protection | 8 levels | `node_modules/`, `.venv*/`, `.git/` |
| Submodule gitdir walk | 6 levels | — |
| Git LFS detection | 3 levels | — |

### B.6 Docker Security Flags

```
--security-opt no-new-privileges:true
--cap-drop ALL
--cap-add SETUID
--cap-add SETGID
--cap-add CHOWN
--cap-add DAC_OVERRIDE
--cap-add FOWNER
--read-only
```

Capabilities SETUID/SETGID are needed for `gosu` privilege drop. CHOWN/DAC_OVERRIDE/FOWNER are needed for the entrypoint to fix ownership of tmpfs and persistent mounts.

### B.7 Network Ranges (Linux iptables)

| CIDR | Purpose |
|---|---|
| `10.0.0.0/8` | Class A private (home/office LANs, VPNs) |
| `172.16.0.0/12` | Class B private (Docker internals, some LANs) |
| `192.168.0.0/16` | Class C private (home/office LANs) |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT / Tailscale |

### B.8 Default Values

| Variable | Default | Notes |
|---|---|---|
| `SANDY_MODEL` | `claude-opus-5` | Passed to `claude --model` |
| `SANDY_SSH` | `token` | Git authentication mode |
| `SANDY_SKIP_PERMISSIONS` | `true` | Skip trust dialog |
| `SANDY_VERBOSE` | `0` | No extra output |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | Max tokens per response |
| `HOST_UID` / `HOST_GID` | `1001` | Default container user if not remapped |
| Container user | `claude` | UID 1001, shell `/bin/bash` |
| `SANDY_CROSS_SESSION_INBOUND` | *(conditional)* | Unset resolves to `accept` iff a feature manifest **selected for this launch** declares `"receives": ["cross_session"]` (2.4.0, #380) and this is not a headless `-p`, `--remote` or `--provision` run (none of those leave a live session to deliver into); else `refuse` — never a plain static default (§C.2a). A feature `entry` alone, with no declared `receives`, resolves `refuse` (the entry-alone default was announced for removal in 2.5.0 and removed in 2.6.0, decision 6). Separately and unconditionally, a configured entry that cannot start still fails the launch (§A.6, §E.12a). |
| Per-entry restart backoff | `1s`, ×2 per restart, cap `60s`, reset to `1s` after a run staying up `>60s` | `_sandy_supervise_entry` in `user-setup.sh` (Appendix A.6) |

### B.9 Tool Versions

| Tool | Version | Install Method |
|---|---|---|
| Go | 1.26 (latest patch at build; fallback pin 1.26.5) | Multi-arch binary from go.dev |
| Node.js | 24 LTS | NodeSource `setup_24.x` |
| Rust | stable (latest) | rustup |
| Bun | latest | `curl https://bun.sh/install` |
| uv | latest | `curl https://astral.sh/uv/install.sh` |
| Python | Debian trixie system default (3.13) | `apt-get install python3` |

---

### B.10 Reasoning Effort Mapping (`SANDY_EFFORT`)

| sandy level | claude | codex (`-c model_reasoning_effort=`) | grok (`--reasoning-effort`) | gemini 3 (`thinkingLevel`) | gemini 2.5 (`thinkingBudget`) |
|---|---|---|---|---|---|
| `low` | `--effort low` | `low` | `low` | `LOW` | `1024` |
| `medium` | `--effort medium` | `medium` | `medium` | `HIGH` | `8192` |
| `high` | `--effort high` | `high` | `high` | `HIGH` | `24576` |
| `xhigh` | `--effort xhigh` | `xhigh` | `xhigh` | `HIGH` | `24576` |
| `max` | `--effort max` | `max` | `xhigh` (clamped, launch notice) | `HIGH` | `24576` |
| _(unset)_ | flag omitted (Claude Code default) | flag omitted (codex/model default) | flag omitted (grok default) | no settings file (gemini-cli default, `HIGH`) | no settings file (gemini-cli default, `8192`) |

Codex (2.4.0, #116) was verified against codex **0.157.1**: `ReasoningEffort::from_str` in `codex-rs/protocol/src/openai_models.rs` accepts `none|minimal|low|medium|high|xhigh|max|ultra|persistent` (any other non-empty string passes through as a custom value), so every sandy level has an exact namesake and the mapping is the identity. `max` maps to codex's `max` ("maximum reasoning depth"), **not** `ultra`, which sorts higher but is "maximum reasoning with automatic task delegation" — a multi-agent behaviour change, not an effort level. `-c` values parse as TOML and fall back to a literal string; both `codex` and `codex exec` take `-c`. Whether a given model offers a level is codex's model catalog's business (in 0.157.1, `gpt-5.4`/`gpt-5.5` top out at `xhigh`). The mapping is a `case`, so a future divergence is one arm and an unmapped value omits the flag rather than inventing one; the value is `printf %q`-quoted at the `bash -c` sink regardless.

Grok (2.7.0, #116): **verified first-hand** on the `sandy-grok` image (`grok --help`): the flag is `--reasoning-effort <EFFORT>` ("Reasoning effort for reasoning models", alias `--effort`), a **top-level** option of `grok [OPTIONS] [PROMPT] [COMMAND]` listed beside `-p, --single`, so it applies to the interactive TUI and to headless alike. Sandy passes the canonical spelling. `--help` does **not** enumerate the accepted values, so the value set rests on third-party probes: `low|medium|high|xhigh` accepted, and `max` a **hard error** (`unknown effort level 'max'`) that would kill the pane at launch. So `max` is **clamped to `xhigh`** — grok's top level — and never passed; the host prints one line naming the clamp when grok is in the agent set, because the marker records the sandy-level `max`. A `case` in `build_grok_cmd`, `printf %q`-quoted, like codex.

Claude's `--effort` is `printf %q`-quoted at the sink too (2.7.0): the value is validated host-side, but R1's rule is to quote at the `bash -c` sink rather than rely on which keys some other block validates.

Gemini (2.7.0, #116) has **no effort flag**; its surface is the settings key `modelConfigs`, verified against gemini-cli **0.61.0** (`@google/gemini-cli` and `@google/gemini-cli-core` from npm; `config/defaultModelConfigs.ts`, `services/modelConfigService.ts`, `cli/src/config/settings.ts`). Every Gemini 3 chat model's alias extends `chat-base-3` (`thinkingLevel: HIGH`) and every 2.5 one extends `chat-base-2.5` (`thinkingBudget: 8192`, `DEFAULT_THINKING_MODE`); an override's `match.model` is matched against the **whole alias chain**, so one override per base covers the family, and helper configs (`web-search`, `classifier`, …) — which extend `base`, not `chat-base` — are untouched. Sandy writes exactly this, and nothing else, into `$SANDBOX_DIR/gemini-system-settings.json`:

```json
{ "modelConfigs": { "customOverrides": [
  { "match": { "model": "chat-base-3" },   "modelConfig": { "generateContentConfig": { "thinkingConfig": { "thinkingLevel": "<LOW|HIGH>" } } } },
  { "match": { "model": "chat-base-2.5" }, "modelConfig": { "generateContentConfig": { "thinkingConfig": { "thinkingBudget": <n> } } } }
] } }
```

and names it with `GEMINI_CLI_SYSTEM_SETTINGS_PATH` (mounted `:ro` at `/etc/sandy-gemini/effort.json`; E.16). **Why a system file**: gemini-cli merges `schemaDefaults → systemDefaults → user → workspace → system`, so a system value wins over the rw `~/.gemini/settings.json` and over a committed `.gemini/settings.json` alike, and the `:ro` mount stops the agent editing it. **Mapping**: the bundled `@google/genai` `ThinkingLevel` enum has only `LOW` and `HIGH`, so `low` → `LOW` and every other level → `HIGH` (gemini-cli's own default); for 2.5, `low` → `1024`, `medium` → `8192` (the default), `high`/`xhigh`/`max` → `24576`, the largest budget **every** 2.5 model accepts (Flash and Flash-Lite cap there; Pro would take `32768`, but one override covers the family). **What it can clobber** — stated because a system file outranks the user: the settings merge **replaces arrays** (no merge strategy on `modelConfigs.*`), so the file carries a single key, `modelConfigs.customOverrides`. `modelConfigs.overrides` — the key gemini-cli's own docs use in their examples — is left entirely to the user; a user's own `customOverrides` **is** shadowed while `SANDY_EFFORT` is set. Among overrides, a sandy entry wins over a user `overrides` entry at the same match depth (custom overrides sort later), and **loses** to one that names a concrete model (`gemini-2.5-pro` sits deeper in the chain) — an explicit per-model choice beats the fleet default. A model outside gemini-cli's alias table resolves through `chat-base` only, so neither override reaches it and it runs at its own default. The derived system-defaults path moves to `/etc/sandy-gemini/system-defaults.json`, which does not exist.

opencode receives nothing: its TUI takes no effort flag, and `opencode run --variant <name>` silently ignores a name the selected model does not define, so no mapping could be shown to have applied. `SANDY_EFFORT` is cleared, with a notice, for a launch that includes none of claude, codex, grok or gemini.

## Appendix C: JSON Schemas

### C.1 `access.json` (Channel Configuration)

Created at `~/.claude/channels/<channel>/access.json`. Two modes:

**Allowlist mode** (when `<CHANNEL>_ALLOWED_SENDERS` is set):
```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["user_id_1", "user_id_2"],
  "groups": {},
  "pending": {}
}
```

**Pairing mode** (when no allowlist configured):
```json
{
  "dmPolicy": "pairing",
  "allowFrom": [],
  "groups": {},
  "pending": {}
}
```

`allowFrom` is computed from the comma-separated env var: split on commas, trim whitespace, wrap each in quotes, join with commas.

The file is only written on first run — if it already exists, it's preserved to respect user edits.

### C.2 `settings.json` (Claude Code Configuration)

**Destination.** As of 0.11.3, the seeded settings file lives at `$SANDBOX_DIR/claude/settings.json` — inside the rw sandbox mount, no `:ro` overlay. It is regenerated from the host on every launch with merge-preserving semantics (agent-owned `enabledPlugins` is carried over from the previous sandbox session). The pre-0.11.3 approach used a `:ro` sidecar at `$SANDBOX_DIR/.seed-settings.json`, but that blocked `/plugin install` with EROFS and was reverted. See §4 Seeding for the full flow. Because the directory is agent-writable and the merge runs host-side, a symlink at `settings.json`, `settings.json.tmp` or `settings.json.base` is removed (with a warning naming its target) before the merge, the jq branch pipes its empty-base `{}` instead of staging a file, and its output is written via `mktemp` + `mv` — never through a planted link (§169).

**Marketplace structure** (added idempotently to `extraKnownMarketplaces`):
```json
{
  "extraKnownMarketplaces": {
    "claude-plugins-official": {
      "source": { "source": "github", "repo": "anthropics/claude-plugins-official" }
    },
    "sandy-plugins": {
      "source": { "source": "github", "repo": "rappdw/sandy-plugins" }
    }
  }
}
```

Note the double-nested `source` — the outer key is the `extraKnownMarketplaces` schema, the inner object describes the repository.

**Sandy defaults merged on every launch** (Node.js tier):
```json
{
  "spinnerTipsEnabled": false,
  "skipDangerousModePermissionPrompt": true,
  "statusLine": { "type": "command", "command": "/usr/local/bin/sandy-claude-statusline", "padding": 0 }
}
```

`enabledPlugins` is **preserved** from the previous sandbox session (and inherited from the host copy on first launch) so `/plugin install` survives relaunches. The file is read-write inside the container — the pre-0.11.3 read-only sidecar was reverted because it broke `/plugin install` with `EROFS`. Host-side edits to `~/.claude/settings.json` still propagate on the next launch (sandy re-reads the host copy every launch), and the sandy-managed keys are re-overwritten every launch regardless of in-session mutations.

**Launch baseline snapshot (#151).** After every host-side writer of `settings.json` has run (the seed merge above, and the cmux hook block) and before `docker run`, sandy extracts `permissions.defaultMode` from the just-seeded file via `_sandy_settings_default_mode()` (a `sed` BRE extraction, "none" when absent/unreadable) and writes it to `$SANDBOX_DIR/.claude-perm-mode-at-launch`. This is rw-writable-settings' one hard blind spot made honest: the file can still be mutated in-container after launch (Claude Code 2.1.232 has been observed doing exactly that, rewriting the pin to `"auto"` ~13s in), and since sandy only controls the file *before* `docker run`, this baseline is what session-end drift detection (§9) compares against. It is not a `:ro` mount and not part of the self-attestation marker's trust boundary — it is a plain sandbox-local scratch file, removed by `cleanup()` (or, for a `SIGKILL`ed prior session, by the stale-snapshot sweep at the next launch) either way.

**`sandbox.enabled` is a MANAGED key, forced `false` every launch (#126, 2.4.0).** Claude Code ships its own Bash sandbox (`/sandbox`; settings key `sandbox.enabled`, Boolean, default unset = no sandbox — verified against code.claude.com/docs `settings-reference` and `sandboxing`) with its **own HTTP/SOCKS egress proxy**, and inside an unprivileged container it needs `enableWeakerNestedSandbox`, whose own caveat is that it is only for when an outer container already provides the boundary. Sandy's container is that boundary and its egress proxy is the single policy chokepoint, so an inner sandbox is redundant and a second, uncoordinated proxy that double-prompts and muddies which posture is in force. Because the host `~/.claude/settings.json` is the merge base, a host `sandbox.enabled: true` would otherwise ride into every sandbox. So all three seeding branches force it, like `disableClaudeAiConnectors`: Node `s.sandbox.enabled = false` (replacing a non-object `sandbox`), jq `.sandbox = ((if (.sandbox|type)=="object" then .sandbox else {} end) | .enabled = false)`, and `"sandbox":{"enabled":false}` in both `printf` literals. **Only `enabled` is forced** — every other key the host set under `sandbox` (`excludedCommands`, `network`, …) is preserved, so re-enabling it outside sandy is one edit. **Honest limit:** this is the userSettings scope, and Claude Code takes a Boolean from the *highest-precedence* scope that sets it, so a workspace's committed `.claude/settings.json` (or a pre-existing `.claude/settings.local.json`) setting `sandbox.enabled: true` still wins. That is a repository asking for *more* isolation, not less, so it is left to the repository; in-session `/sandbox` cannot persist there, because `.claude/settings.local.json` is `:ro` in-container. Guarded by `run-tests.sh §168`, which runs the real seeding block under node, jq-only and no-tool `PATH`s.

**jq branch with no host settings.json (fixed alongside #126).** The jq branch used to read `/dev/null` when the host had no `~/.claude/settings.json`; jq over an empty input emits **nothing**, so the redirect wrote a **0-byte** `settings.json` and every managed key — the `bypassPermissions` pin, #129's connectors-off, #126's sandbox-off — was silently missing on a jq-only host. It now feeds jq a literal `{}` (also for a 0-byte host file).

**`statusLine` (#67)** is set **only if absent** — all three seeding branches (Node `if (!(k in s))`, jq `//=`, and the last-resort `printf` literals) use an only-if-absent guard, so a user's own `statusLine` in `~/.claude/settings.json` is never overwritten. When absent, sandy points it at `/usr/local/bin/sandy-claude-statusline` (baked into the base image, Appendix A.1-adjacent — see the Dockerfile.base `RUN cat > ... STATUSLINE_HELPER` block), a small script that reads Claude Code's statusLine JSON payload from stdin and emits `<model>  ·  [effort: <level>  ·  ]<context%>% ctx`, falling back to a bare `sandy` line on any empty/malformed/wrong-shape input so the TUI never shows an error. This is a live, per-request complement to the tmux status bar (Appendix A.7), which is launch/session-scoped and structurally cannot show per-request model/effort/context — see CLAUDE.md "Status Lines".

**JSON repair** applied before parsing (handles common hand-editing errors):
- Remove trailing commas: regex `,(\s*[}\]])` → `$1`
- Add missing commas between keys: regex `("key")\s*\n(\s*"nextkey")` → `$1,\n$2`
- If parsing still fails, fall back to empty object `{}`

### C.2a Cross-session inbound pin (`crossSessionInbound`, 1.10.0)

**Two files, two purposes — measured against Claude Code 2.1.251, not assumed.** A live probe (nine cases, `docs/security/CROSS_SESSION_INBOUND.md`) found that Claude Code's `crossSessionInbound` resolver treats the workspace's own settings files as **tighten-only**: `hold`/`refuse` written there ARE honored, but `accept` written there is a measured no-op — byte-identical to the key being absent. The only placements the probe found actually deliver `accept` are Claude Code's own **userSettings** (`~/.claude/settings.json`) and the `--settings <file>` CLI flag. Sandy therefore writes the **same resolved value into two files every launch**, via a shared `_sandy_csi_write()` helper (merge-preserving and non-clobbering on a foreign or invalid file) called once per target:

1. **`$SANDBOX_DIR/claude/settings.json`** — the sandbox's own settings file, already seeded/regenerated every launch by the C.2 pipeline above and mounted **RW** as the container's `~/.claude/settings.json` (Claude Code's userSettings). This is the placement that actually makes `accept` deliver (probe case E). Writing here is a *second*, independent write on top of whatever the C.2 seeding pipeline already produced for that launch — `_sandy_csi_write` merges the one key in without touching anything C.2 set.
2. **`$WORK_DIR/.claude/settings.local.json`** — the workspace's own project file, distinct from the sandbox mount, and mounted `:ro` in-container (protected-files list, §9). `hold`/`refuse` are honored here (probe cases B/C) and win over a userSettings `accept` even when the two disagree (probe case H — "a repo may only tighten"). `accept` written here is a no-op for delivery, but is written anyway: it overwrites any stale `hold`/`refuse` sandy itself wrote on an earlier launch (e.g. before a relay was configured), so neither of sandy's own two targets can ever disagree with the current launch's resolution — only a human hand-editing a file afterward can still tighten it, which is the intended "repo may tighten" escape hatch.

Both writes run host-side, after the feature-manifest evaluation (#321) has produced this launch's selected features — their `receives` declarations and their `entry` list (`SANDY_FEATURE_ENTRIES`). The workspace-file write specifically runs before the protected-files `:ro` mount loop and the `.protected-existed-at-launch` snapshot (§9), so that file is immediately read-only in-container and never misreported as a newly-appeared protected file; the sandbox-file write has no such ordering constraint since that file is never `:ro`.

**Gate.** Only runs when `claude` is in `SANDY_AGENT`. `SANDY_CROSS_SESSION_INBOUND` is validated first (`accept`/`hold`/`refuse`/unset; anything else is a hard launch error) — before the agent check, so an invalid value errors regardless of which agent is selected.

**Resolution (updated 2.6.0, decision 6 / #382 — see CLAUDE.md "Cross-session inbound" for the full history).** Precedence: **explicit `SANDY_CROSS_SESSION_INBOUND` > a selected feature's declared need > `refuse`.** Explicit always wins, in either direction. Otherwise: `accept` iff a **selected** feature manifest (D4 selection, evaluated fresh every launch) declares `"receives": ["cross_session"]` (`docs/design/FEATURE-MANIFEST.md` §11) AND this is not a headless (`-p`/`--print`/`--prompt`), `--remote` or `--provision` run (none of those leave a live tmux session for anything to deliver into — "criterion 8"); otherwise `refuse`. A feature `entry` alone, with no declared `receives`, resolves `refuse` — the entry-alone default (`accept` whenever `SANDY_HANDOFF_RELAY` would still be set once the relay block ran) was announced for removal in README's `## Deprecated` table in 2.5.0 and **removed in 2.6.0**. Separately, and unconditionally regardless of `receives`: a configured feature `entry` that fails to start **fails the launch**, host-side (exit 1 before `docker run`) or in-container (`user-setup.sh` exits 1 and the container dies) — that rule was never conditioned on `crossSessionInbound` and is unaffected by this section. `SANDY_HANDOFF_RELAY` (the internal channel a manifest `entry` travels through) is set only by an adopted entry, never by an operator — an operator-set value is a hard error before this block runs (#354). There is no static default — `--print-schema` reports an empty `default` for this key precisely because the true default is a function of another key's value, not a constant.

**Write contract (`_sandy_csi_write`, three branches per target, each merge-preserving and non-clobbering on a foreign or invalid file):**
1. **node** (preferred, if on PATH): reads the target with `JSON.parse`, rejects (return code 3, translated to a warning) if the parsed value isn't a plain object, sets `crossSessionInbound`, and writes back with 2-space indentation via a temp file + atomic `mv`.
2. **jq** (if node absent): `.crossSessionInbound = $v` merged into the existing object, or `jq -n` to create a fresh `{crossSessionInbound: $v}` if the file is empty/absent; a non-object input makes the `jq` filter itself fail (`error("not an object")`), caught the same way.
3. **Last resort** (neither tool on PATH): if the file is empty/absent, write the compact literal `{"crossSessionInbound":"<v>"}`. If it already exists, it is rewritten **only** when its whitespace-stripped content byte-matches one of the three literal forms sandy itself would have written (i.e., a file sandy previously wrote in this same mode) — any other existing content is left untouched with a warning naming the file and recommending node/jq or a manual edit.

**Idempotence.** After computing the new content in a `.sandy-tmp.$$` temp file, sandy `cmp -s`s it against the existing target; byte-identical content is discarded (mtime untouched, matters for IDE file watchers and for a test asserting no-op reruns), otherwise the temp file is `mv -f`'d over the target. Applies independently to each of the two targets.

**Never `$HOME/.claude/settings.json` on the HOST.** Both write targets are inside `$SANDBOX_DIR`/`$WORK_DIR`; the host's own `~/.claude/settings.json` is read (by the separate C.2 seeding pipeline, as its snapshot source) but never written by any of this.

**Logged.** One line per launch naming the value, where it landed, and why:
- both writes succeed: `crossSessionInbound=<value> written to claude/settings.json (sandbox) and .claude/settings.local.json (<reason>)`
- only the sandbox write succeeds: `... written to claude/settings.json (sandbox) only (<reason>)`
- only the workspace write succeeds: `... written to .claude/settings.local.json only (<reason>)` — and, if `<value>` is `accept`, an additional `WARNING:` line explains that Claude Code does not honor `accept` from that file alone, so messages will still be held.

`<reason>` ∈ `explicit SANDY_CROSS_SESSION_INBOUND` / `default: feature <name[, name...]> declares receives cross_session` / `default: feature <name[, name...]> declares receives cross_session, but a <headless run|--remote run|--provision run> has no session to deliver into` / `default: no selected feature declares receives cross_session`. A skipped write to either target additionally logs its own `WARNING:` line naming why (invalid existing JSON, no node/jq and a foreign file, etc.) and never touches that file. When `claude` isn't selected, a `SANDY_VERBOSE=1` info line says so.

**Residual.** Unlike the `:ro` workspace copy, the sandbox target is RW inside the container (required for `/plugin install` and other in-session settings writes), so it is the one placement where a compromised in-session agent could rewrite its own `crossSessionInbound` — reset on the next launch (same class of managed-key residual as `permissions.defaultMode`, #151), not mitigated mid-session.

**Symlink refusal (R2, 1.13.2).** Before either write, sandy walks every path component below the anchor (`$WORK_DIR` for the workspace target, `$SANDBOX_DIR` for the sandbox target) and **refuses the write if any component is a symlink**, naming the offending component:

```
WARNING: crossSessionInbound NOT written: .claude/settings.local.json traverses a symlink (.claude) -- refusing to write through it
```

The refusal is reported through the same `_written` flags as any other failure, so the log lines above already cover it. The check is a symlink-free-chain test rather than a canonicalize-and-compare containment test: the former needs no `realpath` (GNU-only) and, unlike canonicalization, it leaves the link **in place** for `_sandy_resolve_symlinks` (§ "Persistent symlink approval") to surface. `mkdir -p` is not the detector — it succeeds silently on a symlink-to-directory. Guarded by `run-tests.sh §129`.

**gitignore nudge.** When the workspace write to `.claude/settings.local.json` succeeds and the workspace is a git repo, sandy checks (via `git check-ignore`, or a literal `.gitignore` grep fallback when git is unavailable) whether the file is ignored, and prints a two-line warning if not — mirrors the `.gstack/` nudge (§ "Persistent state (gstack)" in CLAUDE.md).

### C.3 `.claude.json` (User Setup State)

Stored at `$SANDY_HOME/sandboxes/<NAME>/claude/.claude.json` since 2.7.0 (#400). It is **not mounted on its own**: it is inside the `claude/` directory mount, and the container gets `CLAUDE_CONFIG_DIR=/home/sandy/.claude`, so Claude Code reads it from `~/.claude/.claude.json`. Claude Code computes its global config as `join(CLAUDE_CONFIG_DIR || homedir(), ".claude.json")`, and `settings.json`/`.credentials.json` keep their paths.

**Why it moved, and what actually fixed #400.** Through 2.6.x the file was a sibling, `$SANDY_HOME/sandboxes/<NAME>.claude.json`, bind-mounted as a single file. It now lives under the documented `claude/` mapping. The torn-file symptom ("Configuration error … contains invalid JSON" while `--start` reported ready) was **not** caused by that mount; measured, Claude Code's safe write works on both.

The cause was the **host replacing a file the previous container had written**: on macOS, the next container's first read of such a file can fail to parse (2 of 20 relaunches in `test/spike/virtiofs-host-rewrite-spike.sh`; 0 of 20 with no host write in between), whether the host rewrote it in place or by rename. Sandy merged the same keys into `.claude.json` at every launch, so every relaunch set this up.

Since 2.7.0 every host-side writer into a container-read file **skips the write when the content would not change** (semantic JSON comparison in node, byte comparison in `_sandy_write_atomic`), so after a sandbox's first launch the per-launch merges write nothing. The trust entry is written only while `projects[<ws>].hasTrustDialogAccepted` is not yet `true`, because Claude Code drops the `hasCompletedProjectOnboarding` flag sandy sets beside it. A write that does change something goes to an exclusively created temp file and is renamed into place (`run-tests.sh` §190).

**Migration (each launch with claude selected):**
- a symlink at `claude/.claude.json` is removed and named;
- a pre-2.7 sibling is moved in **once**, when `claude/.claude.json` does not exist yet;
- a sibling that reappears later is **left untouched** and named in a warning at every launch, so a write to the old path is never dropped silently.

**`--reset-sandbox` always keeps it.** That matches 2.6.x, where the sibling sat outside the reset's reach.

**Operators** who provision MCP servers by writing a top-level MCP server block into the file (§87) write `<sandboxes[].path>/claude/.claude.json`. It falls under the `claude/` → `~/.claude/` mapping in the host-side path contract (§4); sandy never touches that block.

**Seeding from host** (Node.js):
```javascript
let d = JSON.parse(fs.readFileSync(hostPath));
delete d.projects;  // strip host project paths
fs.writeFileSync(sandboxPath, JSON.stringify(d, null, 2) + "\n");
```

Falls back to `cp` if Node.js parsing fails.

**Fallback if no host copy exists**:
```json
{
  "tipsDisabled": true,
  "installMethod": "native"
}
```

**Post-seed merge**: Always ensures `tipsDisabled: true` and `installMethod: "native"` are set.

### C.4 `.credentials.json` (OAuth Credentials)

Loaded ephemerally from the host, never persisted in the sandbox.

**Expected structure for token expiry check**:
```json
{
  "claudeAiOauth": {
    "expiresAt": 1234567890000
  }
}
```

`expiresAt` is milliseconds since epoch. The refresh check uses `Date.now() + 300000 > expiresAt` (5-minute buffer).

### C.5 Channel `.env` Files

Plain `KEY=VALUE` format at `~/.claude/channels/<channel>/.env`:

```
TELEGRAM_BOT_TOKEN=<token>
```
or
```
DISCORD_BOT_TOKEN=<token>
```

Permissions: 600 (owner read-write only).

### C.6 cmux Notification Hook

Auto-generated at `~/.claude/hooks/cmux-notify.sh` when cmux is detected. Merged into `$SANDBOX_DIR/claude/settings.json` host-side during the seed regeneration (see §C.2):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/home/sandy/.claude/hooks/cmux-notify.sh"
          }
        ]
      }
    ]
  }
}
```

The hook script emits `\033]777;notify;<title>;<body>\033\\` OSC sequences.

### C.7 `.update_check` Cache

Plain text file at `$SANDY_HOME/.update_check`:

```
<epoch_timestamp> <latest_version>
```

Example: `1711843200 0.8.0`. Stale after 86,400 seconds.

### E.13 `sandy --exec` (1.11.0)

Opens a shell, or runs one command, inside the workspace's already-running container. An early dispatcher: it runs after argument parsing and before config loading, image builds, and the mutex — like `--provision` and `--attach`, none of whose side effects it needs.

```
docker exec [-i|-i -t] -u <host-uid>:<host-gid> -w <container-workspace> -e HOME=<container-home> <container> <cmd...>
```

| Element | Resolution |
|---|---|
| container | `docker ps --filter label=sandy.daemon=true --filter label=sandy.workspace_path=<wd>`, else `--filter name=^sandy-<sandbox>$`. The name match is **fully anchored** — foreground runs carry only `sandy.managed=true`, so the label filter alone finds daemon sessions only, and an unanchored name would also match the `sandy-proxy-…` sidecar |
| `-u` | **numeric**, never `-u sandy`. Docker resolves a *name* against the image filesystem, where `useradd -u 1001 claude` applies; sandy's host-uid `/etc/passwd` is a runtime bind mount docker does not consult. `-u sandy` therefore runs as uid 1001, prints `I have no name!`, and writes as the wrong owner |
| `-w` | the launch path's own `$HOME`-relative mapping (`SANDY_WORKSPACE`), so the shell starts where the agent works |
| `HOME` | read from the container's own passwd (`getent passwd $(id -u)`), defaulting to `/home/sandy` — docker sets HOME only when it can resolve the user, and as root `HOME=/root` is on the read-only rootfs |
| tty | `-i -t` only when stdin is a tty, so `sandy --exec -- cmd \| grep x` and CI callers work |
| exit | `4` — no running container for the workspace (the `--attach`/`--stop` "no such session" convention); `1` — usage or unreachable docker; otherwise **the command's own status** |

Sub-options: `--workspace PATH`, `--dry-run` (print the command, execute nothing), and `-- CMD...` (default `/bin/bash`). A bare first non-option token also begins the command; an unrecognized `-…` is refused with a pointer to `--`. Guarded by `run-tests.sh §120`.

### C.7b Codex `config.toml` (seeded by sandy)

Written to `$SANDBOX_DIR/codex/config.toml` on first launch of a new sandbox with `SANDY_AGENT=codex`. Mounted into the container at `/home/sandy/.codex/config.toml`.

```toml
# Written by sandy on first launch. Safe to edit, but sandbox_mode must stay
# "danger-full-access" — sandy provides outer isolation; codex's Landlock
# sandbox does not nest cleanly in Docker containers.
model = "gpt-5.5"
sandbox_mode = "danger-full-access"

[notice]
hide_full_access_warning = true
hide_gpt5_1_migration_prompt = true
"hide_gpt-5.1-codex-max_migration_prompt" = true
hide_rate_limit_model_nudge = true
hide_world_writable_warning = true

# [projects."<workspace>"] trust_level = "trusted" appended at session start
# by user-setup.sh, where $SANDY_WORKSPACE is known.
```

The file is created exactly once per sandbox — re-runs preserve user edits. The `[notice]` list may grow upstream; sandy seeds all five documented keys as cheap insurance. Source-of-truth reference: `codex-rs/core/src/config.rs` in the openai/codex repository.

**`sandbox_mode` is additionally repaired by VALUE on every launch.** Creation is first-run only and its gate greps for the *key* `sandbox_mode`, so a file containing `sandbox_mode = "workspace-write"` satisfies that gate and would never be corrected. The gap became reachable when the codex directory went read-write (#238): the user — or codex itself — can edit `config.toml` in-session and the edit persists into every later launch. A non-full-access mode makes codex initialize its own Landlock sandbox **inside** sandy's container, which does not nest; commands then fail to spawn and codex falls back to its approval path, a symptom that reads like a sandy fault and is not one.

So each launch re-reads the file and, if the **top-level** `sandbox_mode` is present and is not `danger-full-access`, rewrites that one line and warns, naming the value it found. The repair is deliberately narrow, because this file is documented as user-editable:

- exactly one line is rewritten; everything else — `model`, `[notice]`, `[projects]`, any user additions — is preserved byte for byte;
- an already-correct file is left byte-identical, with no warning and no churn;
- a **profile-scoped** `sandbox_mode` (under a `[profiles.…]` header) is left alone: it applies only when that profile is selected, and silently rewriting a user's profile is a larger liberty than this repair is entitled to take;
- if the rewrite cannot be completed the original is kept and the failure is warned, rather than leaving a half-written config.

Guarded by `run-tests.sh §118`.

After the first session start, the file additionally contains the trust entry:

```toml
[projects."/home/sandy/dev/myproject"]
trust_level = "trusted"
```

Appended by `user-setup.sh` only if a matching `^[projects."<workspace>"]` line is not already present (idempotent).

### C.7c Codex `auth.json` (ephemeral mount, both auth paths)

Both codex auth paths produce an ephemeral `auth.json` mounted **read-only** into the container at `/home/sandy/.codex/auth.json`; the tmpdir is removed on exit (cleanup trap):

- **api_key** (`OPENAI_API_KEY` set, `SANDY_CODEX_AUTH` is `auto` or `api_key`): sandy generates the file itself as `{"OPENAI_API_KEY":"<key>"}` (with `"` and `\` JSON-escaped) — the same shape `codex login --with-api-key` writes. Required because codex 0.139+ no longer reads the env var for first-party auth.
- **oauth** (host has `~/.codex/auth.json`, mode `auto` or `oauth`): sandy copies the host file to the tmpdir. Schema is opaque to sandy — the file is produced by `codex login` on the host.

### C.8 `.skill_version_<pack>` Cache

Plain text file at `$SANDY_HOME/.skill_version_<pack>`:

```
<version_or_sha>
```

Example: `a1b2c3d4e5f6` (commit SHA) or `v1.2.3` (release tag). Updated whenever a newer version is resolved from GitHub.

### C.9 `sandy-session.json` (Self-Attestation Marker)

Written to `$SANDBOX_DIR/sandy-session.json` on every launch and bind-mounted read-only at `/etc/sandy-session.json` (see Appendix E.16a). The single authoritative in-container proof that the agent is inside sandy:

```json
{
  "schema": 1,
  "sandy_version": "0.14.1-dev-a1b2c3d",
  "egress_mode": "off",
  "workspace": "/home/sandy/dev/myproject",
  "sandbox_name": "myproject-a1b2c3d4",
  "host_uid": 501,
  "host_gid": 20,
  "launched_at": "2026-06-11T12:00:00Z",
  "session_nonce": "3f1c…",
  "effort": "high",
  "permission_mode": "bypassPermissions",
  "cross_session_inbound": "refuse",
  "cross_session_inbound_source": "explicit",
  "agents": ["claude"],
  "image": {"name": "sandy-project-myproject-a1b2c3d4", "id": "sha256:9f2e…", "project_layer": true},
  "agent_args": {"claude": [{"feature": "notify", "args": ["--mcp-config", "/opt/sandy/features/notify/mcp-servers.json"]}]},
  "agent_args_composed": {"claude": [{"flag": "--append-system-prompt-file", "policy": "concat", "composed": true, "from": ["feature 'policy'", "feature 'notify'"], "path": "/opt/sandy/agent-args/claude.append-system-prompt-file.md"}]},
  "feature_entries": {
    "notify": {"path": "/opt/sandy/features/notify/relay"},
    "sync-daemon": {"path": "/opt/sandy/features/sync-daemon/watch"}
  },
  "offline": false,
  "cred_mode": "full"
}
```

| Field | Meaning |
|---|---|
| `schema` | Marker schema version (currently `1`; `effort`, `permission_mode`, `cross_session_inbound`, `cross_session_inbound_source`, `cred_mode`, `sandbox_name`, `agents`, `image`, `agent_args`, `agent_args_composed`, `feature_entries` and `offline` are all additive fields). `handoff_relay` and `relay.slot` were removed in 2.2.0 (#355); that removal moved `--print-state`'s `schema_version` to `3`. `relay{}` itself — every field — and its two `feature_entries.<name>` companions, `relay_alias` and `disabled_by`, were removed in 2.6.0 (#382, decisions 1-2), moving `schema_version` to `4`, which is the signal a host-side consumer reads. |
| `sandbox_name` | The sandbox slug, `<basename>-<sha8>` — the name of this sandbox's directory under `$SANDY_HOME/sandboxes/` (1.15.0, #303). Previously unavailable in-container and **not derivable**: `SANDY_PROJECT_NAME` is the raw workspace basename while the slug is `tr -cd 'a-zA-Z0-9._-'`-filtered, so it is lossy in both directions, and sandy passes no `--hostname`. Also exported as `SANDY_SANDBOX_NAME`, but this `:ro` copy is authoritative. Spelled to match `WORKSPACE.json`. |
| `sandy_version` | Full version incl. git short hash (`sandy_full_version()`). |
| `egress_mode` | Resolved posture: `off` \| `permissive` \| `strict`. |
| `workspace` | Container-side workspace path (matches `SANDY_WORKSPACE`). |
| `host_uid` / `host_gid` | Host identity sandy mapped the container to. |
| `launched_at` | UTC ISO-8601 launch timestamp (host clock). |
| `session_nonce` | Per-launch random hex; printed host-side under `SANDY_VERBOSE!=0` so an external verifier can match the file to a specific launch. Not exported as an env var. |
| `effort` | Reasoning effort sandy PINNED via `SANDY_EFFORT` (JSON string, e.g. `"high"`), or `null` when sandy did not pin it (agent ran at its own default). It is the **sandy-level** value: since 2.4.0 (#116) it also applies to codex, where each level maps to its codex namesake, and since 2.7.0 to grok, where `max` is clamped to `xhigh`, and to gemini, through a read-only system settings file (Appendix B.10) — so in a combo one value describes every pane that received it; a launch with none of claude, codex, grok or gemini records `null`. Makes a run's effort provable after teardown (1.6.0). |
| `permission_mode` | Permission mode sandy PINNED into settings.json for the claude agent this launch: `"bypassPermissions"` when `SANDY_SKIP_PERMISSIONS=true` (the default), or `null` when it did not (skip off, or claude isn't in `SANDY_AGENT`). Reflects what sandy pinned at launch, not necessarily what's in effect right now — see the settings.json seed step (§C.2) and the session-end drift notice (§9) for why (#151). |
| `cross_session_inbound` | (1.10.0) The `crossSessionInbound` value sandy actually wrote this launch (`"accept"` \| `"hold"` \| `"refuse"`), or `null` when neither of the two write targets (§C.2a) succeeded (claude isn't in `SANDY_AGENT`, or both writes failed and a warning was printed). Does not distinguish which of the two targets received it — see the launch-time log line for that. See §C.2a. |
| `cross_session_inbound_source` | (2.4.0, #380) WHY `cross_session_inbound` resolved to that value: `"explicit"` (an operator-set `SANDY_CROSS_SESSION_INBOUND`) \| `"feature:<name>"` (the first, in sorted feature-directory order, SELECTED feature manifest declaring `"receives": ["cross_session"]`) \| `"default"` (neither an explicit value nor a declared need — includes both the case where nothing at all declares the need, and the criterion-8 case where a need WAS declared but this run is headless/`--remote`/`--provision` and has no session to deliver into). JSON `null`, mirroring `cross_session_inbound`'s own convention, exactly when that field is also `null`. `"relay-legacy"` (the pre-2.4.0 rule: no feature declares the need, but a feature `entry` will start) was a valid value from 2.4.0 through 2.5.x — announced for removal in README's `## Deprecated` table in 2.5.0 (#382) — and was **removed in 2.6.0** (decision 6): a marker written by 2.6.0+ sandy never produces it; only a marker written by an older sandy still on disk can carry it. Additive; `schema_version` does not move. |
| ~~`handoff_relay`~~ | **Removed in 2.2.0 (#355).** (1.10.0) Was a bool: whether `SANDY_HANDOFF_RELAY` was forwarded this launch. `relay.source` other than `"none"` carried the same fact — criterion 7 still holds, so it meant the relay was started or the session never came up. |
| ~~`relay.source`~~ | **Removed in 2.6.0 (#382, decisions 1-2), along with `relay{}` itself.** (2.1.0, #345) Was which producer supplied the relay this launch: `explicit` \| `slot` \| `manifest` \| `none`. `feature_entries.<name>` below is where every entry is now reported, uniformly, with no producer distinction. `explicit` and `slot` had both already stopped occurring in 2.2.0 (#354 removed `SANDY_HANDOFF_RELAY` as an operator-settable config key, the only source of `explicit`; #355 removed the `relay-bin/` slot); #382 decision 3 later made `SANDY_RELAY` a hard error too, and decisions 4-5 removed the internal `SANDY_HANDOFF_RELAY` channel, so by 2.6.0 nothing distinguishable by `source` remained to report. |
| ~~`relay.path`~~ | **Removed in 2.6.0, with `relay{}`.** Was the **container** path of the executable the supervisor was told to start. `feature_entries.<name>.path` is the replacement, per entry. |
| ~~`relay.disabled_by`~~ | **Removed in 2.6.0 (#382, decisions 1-2), with `relay{}`.** In 2.5.x recorded which config source had set `SANDY_RELAY=0` for the relay-designated entry (JSON `null` when it had not been disabled). Removing it in the same bump as `relay{}` was an operator decision (#382 decision 1) to bundle a companion field rather than deprecate it on its own — it never appeared in README's `## Deprecated` table separately, and by the time #382 decision 3 made `SANDY_RELAY=0` a hard error, nothing was left that could still set it. |
| `image` | (2.7.0, #295) WHICH image this launch ran, as `{name, id, project_layer}` on ONE line: `name` is the tag handed to `docker run` (`sandy-claude-code`, `sandy-full`, `sandy-skills-<packs>`, or `sandy-project-<sandbox>`); `id` is the `sha256:` id that name resolved to when the marker was written, or JSON `null` when docker could not answer (never a guess); `project_layer` is `true` iff the per-project `.sandy/Dockerfile` layer is the image that ran. **`project_layer: false` in a workspace that has a `.sandy/Dockerfile` is the fallback, recorded**: the approval gate uses the agent image on a decline or an unanswerable (non-TTY, e.g. a `--start` supervisor) prompt, and until this field nothing on disk said which image ran — the only in-container check was observing the layer's effects. Always an object, never a deliberate `null` (the `--print-state` `marker` rule, SPEC_INTROSPECTION.md). Read back per sandbox by `--print-state` as `image`. Additive; `schema_version` does not move. |
| `agent_args` | (2.1.0, #348) Launch arguments a **feature manifest** contributed this launch, keyed by agent name, each entry naming the feature that supplied it. Emitted on ONE line so a host-side reader can take it with a single match anchored on its own key. Recorded **post-filter** — a dropped mode flag is not reported as applied — and only for agents this launch actually ran. **Three states, never collapsed:** field ABSENT = a sandy predating it, which cannot answer; `{}` = sandy looked and no feature contributed; populated = exactly what was applied, and by whom. Rounding absent to "none applied" would report a configured fleet as unconfigured (same `None`-vs-`[]` rule as `agent_args_files`). LAST LAUNCH, never next launch: a sandbox whose manifest changed reports the old value until it relaunches. **It records what was PASSED and cannot answer whether it took effect — see `agent_args_composed`.** |
| `agent_args_composed` | (2.3.0, #363) What sandy did about **two or more contributors of the same flag** that the agent's parser reads only once, keyed by agent. Each entry: `flag`, `policy` (`concat`\|`report`), `composed` (bool), `from` (contributor labels, in the order sandy passed them) and `path` (the container path of the merged file, or `null`). `composed: false` means the collision was detected and REPORTED but the argv was left alone — either the flag replaces rather than appends (`report`), or a value was under no mount sandy made and therefore unreadable to it. Same three states as `agent_args`: ABSENT = a sandy predating the field; `{}` = looked, no collision; populated = what happened. **This is the field that answers "can the contribution have taken effect"**, which `agent_args` structurally cannot. |
| `feature_entries` | (2.4.0, #381) Every feature manifest `entry` this launch adopted, keyed by feature name. Each entry: `{path}` — **launch INTENT only**: the marker is written before `docker run`, so it cannot know whether an entry actually started (that is `--print-state`'s `feature_entries.<name>` object, which adds the LIVE fields `state`/`restarts`/`executable_present`/`state_dir`). `path` is the container path. As of 2.6.0 (#382, decisions 1-2) this is the ONLY field per entry: `relay_alias` and `disabled_by` are removed along with `relay{}` itself — there is no longer a designated entry for `relay_alias` to point at, and no longer a way to disable an entry for `disabled_by` to record (decision 3 made `SANDY_RELAY=0` a hard error). A marker written by a pre-2.6.0 sandy can still carry both keys on disk; `--print-state` still reads such a marker back correctly (§172(7i)/(7j)). Same three states as `agent_args`: ABSENT = a sandy predating the field; `{}` = no feature declared an entry (or every declared one was skip'd by the manifest itself, which is a different, earlier stage than this field covers); populated = every adopted entry. Every entry, including what used to be the relay-designated one, is reported here identically — there is no separate top-level object any more. |
| `offline` | (2.4.0, #219) `true` when `SANDY_OFFLINE=1` / `--no-update-check` suppressed the update lookups this launch (B.3), so a run launched on a possibly-unpatched agent **by choice** is provable after the fact. `false` otherwise. Absent = a sandy predating the field. |
| `cred_mode` | Worst Claude credential actually present in the container (#130): `profile` (1.11.0 — one Anthropic Console profile from `ant auth login`, workspace-scoped; everything else withheld) \| `profile-access-only` (1.12.0 — that profile with its `refresh_token` stripped under `SANDY_SUSPICIOUS`, so it dies at `expires_at`) \| `oauth-token` (long-lived env token) \| `access-token-only` (refresh token stripped under `SANDY_SUSPICIOUS`) \| `full` (complete OAuth file incl. refresh token) \| `api-key` \| `none`. Tested in that order — first match wins, and under `profile` a host `CLAUDE_CODE_OAUTH_TOKEN` may still be *set* (it is withheld at the forwarding site), so the profile test comes first. States blast radius, not intent; recorded every launch. |

`feature_entries.<name>.state_dir` is **not** a marker field: it is `--print-state`-only (2.2.0, #353, generalized per-entry 2.6.0 #382 decisions 1-2, 4-5) — the HOST directory holding `.state` and `supervisor.log` (`$SANDBOX_DIR/feature-state/<name>`, or `$SANDBOX_DIR/relay-state` when reading back an OLD marker's `relay_alias:true` entry that has not relaunched since — the RECOMMENDED compat fallback, §172(7i)/(7j)). Note the frame: `feature_entries.<name>.path` is a CONTAINER path, `state_dir` a HOST path. Live entry state (`state`, restarts, last exit) is likewise `--print-state`-only, because the marker is written before `docker run` and can record only launch intent.

Because the file is a `:ro` bind mount, a committed workspace `.sandy/config` cannot forge it. In-container tooling (the `sandy-isolation-test` kit, CI) should assert on this file rather than on env vars or uid/cap heuristics.

---

## Appendix D: Platform-Specific Behavior

Sandy runs on both Linux and macOS. The following sections document every point where behavior diverges.

### D.1 Network Isolation

> **Scope:** this table describes the **legacy `SANDY_EGRESS_PROXY=0`** path. The **default is `1` (permissive)**, under which the egress proxy provides uniform isolation on *both* platforms (see the "Cross-platform fix" note below and the "Egress Proxy" section) — so this table applies only when a user explicitly opts out of the proxy.

| Aspect | Linux | macOS |
|---|---|---|
| Mechanism | iptables `DOCKER-USER` chain | **None** (only under opt-out `=0`; Docker Desktop does *not* provide LAN isolation) |
| Rules applied | DROP for 5 private ranges; ACCEPT for container subnet and allowed hosts | None — LAN, `host.docker.internal`, and host `localhost` are all reachable |
| Fail-closed | Aborts if iptables unavailable, **or if any DROP rule is missing after insertion** (`iptables -C`, 2.4.0, #299) — unless `SANDY_ALLOW_NO_ISOLATION=1`, which warns instead | Prints loud launch warning banner naming `SANDY_EGRESS=permissive\|strict`; proceeds without isolation |
| Defense-in-depth | n/a | `--add-host gateway.docker.internal:127.0.0.1`, `--add-host metadata.google.internal:127.0.0.1`, and (conditionally) `--add-host host.docker.internal:127.0.0.1` |
| Cleanup | Rules and bridge network deleted on exit | Bridge network deleted on exit |

**macOS `--add-host` condition:** `host.docker.internal` is only nullified when `SANDY_SSH != agent`. In agent mode, sandy's in-container SSH agent relay uses that hostname to reach the host-side socat relay (see §10); nullifying it would break SSH. An additional warn line is emitted in that case.

**Cross-platform fix — `SANDY_EGRESS_PROXY` (M2.7):** the egress proxy sidecar (transparent SNI/Host + CONNECT + DNS) implements uniform outbound isolation on both platforms via a Docker `--internal` network. `1`=permissive (block LAN/host, allow internet — **the default**), `2`=strict (allowlist only). Since the proxy is **on by default**, this entire table describes only the opt-out `=0` path. See the "Egress Proxy" section above, `ISOLATION_STRESS.md` finding F2, and `proxy/` for the implementation.

**Linux iptables flow**:
1. Test `sudo iptables -L DOCKER-USER -n` — if fails, abort (or allow with override)
2. Insert DROP rules for each private range (inserted first = evaluated last)
3. Insert ACCEPT for `SANDY_ALLOW_LAN_HOSTS` entries (if set)
4. Insert ACCEPT for container's own subnet (inserted last = evaluated first)
5. Verify each DROP with `sudo iptables -C DOCKER-USER -i $BRIDGE -d <range> -j DROP`; the first missing one aborts, naming it (or warns "INCOMPLETE" under `SANDY_ALLOW_NO_ISOLATION=1`). Only then print "Network isolation rules applied." (2.4.0, #299)
6. On exit: delete rules in reverse, remove Docker network

### D.2 SSH Agent Relay

| Aspect | Linux | macOS |
|---|---|---|
| Host → container | Direct Unix socket mount (`-v $SSH_AUTH_SOCK:/tmp/ssh-agent.sock`) | TCP relay via `socat` |
| Port allocation | N/A | `python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); ..."` |
| Host relay | N/A | `socat TCP-LISTEN:<port>,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:<SSH_AUTH_SOCK>` |
| Container relay | N/A (direct socket) | `socat UNIX-LISTEN:/tmp/ssh-agent.sock,fork,mode=0600 TCP:host.docker.internal:<port>` |
| Socket wait | N/A | 50 × 0.1s = 5s timeout |
| Dependency | None extra | Requires `socat` and `python3` on host (checked, error with `brew install` suggestion) |

### D.3 Credential Loading

| Aspect | Linux | macOS |
|---|---|---|
| Primary source | `~/.claude/.credentials.json` (file) | Same file |
| Fallback source | None | macOS Keychain: `security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w` |
| Token refresh | Skip (no browser available on headless Linux) | `claude auth login` (can open browser) |
| Browser detection | `can_open_browser()` always returns 1 (false) | Always returns 0 (true) |

### D.4 SHA256 Hash

```bash
sha256() { shasum -a 256 2>/dev/null || sha256sum; }
```

- macOS: `shasum -a 256` (Perl-based, ships with macOS)
- Linux: Falls through to `sha256sum` (coreutils)

### D.5 UID/GID Remapping

| Aspect | Linux | macOS |
|---|---|---|
| Host UID detection | `id -u` (typically non-root, e.g. 1000) | `id -u` (typically 501) |
| Image default UID | 1001 | 1001 |
| Remapping needed | Usually yes (1000 ≠ 1001) | Usually yes (501 ≠ 1001) |
| Implementation | Custom `passwd`/`group` files mounted read-only | Same |

**passwd sed pattern**: `sed "s/^sandy:x:1001:1001:/sandy:x:${HOST_UID}:${HOST_GID}:/"`
**group sed pattern**: `sed "s/^sandy:x:1001:/sandy:x:${HOST_GID}:/"`

(The container user is `sandy` since 2.0.0, #248; it was `claude` before.)

### D.5a Host Timezone Resolution (2.4.0, #384)

`_sandy_host_tz` resolves the zone passed as `-e TZ=` (E.11a-tz). First match wins; a candidate that fails validation is **skipped** and the next source tried, never fatal.

| Step | Source | macOS | Linux |
|---|---|---|---|
| 1 | `$TZ` in sandy's environment (a leading `:` dropped) | same | same |
| 2 | `readlink /etc/localtime`, everything up to and including the last `zoneinfo/` stripped, then a leading `posix/` or `right/` | `/var/db/timezone/zoneinfo/America/Denver` → `America/Denver` | `/usr/share/zoneinfo/Europe/Berlin` (absolute or relative) → `Europe/Berlin` |
| 3 | first line of `/etc/timezone`, trailing whitespace dropped | absent | Debian/Ubuntu, where `/etc/localtime` may be a copy rather than a link |
| 4 | nothing — `TZ` stays unset (UTC, the pre-2.4.0 behaviour) | | |

- Plain `readlink` (no `-f`, which is GNU-only): only the link's text is wanted.
- Validation: `^[A-Za-z0-9_+:,./-]{1,64}$`, no leading `/`, no `..`. POSIX rule strings (`EST5EDT,M3.2.0,M11.1.0`) pass. `TZ=:/etc/localtime` fails the leading-`/` rule after the `:` is dropped and falls through to step 2, which reads that same file.
- An invalid `$TZ` warns only at `SANDY_VERBOSE>=1`.
- `posix/` and `right/` are stripped because the image ships neither variant tree (trixie moved both to `tzdata-legacy`): forwarding `posix/Europe/Berlin` verbatim would be unset by step 0 and the container would read UTC.
- Existence is checked **container-side** by `entrypoint.sh` (A.5 step 0) against the image's zoneinfo, not the host's.
- `tzdata` is not named in `Dockerfile.base`; it arrives transitively in the trixie base, which is what makes the runtime-only design free (no base rebuild). If it ever stops arriving, step 0 unsets `TZ` and the container reads UTC again, which is safe.
- Everything sandy **emits as data** stays UTC regardless: every calendar-time producer is `date -u`, epoch seconds, or jq `todateiso8601` (pinned by `run-tests.sh` §163(17), which runs each one under `TZ=Pacific/Kiritimati`, and by §163(18), a static ratchet over every `date` and human-readable mtime `stat` call in the script, heredocs included — it catches what (17) cannot run, such as a `|| date` fallback behind a `date -u` that succeeds, a backtick `date`, or a `stat -c %y` without `TZ=UTC`).

### D.6 Error Recovery & Fallback Chains

**settings.json merge** (3 tiers, tried in order — target is `$SANDBOX_DIR/claude/settings.json`, rebuilt every launch with merge-preserving semantics):
1. **Node.js**: JSON repair → parse host → read previous sandbox → preserve `enabledPlugins` from previous → merge defaults → merge marketplaces → scrub deprecated → write
2. **jq**: Same shape via `--argjson prev "$_prev_plugins"` read from the previous sandbox settings
3. **printf**: Only if no file exists yet, writes minimal JSON

**.claude.json seeding** (2 tiers):
1. **Node.js**: Parse, delete `projects` key, write pretty-printed
2. **cp**: Raw copy if Node.js fails (host projects key preserved — less clean but functional)

**Token expiry check** (2 tiers):
1. **Node.js**: Parse credentials JSON, check `claudeAiOauth.expiresAt` against `Date.now() + 300000`
2. **Python 3**: Same logic via `json.loads` and `time.time() * 1000`
3. If neither available: warn and return "no refresh needed" (fail-open — the existing credentials are used as-is rather than forcing a re-login)

**Skill pack version resolution** (3 tiers; steps 1–2 are skipped under `SANDY_OFFLINE=1`, B.3):
1. **GitHub releases API**: 5s timeout, looks for tags matching prefix
2. **GitHub commits API**: 5s timeout, gets latest commit SHA (truncated to 12 chars)
3. **Local cache file**: `$SANDY_HOME/.skill_version_<pack>`
4. **Hardcoded fallback**: `SKILL_PACK_VERSIONS` array entry

### D.7 CPU feature floor (x86-64 virtual machines)

Not a Linux/macOS divergence but a host-hardware one, recorded here because it is the platform difference that fails silently (#117). The agent image build runs the native installers of Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`, whose last step executes the downloaded `~/.claude/downloads/claude-<version>-linux-x64 install`) and Grok Build. Both binaries embed a JavaScript runtime that needs at least the **x86-64-v2** feature level. A QEMU/KVM guest on the hypervisor's generic CPU model (`kvm64`/`qemu64`; `lscpu` reports *Common KVM processor*) is offered only the x86-64 baseline — no `sse4_2`, `popcnt`, `avx`, `avx2` — and the binary then **busy-loops in userspace** rather than failing: state `R`, ~90–100% CPU, zero syscalls under `strace`, so the build sits at "Building sandbox image" indefinitely. Real hardware and CI runners expose the full feature set and are unaffected. Sandy does not detect it; the remedy is operator-side — set the VM CPU type to `host` (or an x86-64-v2+ model) and cold-boot. User-facing steps: README "Troubleshooting".

---

## Appendix E: Container Launch Assembly

The `docker run` command is assembled incrementally in a `RUN_FLAGS` array. This appendix documents the complete assembly in order.

### E.0 Workspace Mutex

Only one sandy may run against a given workspace at a time. Early in launch (after config loading, before sandbox seeding), sandy takes a per-workspace mutex:

```bash
mkdir -p "$SANDY_HOME/sandboxes"
SANDY_WORKSPACE_LOCK="$SANDY_HOME/sandboxes/.${SANDBOX_NAME}.lock"
if ! mkdir "$SANDY_WORKSPACE_LOCK" 2>/dev/null; then
    _sandy_lock_state "$SANDY_WORKSPACE_LOCK"      # stale | live | unknown
    if [ "$_SANDY_LOCK_STATE" = stale ]; then
        # _sandy_lock_reap_stale: re-check, mv to .reap.<pid>, re-check what
        # moved; rm -rf only if still stale, else put it back. Then retry mkdir.
    else
        # error: another sandy is already running in this workspace (pid <holder>)
        exit 1
    fi
fi
echo "$$" > "$SANDY_WORKSPACE_LOCK/pid"
```

`mkdir` is used as the lock primitive because it is atomic on every POSIX filesystem and requires no external dependency (unlike `flock(1)`, which is not shipped on macOS by default). The lock dir is released by the cleanup trap (`trap cleanup EXIT INT TERM HUP`) on normal exit, Ctrl-C, or sandy crash. A SIGKILL (OOM, `kill -9`) leaves the lock dir behind, but sandy's next launch reads `$LOCK/pid`, probes liveness via `kill -0 <pid>`, and auto-clears the lock when the holder is gone (and reacquires via a second `mkdir`). PID reuse is a theoretical concern — if the OS recycled the holder's PID to an unrelated process, `kill -0` returns true and sandy errors out (false-positive "still held"); the user clears manually. The conservative default is preferred over a false negative that would clobber an active session.

A non-numeric or empty `$LOCK/pid` (corrupt — sandy died mid-write) is left for the user to inspect; auto-clear refuses to act on it.

**One predicate, one remover (2.7.0, #158).** `_sandy_lock_state <lockdir>` (sets `_SANDY_LOCK_STATE` = `stale`|`live`|`unknown` and `_SANDY_LOCK_PID`, no fork beyond the `cat`, silent on stderr) is the only staleness test: the launch, `--print-state`'s `lock_holder_alive`, `--doctor`'s listing and `--stop`'s direct teardown all call it. EPERM from `kill -0` reads as not-alive, as it always did. `_sandy_lock_reap_stale <lockdir>` is the only remover (launch, `--doctor --fix`, `--stop`): re-check → atomic `mv` to `<lockdir>.reap.<pid>[.<n>]` (a fresh name — `mv` into an existing directory would nest) → re-check the pid read **from the moved dir** → `rm -rf` if still stale, otherwise restore it under its name. Return codes: `0` removed, `1` not stale at the re-check (untouched), `2` moved a re-taken lock and restored it, `3` moved a re-taken lock and the name was taken again before it could be restored (both kept; `_SANDY_LOCK_REAP_PATH` names the displaced dir), `4` another reaper won the rename. The helper's header comment enumerates every interleaving. It closes the race where `--doctor --fix` removed a lock a launch had re-taken between listing and removal. Guarded by `run-tests.sh` §179.

Rationale: two agents editing the same codebase would step on each other's edits, and the sandbox-seeding / venv-materialization code paths assume exclusive ownership. Deliberate parallelism should use separate workspaces.

### E.1 Pre-Launch

**Preflight failure-mode guards (M4 PR 4.4).** After the no-Docker-needed fast paths (`--version`/`--help`/`--upgrade`/`--print-*`/`--validate-config`/`--approvals`) have exited, the launch path fails fast with a *specific, actionable* message (non-zero exit) rather than dying later with a raw error:

| Condition | Check | Message (substring) |
|---|---|---|
| Docker client absent | `command -v docker` | "Docker is not installed or not in PATH." |
| Docker **daemon down** | `docker info` (after the binary check, so "not installed" vs "daemon down" stay distinct) | "Docker is installed but the daemon isn't responding." |
| `$SANDY_HOME` not writable | write-probe (`: > "$SANDY_HOME/.sandy-write-test"`) | "SANDY_HOME (…) is not writable" + `chmod u+rwx` hint |
| Corrupt host `~/.claude/.credentials.json` (claude path) | `_creds_is_valid_json` before the OAuth-token branch — empty is valid (absent creds is a legitimate env-var-auth state); skipped if no host JSON parser | with a token: warn + drop the file + use the token; without: "credentials are corrupt … Re-authenticate on the host" + exit |

Each message is asserted by `run-tests.sh §53` (validator unit test + source-level message lock-in) and `run-integration-tests.sh §15` (read-only `SANDY_HOME` and corrupt-creds exercise the real launch path). Already-clean modes: a **partial sandbox** self-repairs (`mkdir -p "$SANDBOX_DIR/claude"` runs unconditionally), and a **missing image** rebuilds via the build gate.

**Stale container removal**: Before starting, any container with the same name is force-removed to handle unclean previous exits:
```bash
docker rm -f "sandy-<SANDBOX_NAME>" 2>/dev/null || true
```

**Stale session-registry prune (#407)**: immediately after that removal, if `$SANDBOX_DIR/claude` exists and `docker ps -a --format '{{.Names}}'` succeeds and lists no line exactly equal to `sandy-<SANDBOX_NAME>`, sandy removes every **regular file** in `$SANDBOX_DIR/claude/sessions/` whose name matches `^[0-9]+\.json$` or `^[0-9]+\.[0-9a-f]{64}\.key(\.tmp\.[0-9a-f]+)?$`. Those files are Claude Code's live-session registry and messaging keys, stamped with a pid-namespace `pidDomain` that no later container can ever match. Other names, symlinks, and a symlinked `claude/` or `sessions/` (warned) are left alone. The count is printed under `SANDY_VERBOSE=1`. Guarded by `run-tests.sh` §186.

### E.1a Approval pre-pass under `--start` (#221, #296)

A launch can meet three approval gates, and under `--start` all of them are answered on the **client's** tty, never in the supervisor (whose stdin is `/dev/null`, so a gate reached there can only fail closed). Before forking, and only when the client has a TTY on stdin and stderr, `--start` runs `cd <workspace> && SANDY_APPROVE_ONLY=1 <sandy>` synchronously on `/dev/tty`. That pass loads config, resolves the gates, persists approvals, and exits before the workspace mutex, the busy-gate, and every image build.

| gate | approval file | resolved in the pre-pass | declined in the pre-pass | `SANDY_AUTO_APPROVE_PRIVILEGED=1` |
|---|---|---|---|---|
| passive-privileged config keys (§2) | `$SANDY_HOME/approvals/passive-<wd16>.list` | yes (config load) | keys dropped, pass continues | **bypasses** |
| dangerous symlinks (E.9) | `$SANDBOX_DIR/.sandy-approved-symlinks.list` | yes (#221) | **refusal**: pass exits nonzero, `--start` exits `6` | **does not bypass** |
| per-project `.sandy/Dockerfile` (§5) | `$SANDY_HOME/approvals/dockerfile-<wd16>.list` | yes (2.4.0, #296) | **not a refusal**: pass exits `0`, the session runs the base agent image | **bypasses** |

Side effects of the pass are limited to `mkdir -p "$SANDBOX_DIR"` and the approval files above, the same files an interactive foreground launch writes — including the Dockerfile gate's `dockerfile-<wd16>.session-created` record (§5, #295 item 3), which the gate may write (a snapshot a session left behind shows it created `.sandy/`) or remove (the content is approved), exactly as it does in the foreground.

**A Dockerfile decline is carried to the supervisor, bound to content.** The client passes `SANDY_APPROVE_ONLY_RESULT=<daemon-log>.approve`; on a decline the pass writes `dockerfile_declined=<context-hash>` there. The client validates the hash (`^[0-9a-f]{64}$`), deletes the file, and always passes `SANDY_DOCKERFILE_DECLINED_HASH=<hash or empty>` into the supervisor's `nohup env`. The supervisor's gate, finding no approval, compares that value with the context hash it computes itself: equal → one line (`not approved at the --start prompt — using the base agent image`) and the build is skipped; unequal (the context changed in between) → the ordinary non-interactive fail-closed path. The variable can only ever make sandy build *less*, so an env carrier is safe. Both variables are internal and env-only, like `SANDY_APPROVE_ONLY`.

**Why the symlink gate ignores the bypass.** The symlink approval is designed so that a *new* escaping link is a hard error, never a re-prompt: no approval of new content happens without a deliberate human act. An env-wide bypass would silently mount every future escape read-write. The other two gates were built with the bypass for test harnesses, and it remains the only answer for a client that has no terminal at all.

A client with no TTY skips the pre-pass entirely; every gate then fails closed in the supervisor unless its approval was granted earlier or the bypass applies.

**`sandy --approvals [--workspace P]` — the same pass as a report (2.7.0, #296).** Because a client with no TTY cannot be asked, it previously learned nothing either: keys were dropped and the project image skipped with `--start` still exiting `0`. `--approvals` is an introspection fast path that re-execs `cd <workspace> && SANDY_APPROVE_ONLY=1 SANDY_APPROVE_REPORT=<tmpfile> <sandy>` with stdin `/dev/null` and stdout/stderr discarded. With both variables set, each of the three gate functions — `_resolve_passive_privileged_approval`, `_sandy_resolve_symlinks`, `_sandy_project_dockerfile_approved` — appends one record (`status`, gate, one-line JSON) to the file and returns **before** its `mkdir`, prompt, writer and (for symlinks) the approved-list refresh; `_sandy_approve_only_finish` then appends the sandbox name and a `done` line and exits without creating `$SANDBOX_DIR`. The same mode skips the Docker/`SANDY_HOME`-writable preflight, `ensure_build_files`, the network/proxy reapers and `ensure_agent_dockerfile`, so it writes nothing and needs no Docker. The handler assembles one JSON document (`SPEC_INTROSPECTION.md`); a missing `done` line means the launch path exited before the gates and is reported `complete: false`, exit `1`. Statuses: `approved` / `pending` / `changed` / `refused` (symlinks only: a new escape the launch hard-errors on) / `not_applicable`. **Read-only by decision** — there is no grant counterpart. `SANDY_APPROVE_REPORT` alone does nothing, and the `--start` client unsets it for its own pre-pass so an inherited value cannot turn the approval pass into a report. Guarded by `run-tests.sh §183`.

### E.2 Base Flags

```bash
--rm -it
--name sandy-<SANDBOX_NAME>
--cpus <SANDY_CPUS>
--memory <SANDY_MEM>
--security-opt no-new-privileges:true
--cap-drop ALL
--cap-add SETUID --cap-add SETGID
--cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER
--pids-limit 512
--init
--read-only
--tmpfs /tmp:exec,size=1G
--tmpfs /home/sandy:exec,size=2G,uid=1001,gid=1001
--network <NETWORK_NAME>
```

### E.3 GPU Passthrough (conditional)

If `SANDY_GPU` is set and Docker supports GPUs (`docker info --format '{{.Runtimes}}'` contains `nvidia` or `cdi`):
```bash
--gpus <SANDY_GPU>    # e.g., "all" or "device=0,1"
```

### E.4 Credential Mount (conditional)

If credentials were loaded (OAuth token or credentials file):
```bash
-v "<CRED_TMPDIR>/.credentials.json:/home/sandy/.claude/.credentials.json"
```

If `SANDY_CLAUDE_AUTH=profile` resolved a profile (1.11.0) — and then the block above is **not** emitted, because the OAuth file is withheld:
```bash
-v "<PROFILE_TMPDIR>:/home/sandy/.config/anthropic"     # rw, ephemeral; holds ONE profile:
                                                          #   active_config, configs/<name>.json,
                                                          #   credentials/<name>.json (0600)
-e "ANTHROPIC_PROFILE=<name>"                             # only when the operator set it
```

The temporary directory is created per-launch and cleaned up on exit. The mount is **read-write** — Claude Code cloud features (e.g., `/ultrareview`) need to write refreshed or scoped tokens back to the credentials file during a session. The tmpdir is ephemeral (fresh each launch, `rm -rf` on exit), so in-session writes do not persist to the host. Codex `auth.json` and Gemini OAuth mounts remain `:ro` (these agents don't have equivalent cloud features that require token write-back). See §11 for credential loading rules per agent.

**Cleanup trap**: the `cleanup` function that removes `*_CRED_TMPDIR` directories is registered on `EXIT INT TERM HUP QUIT ABRT`. `SIGKILL` cannot be trapped, so a residual cleanup window exists in that case alone.

### E.5 .claude.json (no mount; `CLAUDE_CONFIG_DIR`)

```bash
-e CLAUDE_CONFIG_DIR=/home/sandy/.claude      # claude selected only
```

There is **no** `.claude.json` mount since 2.7.0 (#400): the file is `<NAME>/claude/.claude.json`, inside the `claude/` directory mount. See C.3. Through 2.6.x this was `-v "<SANDY_HOME>/sandboxes/<NAME>.claude.json:/home/sandy/.claude.json"`, a single-file mount. Removing it was not what fixed #400; see C.3.

### E.6 Host Hooks Mount (conditional)

If `~/.claude/hooks/` exists on the host:
```bash
-v "$HOME/.claude/hooks:/home/sandy/.claude/hooks:ro"
```

### E.7 Workspace Mount

```bash
-v "<HOST_PATH>:<CONTAINER_PATH>"
```

Where `CONTAINER_PATH` follows the workspace path mapping rules (Section 13).

### E.7a Workspace `.venv` Overlay (conditional)

If `$WORK_DIR/.venv` exists on the host, is not a symlink, and `SANDY_VENV_OVERLAY` is not `0`, sandy bind-mounts a sandbox-owned dir over the workspace venv path:

```bash
-v "<SANDBOX_DIR>/venv:<CONTAINER_PATH>/.venv"
-e "SANDY_VENV_OVERLAY_ACTIVE=1"
-e "SANDY_VENV_PYTHON_VERSION=<major.minor>"   # if parseable from pyvenv.cfg
```

Must appear **after** the workspace mount (E.7) so Docker can overlay it on top. The sandbox `venv/` dir is created on the host side before `docker run`.

**Python version resolution (host side)**, in order:
1. `$WORK_DIR/.python-version` — authoritative, user-maintained.
2. `$WORK_DIR/.venv/pyvenv.cfg` `version` / `version_info` line — fallback.

The result is normalized to `major.minor` (`cut -d. -f1-2`) and validated against `^[0-9]+\.[0-9]+$`. Values that don't match are discarded and `SANDY_VENV_PYTHON_VERSION` is left unset — the container then defaults to `3.12` in `user-setup.sh`.

**Symlinked `.venv/`** is explicitly skipped on the host side; an info message fires instead of silently proceeding. Rationale: the symlink target may be a path outside `$WORK_DIR` and overlaying it would shadow unpredictable host state.

Inside the container, `user-setup.sh`:
1. If `$WORKSPACE/.venv/pyvenv.cfg` does not exist, materializes a fresh venv via `uv venv --clear --python <version> $WORKSPACE/.venv`. The `--clear` flag is required: the overlay bind-mount target always exists as a directory, and `uv venv` otherwise refuses with "A directory already exists at: .venv". No in-container locking is needed — the host-side workspace mutex (§E.0) guarantees exclusive access.
2. After materialization (or on subsequent launches), compares the overlay's actual `pyvenv.cfg` version against `SANDY_VENV_PYTHON_VERSION`. Mismatch → prints a drift warning with the recreate command. No auto-recreate (would silently nuke installed packages).
3. Activates unconditionally if `$WORKSPACE/.venv/bin/python` exists (`VIRTUAL_ENV` + PATH prepend).

The host `.venv/` is never read or written by sandy — it is shadowed by the bind mount inside the container only.

### E.8 Git Submodule Mount (conditional)

If `.git` is a file (submodule), the gitdir is also mounted:
```bash
-v "<HOST_GITDIR>:<CONTAINER_GITDIR>"
```

Both paths use the same `$HOME`-relative mapping to preserve the relative relationship.

### E.9 Symlink Protection Scan

Before assembling mounts, sandy scans the workspace for symlinks escaping the project directory:
```bash
find <WORKSPACE> -maxdepth 8 \
    -path '*/node_modules' -prune -o \
    -path '*/.venv*' -prune -o \
    -path '*/.git' -prune -o \
    -type l -print
```

Each symlink's real path is checked against the workspace root. If any escape, sandy consults the persisted approval list `<SANDBOX_DIR>/.sandy-approved-symlinks.list` (one `<link>\t<target>` per line). The handling is one of three paths:

1. **No approval list yet (first launch):** prompt the user with
   ```
   These could allow Claude to access files outside the sandbox.
   Proceed anyway? [y/N]
   ```
   On `y`/`Y`, sandy writes the current set to the approval list and proceeds. Anything else aborts with exit 1.

2. **Current set is a subset of the approved list:** proceed silently. Sandy rewrites the list to drop entries the user has deleted (symlink removal is benign).

3. **Current set contains an entry not in the approved list:** **hard error**, naming the new symlink(s), with no re-prompt. Rationale: a y/N that fires every session can be trained past; a hard error forces a deliberate user action. Remediation is `rm` the offending link (restoring the approved state), or `rm <SANDBOX_DIR>/.sandy-approved-symlinks.list` to clear the persisted approval and get a fresh prompt on the next launch.

When the user accepts, each symlink target is mounted into the container (see Section 9, Symlink Protection). Mount path depends on symlink type:
- **Absolute**: `-v "<resolved_host_path>:<raw_symlink_value>"`
- **Relative**: `-v "<resolved_host_path>:<HOME_relative_container_path>"`

Deduplicated by container mount path.

### E.10 Protected File Mounts

Three *static* categories, sourced from the single-source-of-truth helpers in `sandy` (`_sandy_protected_files`, `_sandy_protected_git_files`, `_sandy_protected_dirs`) and exposed to the test harness via `sandy --print-protected-paths`, which emits `file:<path>`, `gitfile:<path>`, and `dir:<path>` lines — **plus one dynamic mount** (a redirected `core.hooksPath`, resolved per-workspace at launch) that is *not* part of `--print-protected-paths`, because it depends on the workspace's git config, which the pure pre-workspace fast-path handler can't see. See §9 for the full path list and threat model.

**Regular files — existence-gated (0.11.2)**:
```bash
while IFS= read -r f; do
    [ -e "<WORKSPACE>/$f" ] && -v "<WORKSPACE>/$f:<CONTAINER_WORKSPACE>/$f:ro"
done < <(_sandy_protected_files)
```
The always-mount-with-empty-fixture pattern was reverted for files in 0.11.2 because Docker creates mount targets on the host inside the rw workspace bind, causing 0-byte stub files to appear in the user's workspace (breaking direnv and polluting `git status`). See §9 for the residual F3 gap and its host-side detection mitigation.

**Git-tree files — existence-gated** (meaningless without a real git repo):
```bash
while IFS= read -r f; do
    [ -f "<WORKSPACE>/$f" ] && -v "<WORKSPACE>/$f:<CONTAINER_WORKSPACE>/$f:ro"
done < <(_sandy_protected_git_files)
```

**Directories — existence-gated** (same model as files; absent dirs are covered by session-end detection, §9):
```bash
while IFS= read -r d; do
    [ -d "<WORKSPACE>/$d" ] && -v "<WORKSPACE>/$d:<CONTAINER_WORKSPACE>/$d:ro"
done < <(_sandy_protected_dirs)
```
(The `--print-schema` JSON field listing these dirs is still named `dirs_always_mount` — the name is historical, kept for introspection-schema stability; see SPEC_INTROSPECTION.md.)

**Dynamic — redirected `core.hooksPath`** (per-workspace, resolved at launch; see §9):
```bash
_extra_hooks="$(_sandy_extra_hooks_dir "<WORK_DIR>")"
[ -n "$_extra_hooks" ] && [ -d "<WORK_DIR>/$_extra_hooks" ] && \
    -v "<WORK_DIR>/$_extra_hooks:<CONTAINER_WORKSPACE>/$_extra_hooks:ro"
```
Mounts the git-consulted hooks directory — the *configured* path, not its canonical target, so a symlinked hooksPath can't be swapped — when it resolves inside the workspace and is neither `.git/hooks`, the workspace root, nor an already-static-protected dir. Not emitted by `--print-protected-paths` (workspace-git-config dependent).

**Submodule gitdir walk** — after the above loops:
```bash
_protect_submodule_gitdirs "<WORK_DIR>/.git/modules" "<CONTAINER_WORKSPACE>/.git/modules"
# When .git is a file (submodule worktree / --separate-git-dir):
[ -d "<GITDIR_HOST>/modules" ] && \
    _protect_submodule_gitdirs "<GITDIR_HOST>/modules" "<GITDIR_CONTAINER>/modules"
```

For each `config` sentinel file found under the root (up to `maxdepth 6`), the helper emits three mounts: `config:ro`, `hooks:ro` (empty fixture if absent), and `info:ro` (only if present). Uses `-print0` and shell-side `dirname` for macOS/BSD portability.

**`$SANDY_HOME/.empty-ro-file`** (zero-byte) and **`$SANDY_HOME/.empty-ro-dir/`** (empty) are created idempotently by `ensure_build_files()` on every launch and live alongside the generated Dockerfiles.

### E.11 Writable Sandbox Overlays

For each of `commands`, `agents`, `plugins`:
```bash
# Only mount if the workspace has .claude/<subdir> OR the sandbox already has data
if [ -d "<WORKSPACE>/.claude/<subdir>" ] || [ -d "<SANDBOX>/workspace-<subdir>" ]; then
    mkdir -p "<SANDBOX>/workspace-<subdir>"
    -v "<SANDBOX>/workspace-<subdir>:<CONTAINER_WORKSPACE>/.claude/<subdir>"
fi
```

This hides host content at these paths and provides a writable overlay from the sandbox.

### E.11a Screenshot Mount (conditional)

If `SANDY_SCREENSHOT_DIR` is set on the host (and passes validation):
```bash
-v "<SANDY_SCREENSHOT_DIR>:/home/sandy/screenshots:ro"
-e "SANDY_SCREENSHOTS_PATH=/home/sandy/screenshots"
```

Read-only by design — the agent must never mutate the host's screenshot folder. The container-side path is fixed (`/home/sandy/screenshots`) so the `/ss` slash command files generated by `user-setup.sh` and the `sandy-ss-paths` helper baked into the base image can hardcode it.

Validation (run at launch, before any `docker run`):
- Reject shell metacharacters (`; $ \` & | < >`).
- Reject literal `$HOME` and `/` after canonicalization (`pwd -P`).
- Missing directory → warn-and-skip (clear `SANDY_SCREENSHOT_DIR`, no mount). Hard-erroring would be noisy; auto-creating the host dir would silently materialize an empty folder where the user expected content.

`SANDY_SCREENSHOT_DIR` has no default. Unset = no mount, no env var, no skill files generated. See §7 step 4a (`user-setup.sh`) for the per-agent skill file generation that runs container-side once the mount is in place.

### E.11a-tz Host Timezone (conditional, 2.4.0, #384)

When the host zone resolves (D.5a):
```bash
-e "TZ=<zone>"      # e.g. America/Denver, or a POSIX rule string
```

A runtime flag, never a build input: the agent image is shared by every sandbox and cached on `BUILD_HASH`, so baking the zone in would force a rebuild after travel or a DST-policy change and carry one host's zone into an image `--rsync` moves elsewhere. Not a config key — the host's own `$TZ` is the override. Emitted in the shared `RUN_FLAGS` assembly after both the foreground (`--rm -it`) and daemon (`-d --restart unless-stopped`) initialisations, so both paths carry it — right after `--network`, **before** the feature-manifest export loop: docker applies repeated `-e` last-wins, so a manifest that `expose`s `TZ` (an operator's explicit choice) wins over the resolved host zone. An operator's `SANDY_EXTRA_ENV=TZ` does not race it either: `_load_sandy_extra_env` exports the value into sandy's own environment, so step 1 of D.5a resolves to it; the `--start` supervisor resolves it in its own process, which inherits the client's environment. The egress proxy container does not get it. Unresolved → no flag, and the container reads UTC as before. Visible effects: `date`, `ls -l`, git's local display, and the tmux status-bar clock follow the host.

### E.11b User-defined Env Passthrough (conditional)

If `SANDY_EXTRA_ENV` is set (privileged tier; comma-separated env-var names):

**The name list composes (2.4.0, #388).** The effective list is the union of every host list (`$SANDY_HOME/config`, then `$SANDY_HOME/.secrets`), every **approved** workspace list (`$WORK_DIR/.sandy/config`, then `$WORK_DIR/.sandy/.secrets`), and an env-set `SANDY_EXTRA_ENV` — deduplicated, each name keeping the position of its first occurrence (host names first, then names the workspace adds, then names the environment adds). An env-set list **adds**; it does not replace — `SANDY_EXTRA_ENV` is the one key where env is not a complete override, because a replacement is exactly the silent drop being fixed. Before 2.4.0 the source loaded last replaced the whole list, so a workspace forwarding one token of its own silently dropped every name the operator forwards host-wide. Approval is unchanged: a workspace's names join the union only once approved (headless/non-TTY drops them, and the host and env names are still forwarded). `_load_sandy_config` records the per-source lists rather than exporting them, the approval step only marks the workspace lists admitted, and `_load_sandy_extra_env` builds the union and exports it as `SANDY_EXTRA_ENV`, so the container's own `SANDY_EXTRA_ENV` names every forwarded name. When more than one source contributes (or under `SANDY_VERBOSE`), the launch prints the effective list and which source named what. `--validate-config` on a workspace file says the names are **added to** the host list.

```bash
# For each name listed:
-e "<NAME>=<VALUE>"
```

Source resolution for each `<VALUE>` (env wins absolutely; among files, last-match-wins iteration in standard precedence order):

```
env  >  $WORK_DIR/.sandy/.secrets  >  $WORK_DIR/.sandy/config
      >  $SANDY_HOME/.secrets        >  $SANDY_HOME/config
```

Workspace sources are consulted for values, matching the standard `_load_sandy_config` precedence (workspace overrides host). The security boundary lives on the *names*: `SANDY_EXTRA_ENV` is privileged-tier, so a workspace setting it triggers the passive-privileged approval prompt. Once a name is approved, the value can come from any of the four files (or env).

**`SANDY_AGENT_ARGS`** (privileged tier, since 1.3.0) and the per-agent operator override **`$SANDBOX_DIR/agent-args.<agent>`** (#per-agent-args): extra CLI arguments appended to the resolved agent command on every launch. After the passive-privileged approval resolves (so an unapproved workspace `SANDY_AGENT_ARGS` value is empty and contributes nothing), the value is tokenized by a shared host-side function, `_sandy_filter_agent_args()`: it normalizes newlines/CRs to spaces (`tr '\n\r' '  '`) so a multi-line file behaves the same as a whitespace-separated config value, then **whitespace-splits** into argv (`read -ra` — never `eval`), dropping `-p`/`--print`/`--prompt` with a warning (headless-mode flags can't work from config/a file — host-side headless detection already ran). The same tokenizer serves both `SANDY_AGENT_ARGS` and an `agent-args.<agent>` file, so there is exactly one filtering path.

As of 2.1.0 (#348) there is a THIRD source: a feature manifest's `agent_args`. It composes differently from the other two — **additive, first, and never suppressible**. The `agent-args.<agent>`-beats-`SANDY_AGENT_ARGS` exclusivity exists because those two are the same actor speaking from two places and sandy discards source attribution at the approval step, so it refuses the ambiguity; a feature is a different actor whose arguments are part of its own wiring, applied unconditionally exactly as its mounts are. Several features compose in sorted slug order, and each feature's tokens are filtered separately so a dropped mode flag can name the feature that supplied it. Final order: sandy's own flags → feature args → operator args → command-line pass-through. Sandy defines the ORDER; PRECEDENCE belongs to the agent's own parser, so this is deliberately not documented as "the operator wins".

**As of 2.3.0 (#363) that rule carries an exception, because it was load-bearing and wrong for part of its range.** It used to justify itself with `claude --mcp-config` being variadic — generalizing one repeatable flag into an assumption about every flag. For a flag the parser reads ONCE, a second occurrence is not precedence, it is DATA LOSS: it silently discards the first contributor, and sandy is the only layer that knows two contributors existed. Measured on Claude Code 2.1.278, `--append-system-prompt-file`, `--append-subagent-system-prompt-file` and `--system-prompt-file` are all last-wins, while `--mcp-config`, `--add-dir`, `--plugin-dir` and `--plugin-dir-no-mcp` carry real collectors.

`_sandy_aa_compose()` therefore runs after the three sources are merged, over the contributor list **with labels**, consulting a small published policy table (`_sandy_aa_compose_table`, surfaced as `--print-schema` → `manifest.agent_args_compose`). At **two or more** contributors of a listed flag:

- `concat` — resolve each container path back to its host source through sandy's own feature mount table (longest destination prefix wins), concatenate in pass order into `$SANDBOX_DIR/agent-args-composed/<agent>.<flag>.md` with a provenance header per section, mount that directory `:ro` at `/opt/sandy/agent-args/`, and rewrite the argv to pass the flag once.
- `report` — the flag replaces rather than appends, so there is no correct merge: warn naming every contributor, and change nothing.
- a value under no mount sandy made is unreadable to it, so the collision is reported and the argv left alone. Fail open on what sandy cannot see; the collision is still proven.

At **one** contributor nothing happens at all and the argv is byte-identical to 2.2.0 — composition engages only where the alternative is a contribution vanishing. The outcome is recorded in the session marker as `agent_args_composed` and surfaced by `--print-state`.

Unlike pre-1.8.0, the result no longer rides a single top-level `set --` prepend onto `"$@"` (that mechanism could only ever apply ONE value to every pane in a multi-agent combo). Instead, once `$SANDBOX_DIR` resolves, sandy loops over the selected agents and resolves ONE value per agent: the `agent-args.<agent>` file if it exists and filters to at least one surviving token, else the filtered `SANDY_AGENT_ARGS` value, else empty. When both a file and a non-empty `SANDY_AGENT_ARGS` exist for the same agent, **the file wins** — never merged — and sandy prints a one-line notice naming the override (source-agnostic, since approval discards whether the surviving `SANDY_AGENT_ARGS` came from workspace, host, or env). The five results are forwarded into the container as five internal env vars, `SANDY_AGENT_ARGS_CLAUDE`/`_GEMINI`/`_CODEX`/`_OPENCODE`/`_GROK` (via plain `-e`, never the secrets channel — these are not secrets) — not config keys, no `_sandy_key_metadata` row, invisible to `--print-schema` and un-settable from any config file.

Container-side, `_sandy_build_agent_cmd` (the single dispatcher every pane's command construction goes through, including all four multi-agent panes) looks up the calling pane's own agent name against those five env vars, `read -ra`-splits the matching value, and **prepends** the resulting tokens onto that pane's own `"${@:2}"` immediately before dispatch — preserving the exact ordering the old top-level prepend gave (sandy flags → config/file tokens → CLI pass-through args), since `build_claude_cmd` scans its own `"$@"` for `--continue`/`--resume` and codex/opencode scan for headless-subcommand selection, and every builder still emits `_sandy_translate_args` last for the actual `%q` quoting (one quoting path, unchanged). The `claude --remote` branch bypasses `_sandy_build_agent_cmd` entirely (it hand-assembles `AGENT_CMD`), so it separately prepends its own `SANDY_AGENT_ARGS_CLAUDE` tokens using the same `read -ra` + its own existing `%q` loop. It is deliberately **not** added to the `--start` re-exec argv as a *second* injection — the `--start` supervisor re-enters the full normal launch flow (config load → the per-agent resolution above → env-forward), so no double application and no extra plumbing. v1 limitation: no embedded-space/quoted-arg support (a value is split on runs of whitespace); `schema_version` stays `1` (additive).

Validation rules:
- Names must match `^[A-Z_][A-Z0-9_]*$` (POSIX env-var convention) — invalid names are skipped with a warning.
- Names that collide with `SANDY_PRIVILEGED_KEYS` or `SANDY_PASSIVE_KEYS` are skipped (those have their own typed path).
- A listed name with no value anywhere produces a launch-time warning, not a failure (the user may have intended a per-host or shell-defined value that's currently absent on this machine).

Use case: tokens for user-installed MCP servers / agent tooling that sandy doesn't know about (Home Assistant API, internal corp APIs, etc.). Without this, users would have to hardcode tokens in `<workspace>/.mcp.json` (less secret-management-friendly) or fork the sandy script.

### E.12 Persistent Package Mounts

```bash
-v "<SANDBOX>/pip:<HOME>/.pip-packages"
-v "<SANDBOX>/uv:<HOME>/.local/share/uv"
-v "<SANDBOX>/npm-global:<HOME>/.npm-global"
-v "<SANDBOX>/go:<HOME>/go"
-v "<SANDBOX>/cargo:<HOME>/.cargo"
```

If `gstack` is in `SANDY_SKILL_PACKS`:
```bash
-v "<WORKSPACE>/.gstack:<HOME>/.gstack"
```
Note: gstack mounts from the **workspace**, not the sandbox — see §6 "Workspace State (gstack)" for rationale and the one-shot migration from the legacy `<SANDBOX>/gstack/` location.

### E.12a Feature entry state mounts (conditional on one or more entries this launch; 2.2.0 #353, every entry made identical 2.6.0 #382 decisions 4-5)

```bash
-e "SANDY_FEATURE_ENTRIES=<feature1>=<container path> <feature2>=<container path> ..."
-v "<SANDBOX>/feature-state/<feature1>:/opt/sandy/feature-state/<feature1>"
-v "<SANDBOX>/feature-state/<feature2>:/opt/sandy/feature-state/<feature2>"
```

One `-e` naming the full adopted list, plus one `-v` per adopted entry — all
identical in shape, since 2.6.0 there is no longer a "relay-designated" entry
that gets a different mount, a different env var, or a second mount of the
same directory. Emitted only when `_sandy_fe_list` is non-empty once the
host-side non-start skip block (below) has run; with **zero** entries none of
this runs and zero `RUN_FLAGS` are emitted for it. `SANDY_HANDOFF_RELAY` and
`SANDY_RELAY_STATE` are **never** emitted, exported, or read anywhere in this
path any more — see the removed-mechanism note below.

Each entry's path comes from a feature manifest `entry` selected for this
sandbox (`$SANDY_HOME/features/<name>/feature.json`, `"entry":
"payload/<file>"`), which the host resolves to
`/opt/sandy/features/<name>/<file>`. `<SANDBOX>/feature-state/<feature>/` is
created host-side (`mkdir -p`) for **every** adopted entry, uniformly, before
`RUN_FLAGS` is assembled — see "Host-side launch assembly for feature
entries" in E.16. The mount is **rw** because the supervisor writes `.state`,
`.startup` and `supervisor.log` there — which means the agent can write them
too, so they are diagnostics, never a trust signal. It lives under
`/opt/sandy`, sandy's own in-container namespace, not the agent home: these
are sandy's supervisor's files, not the entry's, and `~/.sandy` in-container
would read as the host config root. An entry finds its own directory by
reading `SANDY_FEATURE_STATE` (exported to that entry's own process only),
never by constructing the path.

> **Removed in 2.2.0: the `~/.handoff` tree.** Until then this section mounted
> `<SANDBOX>/handoff/{outbox,inbox,peer,relay}` at `/home/sandy/.handoff/…`
> under `SANDY_HANDOFF_DIRS` (default on since 1.10.0), with a
> `$SANDBOX_DIR/.handoff-enabled` override marker and a `~/.handoff`
> workspace-collision guard. #352 removed the `inbox`/`outbox`/`peer` lanes
> and their `SANDY_HANDOFF_INBOX`/`_OUTBOX`/`_PEER` env vars, #353 moved relay
> state here, and #355 removed the rest: the directory, the key (setting
> `SANDY_HANDOFF_DIRS` is now a hard error naming the replacement), the marker
> and the `handoff{}`/`handoff_enabled` reporting. A feature that needs
> directories declares them as manifest `mounts` (`mode: ro` for a
> host-written inbound lane); see `docs/design/FEATURE-MANIFEST.md`.

> **Removed in 2.6.0 (#382, decisions 4-5): `relay-state/`, the shared
> directory of the single "relay-designated" entry, and the `SANDY_RELAY_STATE`
> / `SANDY_HANDOFF_RELAY` variables that named it.** Through 2.5.x, the first
> entry adopted (sorted feature-directory order) used
> `<SANDBOX>/relay-state` — mounted at **both**
> `/opt/sandy/relay-state` and `/opt/sandy/feature-state/<feature>` — while
> `SANDY_HANDOFF_RELAY` carried its container path as the internal channel and
> `SANDY_RELAY_STATE` named its directory. 2.6.0 removed the designation
> entirely: every entry now uses its own `feature-state/<feature>`
> identically, as described above. A leftover `<SANDBOX>/relay-state/` from a
> pre-2.6.0 sandbox is **removed** the next time that sandbox launches — `rm
> -rf --` (a symlink is unlinked, never followed), one `info` line naming the
> removal — rather than migrated into a feature-state directory, since the
> designation it tracked no longer exists. Nothing recreates it. This block
> runs after the approval pre-pass exit and under the workspace lock with the
> busy-gate already passed, so no running container ever has it mounted when
> it runs.

**Fail-the-launch rule (acceptance criterion 7) and the three skips (criterion 8).**
There is no host-side path-shaped validation of entry paths any more — the
metacharacter/whitespace/`..`/host-existence checks this section used to
describe (against a workspace-relative or workspace-absolute
`SANDY_HANDOFF_RELAY`) are gone along with the internal channel they
validated. What replaces them: a manifest entry's path is already constrained
at the **source** by `_sandy_fm_valid_relpath`/`_sandy_fm_valid_segment`
([A-Za-z0-9._-] segments only, no `..`), and is always an absolute path under
`/opt/sandy/features/<feature>/<file>` — never a workspace-relative or
workspace-absolute one the host would need to resolve. The container
independently re-validates every `SANDY_FEATURE_ENTRIES` token
(`*[!A-Za-z0-9._/=-]*`) before using it. The in-container
`_sandy_supervise_entry` (Appendix A.6, 2.4.0 #381 — one instance per entry,
not one function total, and since 2.6.0 identical for every entry) is
therefore the **sole** detection point for a configured entry that cannot
start (a missing or non-executable in-container path, an unmounted state
directory, no `flock` binary, or an entry whose first run exits non-zero
within 5s): it `exit 1`s and the container dies before any tmux session
exists — `--start` classifies the container as crash-looping, exit `7`, and
dumps the container log tail. The option of silently dropping an entry that
cannot start rather than failing the launch was considered and rejected — it
would keep the launch alive with a supervised entry the launch claimed to run
silently absent, and it would make a `feature_entries` member in the marker
ambiguous with an entry that was never configured at all (this rule is
unconditional and does not depend on what `crossSessionInbound` resolves to —
see §C.2a, decision 6).

Three cases are deliberate **skips**, not failures: headless
(`-p`/`--print`/`--prompt`), `sandy --remote` (no tmux session for any entry
to target) and `--provision` (a launch stopped as soon as it is verified, so
an entry would live seconds and deliver nothing). This is the block now
headed `# BEGIN feature entries: non-start cases` / `# END feature entries:
non-start cases` (renamed from `# BEGIN/END handoff relay` in 2.6.0, #382 —
three EVAL-span consumers in `run-tests.sh`, §142/§159/§173, re-anchor their
end to the new header). For a non-empty `_sandy_fe_list` under any of the
three, sandy logs `feature entries not started (<reason>): <feature1>,
<feature2>, ...` — naming **every** adopted entry, comma-separated — and
clears both `_sandy_fe_list` and `SANDY_FEATURE_ENTRIES`, so none of the E.12a
flags above is emitted, the conditional default in §C.2a resolves to
`refuse`, and the marker's `feature_entries` reports `{}`. There is no
host-side path check left to run before this skip decision, since none
exists any more.

### E.13 Sandbox Mount

The sandbox directory itself becomes `~/.claude` inside the container:
```bash
-v "<SANDBOX_DIR>:/home/sandy/.claude"
```

### E.13a Seed `settings.json` (conditional on `claude` agent)

As of 0.11.3, there is no child overlay on `settings.json`. The file lives at `<SANDBOX_DIR>/claude/settings.json` inside the rw sandbox mount (E.13) and is regenerated host-side by the pre-launch seed step (§4 Seeding) every launch. The regeneration re-reads the host `~/.claude/settings.json`, overlays sandy defaults and marketplaces, and preserves `enabledPlugins` from the previous sandbox session. No additional mount flag is emitted.

Rationale: the pre-0.11.3 approach used a `:ro` child overlay (`<SANDBOX_DIR>/.seed-settings.json → /home/sandy/.claude/settings.json:ro`), but that caused `/plugin install` to fail with EROFS because Claude Code writes the plugin list to `settings.json` at install time. The merge-preserving rw approach trades strict F6 reset-on-launch for functional plugin installs, while still guaranteeing sandy-managed keys are re-overwritten every launch.

### E.14 SSH Mounts (conditional on `SANDY_SSH`)

**Token mode** (`SANDY_SSH=token`): No SSH mounts. Git token passed via environment variable.

**Agent mode** (`SANDY_SSH=agent`):

Linux:
```bash
-v "<SSH_AUTH_SOCK>:/tmp/ssh-agent.sock"
-e "SSH_AUTH_SOCK=/tmp/ssh-agent.sock"
```

macOS: Port passed via environment variable (relay handled by entrypoint):
```bash
-e "SSH_RELAY_PORT=<port>"
```

Both platforms (if `~/.ssh` exists):
```bash
-v "$HOME/.ssh:/tmp/host-ssh:ro"
```

If `~/.ssh/known_hosts` exists (mounted separately for token mode too):
```bash
-v "$HOME/.ssh/known_hosts:/tmp/host-ssh-known_hosts:ro"
```

### E.15 UID/GID Remapping (conditional)

If host UID ≠ 1001:
```bash
-e "HOST_UID=<uid>"
-e "HOST_GID=<gid>"
-v "<SANDY_HOME>/passwd:/etc/passwd:ro"
-v "<SANDY_HOME>/group:/etc/group:ro"
```

The passwd/group files are generated by sed:
```bash
sed "s/^claude:x:1001:1001:/claude:x:${HOST_UID}:${HOST_GID}:/" /etc/passwd > passwd
sed "s/^claude:x:1001:/claude:x:${HOST_GID}:/" /etc/group > group
```

### E.16 Environment Variables

All passed via `-e KEY=VALUE`:

```bash
# Workspace identity
SANDY_WORKSPACE=<container_path>
SANDY_PROJECT_NAME=<basename>

# Claude Code config
SANDY_MODEL=<model>
SANDY_SKIP_PERMISSIONS=<true|false>
SANDY_NEW_SESSION=<true|false>
SANDY_REMOTE_CONTROL=<true|false>
SANDY_VERBOSE=<0-3>
CLAUDE_CODE_MAX_OUTPUT_TOKENS=<128000>

# Channels (if configured)
SANDY_CHANNELS=<channel_spec>
TELEGRAM_BOT_TOKEN=<token>
TELEGRAM_ALLOWED_SENDERS=<ids>
DISCORD_BOT_TOKEN=<token>
DISCORD_ALLOWED_SENDERS=<ids>

# Git identity (auto-detected from host git config if not set)
GIT_USER_NAME=<name>
GIT_USER_EMAIL=<email>
SANDY_SSH=<token|agent>
GIT_TOKEN=<token>          # token mode only
GH_ACCOUNTS=<user1:tok1,user2:tok2>  # all gh-authenticated accounts

# Claude credentials (OAuth-first since 0.15.2; block gated on claude ∈ agent set):
#   CLAUDE_CODE_OAUTH_TOKEN set → forward ONLY the token; ANTHROPIC_API_KEY is
#                                 suppressed entirely (launch warning if both set)
#   OAuth credentials MOUNTED   → also suppress ANTHROPIC_API_KEY (it resolves
#                                 ahead of the account credentials; an unapproved
#                                 key parks the session on the startup modal)
#   SANDY_CLAUDE_AUTH=profile   → forward NEITHER; the mounted Console profile is
#                                 the only credential (Claude Code ranks a profile
#                                 below /login and below every env credential)
#   neither                     → forward ANTHROPIC_API_KEY only if non-empty, plus
#                                 CLAUDE_CODE_OAUTH_TOKEN= (emptied vs host-env leak)
CLAUDE_CODE_OAUTH_TOKEN=<token>     # or ANTHROPIC_API_KEY=<key> — never both

# Agent teams (if configured)
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=<0|1>

# System
HOST_UID=<uid>
HOST_GID=<gid>
SANDY_AGENT=<agent[,agent…]>        # resolved agent selection (drives entrypoint pane layout)
SANDY_EGRESS_MODE=<off|permissive|strict>  # posture introspection — forwarded in ALL modes (informational)
TZ=<zone>                           # host timezone, only when one resolves (2.4.0, #384; E.11a-tz, D.5a)
SANDY_FEATURE_ENTRIES=<feature1>=<path> <feature2>=<path> ...  # the full adopted list, one token per entry, only when one or more entries start this launch (E.12a)

# Per-agent operator launch args (#per-agent-args, since 1.8.0). Internal
# channel — not a config key, no _sandy_key_metadata row, never settable from
# a config file. Resolved host-side from SANDY_AGENT_ARGS and/or an operator
# $SANDBOX_DIR/agent-args.<agent> file (file wins per agent, never merged);
# empty string when that agent has neither. _sandy_build_agent_cmd (container-
# side) prepends the calling pane's own value onto that pane's argv before
# dispatch, so each agent in a multi-agent combo sees only its own tokens.
SANDY_AGENT_ARGS_CLAUDE=<tokens|"">
SANDY_AGENT_ARGS_GEMINI=<tokens|"">
SANDY_AGENT_ARGS_CODEX=<tokens|"">
SANDY_AGENT_ARGS_OPENCODE=<tokens|"">
SANDY_AGENT_ARGS_GROK=<tokens|"">
```

`DISABLE_AUTOUPDATER=1` and `FORCE_AUTOUPDATE_PLUGINS=true` are exported by the **entrypoint** inside the container, not passed via docker `-e`.

Git identity fallback: if `GIT_USER_NAME`/`GIT_USER_EMAIL` are not set via config, they are read from the host's `git config user.name` and `git config user.email`.

**Gemini-specific env** (whenever `gemini` is in `SANDY_AGENT`):
```bash
GEMINI_API_KEY=<key>                # if set
GEMINI_MODEL=<model>                # if set
SANDY_GEMINI_AUTH=<auto|api_key|oauth|adc>
GEMINI_SANDBOX=false                # gemini's own sandbox off — sandy provides isolation
GOOGLE_CLOUD_PROJECT=<proj>         # Vertex AI
GOOGLE_CLOUD_LOCATION=<region>
GOOGLE_GENAI_USE_VERTEXAI=<true>
GOOGLE_API_KEY=<key>
GOOGLE_APPLICATION_CREDENTIALS=/home/sandy/.config/gcloud/application_default_credentials.json  # adc mode
GEMINI_CLI_SYSTEM_SETTINGS_PATH=/etc/sandy-gemini/effort.json  # only when SANDY_EFFORT is set (2.7.0, #116; B.10)
```

When `SANDY_EFFORT` is set and gemini is selected, sandy also mounts `$SANDBOX_DIR/gemini-system-settings.json` → `/etc/sandy-gemini/effort.json:ro` — generated host-side every launch (removed on a launch where it does not apply), at the sandbox **top level**, never under the agent-writable `gemini/` (`~/.gemini`); a symlink at the path is removed and named, and the write is `mktemp` + `mv`. Content and rationale: Appendix B.10.

**Codex-specific env** (`SANDY_AGENT=codex`):
```bash
OPENAI_API_KEY=<key>                # if set
CODEX_MODEL=<model>                 # if set
SANDY_CODEX_AUTH=<auto|api_key|oauth>
```

`CODEX_HOME` is **not** a sandy config key and is never forwarded — sandy owns the in-container path (`/home/sandy/.codex`) via the sandbox mount, and overriding it would break the mount. (Removed from the passive allowlist in the PR 4.1 surface audit, where it was found declared-but-never-consumed.)

**Codex-specific mounts** (`SANDY_AGENT=codex`):
```bash
-v "$SANDBOX_DIR/codex:/home/sandy/.codex"
# if OAuth path active:
-v "$CODEX_CRED_TMPDIR/auth.json:/home/sandy/.codex/auth.json:ro"
```

The codex sandbox dir is writable (codex needs `log/`, `memories/`, session rollouts, sqlite state), but the `auth.json` file inside it is shadowed by a read-only overlay bind when either auth path is active (OAuth copy or api-key materialization — see C.7c). See §11 for the rationale of the read-only overlay.

**OpenCode-specific env** (whenever `opencode` is in `SANDY_AGENT`):
```bash
OPENCODE_MODEL=<model>              # if set
SANDY_OPENCODE_AUTH=<auto|api_key|oauth>
SANDY_LOCAL_LLM_HOST=<host:port>    # if set (local-LLM passthrough — proxy forward listener / iptables hole)
# Provider keys forwarded natively for opencode's provider-agnostic auth (each only if set):
ANTHROPIC_API_KEY=<key>
OPENAI_API_KEY=<key>
GEMINI_API_KEY=<key>
```
OpenCode mounts: `$SANDBOX_DIR/opencode/config` → `~/.config/opencode` and `$SANDBOX_DIR/opencode/share` → `~/.local/share/opencode`; the OAuth path additionally mounts host `~/.local/share/opencode/auth.json` read-only when present.

**Host-side launch assembly for feature entries (RUN_FLAGS, 2.4.0 #381; every entry made identical 2.6.0 #382 decisions 4-5).** When `_sandy_fe_list` is non-empty (one or more entries were adopted), sandy emits, in this order:

```bash
-e "SANDY_FEATURE_ENTRIES=$_sandy_fe_list"      # every ADOPTED entry, "<feature>=<path> ..."
# then, once per entry in $_sandy_fe_list:
-v "$SANDBOX_DIR/feature-state/<feature>:/opt/sandy/feature-state/<feature>"
```

`-e SANDY_FEATURE_ENTRIES` carries the **full** adopted list (D5) so the container-side supervisor (`_sandy_start_entries`) can start and report every one. Each entry gets its own `-v` mount at `/opt/sandy/feature-state/<feature>`, sourced from `$SANDBOX_DIR/feature-state/<feature>` — created host-side (`mkdir -p`) for **every** adopted entry, identically, before `RUN_FLAGS` is assembled — never a `relay-state` source of any kind. There is no longer a designated entry that gets a second mount of a shared directory: since 2.6.0 each entry's mount is a distinct host directory. None of these mount targets collide with the `:ro` feature payload at `/opt/sandy/features/<feature>` — a different tree entirely. With **zero** entries (or the criterion-8 skip having already cleared `_sandy_fe_list`), none of this block runs and zero `RUN_FLAGS` are emitted for it — the E.12a zero-diff invariant. With **exactly one** entry the block still runs in full but emits only ONE `-e` and ONE `-v`, both naming that entry — never a second line, and never a `relay-state` mount.

**Per-feature entry derived env** (1.10.0, generalized 2.4.0 #381, every entry made identical 2.6.0 #382 decisions 4-5). `SANDY_FEATURE_STATE` is container-side only — set inside `_sandy_supervise_entry`'s own subshell in `user-setup.sh`, never passed via docker `-e`. **Every** entry's own child process sees `SANDY_FEATURE_STATE` set to `/opt/sandy/feature-state/<feature>`, exported **inside that entry's own subshell only** (never the parent shell, the tmux server, any agent pane, or any other entry's process) — identically for every entry, since there is no longer a designated one whose process is exported into the parent shell. `SANDY_RELAY_STATE` and `SANDY_HANDOFF_RELAY` are **never** exported to any process any more (2.6.0, #382 decisions 4-5); the pre-#382 legacy fallback path this paragraph used to describe (a lone `SANDY_HANDOFF_RELAY` forwarded with no `SANDY_FEATURE_ENTRIES`) is also gone — such a launcher now starts nothing (E.12a). `SANDY_FEATURE_STATE` plus the ambient `SANDY_AGENT`/`SANDY_WORKSPACE`, anything its feature manifest `export`s, and the rest of the container's inherited environment (including `CLAUDE_CODE_OAUTH_TOKEN` if present — see `docs/security/CROSS_SESSION_INBOUND.md` §8). **Removed in 2.2.0**: `SANDY_HANDOFF_INBOX`, `SANDY_HANDOFF_OUTBOX` and `SANDY_HANDOFF_PEER` (#352, with the lanes they named) and `SANDY_HANDOFF_RELAY_STATE` (#353, replaced by `SANDY_RELAY_STATE`, itself removed in 2.6.0 above). Through 2.5.x, a relay wanting to enumerate live sessions ran sandy's own `/usr/local/bin/sandy-handoff-sessions` rather than parsing `~/.claude/sessions/` itself; that helper was removed in 2.6.0 (#382, decision 7) — see "Pane-identity contract" above for what a replacement is built on.

### E.16a Self-Attestation Marker (all modes)

Immediately after forwarding `SANDY_EGRESS_MODE`, sandy writes a marker file and mounts it read-only:

```bash
_sandy_egress_mode=<off|permissive|strict>        # captured once, reused for the env var + marker
_sandy_session_nonce=$(openssl rand -hex 16 || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
printf '{...}' > "$SANDBOX_DIR/sandy-session.json"  # schema in Appendix C.9
RUN_FLAGS+=(-v "$SANDBOX_DIR/sandy-session.json:/etc/sandy-session.json:ro)
```

The nonce is printed host-side only under `SANDY_VERBOSE!=0` and is **not** exported as an env var — the read-only file is the trust root. This is the one authoritative in-container signal of "running inside sandy, at egress mode X." Rationale in `CLAUDE.md` → *Self-Attestation Marker*.

### E.17 Final Command

```bash
docker run "${RUN_FLAGS[@]}" <IMAGE_NAME> "${REMAINING_ARGS[@]}"
```

Where `<IMAGE_NAME>` is the most-derived image in the build chain:
- `sandy-project-<name>-<hash>` if Phase 3 exists
- `sandy-skills-<packs>` if skill packs enabled
- `sandy-claude-code` otherwise
