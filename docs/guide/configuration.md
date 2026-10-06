# Configuration

Every config key, the flags, and how per-project configuration is trusted. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

## Per-project config (`.sandy/config`)

Sandy loads config from two levels, with project overriding user:

1. **User-level**: `~/.sandy/config` and `~/.sandy/.secrets` — apply to all projects on this machine
2. **Per-project**: `.sandy/config` and `.sandy/.secrets` — override user-level for this project

```bash
# ~/.sandy/config — user-level defaults for all projects
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-...       # long-lived token (better in ~/.sandy/.secrets)

# .sandy/config — per-project overrides
SANDY_SSH=agent                          # use SSH agent instead of gh token
SANDY_MODEL=claude-sonnet-4-5-20250929   # override default model
```

Only allowlisted `KEY=VALUE` lines are parsed (not sourced as a shell script). Use `.secrets` files for credentials — they should not be committed. See the environment variables table below for supported keys.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `SANDY_AGENT` | `claude` | AI agent(s) to run. Single: `claude`, `gemini`, `codex`, `opencode`. Multi (comma-separated, 2–4 panes in tmux): e.g. `claude,gemini` or `claude,gemini,codex,opencode`. Alias: `all` = `claude,gemini,codex,opencode` |
| `SANDY_MODEL` | `claude-opus-5` | Claude model to use (applies whenever `claude` is in `SANDY_AGENT`) |
| `SANDY_EFFORT` | _(each agent's own default)_ | Reasoning effort for claude, codex, grok and gemini: `low`\|`medium`\|`high`\|`xhigh`\|`max`. Applied as `claude --effort`, (2.4.0) codex `-c model_reasoning_effort=<level>` (each level maps to its codex namesake), (2.7.0) grok `--reasoning-effort <level>` (`max` is clamped to `xhigh`, grok's top level, with a launch notice — grok rejects `max`) and (2.7.0) gemini through a read-only system settings file sandy generates (Gemini 3 `thinkingLevel` `LOW` for `low`, `HIGH` otherwise; Gemini 2.5 `thinkingBudget` 1024/8192/24576). The gemini file outranks your own gemini settings and **shadows any `modelConfigs.customOverrides` you set** while `SANDY_EFFORT` is set (`modelConfigs.overrides` is untouched). Ignored with a notice for opencode. Recorded in `sandy-session.json` so a run's effort is provable |
| `SANDY_TEAMMATE_MODE` | (unset) | Value passed to `claude --teammate-mode` (claude only). Empty = sandy passes nothing and Claude Code uses its own default; set e.g. `tmux` to opt in. Passive-safe |
| `GEMINI_API_KEY` | (unset) | Google API key for Gemini CLI. Put in `.sandy/.secrets` |
| `GEMINI_MODEL` | (unset) | Gemini model override |
| `SANDY_GEMINI_AUTH` | `auto` | Force Gemini auth path: `auto`, `api_key`, `oauth`, or `adc` |
| `SANDY_GEMINI_EXTENSIONS` | (unset) | Comma-separated Gemini extension URLs/paths to install on first launch. Privileged tier |
| `OPENAI_API_KEY` | (unset) | OpenAI API key for Codex CLI. Put in `.sandy/.secrets` — sandy materializes it as an ephemeral read-only `auth.json` for codex (codex 0.139+ no longer reads the env var for auth) |
| `CODEX_MODEL` | (unset) | Codex model override |
| `SANDY_CODEX_AUTH` | `auto` | Force Codex auth path: `auto`, `api_key`, or `oauth` |
| `OPENCODE_MODEL` | (unset) | OpenCode model override (`provider/model` format, e.g. `anthropic/claude-sonnet-4`) |
| `SANDY_OPENCODE_AUTH` | `auto` | Force OpenCode auth path: `auto`, `api_key`, or `oauth` |
| `XAI_API_KEY` | (unset) | xAI API key for Grok Build. Fully-headless auth; put in `.sandy/.secrets`. Privileged tier |
| `GROK_MODEL` | `grok-4.5` | Grok Build model (passed as `-m`) |
| `SANDY_GROK_AUTH` | `auto` | Force Grok auth path: `auto`, `api_key`, or `oauth` |
| `SANDY_LOCAL_LLM_HOST` | (unset) | `host:port` to allow through LAN isolation, typically for a local LLM (e.g. `127.0.0.1:11434` for Ollama). With the egress proxy on (default), the proxy's forward listener relays `host.docker.internal:<port>` to the host; with the proxy off (`SANDY_EGRESS=off`, Linux), inserts a single iptables ACCEPT rule and maps `host.docker.internal`. Privileged tier |
| `GOOGLE_CLOUD_PROJECT` | (unset) | GCP project ID (Vertex AI) |
| `GOOGLE_CLOUD_LOCATION` | (unset) | GCP region (Vertex AI) |
| `GOOGLE_GENAI_USE_VERTEXAI` | (unset) | Set `true` to route Gemini through Vertex AI |
| `GOOGLE_API_KEY` | (unset) | Google API key for Vertex AI / ADC |
| `SANDY_CHANNEL_TARGET_PANE` | `0` | Which agent receives Telegram relay messages in multi-agent mode. `0` = first agent in `SANDY_AGENT`, `1` = second, `2` = third, `3` = fourth — routed to that agent's pane by name, not by raw tmux pane index |
| `SANDY_SSH` | `token` | Git auth method: `token` (gh CLI + HTTPS) or `agent` (SSH agent forwarding) |
| `SANDY_SSH_KEYS` | (unset) | Comma-separated **filenames** under `~/.ssh` that may be staged into the container, in **any** `SANDY_SSH` mode. Default empty = **no private key material is staged**. `config`, `known_hosts` and `*.pub` come with them. Privileged tier |
| `SANDY_SKIP_PERMISSIONS` | `true` | Set to `false` to keep Claude Code's permission system active |
| `SANDY_HOME` | `~/.sandy` | Sandy config/build/sandbox directory |
| `SANDY_VERBOSE` | `0` | Verbosity: `0` quiet, `1` verbose, `2` debug, `3` full trace |
| `SANDY_HOST_ID` | _(hostname)_ | Advisory host identity reported by `--print-state` for multi-host fleet aggregation (sandbox names hash only the workspace path, so the same path on two hosts collides). **Env-only** — a committed config can't forge it |
| `SANDY_CPUS` | auto-detected | CPU limit for the container |
| `SANDY_MEM` | auto-detected | Memory limit for the container |
| `SANDY_VENV_OVERLAY` | `1` | Set `0` to disable the sandbox-owned `.venv` overlay (see "Using host virtual environments") |
| `SANDY_EGRESS` | `permissive` | Egress posture: `off` (proxy off — legacy iptables-only on Linux, **no** isolation on macOS), `permissive` (block private/LAN/cloud-metadata, allow the internet), or `strict` (built-in allowlist + `SANDY_ALLOW_HOSTS` only). `strict` is safe to commit in a workspace `.sandy/config`; `off` **and `permissive`** set there trigger an approval prompt, because a workspace value outranks your host config and could otherwise downgrade a host that chose strict. Replaces the deprecated `SANDY_EGRESS_STRICT` / `SANDY_EGRESS_NO_ISOLATION` booleans. See "How Network Isolation Works" |
| `SANDY_ALLOW_HOSTS` | (unset) | Comma-separated extra egress-**proxy** allowlist entries (`host`, `*.suffix`, or `host:port`), appended to the built-in default set. This is the way to widen reach when the proxy is on (the default). Privileged tier |
| `SANDY_ALLOW_LAN_HOSTS` | (unset) | **Legacy (proxy-off, Linux only).** Comma-separated IPs/CIDRs to poke through the iptables LAN block. Ignored when the egress proxy is on — use `SANDY_ALLOW_HOSTS` instead |
| `SANDY_ALLOW_NO_ISOLATION` | `0` | **Legacy (proxy-off, Linux only).** `1` = allow launch when iptables rules can't be applied. *Not* the same as `SANDY_EGRESS_NO_ISOLATION` (which turns the proxy off) |
| `SANDY_ALLOW_WORKFLOW_EDIT` | `0` | `1` = drop `.github/workflows/` from the read-only protected set (for legitimate CI work). Weakens protection, so a workspace `.sandy/config` setting it triggers an approval prompt |
| `SANDY_EGRESS_LOG` | `0` | `1`/`summary` = log which hosts the agent's egress actually reached (each distinct allowed `host:port` once) and print a session-end summary. Hostnames only — TLS is never terminated. Passive-safe (adds visibility) |
| `SANDY_TOOL_AUDIT` | `0` | `1` = seed a Claude Code `PreToolUse` hook that appends `{ts,tool,args}` JSONL to `~/.claude/tool-audit.jsonl`. Claude-only, passive-safe (adds visibility); a user's own `PreToolUse` hook is never clobbered |
| `SANDY_CROSS_SESSION_INBOUND` | _(conditional)_ | Whether another local session may inject a turn into this one (Claude Code's `crossSessionInbound`): `accept` (delivered, no prompt), `hold` (interactive approval), `refuse` (sender told it was not accepted). Unset resolves to `accept` when a **selected feature manifest declares `"receives": ["cross_session"]`** (2.4.0) — otherwise `refuse`, so a workspace with neither has no open receive surface. (An entry alone, with no declared `receives`, used to also resolve `accept` — that legacy default was announced for removal in 2.5.0 and REMOVED in 2.6.0.) `hold`/`refuse` are passive-safe; `accept` from a workspace `.sandy/config` triggers an approval prompt. Claude-only. See "Features" and `cross_session_inbound_source` in the session marker |
| `CLAUDE_CODE_OAUTH_TOKEN` | (unset) | Long-lived OAuth token from `claude setup-token`. Put in `.sandy/.secrets`. Recommended for headless servers |
| `ANTHROPIC_API_KEY` | (unset) | API key — not needed with Claude Pro/Max (OAuth). **Not forwarded when a Claude OAuth credential is already going into the container** (Claude Code resolves an env key ahead of the account credentials, so forwarding both either bills per-use or parks the session on Claude Code's custom-API-key startup prompt). Set `SANDY_CLAUDE_AUTH=api_key` to use it anyway |
| `SANDY_CLAUDE_AUTH` | `auto` | Force Claude auth path: `auto`, `api_key`, `oauth`, or `profile`. `api_key` withholds **both** the OAuth credentials file and a long-lived token, so one revocable key is the only Claude credential in the container; `oauth` uses your account login (`/login`) and forwards neither the API key nor a long-lived `CLAUDE_CODE_OAUTH_TOKEN` (2.8.0; if the host has no account login it falls back to the token, with a warning). That is what claude.ai connectors need, see [Using claude.ai connectors](agents.md#using-claudeai-connectors-microsoft-365-gmail-); `profile` uses an Anthropic Console profile from `ant auth login` — the route to workspace-bound entitlements such as **Claude Mythos** (see [Using a Console profile](agents.md#using-a-console-profile--claude-mythos-and-workspace-scoped-access)). `api_key` and `profile` are passive-safe (each reduces what is in the box); `oauth` from a workspace `.sandy/config` triggers an approval prompt |
| `ANTHROPIC_PROFILE` | (unset) | With `SANDY_CLAUDE_AUTH=profile`, the named Console profile to use instead of the host's active one. **Privileged**: it picks *which* profile's token enters the container, and an `org:admin` profile carries organization-wide access, so a committed config cannot select it |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | Max output tokens per response (Claude Code default is 32K) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | (unset) | Model for **subagents** — the parallel researchers a skill fans out. Subagents do *not* inherit the orchestrator's model, so unset they run on their own default tier: a session pinned to a gated model (e.g. `claude-mythos-5-1`) silently does its fan-out on a different one. Set it alongside `SANDY_MODEL` |
| `SANDY_CLAUDE_CONNECTORS` | `0` | `1` = expose claude.ai **account connectors** (Gmail, Drive, …) inside the sandbox. Default `0` suppresses them — the account-scoped OAuth token would otherwise make every connector reachable from every sandbox. Weakens isolation, so a workspace `.sandy/config` setting it triggers an approval prompt. Claude-only. Connectors load only with an account login, see [Using claude.ai connectors](agents.md#using-claudeai-connectors-microsoft-365-gmail-) |
| `SANDY_SUSPICIOUS` | `0` | `1` = hardened posture for a workspace you distrust: strip the OAuth **refresh token** (mount only the short-TTL access token — fails closed if it can't), prefer a disposable `ANTHROPIC_API_KEY` over mounting OAuth at all, force connectors off, default egress to strict. Records `cred_mode` in the session marker. **Strengthens** isolation — safe to commit in a workspace config. In-session token refresh stops at the access token's expiry (relaunch or `/login`) |
| `SANDY_OFFLINE` | `0` | `1` = "use what you have": skip the agent, skill-pack and sandy **update checks** for this launch — for a plane, a captive portal or an air-gapped host, where a detected update would force a rebuild that cannot succeed. Images that are missing or whose inputs changed are **still built**. The trade-off is visible: a line at launch, one at session end, and `"offline": true` in `sandy-session.json`; the next launch without it picks up patches as usual. One-shot form: `--no-update-check`. Passive-safe |
| `SANDY_SKILL_PACKS` | (unset) | Comma-separated skill packs to install (e.g. `gstack`). Built as a cached Docker layer |
| `SANDY_GPU` | (disabled) | GPU passthrough: `all` for all GPUs, or device IDs like `0` or `0,1`. Requires [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) |
| `SANDY_SCREENSHOT_DIR` | (unset) | Host directory of screenshots to mount into the container (read-only at `/home/sandy/screenshots`). When set, sandy generates a `/ss` slash command for Claude/Gemini and a screenshot skill for Codex — type `/ss huh` to have the agent describe your latest screenshot, `/ss 3 explain` for the last three, etc. See "Screenshot skill" below. Privileged tier |
| `SANDY_EXTRA_ENV` | (unset) | Comma-separated env-var names to forward into the container (e.g. `HA_TOKEN,LINEAR_API_KEY`). The name lists **compose** (2.4.0): host, approved workspace, and env lists are unioned (deduplicated), so a workspace adding a name never drops the host's. Values come from env (wins) or any of the four config files (workspace overrides host). Lets you wire up tokens for user-installed MCP servers without patching sandy. Privileged tier; workspace usage requires approval |
| `SANDY_AGENT_ARGS` | (unset) | Extra CLI args appended to the agent command on **every** launch (bare, `-p`, `--start`, sandy-ui). Whitespace-split, never `eval`'d, ordered after sandy's flags and before command-line args. Privileged tier; workspace usage requires approval. For agent-specific flags prefer a per-sandbox `$SANDBOX_DIR/agent-args.<agent>` file (scoped to one agent) |
| `SANDY_CHANNELS` | (unset) | Channel plugins to enable (e.g. `plugin:telegram@claude-plugins-official`) |
| `TELEGRAM_BOT_TOKEN` | (unset) | Telegram bot token (from BotFather). Put in `.sandy/.secrets`, not `.sandy/config`. Privileged tier |
| `TELEGRAM_ALLOWED_SENDERS` | (unset) | Comma-separated Telegram user IDs for allowlist (e.g. `123456,789012`). Privileged tier |
| `DISCORD_BOT_TOKEN` | (unset) | Discord bot token. Put in `.sandy/.secrets`, not `.sandy/config`. Privileged tier |
| `DISCORD_ALLOWED_SENDERS` | (unset) | Comma-separated Discord user IDs for allowlist. Privileged tier |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | (unset) | Set to `1` to enable experimental agent teams |

## Flags

| Flag | Description |
|---|---|
| `--new` | Start a fresh session (default: resume last) |
| `--resume` | Open session picker (claude's, or `codex resume` for codex) |
| `--remote` | Start in [remote-control](https://code.claude.com/docs/en/remote-control) server mode (connect from browser/phone) |
| `--rebuild` | Force rebuild of the Docker image |
| `--build-only` | Build images and exit (for CI) |
| `--no-update-check` | Skip update checks for this launch (one-shot `SANDY_OFFLINE=1`; wins over config). Works with a bare launch, `-p`, `--build-only` and `--start` |
| `--upgrade` | Update sandy to the latest version from GitHub |
| `--agent <list>` | Agent(s) to launch — overrides `SANDY_AGENT` and `.sandy/config` (e.g. `--agent claude,gemini`) |
| `-p "prompt"` | One-shot prompt (no interactive session) |
| `--start` | Start a detached [daemon session](daemon.md#daemon-mode) and return once attachable |
| `--attach` | Attach an interactive client to a running daemon session |
| `--stop` | Stop a running daemon session (full teardown) |
| `--login codex` | Log codex in so its credential persists in this workspace's sandbox (`codex login --device-auth`), inside the running session if there is one, else in a one-shot launch. Sub-options: `--workspace PATH`, `--dry-run`. See [Running Codex CLI](agents.md#running-codex-cli-sandy_agentcodex) |
| `--exec [-- CMD]` | Shell (or run `CMD`) inside this workspace's running container, **as the host uid**. Do not hand-roll it: `docker exec -u sandy` resolves the name against the *image*, where the user is uid 1001, so it runs as the wrong owner and prints `I have no name!`. Sub-options: `--workspace PATH`, `--dry-run`. See [Getting a shell inside a running sandbox](daemon.md#getting-a-shell-inside-a-running-sandbox-sandy---exec) |
| `--stop-all` | **Fleet emergency stop** — stop every daemon session on the host via the hardened per-session teardown. Sub-options: `--dry-run`, `--yes` |
| `--prune-orphans` | Reap orphaned `sandy_*` Docker networks and exit |
| `--update-sessions` | Fleet image refresh + rolling restart across every daemon session on the host (scope to one with `--workspace PATH`). See [Fleet updates](daemon.md#fleet-updates---update-sessions). Sub-options: `--dry-run`, `--yes`, `--idle-for <minutes>`, `--rebuild`, `--workspace` |
| `--reset-sandbox` | Rebuild **one** project's sandbox from a known-good skeleton — destroy its persistent package/agent state (preserving `WORKSPACE.json` lineage), refusing while a live session holds it. Filesystem-only, no Docker. "When in doubt, rebuild" in one command. Sub-options: `--workspace PATH` (default cwd), `--keep-approvals`, `--dry-run`, `--yes` |
| `--rsync HOST` | **Copy** this workspace's sandbox to another host, even when the workspace lives at a different path there: renames it for the destination and rewrites the path-keyed state a hand `rsync` gets wrong (session history and memory, `.claude.json`, `WORKSPACE.json`). The destination workspace defaults to the same path under `$HOME` (`--dest-workspace PATH` to override) and must already exist. Credential files are copied and named in the plan; on a different CPU architecture the package caches are skipped and rebuild on first use. Sub-options: `--dry-run`, `--yes` |
| `--rsync-from HOST` | The reverse: **pull** the other host's sandbox for this workspace to this machine, using only outbound `ssh`/`rsync` from here, so it works when the other host cannot reach you (NAT, VPN). It is named for this machine's workspace path, with the same rewrites and the same plan. The source workspace defaults to the same path under `$HOME` on the remote (`--src-workspace PATH` to override). Nothing is installed unless every step succeeds, and it never overwrites a sandbox already here. Sub-options: `--dry-run`, `--yes` |
| `--remove-sandbox` | Permanently delete a sandbox directory (preserves **nothing**, unlike `--reset-sandbox`). Three selectors: default/`--workspace PATH` (workspace must still exist), `--sandbox NAME` (workspace already gone), `--orphans` (every sandbox whose recorded workspace is gone). Filesystem-only. Sub-options: `--dry-run`, `--yes` |
| `--provision` | Non-interactively create one workspace's sandbox by running the **real launch path** once (start a detached session, confirm it's up, stop it) — never a flag that fabricates state. Safe no-op against a live session. **`--all`** does every sandbox sandy already knows about that is missing the per-sandbox state a launch creates (`pip/` since 2.6.0; `relay-state/` was the target from 2.2.0 through 2.5.x, but a launch no longer creates it) — the state `--reset-sandbox` leaves behind. Needs Docker. Sub-options: `--workspace PATH`, `--all`, `--dry-run`, `--yes` |
| `--doctor` | Host + runtime readiness check (git/curl/docker/PATH/credentials, plus image staleness and orphaned resources). Exit `0` iff every required host check passes; runtime findings are warnings. Sub-options: `--fix` (clear a dead lock, reap orphaned networks), `--yes` |
| `--gc` | One-shot global reclaim of leaked sandy Docker resources: dead-owner containers, orphaned `sandy_*` networks, orphaned per-project/skill images, dangling images. Sub-options: `--dry-run`, `--yes` |
| `--print-state` / `--print-schema` / `--print-version` / `--validate-config` | Machine-readable JSON introspection (runtime state / static schema / version). Fast-path, no Docker needed for schema/version. See [`SPEC_INTROSPECTION.md`](../../SPEC_INTROSPECTION.md) |
| `--approvals` | Before launching without a terminal (CI, cron, a UI with no pty), see what each approval gate would do for this workspace: privileged keys in its `.sandy/config`/`.sandy/.secrets` (dropped if unapproved), symlinks escaping it (launch refused), its `.sandy/Dockerfile` (base image used instead). One JSON document; key **names** only, never values. **Read-only** — it grants nothing; approve by launching once from a terminal. Exit `0` all approved or not applicable, `2` something pending/changed/refused, `1` no report. No Docker needed. Sub-options: `--workspace PATH` |
| `--accounts` | See which Anthropic account each sandbox's Claude Code is signed in to: one row per sandbox, stopped sandboxes first and running ones last (nearest your prompt), with its **email**, **organization** and **plan** (e.g. `Max 20x`, `Team (standard)`, `Enterprise (premium)`), the credential mode its last launch used, and whether a session holds it now. It shows what Claude Code last recorded in that sandbox, not a live query: your login is read from the host at every launch, so a re-login shows up after the next session, and with credential mode `api-key` or `none` the account shown is not what billed. Prints personal data. No Docker needed. Sub-options: `--json` (one JSON document), `--workspace PATH` |

**`--start` exit codes:** `0` = ready, `6` = refused before launch (an approval couldn't be granted — answer it once interactively), `7` = container crash-looping, `8` = timed out waiting for the session.

**Approvals under `--start`.** Run from a terminal, `--start` asks every launch approval — privileged keys in a workspace config, symlinks that escape the workspace, and a `.sandy/Dockerfile` build — on *that* terminal before it detaches, and only then starts the background session. Declining a symlink stops `--start` with `6`; declining the Dockerfile does not — the session starts on the base agent image, as it would in the foreground. A client with no terminal at all can't be asked, so each gate fails closed unless approved earlier — `sandy --approvals` shows which ones would, before you launch; `SANDY_AUTO_APPROVE_PRIVILEGED=1` (env-only, for CI) bypasses the config-key and Dockerfile gates but **not** the symlink gate, deliberately.

All other arguments are forwarded to `claude`.

## Per-project secrets

`.sandy/.secrets` uses the same `KEY=VALUE` format as `.sandy/config` but is intended for credentials. Add it to `.gitignore`:

```
.sandy/.secrets
```

## Screenshot skill (`/ss`)

Set `SANDY_SCREENSHOT_DIR=<host-path>` in `~/.sandy/config` (privileged tier — set freely here, or per-workspace `.sandy/config` with one-time approval) to give the agent **eyes**: sandy mounts the folder read-only into the container and generates a per-agent `/ss` skill that finds the newest screenshots and feeds them to the model.

```sh
# in ~/.sandy/config
SANDY_SCREENSHOT_DIR=/Users/you/Desktop/organized-screenshots
```

Usage inside a session:

```
/ss              # newest screenshot, no instruction → agent describes it
/ss huh          # newest screenshot + "huh" → agent explains
/ss 3 explain    # 3 newest screenshots, agent explains the set
/ss fix          # newest is an error message → agent diagnoses + fixes
/ss do this      # newest is a technique you saw → agent applies it
/ss make infographic  # newest N → agent synthesizes one
```

| Agent | How to invoke |
|---|---|
| Claude | `/ss [N] [action]` slash command |
| Gemini | `/ss [N] [action]` slash command |
| Codex  | "look at my recent screenshot" — codex matches by description |
| OpenCode | manual: `opencode "explain $(sandy-ss-paths 1)"` (no slash-command surface in v0) |

No default — leaving `SANDY_SCREENSHOT_DIR` unset disables the feature entirely. macOS users typically point at `~/Desktop` (the macOS default for `Cmd+Shift+4` captures) or a custom folder configured via `defaults write com.apple.screencapture location <path>`. The mount is read-only by design; the agent should never modify your screenshot folder.
