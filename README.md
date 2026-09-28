[![License: MIT](https://img.shields.io/github/license/rappdw/sandy)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/rappdw/sandy)](https://github.com/rappdw/sandy/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()

# sandy — an isolated sibling for your coding agents

> ### ⚠️ Upgrading from 1.x? Migrate your sandboxes first
>
> 2.0 renames the container user and home from `claude` to `sandy`. `/home/claude` is baked into virtualenv shebangs, `GOPATH`, `PYTHONUSERBASE` and npm/cargo metadata, so **every sandbox created by 1.x must be migrated** — sandy refuses to launch against one rather than limping into it and failing later in ways that look like broken packages.
>
> **Your workspaces are never touched.** The change is entirely inside sandy's own state under `~/.sandy/`.
>
> ```sh
> sandy --reset-sandbox --all --dry-run                 # see exactly what it will do
> sandy --reset-sandbox --all --keep-history --yes      # migrate, keeping transcripts + memory
> ```
>
> `--keep-history` preserves every session transcript and all auto-memory. **It is not the default, and `--yes` does not choose it** — the same command is how you remediate a sandbox you distrust, and there memory is the thing you most want gone. Run it interactively and sandy asks; run it non-interactively and it requires an explicit `--keep-history` or `--purge-history` rather than guessing.
>
> **Do not use `rm -rf` on a sandbox directory.** It also destroys `agent-args.*` — operator state that nothing recreates.
>
> **[Full upgrade guide →](#upgrading-to-20)** — what is preserved, what to back up first, and what to do about scripts that hardcode `/home/claude`.

When you're giving AI agents real autonomy to write code, run tests, and modify systems, the environment needs OS-enforced boundaries, not permission prompts. Sandy is the tool we built to make that work.

Sandy is **two things at once**: a **security sandbox** that keeps a rogue or prompt-injected agent off your machine, and a **per-project virtual environment** that keeps each project's agent state — plugins, memory, credentials, installed packages — from bleeding into the others. It's the same `venv` mental model you already use for Python, applied to your whole coding-agent setup — and the second half is useful even if you completely trust the agent.

Install it, run it. That's it.

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
cd /path/to/your/project
sandy
```

Sandy runs Claude Code, Gemini CLI, OpenAI Codex CLI, OpenCode (provider-agnostic), Grok Build (xAI), or any combination of them side-by-side in a Docker container with agent permission checks disabled — so the agent works without interruption while your system stays protected and each project stays cleanly isolated:

- **Per-project sandboxes**: Isolated `~/.claude` (and `~/.gemini` / `~/.codex` / OpenCode / `~/.grok`), credentials, memory, and package storage per project — no bleed between projects (the "venv" model, [detailed below](#virtual-environments-for-your-coding-agents))
- **Filesystem**: Read/write limited to the mounted working directory only
- **Network**: Public internet only — all LAN/private networks blocked
- **Resources**: Capped CPU and memory (auto-detected from host)
- **Security**: Non-root user, read-only root filesystem, no privilege escalation
- **Protected files**: Shell configs, git hooks, and Claude settings/hooks mounted read-only
- **Dev environments**: Python, Node.js, Go, Rust, and C/C++ with persistent package installs
- **Terminal notifications**: OSC passthrough enabled — works with [cmux](https://www.cmux.dev/), iTerm2, and other notification-aware terminals

No `ANTHROPIC_API_KEY` required if using a Claude paid account (Pro/Max) — credentials are seeded from the host on first run.

## Virtual Environments for Your Coding Agents

Coding agents like Claude Code store plugins, memory, hooks, credentials, and session history in a single global directory (`~/.claude/`, and the equivalent for Gemini / Codex / OpenCode) — shared across every project on your machine. This means a plugin installed for one project is active in all of them. Credentials are shared. Memory bleeds between contexts.

Sandy fixes this with **per-project sandboxes** — the same idea as Python virtual environments, but for your entire coding-agent environment:

```
~/.sandy/sandboxes/
├── webapp-a1b2c3d4/         # project A — one subdir per agent
│   ├── claude/              # mounted at ~/.claude in the container
│   │   ├── plugins/         # plugins installed here stay here
│   │   ├── memory/          # auto-memory is project-scoped
│   │   └── settings.json    # settings don't leak across projects
│   ├── gemini/              # mounted at ~/.gemini (only if SANDY_AGENT uses gemini)
│   ├── codex/               # mounted at ~/.codex  (only if SANDY_AGENT uses codex)
│   └── opencode/            # mounted at ~/.config/opencode + ~/.local/share/opencode
│       │                    # (only if SANDY_AGENT uses opencode)
│       ├── config/
│       └── share/
└── ml-pipeline-e5f6g7h8/    # project B is completely independent
    └── claude/
        └── ...
```

Each project sandbox also gets **isolated package storage** — pip, npm, go, cargo, and uv installs persist across sessions but never leak between projects. Credentials are read fresh from the host each launch and mounted ephemerally — never persisted to the sandbox.

This means you can run multiple sandy sessions across different projects simultaneously, each with its own plugins, memory, context, and installed tools — just like activating different Python venvs.

## Isolation layers

Sandy wraps the agent in seven layers of OS-enforced isolation. For the assumed adversary and the honest residual risks, see [`docs/security/THREAT_MODEL.md`](docs/security/THREAT_MODEL.md).

1. **Network egress.** The agent runs on a Docker `--internal` network with no route off it except a TCP-only proxy sidecar. *Permissive* (default) blocks LAN/host/cloud-metadata and allows the public internet; *strict* allows only an allowlist (model providers, GitHub, package registries) plus `SANDY_ALLOW_HOSTS`. Non-TCP traffic (UDP/QUIC/ICMP/IPv6) is dropped by the topology itself. See [How Network Isolation Works](#how-network-isolation-works).
2. **Filesystem.** Read-only root filesystem; ephemeral `tmpfs` for `/tmp` and the home directory (lost on exit); **only the working directory** is bind-mounted from the host. ~25 sensitive paths inside it (shell configs, `.git/config`, `.git/hooks/` — and a redirected `core.hooksPath` directory — `.claude/settings*.json` / `.claude/hooks/`, `.github/workflows/`, `.vscode/`, `.devcontainer/`, `.sandy/`, …) are mounted **read-only**. A per-project `.sandy/Dockerfile` build is approval-gated (it runs host commands with unfiltered network) — unapproved in a non-interactive session, sandy skips it and uses the base image.
3. **Credentials.** Each project gets its own credential sandbox. The session's `.credentials.json` is mounted **ephemerally and never persisted**; codex/gemini OAuth files are mounted read-only. One project's credentials never leak to another. **claude.ai account connectors** (Gmail, Drive, …) are **suppressed by default** — the account-scoped OAuth token no longer silently exposes them to every sandbox (opt back in per-instance with `SANDY_CLAUDE_CONNECTORS=1`). For a workspace you actively distrust, `SANDY_SUSPICIOUS=1` **strips the OAuth refresh token** before mounting (leaving only the short-TTL access token, so an exfiltrated copy can't be renewed), forces connectors off, and defaults egress to strict. The credential posture is recorded as `cred_mode` in the in-container session marker.
4. **Process & privilege.** Non-root user, `--cap-drop ALL`, `--security-opt no-new-privileges`, Docker's default seccomp + AppArmor profiles, and **no Docker socket** — so the agent can't escalate or reach the daemon.
5. **Resources.** Capped CPU, memory, PID count, and `tmpfs` sizes (auto-detected from the host).
6. **Config trust-tier.** A committed `.sandy/config` is **parsed as `KEY=VALUE`, never sourced** (no shell execution), and can only set non-privileged keys; isolation toggles and credential variables require an explicit per-workspace approval prompt.
7. **Per-instance.** Per-session Docker networks, a per-workspace mutex (one sandy per workspace), and per-project sandboxes keep concurrent sessions and different projects fully independent.

## Prerequisites

Sandy works with any Docker-compatible runtime:

- [Rancher Desktop](https://rancherdesktop.io/)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Colima](https://github.com/abiosoft/colima)
- [Lima](https://github.com/lima-vm/lima)

Not sure whether your machine is ready? Run the doctor script — it checks the host for everything sandy needs (Docker daemon reachable, git, curl, `gh` CLI for default token auth, Claude credentials, `$HOME/.local/bin` on PATH) and prints copy-pasteable install commands for anything missing. It never installs or modifies anything itself.

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/doctor.sh | bash
```

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/rappdw/sandy/main/install.sh | bash
```

Or install locally from a clone:

```bash
LOCAL_INSTALL=./sandy ./install.sh
```

## Usage

```bash
cd /path/to/your/project
sandy                                              # interactive session
sandy -p "Review the code in src/ for security issues"  # one-shot prompt
sandy --remote                                     # remote-control server mode
```

### Daemon mode

By default a sandy session lives and dies with the terminal that launched it.
**Daemon mode decouples the two** — start a session detached, attach and detach
interactive clients whenever you like, and stop it explicitly when you're done:

```bash
sandy --start      # launch a detached session for this workspace; returns once attachable
sandy --attach     # attach an interactive client (last-attach-wins; a second attach
                   # cleanly displaces the first — no screen mirroring)
sandy --stop       # tear the session down completely (container, networks, lock)
```

The container runs with `--restart unless-stopped`, so a daemon session
**survives a host reboot or Docker restart** — close your laptop, come back
tomorrow, and `sandy --attach` picks up where you left off. `--start` is
idempotent (a second `--start` is a no-op), and running bare `sandy` in a
workspace that already has a daemon session errors with a hint to `--attach` or
`--stop` rather than clobbering it. `--start` is interactive-only (it rejects
`-p`/`--print`).

**Exit codes** — `--attach`: `0` = the session ended while you were attached,
`3` = you detached cleanly and the session is still running, `4` = no such
session (`5` is a `--stop` code, unreachable on `--attach`). `--stop`: `0` = stopped, `4` = no such session,
`5` = teardown failed.

This is what [`sandy-ui`](https://github.com/rappdw/sandy-ui) uses to keep a
session alive across a VSCode quit/relaunch.

#### Remote access: what sandy covers, and what sits below it

Three things get conflated when sandy runs on a remote machine (an always-on
workstation or GPU box you reach from a laptop). Sandy owns exactly one of them.

- **Session persistence — sandy's layer.** A daemon session lives on the host
  that ran `sandy --start`, independent of any client. When your SSH or VS Code
  Remote connection drops, only the *client* is gone: the container and its tmux
  session keep running. Reconnect however you like, then `sandy --attach` (from
  the workspace, or with `--workspace PATH`) and carry on. If your client was
  killed mid-attach (a `SIGHUP` from a closed terminal), just run `--attach`
  again; it exits `4` if the session is genuinely gone. A foreground `sandy`
  (no `--start`) is the exception: it is tied to the terminal that launched it
  and cannot be reattached.
- **Connection resilience — below sandy.** Keeping the client link itself alive
  across laptop sleep or a flaky network is a transport problem: Remote-SSH, VS
  Code Remote Tunnels, mosh, Eternal Terminal, autossh and the like. Sandy needs,
  and takes, **zero changes** for any of them — it neither bundles nor checks
  for one, and there is no `sandy --tunnel`. Pick whichever you already trust.
- **Session mobility — not a sandy feature.** Reaching a session *from* another
  device is just the two above: get a shell on the host (SSH, over Tailscale or
  any VPN) and `sandy --attach`. Moving a running session *to* a different
  machine is something sandy does not do; the session stays on the host that
  started it. `sandy --rsync <host>` copies a sandbox's state to another host so
  a new session can start there, and it refuses while a session is live.

These transports run on the **host**, outside sandy's containers, so they are
orthogonal to its isolation: sandy's network blocking applies to what the
*agent* can reach from inside the container (the `--internal` sidecar and egress
proxy), and a host-side `sshd`, `etserver` or tunnel is neither weakened by it
nor governed by it. Securing the path to your host is the host's business.

### Fleet updates (`--update-sessions`)

Daemon sessions can sit up for days, running an ever-staler image. `sandy --update-sessions` is a **global** maintenance command (ignores cwd — it operates on every daemon session on the host) that refreshes each session's images and rolling-restarts the ones that came out stale:

```bash
sandy --update-sessions --dry-run           # show the plan, refresh images, restart nothing
sandy --update-sessions --yes               # restart every stale session, no confirmation prompt
sandy --update-sessions --idle-for 30 --yes # only restart sessions idle 30+ minutes (cron-friendly)
sandy --update-sessions --rebuild --yes     # force a rebuild before checking staleness
sandy --update-sessions --yes --workspace ~/dev/myproj   # scope to ONE session (per-session update)
```

For each session it runs that workspace's own `sandy --build-only` (so image selection, skills, and any per-project Dockerfile are resolved the same way a normal launch would resolve them), compares the running container's image ID against the freshly-built one, and — for anything stale — does `sandy --stop` followed by `sandy --start` for you. `--dry-run` still refreshes images (so the printed plan reflects reality) but never stops or starts anything. Without `--idle-for`, every stale session is a restart candidate; a TTY without `--yes` gets a y/N confirmation, and a non-interactive run without `--yes` refuses with exit `1` — pass `--yes` explicitly for cron/launchd. Exit `0` means everything is clean (including "nothing to do"); exit `1` means something failed or the non-interactive prompt was refused.

A cron/launchd recipe for a nightly quiet-hours refresh:

```cron
0 3 * * * /path/to/sandy --update-sessions --idle-for 30 --yes >> ~/.sandy/update-sessions.log 2>&1
```

Restarted sessions carry a `sandy.updated_at` container label so tooling (e.g. `sandy-ui`) can distinguish "restarted for an image update" from a session you stopped and started yourself.

## Configuration

### Per-project config (`.sandy/config`)

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

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `SANDY_AGENT` | `claude` | AI agent(s) to run. Single: `claude`, `gemini`, `codex`, `opencode`. Multi (comma-separated, 2–4 panes in tmux): e.g. `claude,gemini` or `claude,gemini,codex,opencode`. Alias: `all` = `claude,gemini,codex,opencode` |
| `SANDY_MODEL` | `claude-opus-5` | Claude model to use (applies whenever `claude` is in `SANDY_AGENT`) |
| `SANDY_EFFORT` | _(each agent's own default)_ | Reasoning effort for claude and codex: `low`\|`medium`\|`high`\|`xhigh`\|`max`. Applied as `claude --effort` and (2.4.0) codex `-c model_reasoning_effort=<level>` (each level maps to its codex namesake); ignored with a notice for gemini/opencode/grok. Recorded in `sandy-session.json` so a run's effort is provable |
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
| `SANDY_RELAY` | `1` | Run the installed relay if there is one — since 2.2.0 that means a feature manifest `entry`. A **capability** toggle naming no path: inert when nothing is installed. `0` disables the relay capability entirely (including an `entry`, which it did not before), loudly. Passive-safe. See "Installing a relay" |
| `SANDY_CROSS_SESSION_INBOUND` | _(conditional)_ | Whether another local session may inject a turn into this one (Claude Code's `crossSessionInbound`): `accept` (delivered, no prompt), `hold` (interactive approval), `refuse` (sender told it was not accepted). Unset resolves to `accept` when a **selected feature manifest declares `"receives": ["cross_session"]`** (2.4.0) — otherwise `refuse`, so a workspace with neither has no open receive surface. (An entry alone, with no declared `receives`, used to also resolve `accept` — that legacy default was announced for removal in 2.5.0 and REMOVED in 2.6.0.) `hold`/`refuse` are passive-safe; `accept` from a workspace `.sandy/config` triggers an approval prompt. Claude-only. See "Features" and `cross_session_inbound_source` in the session marker |
| `CLAUDE_CODE_OAUTH_TOKEN` | (unset) | Long-lived OAuth token from `claude setup-token`. Put in `.sandy/.secrets`. Recommended for headless servers |
| `ANTHROPIC_API_KEY` | (unset) | API key — not needed with Claude Pro/Max (OAuth). **Not forwarded when a Claude OAuth credential is already going into the container** (Claude Code resolves an env key ahead of the account credentials, so forwarding both either bills per-use or parks the session on Claude Code's custom-API-key startup prompt). Set `SANDY_CLAUDE_AUTH=api_key` to use it anyway |
| `SANDY_CLAUDE_AUTH` | `auto` | Force Claude auth path: `auto`, `api_key`, `oauth`, or `profile`. `api_key` withholds **both** the OAuth credentials file and a long-lived token, so one revocable key is the only Claude credential in the container; `oauth` never forwards the API key; `profile` uses an Anthropic Console profile from `ant auth login` — the route to workspace-bound entitlements such as **Claude Mythos** (see "Using a Console profile" below). `api_key` and `profile` are passive-safe (each reduces what is in the box); `oauth` from a workspace `.sandy/config` triggers an approval prompt |
| `ANTHROPIC_PROFILE` | (unset) | With `SANDY_CLAUDE_AUTH=profile`, the named Console profile to use instead of the host's active one. **Privileged**: it picks *which* profile's token enters the container, and an `org:admin` profile carries organization-wide access, so a committed config cannot select it |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `128000` | Max output tokens per response (Claude Code default is 32K) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | (unset) | Model for **subagents** — the parallel researchers a skill fans out. Subagents do *not* inherit the orchestrator's model, so unset they run on their own default tier: a session pinned to a gated model (e.g. `claude-mythos-5-1`) silently does its fan-out on a different one. Set it alongside `SANDY_MODEL` |
| `SANDY_CLAUDE_CONNECTORS` | `0` | `1` = expose claude.ai **account connectors** (Gmail, Drive, …) inside the sandbox. Default `0` suppresses them — the account-scoped OAuth token would otherwise make every connector reachable from every sandbox. Weakens isolation, so a workspace `.sandy/config` setting it triggers an approval prompt. Claude-only |
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

### Flags

| Flag | Description |
|---|---|
| `--new` | Start a fresh session (default: resume last) |
| `--resume` | Open session picker (forwarded to claude) |
| `--remote` | Start in [remote-control](https://code.claude.com/docs/en/remote-control) server mode (connect from browser/phone) |
| `--rebuild` | Force rebuild of the Docker image |
| `--build-only` | Build images and exit (for CI) |
| `--no-update-check` | Skip update checks for this launch (one-shot `SANDY_OFFLINE=1`; wins over config). Works with a bare launch, `-p`, `--build-only` and `--start` |
| `--upgrade` | Update sandy to the latest version from GitHub |
| `--agent <list>` | Agent(s) to launch — overrides `SANDY_AGENT` and `.sandy/config` (e.g. `--agent claude,gemini`) |
| `-p "prompt"` | One-shot prompt (no interactive session) |
| `--start` | Start a detached [daemon session](#daemon-mode) and return once attachable |
| `--attach` | Attach an interactive client to a running daemon session |
| `--stop` | Stop a running daemon session (full teardown) |
| `--exec [-- CMD]` | Shell (or run `CMD`) inside this workspace's running container, **as the host uid**. Do not hand-roll it: `docker exec -u sandy` resolves the name against the *image*, where the user is uid 1001, so it runs as the wrong owner and prints `I have no name!`. Sub-options: `--workspace PATH`, `--dry-run`. See [Getting a shell inside a running sandbox](#getting-a-shell-inside-a-running-sandbox-sandy---exec) |
| `--stop-all` | **Fleet emergency stop** — stop every daemon session on the host via the hardened per-session teardown. Sub-options: `--dry-run`, `--yes` |
| `--prune-orphans` | Reap orphaned `sandy_*` Docker networks and exit |
| `--update-sessions` | Fleet image refresh + rolling restart across every daemon session on the host (scope to one with `--workspace PATH`). See "Fleet updates" above. Sub-options: `--dry-run`, `--yes`, `--idle-for <minutes>`, `--rebuild`, `--workspace` |
| `--reset-sandbox` | Rebuild **one** project's sandbox from a known-good skeleton — destroy its persistent package/agent state (preserving `WORKSPACE.json` lineage), refusing while a live session holds it. Filesystem-only, no Docker. "When in doubt, rebuild" in one command. Sub-options: `--workspace PATH` (default cwd), `--keep-approvals`, `--dry-run`, `--yes` |
| `--rsync HOST` | **Copy** this workspace's sandbox to another host, even when the workspace lives at a different path there: renames it for the destination and rewrites the path-keyed state a hand `rsync` gets wrong (session history and memory, `.claude.json`, `WORKSPACE.json`). The destination workspace defaults to the same path under `$HOME` (`--dest-workspace PATH` to override) and must already exist. Credential files are copied and named in the plan; on a different CPU architecture the package caches are skipped and rebuild on first use. Sub-options: `--dry-run`, `--yes` |
| `--remove-sandbox` | Permanently delete a sandbox directory (preserves **nothing**, unlike `--reset-sandbox`). Three selectors: default/`--workspace PATH` (workspace must still exist), `--sandbox NAME` (workspace already gone), `--orphans` (every sandbox whose recorded workspace is gone). Filesystem-only. Sub-options: `--dry-run`, `--yes` |
| `--provision` | Non-interactively create one workspace's sandbox by running the **real launch path** once (start a detached session, confirm it's up, stop it) — never a flag that fabricates state. Safe no-op against a live session. **`--all`** does every sandbox sandy already knows about that is missing the per-sandbox state a launch creates (`relay-state/`) — the state `--reset-sandbox` leaves behind. Needs Docker. Sub-options: `--workspace PATH`, `--all`, `--dry-run`, `--yes` |
| `--doctor` | Host + runtime readiness check (git/curl/docker/PATH/credentials, plus image staleness and orphaned resources). Exit `0` iff every required host check passes; runtime findings are warnings. Sub-options: `--fix` (clear a dead lock, reap orphaned networks), `--yes` |
| `--gc` | One-shot global reclaim of leaked sandy Docker resources: dead-owner containers, orphaned `sandy_*` networks, orphaned per-project/skill images, dangling images. Sub-options: `--dry-run`, `--yes` |
| `--print-state` / `--print-schema` / `--print-version` / `--validate-config` | Machine-readable JSON introspection (runtime state / static schema / version). Fast-path, no Docker needed for schema/version. See [`SPEC_INTROSPECTION.md`](SPEC_INTROSPECTION.md) |

**`--start` exit codes:** `0` = ready, `6` = refused before launch (an approval couldn't be granted — answer it once interactively), `7` = container crash-looping, `8` = timed out waiting for the session.

**Approvals under `--start`.** Run from a terminal, `--start` asks every launch approval — privileged keys in a workspace config, symlinks that escape the workspace, and a `.sandy/Dockerfile` build — on *that* terminal before it detaches, and only then starts the background session. Declining a symlink stops `--start` with `6`; declining the Dockerfile does not — the session starts on the base agent image, as it would in the foreground. A client with no terminal at all can't be asked, so each gate fails closed unless approved earlier; `SANDY_AUTO_APPROVE_PRIVILEGED=1` (env-only, for CI) bypasses the config-key and Dockerfile gates but **not** the symlink gate, deliberately.

All other arguments are forwarded to `claude`.

### Headless / remote servers

**Recommended**: Use a long-lived token (valid 1 year) to avoid OAuth expiry entirely:

1. On a machine with a browser, run: `claude setup-token`
2. Copy the token and add to `~/.sandy/.secrets` on the headless server (applies to all projects):
   ```
   CLAUDE_CODE_OAUTH_TOKEN=your_token_here
   ```
3. Run `sandy` — no browser needed, no `/login` needed

**Fallback** (without a long-lived token): Sandy skips the browser-based OAuth flow on Linux and directs you to use `/login` inside the session.

The `/login` URL is long and Claude Code wraps it with indentation, which breaks copy-paste. To work around this on macOS:

1. Select the wrapped URL text in your terminal and copy it (Cmd+C)
2. Clean and open it with: `pbpaste | tr -d ' \n\t' | xargs open`

To automate this as a global keyboard shortcut (e.g., Ctrl+Cmd+U):

1. Open **Automator** > File > New > **Quick Action**
2. Set "Workflow receives" to **no input** in **any application**
3. Add a **Run Shell Script** action with: `pbpaste | tr -d ' \n\t' | xargs open`
4. Save as "Open Cleaned URL"
5. Assign a shortcut in **System Settings > Keyboard > Keyboard Shortcuts > Services**

### Getting a shell inside a running sandbox (`sandy --exec`)

```sh
sandy --exec                  # interactive shell in this workspace's container
sandy --exec -- codex login --device-auth
sandy --exec --workspace ~/other-project -- git status
sandy --exec --dry-run        # print the docker exec command, run nothing
```

**Do not hand-roll this.** The obvious form is wrong in a way that does not announce itself:

```sh
docker exec -it -u claude <container> /bin/bash     # -> "I have no name!"
```

The image creates the user with `useradd -u 1001 claude`, but sandy bind-mounts a generated `/etc/passwd` carrying **your** uid so bind-mount ownership works. Docker resolves `-u <name>` against the container's *image* filesystem, not the runtime mount — so `-u sandy` runs as **uid 1001**. The prompt reading `I have no name!` is the harmless symptom; the real one is that every write lands as the wrong owner on a workspace mount owned by you.

`--exec` uses the numeric `-u $(id -u):$(id -g)`, sets `-w` to the container-side workspace path, and sets `HOME` explicitly (as root, `HOME=/root` sits on the read-only rootfs — which is why an in-container `codex logout` fails with `Read-only file system`). It finds a daemon container by label and a foreground one by exact name, exits `4` when the workspace has no running container, and otherwise passes the command's own exit status through.

For an interactive *agent* session, attach to the tmux session instead: `sandy --attach`.

### Using a Console profile — Claude Mythos and workspace-scoped access

Some Claude entitlements are granted to a **Console workspace**, not to an API key or a claude.ai subscription — Claude Mythos 5.1 (`claude-mythos-5-1`, Project Glasswing) is one. You reach them with an *Anthropic profile* written by the Claude Platform CLI, `ant`. Sandy supports that as `SANDY_CLAUDE_AUTH=profile`:

```sh
# on the HOST (browser flow; use --no-browser on a remote box):
ant auth login --workspace-id wrkspc_<id>      # binds the profile to the workspace
ant auth status                                # want: "(active) * Profile (user_oauth)"

# ~/.sandy/config
SANDY_CLAUDE_AUTH=profile
SANDY_MODEL=claude-mythos-5-1                  # or set it per workspace in .sandy/config
```

What sandy does on each launch: copies **only the selected profile** (`ANTHROPIC_PROFILE`, else the host's `active_config`, else `default`) from `~/.config/anthropic` into an ephemeral read-write mount at the same path in the container, and **withholds** `~/.claude/.credentials.json`, `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`. That is not optional: Claude Code ranks a profile *below* a `/login` credential and below every environment credential, so any of those in the box would silently win and you would be running on the wrong account. Inside, `/status` shows a `Profile` row; the session marker records `cred_mode: "profile"`.

Two things to know. The mount is a copy, so an in-session token refresh never rewrites the host's file (same rule as `.credentials.json`) — the host copy refreshes when you use `ant` or Claude Code there. And a profile directory can hold several profiles; sandy copies one, never the directory, so an `admin` profile on your host does not ride along.

Run `ant auth login` on the host, not in the container — the browser callback cannot reach a port bound inside the sandbox.

### Running Gemini CLI (`SANDY_AGENT=gemini`)

Sandy supports four Gemini auth paths, probed automatically unless `SANDY_GEMINI_AUTH` pins a specific one:

| Path | How to set up | When to use |
|---|---|---|
| **API key** (recommended) | `GEMINI_API_KEY=...` in `.sandy/.secrets` | Simplest; works on headless servers |
| ADC | `gcloud auth application-default login` on the host | Google Cloud / Vertex AI workflows |
| Vertex AI | ADC + `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT=...`, `GOOGLE_CLOUD_LOCATION=...` | Enterprise / Vertex billing |
| OAuth (browser login) | Run `gemini auth` **on the host** once — sandy copies `~/.gemini/oauth_creds.json` (Gemini CLI ≥0.30; falls back to legacy `tokens.json`) into the container ephemerally on each launch | ⚠️ **See note below — free-tier OAuth is deprecated upstream** |

> ⚠️ **Gemini free-tier OAuth is deprecated by Google.** As of mid-2026, Google
> retired the free-tier `gemini-cli` OAuth login ("Gemini Code Assist for
> individuals") — a session using it fails with `IneligibleTierError` (redirect
> to the Antigravity product suite). This is **upstream**, not a sandy issue:
> sandy loads and forwards the credentials correctly; Google rejects them at the
> tier check, and the same happens running `gemini-cli` directly. **Use the API
> key or Vertex/ADC path instead.** (Tracked: issue #21.)

`gemini auth` must be run on the host because the container is headless and cannot open a browser. `--remote` is not supported in any multi-agent combo — only `SANDY_AGENT=claude` (single) works with `--remote`.

### Running Codex CLI (`SANDY_AGENT=codex`)

Sandy supports two Codex auth paths, probed automatically unless `SANDY_CODEX_AUTH` pins a specific one:

| Path | How to set up | When to use |
|---|---|---|
| API key | `OPENAI_API_KEY=sk-...` in `.sandy/.secrets` — sandy writes it into an ephemeral `auth.json` (what `codex login --with-api-key` would create) and mounts it **read-only**; codex 0.139+ ignores the bare env var for auth | Simplest; works on headless servers |
| OAuth (ChatGPT) | Run `codex login` **on the host** once — sandy copies `~/.codex/auth.json` into the container as a **read-only** mount on each launch | ChatGPT Plus/Team/Enterprise accounts |

Because the OAuth mount is read-only, in-session token refresh will fail — if your token expires, run `codex login` inside the sandy session (or back on the host for next launch). This is intentional: a writable mount would leak refreshed tokens back to the host and open a stale-token race on session exit.

Sandy forces `sandbox_mode = "danger-full-access"` in the container's `~/.codex/config.toml` and passes `--sandbox danger-full-access` on the CLI (belt-and-suspenders). Codex's Landlock sandbox does not nest cleanly inside Docker — sandy provides the outer isolation. On first launch sandy also seeds a full `[notice]` block in `config.toml` to suppress all first-run prompts and appends a trusted-project entry for your workspace.

Headless mode (`-p` / `--print` / `--prompt "..."`) translates to `codex exec --skip-git-repo-check` — the prompt is passed as a positional arg, not a flag, and the trust/git-repo gate is skipped (codex 0.139+ otherwise refuses to run headless outside a git repo; sandy already provides the isolation). `codex exec` only returns exit codes 0 (success) or 1 (failure), with no nuanced exit codes. `--continue` / `-c` is silently dropped (codex has `codex resume`, but no headless continuation flag).

Not supported with `codex`: `--remote`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS=discord`. Telegram channels work via the host-side tmux relay.

### Running OpenCode (`SANDY_AGENT=opencode`)

OpenCode (sst/opencode) is a provider-agnostic agent — sandy doesn't bind it to a specific LLM vendor. Set whichever provider key you have (in `.sandy/.secrets` or env), tweak `~/.config/opencode/opencode.json`, and OpenCode picks the matching provider:

| Provider | Key | Notes |
|---|---|---|
| Anthropic | `ANTHROPIC_API_KEY=sk-ant-...` | OpenCode reads natively |
| OpenAI | `OPENAI_API_KEY=sk-...` | Shared with Codex agent if both active |
| Google | `GEMINI_API_KEY=...` | Shared with Gemini agent if both active |
| OAuth | `opencode auth login` on host → `~/.local/share/opencode/auth.json` | Mounted read-only into the container |

Sandy seeds `~/.config/opencode/opencode.json` from the host's copy on first launch — point it at any provider OpenCode supports, including a local LLM.

**Local LLM passthrough.** Pair OpenCode with `SANDY_LOCAL_LLM_HOST=<ip>:<port>` (e.g. `127.0.0.1:11434` for Ollama, `localhost:8000` for vLLM, etc.) to allow the container to reach a local LLM running on the Docker host. With the egress proxy on (default), the proxy's dedicated forward listener relays `host.docker.internal:<port>` to the real host; with the proxy off (`SANDY_EGRESS=off`, Linux) sandy instead inserts a single narrow `iptables ACCEPT` for that exact `host:port` and maps `host.docker.internal` to the bridge gateway (Linux Docker doesn't auto-resolve it). Either way sandy rejects world-open IPs (`0.0.0.0`) and bare IPs without ports. Edit `~/.config/opencode/opencode.json` to set the provider's `baseURL` to `http://host.docker.internal:<port>/v1`. The rule is removed on session exit. The rest of LAN remains blocked.

Headless mode (`-p` / `--print` / `--prompt "..."`) translates to `opencode run` — the prompt is positional. `--continue` / `-c` is silently dropped (no headless resume flag yet).

Not supported with `opencode` in v0: `--remote`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS=discord`. Synthkit is installed in the image but skill auto-discovery for opencode is deferred until upstream support stabilizes.

### Running Grok Build (`SANDY_AGENT=grok`)

Grok Build is xAI's coding agent. Sandy installs it in the image from `https://x.ai/cli/install.sh` (a prebuilt binary, relocated onto `PATH` since the home dir is a tmpfs) and authenticates it **fully headless from an `XAI_API_KEY`** — no auth file to manage:

| Auth | How | Notes |
|---|---|---|
| API key | `XAI_API_KEY=xai-...` in `.sandy/.secrets` or env | Forwarded into the container; the primary path |
| OAuth | `grok login` inside the container | Session persists in the `~/.grok` sandbox mount across launches |

- Model: `GROK_MODEL=grok-4.5` (default; passed as `-m`). Probe override: `SANDY_GROK_AUTH=auto|api_key|oauth`.
- Headless mode (`-p` / `--print` / `--prompt "..."`) runs `grok --no-auto-update -p "<prompt>"` (grok can't self-update against the read-only rootfs). `--continue` / `-c` is dropped.
- Not supported with `grok` in v0: `--remote`, `SANDY_SKILL_PACKS`, synthkit slash-commands, channels beyond the host-side Telegram relay. Auto-update detection isn't wired (no version API) — `sandy --rebuild` re-fetches the latest grok.

### Multi-agent mode

Sandy runs any combination of Claude, Gemini, Codex, OpenCode, and Grok side-by-side in a single tmux session — **up to 4 at once** (the layout is a 2×2 grid) — selected via comma-separated values in `SANDY_AGENT`:

```bash
SANDY_AGENT=claude,gemini              # two panes
SANDY_AGENT=claude,codex               # two panes
SANDY_AGENT=claude,opencode            # two panes
SANDY_AGENT=claude,gemini,codex,opencode  # four panes
SANDY_AGENT=all                        # alias for claude,gemini,codex,opencode
```

Panes appear in the order listed. Each agent has its own config dir(s): `~/.claude`, `~/.gemini`, `~/.codex`, and `~/.config/opencode` + `~/.local/share/opencode`. All panes share the same workspace mount. Exiting one pane leaves the others running. Single-agent modes use their own Docker images (`sandy-claude-code`, `sandy-gemini-cli`, `sandy-codex`, `sandy-opencode`, `sandy-grok`); any multi-agent combo uses the `sandy-full` image, which bundles all five CLIs. **Note:** in the 4-agent 2×2 grid, tmux's pane-index numbering does not match the order panes were spawned in — sandy publishes a stable pane-identity contract for anything that needs to tell agents apart in-container (session name, pane option, spawn order); see "Pane-identity contract" in `SPECIFICATION.md`.

**Resizing panes**: `prefix` + `H` / `J` / `K` / `L` (the prefix is tmux's default, `Ctrl-b`) resizes the active pane by 5 cells, moving its border left / down / up / right, and repeats — press the prefix once, then tap the letter as many times as you need. Sandy adds these because tmux's own resize keys do not work on macOS out of the box: `prefix` + Ctrl-Arrow is captured by Mission Control, and `prefix` + Option-Arrow needs the terminal's "Option as Meta" setting. Dragging a pane border with the mouse also works.

**Feature support in multi-agent mode**: skill packs apply to the Claude pane only. Telegram channels use the host-side relay and are routed to the first agent in `SANDY_AGENT` by default — override with `SANDY_CHANNEL_TARGET_PANE=0|1|2|3` (the Nth agent, 0-based; sandy finds that agent's pane by name, so the 2×2 grid routes correctly). `--remote` is not supported in any multi-agent combo. `SANDY_LOCAL_LLM_HOST` works in any combo that includes opencode (or any agent that wants to reach a host-side service over the gateway).

### Screenshot skill (`/ss`)

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

### Per-sandbox directories for a feature

**The `~/.handoff` tree was removed in 2.2.0.** A feature manifest names its own directories instead — see "Features" above — which is more flexible and does not require every sandbox to carry four fixed directories it may not use.

If you were using it: `inbox`, `outbox` and `peer` become manifest `mounts` (`mode: ro` for host-written inbound lanes). Relay state moved to `$SANDBOX_DIR/relay-state`, mounted at `/opt/sandy/relay-state`, and sandy reports that path as `relay.state_dir` in `--print-state` so nothing has to construct it. `SANDY_HANDOFF_DIRS` and the `.handoff-enabled` marker are gone; setting the key is a hard error naming the replacement.

## How Network Isolation Works

> Network egress is one of sandy's isolation layers. For the full picture —
> the assumed adversary, every layer, and the honest residual risks — see
> [`THREAT_MODEL.md`](docs/security/THREAT_MODEL.md). Empirical bypass attempts are in
> [`ISOLATION_STRESS.md`](docs/security/ISOLATION_STRESS.md).


### Re-provisioning sandboxes after a reset

Some per-sandbox state is created **by the launch**, deliberately: it exists only because the thing that mounts it made it, so hand-made state can never pass for working state. Today that is `relay-state/`, plus `feature-state/<feature>` for every non-designated feature entry (see "Installing a relay" below). The cost is that a sandbox can sit without it — most often after `sandy --reset-sandbox`, which keeps the sandbox but destroys everything a launch re-creates, and also after any launch that failed part-way.

To bring every sandbox back in one pass:

```sh
sandy --provision --all --dry-run   # what would be done
sandy --provision --all --yes
```

This provisions every sandbox sandy already **knows about** that is missing that state, serially, through the real launch path. It **cannot** reach a workspace that has never been launched — that has no sandbox directory, so sandy does not know it exists; enrolling one is a deliberate `sandy --provision --workspace PATH`. A sandbox whose workspace has been deleted cannot be provisioned at all: it is named, counted as unprepared, and makes the run exit non-zero rather than being skipped into a false success.

A sandbox with a **live session** is named and skipped the same way — it cannot be provisioned while it runs, so the run exits non-zero and tells you to stop it and re-run. Nothing running is ever touched. Because of that, **exit `1` here means "re-read the output and see which", not "something broke"**.

### Features (`$SANDY_HOME/features/<name>/feature.json`)

A **feature** is something you deploy into sandboxes that is not sandy's — a connector, a fleet agent, a shared toolchain. It lives in one directory with a manifest that says which sandboxes get it and what they get:

```json
{
  "sandboxes": { "include": ["*"], "exclude": ["scratch-*"] },
  "agents":    { "include": ["claude"] },
  "create":    ["instances/${slug}/inbox"],
  "mounts": [
    { "name": "payload", "from": "payload", "export": "MYTOOL_DIR" },
    { "name": "inbox",   "from": "instances/${slug}/inbox" }
  ],
  "entry": "payload/relay",
  "agent_args": {
    "claude": ["--mcp-config", "/opt/sandy/features/mytool/mcp-servers.json"]
  }
}
```

Sandy computes every container path — you name a mount, sandy decides where it lands (`payload` at `/opt/sandy/features/<name>`, anything else under `~/.<name>/`) and exports it if you ask. Mounts are **read-only unless you say `rw`**.

**`entry` names a supervised, container-level process** — sandy runs it as a sibling of the tmux server, restarted on death, held to one instance; see "Installing a relay" below. **One `entry` per feature** (2.4.0) — a feature declares at most one, but a sandbox can have several features each with their own, and every one of them runs independently. `SANDY_RELAY=0` stops all of them (since 2.2.0/2.4.0), and the launch says so by name rather than running without them silently.

**Selection is enrolment.** A sandbox gets the feature only if an include matches in both blocks and no exclude matches in either. A sandbox that is not selected gets nothing at all — no mount, no export, no entry. Check what applied:

```sh
sandy --print-state | jq '.sandboxes[] | {name, features, feature_problems}'
```

and `$SANDY_HOME/features/<name>/selected.json` says the same thing for tools that cannot run sandy.

**`agent_args` wires the agent, not just the files** (2.1.0). Mounting a config does not make the agent read it; these are passed to the agent at launch, per agent, straight from the `:ro` payload — so a feature needs no write into the sandbox and leaves nothing behind when you remove it.

A manifest is **all-or-nothing**: an unknown key, an unknown agent name, or a token containing a space refuses the whole file, and that feature's mounts and exports do not happen either. So before a tool writes `agent_args` into a manifest, it should check that the host accepts it — by membership, never by version number:

```sh
sandy --print-schema | jq '.manifest.top_level_keys | index("agent_args")'
```

`null` (or no `.manifest` block at all) means this sandy predates the key: do not emit it. What a launch actually passed is recorded per sandbox:

```sh
sandy --print-state | jq '.sandboxes[] | {name, agent_args}'
```

`{}` means sandy looked and no feature contributed; `null` means the sandbox last launched under a sandy too old to say — not the same thing.

**Two features can contribute the same flag, and for some flags that discards one of them** (2.3.0). `agent_args` is additive in the command line sandy builds; whether it is additive in *effect* is up to the agent. Claude Code reads `--append-system-prompt-file` **once** — the last occurrence wins — so two features each supplying it meant one feature's prompt silently never arrived, with every other signal looking healthy.

Sandy now merges those contributions itself, into a file it owns and mounts `:ro`, and passes the flag once. Which flags it will do this for is published:

```sh
sandy --print-schema | jq '.manifest.agent_args_compose'
```

At one contributor nothing changes. At two or more, the result is recorded per sandbox:

```sh
sandy --print-state | jq '.sandboxes[] | {name, agent_args_composed}'
```

`{}` means no collision; an entry with `composed: false` means sandy **found** a collision and deliberately did not merge it — either the flag replaces rather than appends, or it named a file sandy cannot read — and `from` says which contributors were involved. The launch prints this too, alongside a line naming every feature that applied and what it contributed.

**`receives` declares a need, not a mechanism (2.4.0).** A feature that needs another local session to be able to inject a turn into a session running in its sandbox says so directly:

```json
{
  "sandboxes": { "include": ["*"] },
  "agents":    { "include": ["claude"] },
  "receives":  ["cross_session"]
}
```

`receives` is an array from a closed, published set (today just `cross_session`; `sandy --print-schema | jq '.manifest.receives_values'`) — an unknown value refuses the whole manifest, the same as an unknown top-level key. It names no consumer and no mechanism: a feature can declare this need with **no `entry` at all**, and it is **not** affected by `SANDY_RELAY` — that key gates whether an entry *process* runs, while `receives` is a separate statement of what the feature needs to receive. When a selected feature declares it, `SANDY_CROSS_SESSION_INBOUND`'s unset default resolves to `accept` (unless this is a headless, `--remote` or `--provision` run, which have no session to deliver into). See `SANDY_CROSS_SESSION_INBOUND` above and `docs/security/CROSS_SESSION_INBOUND.md` for the full precedence and residual risks.

Reading a manifest needs `node` or `jq` on the host. If neither is there, a launch that would use one **refuses** rather than mounting a guess — see `sandy --doctor`.

### Installing a relay (`SANDY_RELAY`)

A *relay* is a program sandy runs as a container-level process — a sibling of the tmux server, never a pane — restarted on death with backoff and held to one instance by a lock.

**Installing one is a feature manifest `entry`:**

```json
{
  "sandboxes": { "include": ["*"] },
  "agents":    { "include": ["claude"] },
  "mounts":    [ { "name": "payload", "from": "payload" } ],
  "entry":     "payload/relay"
}
```

> **Removed in 2.2.0.** The two older routes are gone. `SANDY_HANDOFF_RELAY=<path>` as a configuration key, and installing an executable at `~/.sandy/sandboxes/<sandbox>/relay-bin/relay`, are both now **hard errors** naming the replacement — never silent skips, because ignoring either would start the wrong relay, or none, without saying so. `sandy --reset-sandbox` **destroys** a leftover `relay-bin/relay` for the same reason.

`SANDY_RELAY` is the capability toggle. It is on by default and means *"run the installed relay if there is one"* — safe as a default because it is inert without host-side state a repository cannot create: no feature, no entry, nothing to run.

Setting `SANDY_RELAY=0` disables the relay capability for that host or workspace. **Since 2.2.0 that covers a manifest `entry` too** — previously it stopped only the `relay-bin` slot, so `=0` could mean "no relay" while a relay ran. A launch that declines to start a declared entry **says so by name**, and records `disabled_by` in `--print-state` and the session marker, so a cloned repo shipping `0` is visible rather than forbidden.

**More than one feature, more than one entry (2.4.0, #381).** Each selected feature's `entry` runs, independently supervised — its own lock, its own backoff, its own state directory. The **first** one adopted (sorted feature-directory order) is the *relay-designated* entry: it is the one `relay{}`, `SANDY_RELAY_STATE` and `/opt/sandy/relay-state` describe, so a sandbox with a single feature entry — the common case — behaves exactly as before. Every entry, designated or not, is additionally reported per feature:

```sh
sandy --print-state | jq '.sandboxes[] | .feature_entries'
```

Each value carries `state`, `restarts`, `executable_present`, `path`, `state_dir` and `relay_alias` (whether it is the one `relay{}` also describes). `{}` means no feature declared an entry; `null` means the sandbox last launched under a sandy too old to answer.

**Read-only by construction.** An `entry` lives on the feature payload, which the manifest mounts `:ro`. That matters because the container process runs as *your* uid and owns the file, so permission bits bind nothing — `chmod` would succeed against a normal mount and the agent could rewrite its own relay. Under `:ro` the write returns `EROFS`, because the mount flag is checked above the permission check. An adapter can write files; only sandy can create a mount.

**The honest limit**: sandy guarantees the *first* executable. It cannot guarantee the chain — a relay that execs a daemon out of a writable directory is replaceable at that second link.

Two failure shapes, handled differently:

- **Cannot start** (missing, not executable, no `relay-state` mount, no `flock`): fails the launch, before or during container start. **One documented exception**: a stale image built before the `sandy.feature_entries=1` Dockerfile label existed (a build deferred by #218's reachability gate, or any other old cached image) only ever knew the pre-#381 single-relay path, so with more than one entry adopted it starts the relay-designated entry and never sees the rest — that is not a broken entry, so it does not fail the launch. Sandy warns at launch instead, naming every entry that will not start and pointing at `sandy --rebuild`; `--print-state` reports those entries as `state: "absent"`.
- **Starts, then exits**: if the first run exits non-zero within ~5s the session fails with that exit code. Past that window it is a runtime loop, which cannot un-succeed a launch that already completed — it is reported instead:

```sh
sandy --print-state | jq '.sandboxes[] | {name, relay}'
# {"name":"myproj-1a2b3c4d","relay":{"state":"looping","restarts":417,"last_exit_code":3, ...}}
```

`state` is one of `absent`, `started`, `looping`, `failed`, `disabled`. `--print-state` also reports `source` (who supplied the relay: `manifest`, or `none`), `path` (a **container** path), `executable_present` (checked on the host at query time — a fact, not a health verdict), `disabled_by`, and `state_dir` — the **host** path of `$SANDBOX_DIR/relay-state`, where the relay's `.state` and `supervisor.log` live. Inside the container that directory is `/opt/sandy/relay-state`; a relay finds it through `SANDY_RELAY_STATE` rather than by building the path.

The session marker (`/etc/sandy-session.json`) carries `relay.source`, `relay.path` and `relay.disabled_by` — launch **intent**, because it is written **before** the container starts and cannot know whether the relay ran; live state comes from `--print-state`. Treat all of it as diagnostics: `relay-state/` is mounted read-write, so the agent can write it.


### Egress proxy — cross-platform isolation

The egress proxy is the recommended isolation mechanism and the **only** one that works on macOS. It routes the agent through a small proxy sidecar on a Docker `--internal` network (no route off the bridge except through the proxy), so it behaves identically on macOS and Linux. The posture is one key, `SANDY_EGRESS` (default **permissive**):

| Setting | Mode | Behavior |
|---|---|---|
| `SANDY_EGRESS=permissive` *(or unset)* | permissive (default) | Blocks private/LAN/host/cloud-metadata destinations and well-known DNS-over-HTTPS resolvers, allows all other internet. Closes the macOS LAN gap with ~zero friction. |
| `SANDY_EGRESS=strict` | strict | Allows only a built-in default allowlist (model providers, GitHub incl. SSH, npm/PyPI/crates/Go/Debian) plus `SANDY_ALLOW_HOSTS`. Fails closed on everything else. **Strengthens isolation — safe to commit in a workspace config.** |
| `SANDY_EGRESS=off` | off | Linux iptables only; macOS has no network isolation (see below). **Weakens isolation — a workspace `.sandy/config` setting it triggers an approval prompt** so a cloned repo can't silently disable your sandbox. |

```sh
SANDY_EGRESS=strict   # in ~/.sandy/config or a workspace .sandy/config
```

**A workspace `SANDY_EGRESS=permissive` also triggers the approval prompt.** A workspace `.sandy/config` outranks `~/.sandy/config` for the same key, so on a host that chose `strict`, a cloned repository's one-line `SANDY_EGRESS=permissive` would otherwise re-open the whole internet with no prompt (#371; sandy 2.0.0–2.3.x gated only `off`). Only `strict` — the tightening value — is free from a workspace. The prompt appears even when your host is already permissive, because the gate judges the value, not what your host resolved; approving it once for that workspace silences it.

**Permissive mode refuses well-known DNS-over-HTTPS resolvers** (`dns.google`, `cloudflare-dns.com`, `dns.quad9.net`, `doh.opendns.com`, `dns.nextdns.io`, … — the list is in `proxy/doh.go`). A tool that resolves names over HTTPS instead of DNS would otherwise take resolution off the path sandy observes, so `SANDY_EGRESS_LOG`'s "what did this session reach" summary would be incomplete. The refusal is logged in `proxy.log` like any other denial. If you genuinely route DNS that way, add the resolver to `SANDY_ALLOW_HOSTS` — an allowlisted provider is reachable again. The list is **best-effort and enumerable, not complete**: an unlisted or self-hosted resolver, or one addressed by raw IP through the proxy, is not caught. For a real guarantee use `SANDY_EGRESS=strict`, which already denies every resolver you have not allowlisted.

> The pre-2.0 keys still work and are listed under **Deprecated**: `SANDY_EGRESS_STRICT=1`/`=0` (strict/permissive), `SANDY_EGRESS_NO_ISOLATION=1` (off), and the older `SANDY_EGRESS_PROXY=0|1|2` alias (`0`→off, `1`→permissive, `2`→strict). If `SANDY_EGRESS` is set it wins and the old values are ignored with a notice. Their weakening values are approval-gated from a workspace the same way: `SANDY_EGRESS_STRICT=0`, `SANDY_EGRESS_NO_ISOLATION=1`, `SANDY_EGRESS_PROXY=0` and `=1`.

Add extra reachable hosts with `SANDY_ALLOW_HOSTS` (privileged; comma-separated `host`, `*.suffix`, or `host:port`). git-over-SSH (`SANDY_SSH=agent`) is tunneled through the proxy automatically on both platforms; on macOS, host-agent *key signing* is unavailable under the proxy (use `SANDY_SSH=token` for a fully-supported HTTPS path). A local LLM (`SANDY_LOCAL_LLM_HOST`) is forwarded through the proxy rather than an iptables hole. See `CLAUDE.md` → "Egress Proxy" for the full topology.

**`SANDY_SSH=agent` no longer hands the container your whole `~/.ssh`.** Before 1.14.0 it mounted `~/.ssh` in full and copied every file into the container, agent-readable — in one measured case 35 private keys, including the operator's employer credentials and six AWS `.pem` files, in a container working on an unrelated repo. Now nothing private is staged unless you name it:

```sh
# in <project>/.sandy/config — one approval prompt, scoped to this workspace
SANDY_SSH_KEYS=id_rsa_homelab,id_rsa_deploy
```

This works in **any** `SANDY_SSH` mode. If your workspace reaches other machines with `ssh -i` and doesn't need agent forwarding, `SANDY_SSH=token` plus an allowlist is the right combination — git over HTTPS, the specific keys you named, and no agent relay at all.

`config`, `known_hosts` and `*.pub` are always staged. A name that matches no file warns rather than silently doing nothing. A named key with no `.pub` sibling gets one derived. `SANDY_SUSPICIOUS=1` forces the list empty.

**macOS SSH-agent relay exposure.** Outside proxy mode, `SANDY_SSH=agent` on macOS bridges the host SSH agent into the container via a host-side TCP relay (`socat TCP-LISTEN:<port>,bind=127.0.0.1`) — Linux doesn't need this since the agent socket is bind-mounted directly. The relay is bound to `127.0.0.1` and lives only for the session, but on a multi-user Mac any local process that can reach `127.0.0.1` can connect to it and sign with your keys for as long as the session is open (the ephemeral port number is weak obscurity, not an authentication boundary). If that matters for your threat model, prefer `SANDY_SSH=token` (HTTPS via `gh auth token`), which never exposes the agent.

### macOS (Docker Desktop) — not isolated when the proxy is off

**Warning:** if you turn the proxy off with `SANDY_EGRESS=off` (the proxy is on by default), Docker Desktop does *not* provide LAN isolation. The container *can* reach `host.docker.internal` (→ your Mac's gateway), your host's `localhost` services, and any device on your physical LAN — your home router at `192.168.1.1`, a NAS, a printer, an internal dashboard, your SSH daemon. A stress test in April 2026 opened a live TCP connection from inside the container to the host's SSHD and read its banner (see `ISOLATION_STRESS.md`, finding F2).

As defense-in-depth, sandy nullifies the Docker Desktop magic hostnames (`gateway.docker.internal`, `metadata.google.internal`, and — when `SANDY_SSH != agent` — `host.docker.internal`) via `--add-host`, and prints a launch-time warning banner on macOS. But **raw-IP access is unaffected**, and the banner is a warning, not a fix.

**Fix:** leave the proxy on (the default) or set `SANDY_EGRESS=strict` — both apply real isolation on macOS. Otherwise treat proxy-off macOS sandy as "process and filesystem isolation only; no network isolation."

### Linux
Sandy automatically inserts `iptables` rules into the `DOCKER-USER` chain that block all RFC 1918 traffic from the container's bridge interface:

| Range | What it blocks |
|---|---|
| `10.0.0.0/8` | Home/office LAN, VPNs |
| `172.16.0.0/12` | Docker internals, some LANs |
| `192.168.0.0/16` | Home/office LAN |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT, Tailscale |

Rules are automatically cleaned up when sandy exits. Stale rules from a previous unclean exit are cleaned up on startup. If `iptables` is not accessible, sandy **refuses to launch**. Each DROP rule is then re-checked with `iptables -C` after insertion, and if any is missing — a readable chain can still refuse an insert — sandy refuses too, naming the range, rather than reporting isolation it does not have. `SANDY_ALLOW_NO_ISOLATION=1` overrides both refusals with a warning instead.

## Verifying Isolation

From inside the container, you can verify:

```bash
# Should FAIL — LAN is blocked
curl -m 5 http://192.168.1.1

# Should SUCCEED — public internet works
curl -m 5 https://api.anthropic.com
```

## What's in the Box

Sandy's base image is a self-contained development environment. Everything below is pre-installed and ready to use — no setup required.

### Language toolchains

| Toolchain | Version | Notes |
|---|---|---|
| Python 3 | Debian trixie default (3.13) | System Python; use `uv` for other versions |
| Node.js | 24 LTS | Via NodeSource |
| Go | 1.26 | Latest 1.26.x patch resolved at image build |
| Rust | stable | Via rustup |
| C/C++ | build-essential | gcc, g++, make, libc-dev |

### System tools

| Tool | Purpose |
|---|---|
| `git` | Version control |
| `git-lfs` | Large file storage (auto-detected, auto-configured) |
| `gh` | GitHub CLI — PRs, issues, releases |
| `jq` | JSON processor |
| `ripgrep` (`rg`) | Fast code search |
| `curl` | HTTP client |
| `cmake` | Build system |
| `pkg-config` | Build helper |
| `socat` | Socket relay (SSH agent forwarding) |
| `tmux` | Terminal multiplexer (sandy's session wrapper) |
| `less` | Pager |
| `openssh-client` | SSH client |

### Python tools

| Tool | Purpose |
|---|---|
| `uv` | Fast Python version & package manager |
| `pip` / `pip3` | Package installer (auto `--user` outside venvs) |
| `python3-venv` | Virtual environment support |

### Libraries

| Library | Purpose |
|---|---|
| `libcairo2` | 2D graphics / PDF rendering |
| `libpango1.0-0` | Text layout / PDF rendering |
| `libgdk-pixbuf-2.0-0` | Image loading / PDF rendering |
| `libssl-dev` | TLS development headers |
| `ncurses-term` | Terminal definitions |

### Plugin marketplace

Two plugin marketplaces are pre-configured in every sandbox: [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) and [sandy-plugins](https://github.com/rappdw/sandy-plugins). Browse and install plugins with:

```
/plugin                                    # browse available plugins
/plugin install <name>@<marketplace>       # install a plugin
/plugin update                             # update installed plugins
```

**Note — synthkit is no longer a plugin.** Earlier versions of sandy referenced `/plugin install synthkit@thinkkit`. Synthkit is now a regular CLI tool (`uv tool install synthkit`, or `uvx synthkit ...`) and is **pre-installed in the base image** — the `/md2pdf`, `/md2doc`, `/md2html`, `/md2email` slash commands are generated by sandy at session start (no `/plugin install` needed).

**Known issue — slash command autocomplete**: Plugin skills are lazy-loaded by Claude Code and won't appear in slash command autocomplete until invoked once — either by typing the request naturally or via the fully qualified name (e.g. `<plugin>:<skill>`). After first invocation, they appear in autocomplete for the rest of the session. This is a [known Claude Code bug](https://github.com/anthropics/claude-code/issues/18949) — the slash command resolver only indexes the legacy `commands/` system and ignores `skills/` entries (despite commands being [merged into skills](https://code.claude.com/docs/en/skills.md)). Sandy's own builtins (`/md2pdf`, `/ss`, etc.) live under `commands/` so they're not affected.

### Skill packs

Skill packs are optional Docker image layers that bake curated skill collections into the container. They're not included by default — enable them per-project and they're built once, cached, and instantly available on subsequent launches.

```bash
# .sandy/config
SANDY_SKILL_PACKS=gstack
```

| Pack | Description | Source |
|------|-------------|--------|
| `gstack` | 28 Claude Code skills (QA, review, ship, browse, etc.) + headless Chromium browser engine | [garrytan/gstack](https://github.com/garrytan/gstack) |

First launch with a new skill pack takes a few minutes (downloading, compiling, installing Chromium). After that, launches are instant — everything is cached in a Docker image layer. Sandy auto-checks for newer skill pack releases on each launch and rebuilds when updates are available.

Skills are automatically discovered by Claude Code at session start. Skill pack `bin/` directories are added to PATH.

### GPU support

Sandy can pass host GPUs into the container for ML/AI workloads. This requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) installed on the host.

Enable via environment variable or `.sandy/config`:

```bash
# .sandy/config
SANDY_GPU=all          # all GPUs
SANDY_GPU=0            # specific GPU
SANDY_GPU=0,1          # multiple GPUs
```

The sandy base image does not include CUDA. Use `.sandy/Dockerfile` to layer GPU tools for projects that need them (see [`examples/gpu/Dockerfile`](examples/gpu/Dockerfile) for a ready-to-copy starting point). The per-project image is cached and only rebuilds when `.sandy/Dockerfile` changes.

**Example — CUDA + Python ML (works on x86_64 and arm64, including DGX Spark):**

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Add NVIDIA CUDA apt repository (arch-aware — maps aarch64 to sbsa for Debian)
RUN CUDA_ARCH="$(uname -m)"; [ "$CUDA_ARCH" = "aarch64" ] && CUDA_ARCH="sbsa"; \
    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/debian12/${CUDA_ARCH}/cuda-keyring_1.1-1_all.deb" \
        -o /tmp/cuda-keyring.deb \
    && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends cuda-toolkit \
    && rm -rf /var/lib/apt/lists/*
```

For a lighter setup that skips system CUDA and uses pre-built wheels:

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN pip install --user torch torchvision torchaudio
```

**Platform notes:**
- **x86_64**: Standard NVIDIA GPUs (RTX, A100, H100, etc.) — fully supported
- **arm64 / DGX Spark**: Grace Blackwell architecture — fully supported (base image and CUDA repo are multi-arch)
- **macOS**: Docker Desktop does not support GPU passthrough; `SANDY_GPU` has no effect

### Persistent packages

Packages installed inside sandy persist across sessions per project. Each project sandbox has dedicated bind-mounted directories for each package manager:

```bash
pip install flask          # persists in sandbox pip/ dir
npm install -g typescript  # persists in sandbox npm-global/ dir
go install golang.org/x/tools/gopls@latest  # persists in sandbox go/ dir
cargo install ripgrep      # persists in sandbox cargo/ dir
```

These are per-project — packages installed in one project don't leak to another.

### Python version management

The base image ships one system Python (Debian trixie's default, 3.13). If your project needs a specific version, use `uv`:

```bash
uv python install 3.11        # downloads once, persists across sessions
uv venv --python 3.11         # creates .venv in project dir
source .venv/bin/activate
uv pip install -r requirements.txt
```

Different projects can use different Python versions with the same sandy image — each project's sandbox stores its own `uv`-managed Python installations.

### Using host virtual environments and build artifacts

Your project directory is bind-mounted read-write, so `node_modules/`, `target/`, and other build directories from the host are visible inside the container. `.venv/` is a special case — see below.

- **Python `.venv/`** — a host-created venv's `bin/python` is a symlink to a host-only interpreter path (e.g. `/Users/you/.local/share/uv/python/cpython-3.12-macos-aarch64/bin/python3.12`) that doesn't exist inside the Linux container. To avoid breaking the host venv *and* to give the container a working venv, sandy **shadows `.venv/` with a sandbox-owned overlay**:
  - On launch, if `$WORKSPACE/.venv` exists on the host and isn't a symlink, sandy bind-mounts a sandbox-owned directory over it inside the container. The host venv on disk is untouched.
  - On first launch the overlay is empty; sandy runs `uv venv --clear --python <version>` to materialize a fresh venv. The Python version comes from `.python-version` if present (authoritative), otherwise from the host's `pyvenv.cfg`.
  - Populate it once: `uv sync` / `uv pip install -e .` / `pip install -r requirements.txt`. Subsequent launches skip straight to activation — the overlay persists in `~/.sandy/sandboxes/<project>/venv/`.
  - Sandy sets `VIRTUAL_ENV` and prepends `.venv/bin` to `PATH` automatically — no need to `source .venv/bin/activate`.
  - If you bump `.python-version` after the overlay was built, sandy prints a drift warning with the recreate command (auto-recreate is deliberately not done — it would nuke installed packages).
  - Opt out with `SANDY_VENV_OVERLAY=0` in `.sandy/config` if you want the raw bind mount. The host and container then need matching Python versions at matching paths or the venv is broken.
  - Non-standard venv names (`venv/`, `.venv-py311/`) are **not** overlaid — only the standard `.venv/` is.
- **Node.js `node_modules/`** — pure JS packages work fine. Native addons compiled on the host work if the host is also Linux with compatible glibc. Fix: `npm rebuild`
- **Rust `target/`** — reusable if both sides are Linux x86_64. macOS host → Linux container triggers a full rebuild automatically
- **Go `vendor/`** — pure source, always works

### Per-project tooling (`.sandy/Dockerfile`)

If your project needs system tools beyond the base image, create a `.sandy/Dockerfile` in your project directory:

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# No USER directive needed — entrypoint handles privilege dropping
RUN curl -LsSf https://github.com/typst/typst/releases/latest/download/typst-x86_64-unknown-linux-musl.tar.xz \
    | tar -xJ --strip-components=1 -C /usr/local/bin
ARG QUARTO_VERSION=1.9.36
RUN curl -fL "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /opt \
    && ln -s /opt/quarto-${QUARTO_VERSION}/bin/quarto /usr/local/bin/quarto
```

Sandy detects this file and builds a project-specific image layered on top of the standard sandy image. The project image:

- Rebuilds automatically when the Dockerfile changes or the base sandy image updates
- Is cached per-project (tagged as `sandy-project-<name>-<hash>`)
- Uses the `.sandy/` directory as build context, so you can `COPY` files from there

This is the right approach for system packages (`apt-get`), large binary tools, or anything that needs root to install. See [`examples/`](examples/) for ready-to-use configurations.

**Approval gate.** Because the build runs its `RUN` commands on your **host** Docker daemon with **unfiltered network** (build-time is not behind the egress proxy) and takes the whole `.sandy/` directory as context, sandy will not build a `.sandy/Dockerfile` it hasn't seen approved. The first time it appears — or after any change to the Dockerfile or a file it `COPY`s — sandy prints it and asks `y/N` before building; the approval is remembered per workspace (`~/.sandy/approvals/dockerfile-<hash>.list`, revoke by deleting it). `sandy --start` from a terminal asks this on that terminal before the session detaches (2.4.0, #296); answering `N` there means "use the base image", not "don't start". Where nobody can answer — `-p`, a `--start` with no terminal, no TTY — sandy **fails closed**: it skips the project build and launches the base agent image, so you need to approve it once interactively from that directory first. `SANDY_AUTO_APPROVE_PRIVILEGED=1` skips this prompt entirely — it exists for sandy's own test harnesses, and it means an unreviewed Dockerfile builds on your host. The prompt says which question it is asking — **no prior approval** for this workspace, or **changed since you approved it on <date>** — and gives a reading rule: a `RUN` line that fetches and installs from a package registry is expected; one that does anything else (pipes a URL to a shell, writes outside the image, reads from the build context) is what deserves your attention.

**What stops an agent planting one.** `.sandy/` is mounted read-only during a session **only if it already existed when the session started** — like every protected directory, the mount is existence-gated (see [Protected files](#protected-files-and-directories)). In a workspace with no `.sandy/`, an agent *can* create `.sandy/Dockerfile`; sandy reports it at session end as a newly-appeared protected path. What keeps such a file from building is this approval: the next launch sees a context it has no approval for and asks, saying so — nothing builds unreviewed unless `SANDY_AUTO_APPROVE_PRIVILEGED=1` is set.

**Network check scope.** Before any build sandy checks that its **own** build hosts (`deb.debian.org`, `registry.npmjs.org`) are reachable, so a captive portal defers a rebuild instead of breaking the launch. That check knows nothing about what *your* Dockerfile fetches (`rubygems.org`, `pypi.org`, a vendor CDN): on a partly reachable network the check can pass and the project build still fail at its own download step. Sandy says so when the project build fails.

### Automatic environment detection

Sandy checks your project on startup and handles common issues:

- **`.python-version`** — if present, sandy auto-installs that Python version via `uv` (persists across sessions)
- **Host `.venv/`** — shadowed with a sandbox-owned overlay (see above). The host venv is never modified; the container gets its own materialized venv matching the host's Python version, auto-activated via `VIRTUAL_ENV` + `PATH`. Drift between the overlay and `.python-version` triggers a warning on relaunch
- **Foreign native modules** — if `node_modules/` contains native addons compiled for a different platform (e.g. macOS), sandy warns with `npm rebuild` as the fix
- **Orphaned pip user-site** — if persistent `pip install --user` packages were installed under a different Python minor version than the image now ships (e.g. after a base-image Python bump), sandy warns with the old path and a reinstall/cleanup pointer
- **Host timezone** (2.4.0) — the container clock follows the host: sandy passes your zone as `TZ` at launch (from `$TZ` if set, else `/etc/localtime`, else `/etc/timezone`), so `date`, `ls -l`, git and the tmux status clock read local time. Set `TZ` before launching to override it. Nothing to rebuild when you travel — it is re-read every launch. Timestamps sandy itself records (`sandy-session.json`, `WORKSPACE.json`, container labels) stay UTC

These checks run on every session start and add negligible overhead.

## Terminal Notifications

Sandy passes through OSC escape sequences (9/99/777) from Claude Code to the outer terminal. This enables notification features in terminals like [cmux](https://www.cmux.dev/) and iTerm2 — pane rings, desktop alerts, and badges when Claude needs attention.

**cmux auto-setup**: When sandy detects it's running inside cmux (via the `CMUX_WORKSPACE_ID` environment variable), it automatically installs a notification hook that emits OSC 777 sequences on Claude Code events. No manual configuration needed — just run `sandy` in a cmux pane.

**Custom hooks**: If you have Claude Code hooks configured on the host (`~/.claude/hooks/`), sandy mounts them read-only into the container automatically. Host hooks take precedence over auto-setup (cmux auto-setup is skipped if `~/.claude/hooks/` exists on the host).

**Clipboard**: Sandy's tmux uses OSC 52 to copy mouse selections to the system clipboard. In iTerm2, enable this under **Settings > General > Selection > "Applications in terminal may access clipboard"**. With this enabled, click-drag selections in the container are automatically copied to your Mac clipboard.

## Channels (Telegram, Discord)

Sandy supports [Claude Code channels](https://code.claude.com/docs/en/channels) — push messages from Telegram or Discord into your running session. Sandy auto-installs the channel plugin and seeds credentials on startup.

### Quick setup (Telegram)

1. Create a bot via [BotFather](https://t.me/BotFather) and copy the token
2. Add to `.sandy/.secrets` (gitignored):
   ```
   TELEGRAM_BOT_TOKEN=123456789:AAH...
   TELEGRAM_ALLOWED_SENDERS=your_telegram_user_id
   ```
3. Add to `.sandy/config`:
   ```
   SANDY_CHANNELS=plugin:telegram@claude-plugins-official
   ```
4. Run `sandy` — the plugin is auto-installed, credentials are seeded, and Claude starts with the channel active

To find your Telegram user ID, message [@userinfobot](https://t.me/userinfobot).

**`TELEGRAM_ALLOWED_SENDERS` is required for the host-side relay**, which is what runs for `gemini`, `codex`, `opencode`, `grok` and every multi-agent combo. Without it the relay refuses to start, because an empty allowlist would let any Telegram user who finds your bot send keystrokes to the agent. Pairing mode is the **in-container Claude plugin only** (single-agent `claude`): there, omitting the allowlist starts `pairing` — DM your bot, then run `/telegram:access pair <code>` inside the session. The host relay has no pairing flow.

### Quick setup (Discord)

1. Create an application at the [Discord Developer Portal](https://discord.com/developers/applications)
2. In the **Bot** section, create a bot, reset the token, and copy it
3. Enable **Message Content Intent** under **Privileged Gateway Intents**
4. Use **OAuth2 > URL Generator** with the `bot` scope and these permissions: View Channels, Send Messages, Send Messages in Threads, Read Message History, Attach Files, Add Reactions. Open the generated URL to invite the bot to your server.
5. Add to `.sandy/.secrets` (gitignored):
   ```
   DISCORD_BOT_TOKEN=your_discord_bot_token
   DISCORD_ALLOWED_SENDERS=your_discord_user_id
   ```
6. Add to `.sandy/config`:
   ```
   SANDY_CHANNELS=plugin:discord@claude-plugins-official
   ```
7. Run `sandy` — the plugin is auto-installed, credentials are seeded, and Claude starts with the channel active

If `DISCORD_ALLOWED_SENDERS` is omitted, sandy starts in `pairing` mode — DM your bot, then run `/discord:access pair <code>` inside the session.

### Using both channels

Set both tokens in `.sandy/.secrets` and list both plugins in `.sandy/config`:

```
SANDY_CHANNELS=plugin:telegram@claude-plugins-official plugin:discord@claude-plugins-official
```

### Channels with Gemini / Codex / multi-agent mode

For any `SANDY_AGENT` value other than single-agent `claude`, sandy uses a **host-side Telegram relay** instead of the in-container plugin — it long-polls the Telegram Bot API on the host and injects messages into the container's tmux session via `docker exec … tmux send-keys`. This is agent-agnostic but lower-fidelity: no chat threading, no edit-message updates, no attachments. Set `SANDY_CHANNEL_TARGET_PANE=0|1|2|3` to route messages to a specific agent in multi-agent mode — `N` is the Nth agent listed in `SANDY_AGENT`, 0-based (default `0` = the first); the relay looks up that agent's pane by its tag rather than trusting the tmux pane number. Discord via relay is not supported yet — use single-agent `SANDY_AGENT=claude` for Discord.

> ⚠️ **`SANDY_CHANNELS` format for the relay is different.** The relay matches the **bare channel name** — `SANDY_CHANNELS=telegram` — *not* the `plugin:telegram@claude-plugins-official` form used for single-agent `claude` above (that qualified form is what `claude --channels` needs, but it won't trigger the relay). Use bare names when the relay is in play (any non-single-`claude` `SANDY_AGENT`). This dual-format wart is tracked in [#30](https://github.com/rappdw/sandy/issues/30) and will be unified.

### Per-project secrets

`.sandy/.secrets` uses the same `KEY=VALUE` format as `.sandy/config` but is intended for credentials. Add it to `.gitignore`:

```
.sandy/.secrets
```

## Troubleshooting

### The build hangs at "Building sandbox image" on a VM (generic CPU model)

**Symptom.** On a QEMU/KVM virtual machine — Proxmox is the common case — the
first launch stops at `[sandy] Building sandbox image (may take a few
minutes)...` and never finishes. The build makes no further progress, and one process
sits at ~90–100% CPU indefinitely, typically
`/home/sandy/.claude/downloads/claude-<version>-linux-x64 install` (or the Grok
Build binary being installed the same way).

**Cause.** Claude Code and Grok Build ship as **native binaries** with an
embedded JavaScript runtime, and the image build runs each one's own installer
(Claude Code's installer ends by executing the downloaded binary's `install`
step). On a VM that uses the hypervisor's **generic CPU model** — `kvm64` or
`qemu64`, which `lscpu` reports as *Common KVM processor* / *QEMU Virtual CPU*
— the guest is offered only the x86-64 baseline feature set: no `sse4_2`,
`popcnt`, `avx` or `avx2`. The runtime then spins in userspace instead of
failing. It is not a network or egress stall, and not cross-architecture
emulation (both sides are x86_64); the same build works in CI and on real
hardware because those expose the full feature set.

**How to tell.** On the VM:

```bash
lscpu | grep 'Model name'                        # "Common KVM processor" / "QEMU Virtual CPU" is the tell
grep -oE 'sse4_2|popcnt|avx2' /proc/cpuinfo | sort -u   # empty, or missing entries, means a generic model
/lib64/ld-linux-x86-64.so.2 --help | grep x86-64-v      # glibc >= 2.33: is x86-64-v2 "supported"?
```

And, to rule out the network: find the spinning process (`ps aux | grep
'downloads/claude'` on the VM — `docker build` steps are ordinary host
processes on Linux) and run `sudo strace -f -p <pid>`. A process in state `R`
making **no syscalls at all** is a pure userspace spin; a network stall would
be blocked in `connect`/`recv`/`poll`.

**Fix.** Give the VM real CPU features — the agent binaries need at least an
**x86-64-v2** feature level:

- **Proxmox**: VM → Hardware → Processors → Type → `host` (or `x86-64-v2-AES`
  / `x86-64-v3` if live migration between different hosts rules out `host`).
- **libvirt / virt-manager**: `<cpu mode='host-passthrough'/>`, or tick "Copy
  host CPU configuration". **Plain QEMU**: `-cpu host`.
- **Cold-boot the VM** — stop it, then start it. A reboot from inside the guest
  keeps the old CPU model; the type only changes on a fresh power cycle.
- Re-check with the `grep` above (the flags should now appear), then run
  `sandy` again. An interrupted build is retried on the next launch; no
  `--rebuild` is needed.

## Upgrading to 2.0

**Read this before upgrading. 2.0 renames the container user and home from `claude` to `sandy`, and every sandbox created by 1.x must be migrated.**

Your **workspaces are never touched** — the change is entirely inside sandy's own state under `~/.sandy/`.

### Why a migration is needed at all

`/home/claude` is baked into files sandy does not own: virtualenv shebangs and `pyvenv.cfg`, `.pth` files, editable installs, `GOPATH` and `PYTHONUSERBASE` metadata, npm and cargo state. Moving the home leaves those pointing at a directory that no longer exists, and they fail in ways that look like broken packages rather than a moved home. Sandy refuses to launch against such a sandbox rather than limping into it.

### The migration

One command, once, for every sandbox on the host:

```sh
sandy --reset-sandbox --all --dry-run                  # see what it will do
sandy --reset-sandbox --all --keep-history --yes       # migrate
```

`--keep-history` preserves `claude/projects/` — every Claude session transcript and all auto-memory — **and nothing else**. Other agents' own history (`codex/`, `gemini/`, …), anything else under `claude/`, and any directory a host-side tool keeps in the sandbox are destroyed even with it; the reset plan **names each of them** under *NOT kept by --keep-history* (derived from what is actually in the sandbox), so stash anything you need first. **It is not the default and `--yes` does not choose it**, because the same command is also how you remediate a sandbox you distrust, and there memory is the thing you most want gone: it reaches the agent's context every session, so a compromised session writing to it is persistent injection with no expiry. Run interactively and sandy asks; run non-interactively and it requires `--keep-history` or `--purge-history` rather than guessing.

| destroyed (rebuilt on next launch) | preserved |
|---|---|
| `pip/`, `uv/`, `npm-global/`, `go/`, `cargo/` package caches | `WORKSPACE.json` (lineage) |
| the `venv/` overlay | — |
| per-agent state: `claude/`, `gemini/`, `codex/`, `opencode/`, `grok/` | `agent-args.<agent>` (per-agent launch args) |
| `.claude.json`, installed plugins, approvals | — |
| `claude/projects/` — transcripts and auto-memory, **unless `--keep-history`** | `claude/projects/` **with `--keep-history`** |

### Back up anyway

`--keep-history` preserves the corpus, but a backup costs little against 149 MB of irreplaceable transcripts per sandbox:

```sh
tar czf sandy-history-$(date +%F).tar.gz ~/.sandy/sandboxes/*/claude/projects
```

If you use [lore](https://github.com/rappdw/lore), also export the memory corpus — **its JSON export covers memories only and does not include transcripts**, so you want both:

```sh
lore export --json > lore-memories-$(date +%F).json
```

**Do not use `rm -rf` on the sandbox directory.** It takes the preserved column with it, and nothing recreates those — `agent-args.*` is operator state a repository cannot carry. (`relay-bin/` is **not** preserved since 2.2.0: the slot was removed, and a leftover entry would block the next launch.)

The cost is time and bandwidth: the next launch in each workspace re-downloads packages and rebuilds the venv. Nothing is lost that a `uv sync` or `npm install` will not restore.

A sandbox whose workspace no longer exists cannot be migrated — it is named and counted, and `sandy --remove-sandbox --orphans` is the command for it.

### If you have scripts, MCP configs or agent args that hardcode `/home/claude`

They break. Container paths are available from the environment and from the read-only attestation marker rather than by assumption:

```sh
sandy --exec -- printenv HOME                 # the container home
sandy --exec -- cat /etc/sandy-session.json   # workspace, sandbox_name, posture
```

### Also in 2.0

- `--print-state`'s `schema_version` was **`2`** in the 2.0 line and is **`3`** as of 2.2.0 (see **Deprecated**). Gate on that number, not on sandy's version string — `2.0.0-dev` compares equal to `2.0.0`. Treat it as an **opaque token**: compare against a reviewed set, not with `>=`, so a future bump is something you read rather than something you silently accept.
- `sandboxes[].features` now reports **manifest selection** rather than per-sandbox markers; `SANDY_FEATURES_DIR` is removed with an error naming its replacement.
- `SANDY_EGRESS=off|permissive|strict` replaces two booleans. The old keys still work — see **Deprecated** below.

## Deprecated

Everything here still works. Each entry was announced in the major release named, and **may be removed in any later `X.Y.0`** — so if you depend on one, plan the move rather than waiting for it to break.

Sandy's rule: an entry can only be **added** to this list in an `X.0.0` release, and nothing is ever removed that was not listed here first. Reading this section after a major upgrade tells you everything that may disappear during that line.

An entry may also be **withdrawn** in any release — it is struck through and marked *kept*. Withdrawal is allowed in a minor because it **strictly reduces** what you have to plan for: it retracts a threat rather than creating one, which is the opposite of what the add-only rule guards against.

**One written exception (2.5.0, #382):** a surface may be announced here in a *minor* only if it was shaped around a single consumer's protocol (it fails the consumer-boundary test in `CLAUDE.md`) **and** every known consumer is named and has released its migration off it before removal. Such rows say `2.5.0 (exception)` in the *since* column, and every one that sandy can detect in use **warns at launch** for at least one minor before removal, because this list alone cannot reach someone who does not read it. Anything else still waits for a major.

| deprecated | since | use instead |
|---|---|---|
| ~~`SANDY_HANDOFF_DIRS`, and the `~/.handoff/{inbox,outbox,peer,relay}` tree it mounts~~ **— REMOVED in 2.2.0** | 2.0.0 | a feature manifest's `mounts` — it names its own directories instead of using sandy's four fixed ones |
| ~~`SANDY_HANDOFF_*` container env vars (`_INBOX`, `_OUTBOX`, `_PEER`, `_RELAY_STATE`)~~ **— REMOVED in 2.2.0** | 2.0.0 | a mount's `export`, which names the variable the feature wants |
| ~~`SANDY_HANDOFF_RELAY` and the `relay-bin/` slot~~ **— REMOVED in 2.2.0** | 2.0.0 | a feature manifest's `entry`. Setting the key, or leaving an executable in the slot, is now a **hard error** naming the replacement. The *variable* survives as the manifest entry's internal channel; only the operator-facing key is gone |
| ~~`relay{}` in `/etc/sandy-session.json` and `--print-state`~~ **— WITHDRAWN, kept; RE-ANNOUNCED in 2.5.0, see the `relay{}` row below** · `handoff_relay`, `relay.slot` **— REMOVED in 2.2.0, `schema_version` 3** (`relay.disabled_by` is NOT removed — it survives) | 2.0.0 | **`relay{}` stays.** Its stated replacement, "the feature's own entry in `--print-state`", was never built when 2.2.0 shipped, and the premise for it — a sandbox runs exactly one relay — no longer holds now that a sandbox can adopt more than one feature entry (2.4.0, #381): `relay{}` dual-reports the first entry in sorted feature-directory order, byte-identical to before #381, and every entry (including that one) is additionally reported under `feature_entries.<name>`. What went in 2.2.0 is the dead field inside it — `slot` described the `relay-bin` slot, removed that release |
| ~~`handoff_enabled` and `handoff{}` in `--print-state`~~ **— REMOVED in 2.2.0, `schema_version` 3** | 2.0.0 | they report on the handoff tree above, so they go with it — and their removal bumps `schema_version` for the same reason |
| ~~the `.handoff-enabled` sandbox marker~~ **— REMOVED in 2.2.0** | 2.0.0 | nothing: it forces the handoff tree on for one sandbox, and the tree is what is going. A feature manifest selects per sandbox instead |
| `SANDY_SCREENSHOT_DIR` | 2.0.0 | intended to become a feature manifest; the design is not settled (#317), and the key stays until it is |
| `SANDY_EGRESS_PROXY` | 2.0.0 | `SANDY_EGRESS=off\|permissive\|strict`. It has warned since 0.14.0; listing it here is what finally gives its removal a date |
| `SANDY_EGRESS_NO_ISOLATION` | 2.0.0 | `SANDY_EGRESS=off` — same posture, same approval gate, one key instead of two mutually exclusive booleans |
| `SANDY_EGRESS_STRICT` | 2.0.0 | `SANDY_EGRESS=strict` (or `permissive`) |
| `SANDY_CHANNELS`: the `plugin:<name>@<marketplace>` form | 2.0.0 | bare comma-separated names. The key itself is **not** deprecated — only that spelling of its value |
| `relay{}` in `/etc/sandy-session.json` and `--print-state`, every field | 2.5.0 (exception) | `feature_entries.<name>` (2.4.0), which reports every feature entry; the one `relay{}` describes has `relay_alias: true`. Its replacement now exists, which is what the 2.0.0 withdrawal above was waiting for. Removing it bumps `schema_version` to 4 |
| `SANDY_RELAY` | 2.5.0 (exception) | a feature manifest's `"sandboxes": {"exclude": [...]}` takes a sandbox out of a feature. There is deliberately no per-feature off switch. Setting the key warns at launch now, and will be an error |
| `SANDY_RELAY_STATE` and the `/opt/sandy/relay-state` mount | 2.5.0 (exception) | `SANDY_FEATURE_STATE` (exported to each entry's own process) and `/opt/sandy/feature-state/<feature>` |
| ~~`SANDY_CROSS_SESSION_INBOUND`: the relay-conditional unset default (`cross_session_inbound_source: "relay-legacy"`)~~ **— REMOVED in 2.6.0** | 2.5.0 (exception) | declare `"receives": ["cross_session"]` in the feature's manifest (2.4.0, #380), or set the key explicitly. The key itself is **not** deprecated — only this way of defaulting it was, and it is now removed. An entry alone now resolves `refuse` |
| `SANDY_HANDOFF_RELAY` as the internal channel a manifest `entry` travels through | 2.5.0 (exception) | the per-feature entry plumbing (`SANDY_FEATURE_ENTRIES`). Already a hard error as a configuration key since 2.2.0; this row is about the internal variable |
| ~~`/usr/local/bin/sandy-handoff-sessions`~~ **— REMOVED in 2.6.0** | 2.5.0 (exception) | a consumer's own copy, built on the published pane-identity contract (`SPECIFICATION.md`, #378) |

Removals are loud where sandy can see them: a removed config key is a hard error naming its replacement, a removed mechanism warns first, and a removed introspection field bumps `schema_version`.

*(For maintainers: a deprecation warning in `sandy` names the deprecated thing **first**, before any replacement — `run-tests.sh` §138 reads the first `SANDY_*` token on the line and requires it to appear in the table above, so a deprecation added in code but never announced here fails the suite.)*

## Security Notes

- The container runs as a non-root user (`sandy`, mapped to host UID)
- The root filesystem is read-only (`/tmp` and `/home/sandy` are tmpfs)
- `no-new-privileges` prevents privilege escalation
- Credentials are seeded into per-project sandboxes, not shared across projects
- claude.ai account connectors are suppressed by default (`SANDY_CLAUDE_CONNECTORS=1` to opt in); `SANDY_SUSPICIOUS=1` additionally strips the OAuth refresh token so a distrusted workspace only ever sees a short-lived access token
- Claude Code's own `/sandbox` (`sandbox.enabled`) is forced **off** in the sandbox's `settings.json` every launch, even if your host settings turn it on — sandy's container is the boundary and its egress proxy the one policy chokepoint, so an inner sandbox would only add a second, uncoordinated proxy. Your other `sandbox.*` settings are left as they are, and a repository's own `.claude/settings.json` can still turn it on (Claude Code gives project settings precedence)
- The working directory is bind-mounted read/write — Claude can modify your files there (that's the point)
### Protected files and directories

The workspace is bind-mounted read/write so Claude can modify your project files. However, certain files and directories are overlaid with read-only or sandbox mounts to block the most dangerous attack vectors for an AI coding agent: shell config injection, git hook injection, and tool config tampering.

**Read-only mounts** — host content is visible but cannot be modified:

| Path | Why |
|---|---|
| `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile` | Blocks shell config injection (e.g. aliases, PATH hijacking) |
| `.gitconfig` | Blocks git config tampering (e.g. credential helpers, aliases) |
| `.ripgreprc` | Blocks search config injection |
| `.mcp.json` | Blocks MCP server config tampering |
| `.envrc` | Blocks `direnv` auto-sourcing (executes on `cd`) |
| `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version` | Blocks asdf/mise/nvm/pyenv/rbenv toolchain hijacking |
| `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc` | Blocks registry hijacking and credential exfiltration |
| `.pre-commit-config.yaml` | Blocks pre-commit hook injection |
| `.git/config`, `.gitmodules`, `.git/packed-refs` | Blocks git remote/hook path manipulation and ref spoofing (`.git/HEAD` is left writable so `git switch` works in-container — #80) |
| `.git/hooks/` | Blocks git hook injection (pre-commit, post-checkout, etc.) |
| `.git/info/` | Blocks `.git/info/attributes` filter-driver injection |
| `.git/modules/<sub>/{config,hooks,info}` | Same, for every submodule gitdir (walked recursively) |
| `.vscode/`, `.idea/` | Blocks IDE task/launch config injection |
| `.github/workflows/` | Blocks CI pipeline escape (opt-out via `SANDY_ALLOW_WORKFLOW_EDIT=1`) |
| `.circleci/`, `.devcontainer/` | Blocks CircleCI and devcontainer escape |
| `.claude/settings.json`, `.claude/settings.local.json`, `.claude/hooks/` | Blocks agent→host Claude Code hook injection (a host `claude` run in the same dir would otherwise execute an agent-written hook) |
| `.sandy/` | Blocks tampering with sandy's own build inputs **when `.sandy/` exists at launch** (existence-gated, like every row here — a session that starts without one can create it, and is warned about at session end). A per-project `.sandy/Dockerfile` build is additionally approval-gated by a hash of the whole build context, which is what stops a planted one from building unreviewed |

A redirected `core.hooksPath` (e.g. `.githooks/`) is resolved at launch and its target directory is mounted read-only too, so the protection follows git's actual hook path rather than only the default `.git/hooks/`.

**Sandbox-mounted directories** — overlaid with writable sandbox copies so Claude can create and modify them without touching the host:

| Path | Behavior |
|---|---|
| `.claude/commands/` | Starts empty. Claude can create new slash commands |
| `.claude/agents/` | Starts empty. Claude can create new agents |
| `.claude/plugins/` | Starts empty. Managed via `/plugin install` inside the container |

**Mount policy (existence-gated).** Protected files and directories are mounted read-only only when they exist on the host — a path the host doesn't have gets no mount (an always-mount-with-empty-stubs approach was tried and reverted: the stubs polluted `git status`, broke `direnv`, and confused IDE scanners). The trade-off is covered by **session-end detection**: sandy records which protected paths existed at launch, and on exit warns about any protected file or directory that newly appeared (e.g. an agent-written `.git/hooks/post-checkout` or `.github/workflows/ci.yml`), with the remediation command — so you can review it before the next `git pull`/`push`/IDE-open would fire it.

**Caveat — a host IDE on the shared workspace.** Sandy's protection assumes the *host* isn't independently reading the workspace while the agent runs. A common setup breaks that assumption: the same project directory open in a host IDE (VS Code, Cursor, JetBrains) at the same time as the sandy session. The workspace is bind-mounted read/write, so an auto-execution config the agent writes into it — `.vscode/tasks.json`, a `.githooks/` script, a `.devcontainer/`, a `.claude/settings.json` hook — can be run by that host IDE, entirely outside sandy's boundary. Sandy blocks the common vectors *when they exist at launch* (the read-only mounts above) and warns at session end about newly-appeared ones, but this is existence-gated **detection, not prevention**: an absent `.vscode/` is unprotected in-session, and the end-of-session warning can be missed before the IDE auto-runs the file. When working an untrusted repository, don't leave the same workspace open in a host IDE during the session — read sandy's session-end report first.