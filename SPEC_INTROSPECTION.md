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

Three new flags added to sandy's existing flat CLI (matching the `--print-protected-paths` debug flag that already exists):

| Flag | Purpose | Reads | Writes |
|---|---|---|---|
| `--print-schema` | Static schema: config keys, flags, agents, paths | nothing on disk | stdout |
| `--print-state` | Runtime state: sandboxes, approvals, locks | `$SANDY_HOME/` | stdout |
| `--validate-config PATH` | Check a config file against the schema | the path given | stdout + exit code |

All three:
- Emit JSON to stdout, errors to stderr
- Are non-interactive (no TTY required, no prompts)
- Exit 0 on success, non-zero on schema load / validation failure
- Suppress `[sandy] ...` log lines (logging goes to stderr regardless)
- Work without Docker running (for `--print-schema`) — pure script introspection

### Discoverability

`sandy --help` gains a "Introspection" section listing the three flags. `sandy --version` already prints version + commit; unchanged.

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
        "default": "claude-opus-4-7",
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
        "description": "Comma-separated agent list. 'all' is an alias for 'claude,gemini,codex'.",
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

### `--print-state`

```json
{
  "schema_version": 1,
  "sandy_home": "/Users/drapp/.sandy",
  "installed_images": [
    { "name": "sandy-base", "id": "sha256:abc...", "created": "2026-04-15T..." },
    { "name": "sandy-claude-code", "id": "sha256:def...", "created": "2026-04-15T..." }
  ],
  "sandboxes": [
    {
      "name": "zork-3dfda686",
      "path": "/Users/drapp/.sandy/sandboxes/zork-3dfda686",
      "workspace_path": "/Users/drapp/dev/foo/zork",
      "created_version": "0.11.2",
      "last_used_version": "0.11.4",
      "created_at": "2026-04-15T10:00:00Z",
      "last_used_at": "2026-04-20T14:45:00Z",
      "agent": "claude",
      "size_bytes": 123456789,
      "lock_held": false,
      "lock_holder_pid": null,
      "lock_holder_alive": null,
      "compat_warning": null
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
      "name": "sandy_zork-3dfda686_12345",
      "sandbox": "zork-3dfda686",
      "started_at": "2026-04-20T14:00:00Z",
      "agent": "claude"
    }
  ]
}
```

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

## Schema versioning

- Current: `schema_version: 1`
- **Additive changes** (new keys in existing objects, new flags in `cli_flags`): no version bump. Clients ignore unknown fields.
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
SANDY_MODEL	string	claude-opus-4-7	^[a-zA-Z0-9._-]+$	Model ID for Claude agent
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
