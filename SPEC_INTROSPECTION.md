# Sandy Introspection Specification

**Status**: Draft
**Target**: sandy 0.12.0 (new minor — introduces a public schema contract)
**Author**: Design doc for `sandy-ui` integration
**Related**: [SPEC_SANDY_UI.md](SPEC_SANDY_UI.md)

## Motivation

Sandy's configuration surface — CLI flags, config keys, env vars, protected-path lists, agent capabilities — is currently spread across:

- Case statements in `_load_sandy_config` (sandy:1710-1790ish)
- Arg parsing blocks scattered near the top of the script
- `_sandy_protected_files` / `_sandy_protected_dirs` heredocs
- Prose in `CLAUDE.md` and `SPECIFICATION.md`
- Magic constants (`SANDY_SANDBOX_MIN_COMPAT`, `SKILL_PACK_*` arrays)

External consumers — most immediately `sandy-ui`, but also editor integrations, shell completions, CI linters — need a **stable, machine-readable contract** so they don't go stale on every sandy release. Today those consumers would have to scrape the bash source or maintain a parallel copy of the allowlist; both options rot fast and silently.

This spec defines a JSON introspection surface emitted by sandy itself as the single source of truth.

## Goals

- **Single source of truth**: one JSON blob describes every user-facing knob sandy exposes. The bash script becomes the authoritative producer; no separate `.proto` / `.yaml` / `schema.json` file to keep in sync.
- **Stable contract**: `schema_version` enables tools to pin a known-good version; additive changes don't break clients.
- **Low maintenance burden**: the schema is generated from existing bash constants where practical (not a hand-maintained duplicate).
- **Introspectable runtime state**: separate from the static schema, surface information about the current user's install — existing sandboxes, pending approvals, lock files, installed agents.
- **Testable**: the test suite verifies the schema stays in lockstep with the implementation (no drift).

## Non-goals

- Not a replacement for `SPECIFICATION.md` or `CLAUDE.md` — those explain *why*; the schema states *what*.
- Not a long-running API (no daemon, no RPC server) — one-shot command output only.
- Not a config *loader* for third parties — external tools should still invoke `sandy` for actual runs, not reimplement the loader.
- Not a remote API — introspection is always local to the machine running sandy.
- Not a generic schema framework (no JSON Schema Draft validation, no OpenAPI) — just "here's the shape".

## Invocation

Four flags added to sandy's existing flat CLI (matching the `--print-protected-paths` debug flag that already exists — `--print-version` joined the other three in 1.7.0, #159):

| Flag | Purpose | Reads | Writes |
|---|---|---|---|
| `--print-schema` | Static schema: config keys, flags, agents, paths | nothing on disk | stdout |
| `--print-state` | Runtime state: sandboxes, approvals, locks | `$SANDY_HOME/` | stdout |
| `--validate-config PATH` | Check a config file against the schema | the path given | stdout + exit code |
| `--print-version` | Machine-readable version probe (`schema_version`, `version`, `commit`, `full_version`) | nothing on disk | stdout |

All four:
- Emit exactly one JSON document to stdout; diagnostics go to stderr only. See "Stream contract (guaranteed, 1.7.0)" below for the precise, test-pinned guarantee.
- Are non-interactive (no TTY required, no prompts)
- Exit 0 on success, non-zero on schema load / validation failure
- Suppress `[sandy] ...` log lines (logging goes to stderr regardless)
- Work without Docker running (for `--print-schema`) — pure script introspection

### Stream contract (guaranteed, 1.7.0)

As of 1.7.0, sandy guarantees a stronger, test-pinned contract for these four flags (#160, extended to `--print-version` by #159): **exactly one JSON document on stdout and nothing else** — including in JSON-shaped failure cases. Concretely:

- `--print-schema`, `--print-state` (both modes), and `--print-version` always write exactly one JSON document to stdout and zero bytes to stderr, on every exercised code path.
- `--validate-config PATH` on a resolvable invocation (the file exists or does not; the key set is valid, unknown, or requires approval) writes exactly one JSON document to stdout and zero bytes to stderr, with the outcome encoded in the JSON body (`errors[]`, `warnings[]`, `approval_status`) and the exit code — including the file-not-found case, which exits 1 WITH a JSON body naming the failure in `errors[]`, not a bare stderr message.
### Daemon exit codes: no code observed is not a verdict (#157)

`--attach`'s exit codes (`0`/`3`/`4`) are *evidence-backed* — sandy discards `tmux attach`'s return value and re-derives the answer by probing live state afterward. If the sandy process is killed by a signal (typically `SIGHUP` from a pty teardown when an editor closes a terminal), that probe never runs and a supervising parent observes **no exit code at all** (`code === null`).

**That state carries no information about the session.** It means the decision procedure did not execute — not that the attach or the session failed — and it must not be mapped onto `5`. Under D9 the durable session is owned by the running labeled container, and a killed *local client* says nothing about it.

Consumers should **reconcile against `--print-state`**, or simply re-run `--attach` (which returns `4` if the session is genuinely gone), rather than infer liveness from a missing code. Sandy deliberately declines to guess: reporting "the session survived" without probing would be an unverified claim.

(`5` is additionally unreachable on the `--attach` path today — both `exit 5` sites are in `--stop` — so treating an unknown state as "attach failed" maps it onto a code `--attach` never emits.)

- Only the **usage-error** case — `--validate-config` invoked with no PATH argument at all — departs from the JSON contract: stdout is exactly 0 bytes, stderr is non-empty and carries a `[sandy] ERROR: ...` line, and the exit code is 1. This is the one case where there is no path to validate, so there is nothing to build a JSON body around.
- Consumers may therefore pipe the stdout of any of these four invocations directly into a strict JSON parser (`json.load`, `jq -e`) without pre-filtering: a parse failure signals a genuine sandy bug, not an expected log line sharing the stream.

**Implementation rule.** Introspection handlers (`_sandy_emit_schema`, `_sandy_emit_state`, `_sandy_validate_config`, `_sandy_emit_version`, and their fast-path dispatchers) must never call `info()` or `warn()` — both are stdout writers by design (sandy:291-292; only `error()` redirects to stderr, sandy:293) — and may only call `error()` for the usage-error case above. A future `info`/`warn` call added inside one of these handlers would corrupt the "pure JSON" guarantee without a single byte landing on stderr to hint at it; see the two-sided (stdout-purity AND stderr-emptiness) assertions in `test/run-tests.sh` §92, which pin exactly this (case (h) covers `--print-version`).

**Honest bound.** This contract covers only bytes sandy itself writes to file descriptors 1 and 2 inside the handler. It says nothing about what an inherited fd 1 already carries before sandy's `printf`s run — e.g. a login shell's prompt hook (PS1/PROMPT_COMMAND) that emits an OSC terminal-title escape sequence on every command, which lands on the same stdout a consumer captures if sandy is invoked from an interactive shell with such a hook installed. That failure mode motivated this section but is out of sandy's control — pipe sandy's introspection flags from a plain, hook-free shell (or a script) for a stream a strict parser can trust. See `test/run-tests.sh` §91 (parser↔cli_flags lockstep), §92 (this stream contract), and §93 (`--print-version`-specific composition/identity guarantees, #159) for the pinned assertions.

### Discoverability

`sandy --help` gains a "Introspection" section listing the four flags. **`sandy --version` / `-v` has a guaranteed, test-pinned format as of 1.7.0 (#159):** its stdout is exactly `sandy <full_version>`, byte-for-byte, where `<full_version>` is the same string `--print-version` reports as `full_version`. This is deliberate — `--version` is the one introspection surface a *pre-1.7.0* sandy also understands (the main parser's catch-all forwards any other unrecognized flag, including `--print-version` itself, straight through to the wrapped agent rather than erroring), so it is the safe probe a consumer uses to detect "is this sandy 1.7.0+" before ever calling `--print-version`. `test/run-tests.sh` §93(2) pins this identity byte-for-byte.

## Output format

### `--print-schema`

```json
{
  "schema_version": 1,
  "sandy": {
    "version": "0.12.0",
    "commit": "abc1234",
    "sandbox_min_compat": "0.7.10"
  },
  "config": {
    "privileged_keys": [
      {
        "name": "SANDY_SSH",
        "type": "enum",
        "choices": ["token", "agent"],
        "default": "token",
        "since": "0.1.0",
        "stability": "stable",
        "description": "SSH authentication mode for git. 'token' uses gh CLI (HTTPS); 'agent' forwards the host SSH agent into the container.",
        "sources": ["home_config", "home_secrets", "env"],
        "passive_approval_required": true
      },
      {
        "name": "ANTHROPIC_API_KEY",
        "type": "secret",
        "description": "Anthropic API key for Claude Code. Not required when using Claude Max OAuth.",
        "sources": ["home_config", "home_secrets", "env"],
        "passive_approval_required": true
      }
    ],
    "passive_keys": [
      {
        "name": "SANDY_MODEL",
        "type": "string",
        "pattern": "^[a-zA-Z0-9._-]+$",
        "default": "claude-opus-5",
        "description": "Model ID for the Claude agent.",
        "sources": ["home_config", "workspace_config", "env"]
      },
      {
        "name": "SANDY_CPUS",
        "type": "int",
        "min": 1,
        "default": 2,
        "sources": ["home_config", "workspace_config", "env"]
      },
      {
        "name": "SANDY_AGENT",
        "type": "agent_combo",
        "default": "claude",
        "description": "Comma-separated agent list. 'all' is an alias for 'claude,gemini,codex,opencode'.",
        "sources": ["home_config", "workspace_config", "env"]
      }
    ],
    "env_only_keys": [
      {
        "name": "SANDY_AUTO_APPROVE_PRIVILEGED",
        "type": "bool",
        "description": "Bypass the passive-privileged approval prompt. Intended for CI / test harnesses only.",
        "sources": ["env"]
      },
      {
        "name": "SANDY_DEBUG_CLEANUP",
        "type": "bool",
        "description": "Print session-stub cleanup diagnostics on exit.",
        "sources": ["env"]
      }
    ]
  },
  "cli_flags": [
    {
      "name": "--rebuild",
      "type": "flag",
      "description": "Force rebuild of sandy images.",
      "conflicts_with": []
    },
    {
      "name": "--print",
      "short": "-p",
      "type": "string",
      "arg_name": "PROMPT",
      "description": "Headless / one-shot mode. Pass the prompt as the argument.",
      "conflicts_with": ["--continue"]
    },
    {
      "name": "--continue",
      "short": "-c",
      "type": "flag",
      "description": "Resume the most recent Claude session (claude agent only).",
      "conflicts_with": ["--print"]
    },
    {
      "name": "--remote",
      "type": "flag",
      "description": "Run as a remote-controlled session (claude agent only).",
      "agents": ["claude"]
    }
  ],
  "agents": [
    {
      "name": "claude",
      "image": "sandy-claude-code",
      "features": ["skills", "channels_telegram", "channels_discord", "remote", "synthkit"],
      "credentials": {
        "probe_order": ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "host_credentials_file"]
      }
    },
    {
      "name": "gemini",
      "image": "sandy-gemini-cli",
      "features": ["synthkit_toml", "extensions"],
      "credentials": {
        "probe_order": ["GEMINI_API_KEY", "host_tokens_json", "host_adc"]
      }
    },
    {
      "name": "codex",
      "image": "sandy-codex",
      "features": ["skills_context"],
      "credentials": {
        "probe_order": ["OPENAI_API_KEY", "host_auth_json"]
      }
    },
    {
      "name": "opencode",
      "image": "sandy-opencode",
      "features": ["local_llm_passthrough", "provider_choice"],
      "credentials": {
        "probe_order": ["provider_env_keys", "host_auth_json"]
      }
    }
  ],
  "protected_paths": {
    "files": [".bashrc", ".bash_profile", ".zshrc", ".envrc", ".npmrc", "..."],
    "git_files": [".git/config", ".gitmodules", ".git/HEAD", ".git/packed-refs"],
    "dirs_always_mount": [".git/hooks", ".git/info", ".vscode", ".idea", ".circleci", ".devcontainer", ".github/workflows"],
    "dirs_workflow_edit_conditional": [".github/workflows"]
  },
  "skill_packs": [
    {
      "name": "gstack",
      "repo": "garrytan/gstack",
      "description": "28 Claude Code skills (QA, review, ship, browse) + headless Chromium"
    }
  ],
  "compatibility": {
    "current_schema_version": 1,
    "supported_schema_versions": [1],
    "deprecated_schema_versions": []
  }
}
```

> **Field-name note:** `protected_paths.dirs_always_mount` is a historical
> *name* kept for schema stability (`schema_version` 1). Semantics since 0.13:
> these directories are **existence-gated** — bind-mounted `:ro` only when
> present on the host, with session-end detection covering absent paths. Only
> the name is stale; a rename would be a breaking schema change and waits for
> `schema_version` 2.

### `--print-state`

```json
{
  "schema_version": 1,
  "sandy_home": "/Users/drapp/.sandy",
  "host_id": "drapp-mbp",
  "host_id_source": "hostname",
  "installed_images": [
    { "name": "sandy-base", "id": "sha256:abc...", "created": "2026-04-15T..." },
    { "name": "sandy-claude-code", "id": "sha256:def...", "created": "2026-04-15T..." }
  ],
  "sandboxes": [
    {
      "name": "zork-3dfda686",
      "path": "/Users/drapp/.sandy/sandboxes/zork-3dfda686",
      "workspace_path": "/Users/drapp/dev/foo/zork",
      "workspace_exists": true,
      "created_version": "0.11.2",
      "last_used_version": "0.11.4",
      "created_at": "2026-04-15T10:00:00Z",
      "last_used_at": "2026-04-20T14:45:00Z",
      "size_bytes": 123456789,
      "lock_held": false,
      "lock_holder_pid": null,
      "lock_holder_alive": null
    }
  ],
  "approvals": [
    {
      "workspace_hash": "abc123...",
      "workspace_path_hint": "/Users/drapp/dev/foo/zork",
      "approved_keys_sha256": "def456...",
      "approved_at": "2026-04-15T10:00:00Z"
    }
  ],
  "running_containers": [
    {
      "id": "abc123",
      "name": "sandy-zork-3dfda686",
      "image": "sandy-full",
      "started_at": "2026-04-20T14:00:00Z",
      "sandbox": "zork-3dfda686",
      "daemon": true,
      "attached_clients": 1,
      "image_stale": false,
      "updated_at": "2026-04-20T13:30:00Z"
    },
    {
      "id": "def456",
      "name": "sandy-quux-99999999",
      "image": "sandy-claude-code",
      "started_at": "2026-04-20T13:00:00Z",
      "sandbox": "quux-99999999",
      "daemon": false,
      "attached_clients": null,
      "image_stale": true,
      "updated_at": null
    }
  ],
  "orphan_networks": 0,
  "dangling_images": 1,
  "orphaned_containers": 0,
  "proxy_image_created": "2026-07-28T12:00:00Z"
}
```

> **`host_id` / `host_id_source`** (top-level, added additively in `1.8.0`,
> #179 — no `schema_version` bump). Advisory host identity for multi-host
> fleet aggregation: sandbox names are `basename-<hash-of-workspace-path>`,
> so the SAME workspace path on two hosts yields the SAME slug, making a
> `--print-state` view merged across machines unattributable without this.
> `host_id` is a JSON string or `null`; `host_id_source` is one of
> `"env"` (an operator-set `SANDY_HOST_ID` was honored), `"hostname"`
> (the `uname -n` default was used), or `null` (neither could be
> determined). Default source is `uname -n` (flagless, guarded — a failure
> or empty result yields `host_id: null, host_id_source: null`, never an
> error). `SANDY_HOST_ID` is an **env-only** config key — set only in the
> process environment, never honored from any `.sandy/config` file (see the
> config-keys table above) — a committed workspace config could otherwise
> forge the identity of whatever machine the repo happens to be cloned onto.
> An invalid or over-long (>128 char) override is silently ignored and
> falls back to `uname -n`, with no diagnostic: `--print-state` guarantees
> zero bytes of stderr (see "Stream contract" above), so `host_id_source`
> flipping to `"hostname"` when an override was set is the only signal of a
> rejected value. **Advisory, not a blind join key** — hostnames are
> neither unique nor immutable in general, and a consumer aggregating
> across hosts should treat `host_id` as an operator-facing label, not a
> cryptographic identity. Emitted identically in both `--print-state` and
> `--print-state light` — `uname -n` is one cheap non-docker spawn, well
> within the light-mode budget (which counts only docker spawns), and a
> fleet poller using light mode is exactly the consumer that needs
> attribution. Sandy itself stays single-host: this field exists so a tool
> layered above sandy can tell instances apart, not to make sandy aware of
> other hosts.

> **`sandbox` / `daemon` / `attached_clients`** (per `running_containers[]` entry,
> added additively in 1.1.0, #17 — no `schema_version` bump). `sandbox` is the
> join key to `sandboxes[].name`: derived from the container's `sandy.session`
> label when present (daemon sessions), else a best-effort strip of the
> `sandy-proxy-`/`sandy-` prefix from the container name. `daemon` is a JSON
> bool from the `sandy.daemon=true` label — `true` for an attachable `sandy
> --start` session, `false` for a bare/foreign container. `attached_clients` is
> a JSON int (tmux's `#{session_attached}` count) for daemon containers, or
> JSON `null` for non-daemon entries — lets a consumer distinguish an attached
> vs. detached daemon session. Both `--print-state` and `--print-state light`
> emit all three fields identically; a client on the pre-1.1.0 shape still
> parses (unknown fields ignored) since `id`/`name`/`image`/`started_at` are
> unchanged.

> **`updated_at`** (per `running_containers[]` entry, added additively in
> `1.2.0`, #44 — no `schema_version` bump). The container's `sandy.updated_at`
> label as a JSON string (ISO-8601), or JSON `null` when the label is absent.
> `sandy --update-sessions` stamps this label on any container it restarts
> (DEC-U3), so a fresh timestamp means "this session was rolling-restarted for
> an image update," while `null` means a session the user started/stopped
> themselves. The sandy-ui reconnect flow uses it to tell an update-restart
> (auto-reattach silently) from a user-initiated stop. Emitted identically in
> both `--print-state` and `--print-state light` — it rides the same `docker
> ps` label read as `sandbox`/`daemon`, so it costs no extra docker spawn.

> **`image_stale`** (per `running_containers[]` entry, **FULL MODE ONLY**,
> added additively in `1.2.0`, #41 — no `schema_version` bump; powers `sandy
> --update-sessions`'s staleness check). Tri-state: `true` when the
> container's running image id differs from the CURRENT id of the image
> REFERENCE it was created with — a rebuild has landed since this container
> launched. The reference is read from the container's own `.Config.Image`
> (the name passed at `docker run`), NOT from `docker ps` (which reports a
> raw sha once a tag has been reassigned, which would make a stale container
> read as current).
> `false` when they match. `null` when it can't be computed (the image name
> no longer resolves, or either `docker inspect` failed). Absent entirely
> from `--print-state light` entries — computing it costs one **batched**
> `docker inspect` for ALL sandy containers (#52 — was one per container)
> plus one `docker image inspect` per unique image name (deduplicated across
> containers sharing an image), which is still over the light-mode two-spawn
> budget (see "Light mode" below). A consumer
> that wants a staleness badge on a light-mode poll fetches full mode
> on demand.

> **`size_bytes`** (per sandbox, **FULL MODE ONLY**, added additively in `1.8.0`,
> #176 — no `schema_version` bump). Integer bytes of allocated disk for the
> sandbox directory (`du -skx`, block-allocated size, not apparent size,
> multiplied by 1,024 to convert the KiB result to bytes). `-x` stays on one
> filesystem; a subpath unreadable by the sandy process still yields a
> best-effort partial total (du warns to stderr but still emits a total on
> stdout). `null` on any failure — `du` missing, empty output, non-numeric
> output — and `null`, always, in `--print-state light`: a du walk over a
> multi-GB sandbox is exactly the cost class the light-mode two-spawn poll
> budget (see "Light mode" below) exists to exclude. The key is **present**
> as `null` in light mode rather than absent, matching the
> `dangling_images`/`orphaned_containers`/`proxy_image_created` precedent
> above. Cost note: one `du` walk per sandbox per full-mode call —
> seconds-scale at tens of large sandboxes, and materially worse on a cold
> cache over a virtiofs mount (macOS/OrbStack) — pollers that want a cheap,
> frequent read should stick to light mode and fetch full mode only when a
> size figure is actually needed.

> **`workspace_path`** (per sandbox) is read from the `WORKSPACE.json` marker
> sandy writes into each sandbox on launch; it is an empty string for a legacy
> sandbox that predates the marker. It is a stable field of the contract — a
> consumer (e.g. sandy-ui) may key its UI on it.

> **`workspace_exists`** (per sandbox, added additively in `1.8.0`, #178 — no
> `schema_version` bump). Tri-state, and emitted identically in **both**
> `--print-state` and `--print-state light` (unlike `size_bytes` above, this
> costs zero extra process spawns — `[ -d ]` is a shell builtin): `true`/
> `false` via a plain `[ -d "$workspace_path" ]` test when `workspace_path` is
> non-empty; JSON `null` when `workspace_path` itself is empty (a legacy
> sandbox with no `WORKSPACE.json` marker — unknowable whether the workspace
> exists, so sandy never claims what it cannot prove, the same
> fail-open-on-uncertainty rule the sandbox compat floor uses). This is the
> field `sandy --remove-sandbox --orphans` sweeps on (see the CLAUDE.md
> "`--remove-sandbox`" section) — `false` marks an orphaned sandbox whose
> workspace has moved, been renamed, or been deleted.
>
> Two residuals, stated rather than glossed:
> - **Network-mount latency.** `workspace_path` is not guaranteed to be a
>   local path — a workspace on an unreachable network mount (NFS, a stale
>   SMB share) can make `[ -d ]` **block**, and light mode is specifically
>   the "cheap enough to poll frequently" mode, so this is new exposure
>   relative to every other light-mode field, which touches only local
>   `$SANDY_HOME` paths. The design is still right (a builtin is genuinely
>   cheap in the normal, locally-mounted case) — this is a known cost in an
>   abnormal one, not a defect to fix by changing modes.
> - **Unmounted-volume false positive.** A workspace that is merely
>   unmounted (removable media, an unmounted network share that resolves
>   instantly to "absent" rather than hanging) reads identically to a
>   genuinely deleted workspace — `workspace_exists: false` either way.
>   `sandy --remove-sandbox --orphans` is the consumer of this field that
>   can actually destroy state on a false positive, and it mitigates this
>   procedurally rather than by trying to distinguish the two cases: it
>   always prints the full plan (workspace path, last-used timestamp, size)
>   before requiring `--yes` or an interactive confirmation — never a silent
>   removal. Operators should not cron `sandy --remove-sandbox --orphans
>   --yes` on a host where workspaces live on removable or intermittently
>   mounted media.

> **`orphan_networks`** (top-level, added additively in `1.1.0`, #26 — no
> `schema_version` bump). Integer count of `sandy_(sidecar|egress|net)_<pid>`
> networks that are reap-eligible right now: the owning `<pid>` is dead (or
> non-numeric) **and** no container is attached — the exact gate
> `_sandy_reap_orphan_networks` already applies, so a live session's network,
> and a container-still-attached network (including a D9 reboot-resurrected
> daemon container whose supervisor pid is gone), are never counted. `null`
> when `docker_reachable` is `false` (matches the `running_containers: null`
> convention). Present identically in both `--print-state` and `--print-state
> light`. A UI can call `--prune-orphans` and then re-read this field to
> confirm the count dropped.

> **`dangling_images` / `orphaned_containers`** (top-level, added additively in
> `1.3.0`, #36 — no `schema_version` bump; powers `sandy --gc`). **FULL MODE
> ONLY** — same reasoning as `image_stale`: both cost extra docker spawns
> (`dangling_images` a `docker images -f dangling=true -f label=sandy.managed=1`
> call; `orphaned_containers` a `docker ps -a` plus a bounded `docker exec …
> tmux has-session` probe per running daemon-labeled container), so `--print-
> state light` always reports both as `null` — even when real orphans exist —
> to stay within its two-spawn poll-friendly budget. `dangling_images` is the
> count of `<none>:<none>` images carrying the `sandy.managed=1` build label
> (§1 of the #36 provenance-label change); `orphaned_containers` is the count
> of `sandy-*`/`sandy-proxy-*` containers `sandy --gc`'s container-liveness
> predicate would reap (the same D6/D9 "truth only with a live inner tmux
> session" rule daemon mode uses — a running daemon-labeled container with a
> live session is never counted, regardless of `sandy.daemon_pid` liveness).
> Both are `null` when `docker_reachable` is `false`. A UI can call `sandy --gc
> --yes` and then re-read these fields to confirm the counts dropped.

> **`proxy_image_created`** (top-level, added additively in `1.4.0`, HF-incident
> Issue 3 — no `schema_version` bump). **FULL MODE ONLY** (one extra `docker
> image inspect -f '{{.Created}}' sandy-proxy`, over the light-mode two-spawn
> budget), so `--print-state light` always reports it `null`. It's the RFC 3339
> build timestamp of the local `sandy-proxy` image, or `null` if the image
> doesn't exist or `docker_reachable` is `false`. Surfaces proxy staleness for
> `sandy-ui` and the user — the proxy now auto-rebuilds ~monthly (a freshness
> epoch in `Dockerfile.proxy` + `--pull`, so the golang base + Go stdlib get
> security fixes between sandy releases), and this date makes that visible.

> **Light mode — `sandy --print-state light`.** A second positional arg selects
> a cheap variant for pollers: its steady-state budget is **exactly two** docker
> invocations (vs. ~nine) by (a) skipping `installed_images` — the key stays
> present as `[]` — and (b) deriving `docker_reachable`/`running_containers`
> from a single `docker ps` (its exit status is the reachability signal)
> instead of the `docker info` gates; the second invocation is the `docker
> network ls` behind `orphan_networks` (added in `1.1.0`, #26 — light mode was
> exactly one invocation before that). Two bounded extras apply only when the
> corresponding state exists: one `docker exec … tmux display` per **daemon**
> container (for `attached_clients`, #17) and one `docker network inspect` per
> dead-owner orphan **candidate** (#26) — both zero on a host with no daemon
> sessions and no orphans. Non-docker fields (`sandboxes`, `approvals`,
> `workspace_path`, locks) are **not all** identical to full mode as of
> `1.8.0`: `size_bytes` (#176, above) is the first non-docker field to
> diverge between the two modes — it is always `null` in light mode, because
> the `du` walk it requires costs the same class of latency the light-mode
> budget exists to avoid, even though computing it needs no docker spawn at
> all. Every other non-docker field is still identical between modes. The
> arg is **forward-compatible**: any value other than `light` (including
> none, and an older sandy that ignored `$2`) yields full mode, so a
> consumer may pass `light` unconditionally. No `schema_version` bump — the
> shape is unchanged.

### `--validate-config`

Takes a path to a `.sandy/config`-style file. Emits:

```json
{
  "schema_version": 1,
  "path": "/Users/drapp/dev/foo/zork/.sandy/config",
  "source_tier": "workspace",
  "errors": [],
  "warnings": [
    {
      "key": "SANDY_SKIP_PERMISSIONS",
      "message": "privileged key set from workspace — requires explicit approval",
      "severity": "warning"
    }
  ],
  "unknown_keys": ["FOO_BAR"],
  "privileged_keys_requiring_approval": ["SANDY_SSH"],
  "approval_status": "pending",
  "approval_file_path": "/Users/drapp/.sandy/approvals/passive-abc123.list"
}
```

Exit code: `0` on schemas that load cleanly (even with warnings), `1` on fatal errors (unparseable file, etc).

### `--print-version` (1.7.0, #159)

```json
{"schema_version":1,"version":"1.7.0-dev","commit":"d89aaba","full_version":"1.7.0-dev-d89aaba"}
```

The standalone, minimal-payload version probe. It exists to unblock a consumer (`sandy-ui`) that needs to know sandy's version *before* it can safely call `--print-schema` — keying a schema cache off `--print-schema`'s own `sandy.version` field is chicken-and-egg, since that field is inside the payload being cached.

- **`commit`** is `""`, not JSON `null`, when no commit hash is known (e.g. a curl-installed sandy with no `SANDY_COMMIT` baked in, running outside a git checkout) — this matches `--print-schema`'s existing `sandy.commit` convention exactly. Both fields are computed by the same `_sandy_commit_hash()` helper so the two surfaces cannot drift apart.
- **`full_version`** is `version` alone when `commit` is `""`, else `version + "-" + commit`.
- **Cache-keying guidance: key on `full_version`, never on the first dotted-numeric token of `version` (or of `--version`'s output).** `version` is `SANDY_VERSION` verbatim — on the `1.x-dev`/`-rcN` channel this stays e.g. `"1.7.0-dev"` across every commit until the numbered release ships, so a cache keyed on it (or on a regex that strips the suffix down to `1.7.0`) never invalidates across exactly the upgrades a dev-channel consumer makes. `full_version` changes on every commit, so it is the only field that actually behaves like a cache key.
- **Pre-1.7.0 forwarding hazard.** `--print-version` did not exist before 1.7.0, and sandy's main parser forwards any flag it does not recognize straight through to the wrapped agent instead of erroring — so calling `--print-version` against an older sandy does not fail fast, it silently attempts a full container launch. Probe with `--version` first (its `sandy <full_version>` format is guaranteed on every sandy version, old and new — see "Discoverability" above); only call `--print-version` once the parsed version is confirmed `>= 1.7.0`.

No exit-code surprises: always `0` (see the stream contract above — this flag carries the same guarantee as `--print-schema`/`--print-state`).

## Schema versioning

- Current: `schema_version: 1`
- **Config-key object fields:** each key object carries `name`, `type` (+ `choices` for enums), `default` (omitted if none), `pattern` (omitted if none), `since` (introduction version, omitted if unknown), `stability` (always present: `stable` | `experimental` | `internal`), `description`, `sources`, and `passive_approval_required` (privileged keys only). `since` and `stability` were added additively in `0.15.0` (PR 4.1); per the rule below, older clients ignore them without a version bump.
- **Additive changes** (new keys in existing objects, new flags in `cli_flags`): no version bump. In `1.7.0`, one new `sandboxes[]` field: `handoff_enabled` (bool — whether `$SANDBOX_DIR/.handoff-enabled`, the operator-side handoff enable marker, is present; reports the marker only, not a workspace `SANDY_HANDOFF_DIRS=1`). Clients ignore unknown fields. Three additive changes shipped this way: `since`/`stability` on config-key objects (`0.15.0`, PR 4.1, above); in `1.1.0` (#17), three new `cli_flags` entries (`--start`, `--attach`, `--stop` — daemon-mode flags) plus three new `running_containers[]` fields (`sandbox`, `daemon`, `attached_clients` — see `--print-state` below); and, also in `1.1.0` (#26), one more `cli_flags` entry (`--prune-orphans` — reap orphaned sandy networks and exit) plus one new top-level `--print-state` field (`orphan_networks` — see above). In `1.2.0`, one more `cli_flags` entry (`--update-sessions` — fleet image refresh + rolling restart across every daemon session on the host, scopeable to a single session with `--workspace PATH`, #41) plus two new `running_containers[]` fields: `image_stale` (FULL MODE ONLY, #41 — see above) and `updated_at` (both modes, #44 — see above). In `1.3.0`, one more `cli_flags` entry (`--gc` — unified reclaim of dead-owner containers, orphaned networks, orphaned per-project/skill images, and dangling sandy images, with `--dry-run`/`--yes` sub-options, #36) plus two new top-level `--print-state` fields: `dangling_images` and `orphaned_containers` (both FULL MODE ONLY — see above). In `1.7.0`, one more `cli_flags` entry (`--workspace` — the parsers have accepted this flag since `1.1.0` (#17); only the schema advertisement was missing, #156) plus the guaranteed stream contract for `--print-schema`/`--print-state`/`--validate-config` documented above (#160) — the stream contract formalizes and test-pins behavior every one of these handlers already had, so it carries no field or shape change and needs no `schema_version` bump either. Also in `1.7.0` (#159), a new `cli_flags` entry (`--print-version`) plus the new `--print-version` flag itself (see the `### --print-version` section above) — a wholly new, additive introspection surface, not a change to any existing emitted shape, so it needs no `schema_version` bump either; it does, however, extend the 1.7.0 stream contract (above) to cover this fourth flag. In `1.8.0` (#176), one new `sandboxes[]` field: `size_bytes` (FULL MODE ONLY, always `null` in `--print-state light` — see above) — the allocated-disk-usage figure for each sandbox, computed via `du -skx`. Also in `1.8.0` (#178), one more `cli_flags` entry (`--remove-sandbox` — permanently delete a sandbox directory, with three mutually exclusive selectors: default/`--workspace PATH`, `--sandbox NAME`, `--orphans`; sub-options `--dry-run`/`--yes`) plus one new `sandboxes[]` field: `workspace_exists` (tri-state, emitted identically in BOTH `--print-state` modes since it costs no extra process spawn — see above). The existing `--workspace` `cli_flags` entry's description was also updated to name `--remove-sandbox` among the flags it honors, per the drift discipline #156 established. Also in `1.8.0` (#179), two new top-level `--print-state` fields: `host_id` and `host_id_source` (see above) — advisory host identity for multi-host fleet aggregation, sourced from `uname -n` by default with an env-only `SANDY_HOST_ID` override, emitted identically in both `--print-state` modes. `SANDY_HOST_ID` also appears as a new `env_only_keys` entry in `--print-schema`.
- **Deprecations** (existing key changes semantics): bump to `schema_version: 2`. Sandy publishes both versions in parallel via `--print-schema --schema-version 1` for one minor release, then drops v1 with a release-note callout.
- **Compatibility range**: each sandy version declares `supported_schema_versions` and `deprecated_schema_versions` so clients can decide to warn/refuse.

Clients should:
1. Pin a minimum supported `schema_version`.
2. Read only known fields — ignore the rest gracefully.
3. Surface a soft warning when `sandy.version` is newer than the client's tested `max_sandy_version`.

## Implementation strategy

### Lift allowlists to named bash arrays

Today the config tier lists are inlined in `_load_sandy_config` case statements. First, refactor them into module-level arrays at the top of the script (near `SANDY_VERSION`):

```bash
SANDY_PRIVILEGED_KEYS=(
    SANDY_SSH SANDY_SKIP_PERMISSIONS SANDY_ALLOW_NO_ISOLATION SANDY_ALLOW_LAN_HOSTS
    ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
    GEMINI_API_KEY OPENAI_API_KEY GOOGLE_API_KEY
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
)

SANDY_PASSIVE_KEYS=(
    SANDY_AGENT SANDY_MODEL SANDY_CPUS SANDY_MEM SANDY_GPU
    SANDY_SKILL_PACKS SANDY_CHANNELS SANDY_CHANNEL_TARGET_PANE
    SANDY_VERBOSE SANDY_VENV_OVERLAY SANDY_ALLOW_WORKFLOW_EDIT
    CLAUDE_CODE_MAX_OUTPUT_TOKENS
    GEMINI_MODEL SANDY_GEMINI_AUTH SANDY_GEMINI_EXTENSIONS
    GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION GOOGLE_GENAI_USE_VERTEXAI
    CODEX_MODEL SANDY_CODEX_AUTH CODEX_HOME
    TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_SENDERS
    DISCORD_BOT_TOKEN DISCORD_ALLOWED_SENDERS
)

SANDY_ENV_ONLY_KEYS=(
    SANDY_AUTO_APPROVE_PRIVILEGED SANDY_DEBUG_CLEANUP
)
```

The case statements become array iterations:

```bash
_key_in_list() {
    local target="$1"; shift
    local k
    for k in "$@"; do [ "$k" = "$target" ] && return 0; done
    return 1
}

# In _load_sandy_config:
if [ "$tier" = "privileged" ]; then
    if _key_in_list "$key" "${SANDY_PRIVILEGED_KEYS[@]}" "${SANDY_PASSIVE_KEYS[@]}"; then
        export "$key=$value"
    fi
elif [ "$tier" = "passive" ]; then
    if _key_in_list "$key" "${SANDY_PRIVILEGED_KEYS[@]}"; then
        # queue for approval (existing logic)
    elif _key_in_list "$key" "${SANDY_PASSIVE_KEYS[@]}"; then
        export "$key=$value"
    fi
fi
```

This refactor is prerequisite to `--print-schema` — otherwise the schema generator would have to parse the case statements or maintain a parallel list.

### Key metadata

For each key, additional metadata (type, default, description, pattern) is harder to derive from code alone. Two options:

**Option A: Inline metadata via associative arrays.** bash 4+ only (macOS ships 3.2). Would require a shebang bump or a feature detect. Rejected.

**Option B: Heredoc table parsed at introspection time.**

```bash
_sandy_key_metadata() {
    cat <<'EOF'
key	type	default	pattern	description
SANDY_MODEL	string	claude-opus-5	^[a-zA-Z0-9._-]+$	Model ID for Claude agent
SANDY_CPUS	int	2		Number of CPUs allocated to the container
SANDY_SSH	enum:token,agent	token		SSH auth mode: token (gh CLI) or agent (forward host SSH agent)
...
EOF
}
```

The introspection command parses this tab-separated table and emits JSON. Tables stay human-editable; `--print-schema` output stays programmatically consumable.

### Schema emitter

A single new function `_sandy_emit_schema()` that:
1. Walks `SANDY_PRIVILEGED_KEYS` and `SANDY_PASSIVE_KEYS`
2. Joins each with metadata from `_sandy_key_metadata`
3. Emits JSON via `printf` + manual escaping (no `jq` dependency — sandy doesn't require jq)

### State emitter

`_sandy_emit_state()`:
- Walks `$SANDY_HOME/sandboxes/*/` for directory listing
- Reads each sandbox's `.sandy_created_version` and `.sandy_last_version` files
- Walks `$SANDY_HOME/approvals/passive-*.list` for approval entries
- Calls `docker ps --filter label=sandy --format json` for running containers (if Docker is reachable; silent skip if not)
- Calls `stat` for directory sizes (portable — macOS `stat -f %z`, Linux `stat -c %s`)

### JSON-without-jq safety

No external JSON library. Use a small set of helper functions:

```bash
_json_escape() {
    # Escape a string for JSON: backslash, quote, control chars
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

_json_kv() {
    # "key": "escaped_value",
    printf '"%s":%s' "$1" "$(_json_escape "$2")"
}
```

## Test coverage

Additions to `test/run-tests.sh`:

1. **Schema is valid JSON**
   ```sh
   sandy --print-schema | python3 -c "import sys, json; json.load(sys.stdin)"
   ```
2. **Schema version matches constant**
   ```sh
   sandy --print-schema | jq -r .schema_version | grep -qE '^[0-9]+$'
   ```
3. **Every key in `SANDY_PRIVILEGED_KEYS` appears in schema**
4. **Every key in `SANDY_PASSIVE_KEYS` appears in schema**
5. **No schema-listed key is missing from the case-statement dispatch** (the array refactor makes this trivially true)
6. **`--validate-config` catches known-bad configs** (privileged key in passive source, unknown key, bad value)
7. **`--print-state` works with empty `$SANDY_HOME`** (returns empty arrays, not errors)
8. **`--print-state` on a real sandbox reports correct metadata**
9. **§91 (1.7.0, #156) parser↔cli_flags lockstep** — extracts every flag sandy's real parsers accept (fast-path if-dispatches + case labels) and diffs it against `cli_flags`, both directions, against a small hand-verified allowlist of sub-options/private/forwarded exceptions
10. **§92 (1.7.0, #160/#159) stream contract pin** — for `--print-schema`, `--print-state` (both modes), `--validate-config` (valid/unknown/privileged-from-passive fixture, missing-file, and no-argument cases), and `--print-version` (case (h), base + `SANDY_VERBOSE=1`), asserts stdout is exactly one JSON document (or exactly 0 bytes in the no-argument case) and stderr is exactly 0 bytes (or non-empty and contains `ERROR` in the no-argument case) — two-sided, so a future `info`/`warn` call landing on stdout is caught even though it would leave stderr untouched
11. **§93 (1.7.0, #159) machine-readable version** — pins `--print-version`'s `.version` against `SANDY_VERSION` in source; the `--version` ⇄ `--print-version.full_version` identity byte-for-byte; cross-surface agreement between `--print-schema`'s `sandy.version`/`sandy.commit` and `--print-version`'s `version`/`commit` (both computed via the shared `_sandy_commit_hash()` helper); the `full_version = version[-commit]` composition and the `commit` hex-hash shape; two NEGATIVE fixtures — a stubbed-`git`, outside-any-repo copy (`commit==""`, `full_version==version`) and the same copy with `install.sh`'s exact `SANDY_COMMIT` bake-in sed applied (`commit=="abc1234"`); and `.schema_version` against `SANDY_SCHEMA_VERSION` in source

## Migration for sandy itself

- 0.11.x → 0.12.0: refactor adds `SANDY_*_KEYS` arrays, `--print-schema` ships. No user-facing behavior change.
- 0.12.x: `sandy-ui` can begin consuming the schema.
- Future deprecations go through the `schema_version` bump mechanism.

## Open questions

1. **Should `--print-schema` be versioned independently of `SANDY_VERSION`?** Yes — `schema_version` is the contract; `sandy_version` is informational. `schema_version` changes far less often.
2. **Do we need a JSON Schema (Draft-07) sidecar for validation in clients?** Not initially — the shape is documented here. If demand materializes, publish `sandy-schema-v1.json` as an artifact on GitHub Releases.
3. **Should `--print-state` shell out to Docker?** Yes for running-container listing, but gracefully skip if Docker is unreachable (return `"running_containers": null` with a `"docker_reachable": false` flag).
4. **Do we expose credentials in the state output?** Never. Output redacts any env var whose name is in a `SECRETS` list (anything ending in `_KEY`, `_TOKEN`, `_SECRET`, `.credentials.json` paths). Only existence flags, never values.
5. **Shell completion generation** — bash/zsh/fish completions could be auto-generated from the schema. Out of scope for 0.12.0; tracked as a 0.13+ nice-to-have.
