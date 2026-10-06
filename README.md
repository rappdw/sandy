[![License: MIT](https://img.shields.io/github/license/rappdw/sandy)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/rappdw/sandy)](https://github.com/rappdw/sandy/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue)]()

# sandy — an isolated sibling for your coding agents

**New to sandy?** [sandy, explained](https://rappdw.github.io/sandy/) is a short guided walkthrough: what it isolates, animated examples of the boundary at work, and how to get running.

> **Upgrading from 1.x?** Sandboxes created by 1.x must be migrated first: `sandy --reset-sandbox --all --keep-history`. Read the [upgrade guide](docs/guide/upgrading-to-2.0.md) before you run it.

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


## Why sandy

Coding agents are most useful when they can act without asking first, and most dangerous for the same reason. A prompt-injected or simply mistaken agent runs with your user's reach: your other repositories, your SSH keys, your home network, the git hook that runs on your next checkout. Sandy's answer is that the operating system, not the agent's own judgement, decides what it can touch, and that each project gets its own agent setup so nothing bleeds between them.

Several good tools now attack the same problem from different angles. Here is an honest comparison, as of October 2026. Their docs move fast, so check before relying on a row.

| | **sandy** | **[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)** | **[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)** | **The agent's built-in sandbox** (Claude Code `/sandbox`, Codex) |
|---|---|---|---|---|
| **Boundary** | Hardened container: shared kernel, all capabilities dropped, read-only root, no Docker socket | **microVM: its own kernel** and its own Docker daemon | Container or VM per sandbox, plus Landlock, seccomp, no capabilities | OS sandbox (bwrap, Seatbelt) around the agent's **shell commands only** |
| **What you install** | One bash script, on the Docker you already have (Docker Desktop, OrbStack, Colima, Rancher, Lima) | The `sbx` CLI and its own VM runtime | A gateway and supervisor (control plane), Docker/Podman/VM or Kubernetes | Nothing; it ships with the agent |
| **Platforms** | macOS, Linux | macOS, Linux, Windows | Linux, macOS (Apple Silicon), Windows via WSL 2 (experimental) | Each agent's own |
| **Agents** | Claude Code, Gemini, Codex, OpenCode, Grok; **up to 4 side by side** in one session | 11, including Claude Code, Codex, Gemini, Copilot, Cursor, OpenCode | Several via providers (Claude Code, Codex, Copilot, Cursor, OpenCode, …) | One: itself |
| **Per-project agent state** | **Yes**: each project has its own plugins, memory, history, logins and installed packages | Each sandbox persists until removed | Per sandbox | No: global (`~/.claude` and the like) |
| **Credentials** | Mounted per session from the host, never stored in the sandbox; one credential per agent; SSH keys only if named | **Injected by a host proxy; never enter the VM** | **Injected by the policy proxy; the agent never sees them** | The agent's own, in its own process |
| **Network** | Egress proxy: permissive (default, blocks LAN and cloud metadata) or strict allowlist; host-level, TLS never decrypted | Presets from open to locked down; the default is deny with a baseline allowlist; host **and HTTP method/path** rules | **Deny by default; L7 rules**, per-binary identity, formally verified policy | Domain allow/deny for shell commands |
| **A repo you didn't write** | **Git hooks, CI workflows, shell rc and IDE configs mounted read-only**; approval prompts before a repo's config can loosen the sandbox, an escaping symlink is mounted, or a project Dockerfile builds | A clone mode gives the agent a private copy; in direct mode the docs warn the agent can change hooks and CI config | Filesystem policy (Landlock) per sandbox | Partial, shell commands only |
| **Proof of posture** | Read-only `/etc/sandy-session.json` in every session; `--print-state` and `--accounts` from the host | Not documented | Not documented (its policies are reviewable and formally verified) | No |
| **Cost and licence** | Free, MIT | Free locally, including commercial use; paid cloud and organization governance | Apache 2.0; 0.1.x, early | Free |

**Choose something else when:**
- **You need a hypervisor boundary**, for example against an agent that may actively try to escape. Docker Sandboxes gives each agent its own kernel. A container cannot match that.
- **You want credentials to never enter the sandbox at all.** Docker Sandboxes and OpenShell inject them at a proxy. Sandy mounts a per-session copy; a credential broker is on the roadmap ([#121](https://github.com/rappdw/sandy/issues/121)).
- **You need HTTP method or path rules, or centrally governed policy for a fleet.** OpenShell and Docker Sandboxes have them. Sandy filters by host and deliberately never decrypts TLS.
- **Your agent must build and run containers.** Docker Sandboxes gives it a Docker daemon.
- **You're on Windows.**

**Choose sandy when:**
- **You want it on the Docker you already have**, with no VM layer, no daemon of its own and no account, on a laptop or a remote Linux box.
- **You open repositories you didn't write.** Sandy is built for the agent that is wrong rather than evil, and follows an instruction planted in the repo. A committed config can tighten the sandbox but never loosen it without asking you, and the files that run on your next git or IDE action are read-only.
- **You run several agents.** Claude, Codex, Gemini, OpenCode and Grok run side by side in one workspace, each with its own logins.
- **You want each project's agent setup kept separate**: a per-project `~/.claude`, the venv model below. That's useful even if you trust the agent completely.
- **You want to audit the whole thing**: one script, a specification, and a record in every session of what it is running under.

**What sandy does not do, plainly:** the agent shares the host kernel (Docker's VM kernel on macOS), so a kernel exploit is out of scope. Credentials it is given are inside the container for the session. `.env` files in the project are readable by the agent today. With `SANDY_EGRESS=off` on macOS, nothing blocks the LAN. The [threat model](docs/security/THREAT_MODEL.md) has the rest. These tools also combine: a sandy-style per-project setup inside a microVM is stronger than either alone.


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

1. **Network egress.** The agent runs on a Docker `--internal` network with no route off it except a TCP-only proxy sidecar. *Permissive* (default) blocks LAN/host/cloud-metadata and allows the public internet; *strict* allows only an allowlist (model providers, GitHub, package registries) plus `SANDY_ALLOW_HOSTS`. Non-TCP traffic (UDP/QUIC/ICMP/IPv6) is dropped by the topology itself. See [How Network Isolation Works](docs/guide/network.md).
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

This installs the **latest release**. `sandy --upgrade` later moves you to the newest release, the one the "Update available" notice names. To follow unreleased work on `main` instead, set `SANDY_CHANNEL=dev`, either on the install (`curl … | SANDY_CHANNEL=dev bash`) or on an upgrade (`SANDY_CHANNEL=dev sandy --upgrade`). A dev build records its commit, so `sandy --version` tells two builds of the same `-dev` version apart. A plain `--upgrade` never downgrades a dev build to an older release; `SANDY_CHANNEL=release sandy --upgrade` does that on purpose. If the release can't be looked up (offline, or GitHub's rate limit), both stop with an error rather than installing `main` instead.

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

Sessions can also outlive the terminal that started them:

```bash
sandy --start      # start a detached session for this workspace
sandy --attach     # attach from any terminal, or over ssh
sandy --stop       # tear it down
```

A daemon session survives a closed laptop or a reboot. [Daemon mode and maintenance](docs/guide/daemon.md) covers remote access, keeping sessions on current images (`--update-sessions`), and `sandy --exec` for a shell in a running session. [sandy-ui](https://github.com/rappdw/sandy-ui) uses daemon mode to keep sessions alive across VS Code restarts.

## Configuration

Settings are `KEY=VALUE` lines, read from two places:

- **`~/.sandy/config`** (and `~/.sandy/.secrets` for credentials): your defaults for every project.
- **`<project>/.sandy/config`** (and `.sandy/.secrets`): per project. The config is safe to commit; keep `.secrets` out of git. A repository's config can **tighten** the sandbox freely; anything that **loosens** it, or brings in a credential, asks you once for that workspace.

```sh
# <project>/.sandy/config
SANDY_AGENT=claude,codex     # which agents to run, up to four side by side
SANDY_EGRESS=strict          # network: off | permissive (default) | strict
SANDY_EFFORT=high            # reasoning effort, for the agents that support it
SANDY_MEM=8g
```

The keys most people use:

| Key | What it does |
|---|---|
| `SANDY_AGENT` | `claude` (default), `gemini`, `codex`, `opencode`, `grok`, a comma-separated combination of up to four, or `all` |
| `SANDY_MODEL` / `SANDY_EFFORT` | Claude's model; reasoning effort (`low` … `max`) for claude, codex, gemini and grok |
| `SANDY_EGRESS` | `permissive` (default: public internet, no LAN), `strict` (allowlist only) or `off` |
| `SANDY_ALLOW_HOSTS` | Extra hosts the agent may reach: in strict mode, beyond the built-in allowlist; in permissive mode, LAN hosts despite the block |
| `SANDY_SSH` / `SANDY_SSH_KEYS` | git over HTTPS with your `gh` token (`token`, default) or SSH agent forwarding (`agent`); which `~/.ssh` keys, if any, enter the container |
| `SANDY_CPUS` / `SANDY_MEM` | Resource limits (detected from your machine by default) |
| `SANDY_CLAUDE_AUTH` | Which Claude credential to use: `auto`, `oauth` (your account login), `api_key` or `profile` |
| `SANDY_CLAUDE_CONNECTORS` | `1` exposes your claude.ai connectors (Microsoft 365, Gmail, …); off by default |
| `SANDY_SUSPICIOUS` | `1` for a repository you distrust: strict egress by default, connectors off, refresh token stripped |
| `SANDY_EXTRA_ENV` | Names of extra environment variables to forward, for MCP servers and tools |
| `SANDY_SKILL_PACKS` | Optional skill collections baked into the image (`gstack`) |

[Configuration](docs/guide/configuration.md) lists every key and flag, and explains which settings a repository may change without asking.

## Agents

| Agent | `SANDY_AGENT=` | Signs in with |
|---|---|---|
| Claude Code | `claude` (default) | Your Claude login from the host (Pro, Max, Team, Enterprise), a long-lived token, an API key, or an Anthropic Console profile |
| Gemini CLI | `gemini` | `GEMINI_API_KEY`, your Google login, or gcloud credentials |
| OpenAI Codex CLI | `codex` | `OPENAI_API_KEY`, or a ChatGPT login kept per project (`sandy --login codex`, 2.8.0) |
| OpenCode | `opencode` | Any provider's API key, or a local model on your network (`SANDY_LOCAL_LLM_HOST`) |
| Grok Build | `grok` | `XAI_API_KEY`, or `grok login` |

Each agent gets its own home directory and credentials inside the project's sandbox. [Agents and credentials](docs/guide/agents.md) covers each one in detail, multi-agent sessions, claude.ai connectors, and Console profiles.

## Documentation

| Guide | What's in it |
|---|---|
| [Configuration](docs/guide/configuration.md) | Every config key and flag; `.sandy/config` and `.sandy/.secrets`; what a repository may change |
| [Agents and credentials](docs/guide/agents.md) | Per-agent setup, multi-agent sessions, connectors, Console profiles, headless servers |
| [Daemon mode and maintenance](docs/guide/daemon.md) | Detached sessions, remote access, `--update-sessions`, `--exec` |
| [Network isolation](docs/guide/network.md) | The egress proxy, macOS and Linux specifics, checking it works |
| [What's in the box](docs/guide/environment.md) | Toolchains, persistent packages, `.venv`, skill packs, GPU, `.sandy/Dockerfile` |
| [Features](docs/guide/features.md) | Feature manifests, supervised entries, re-provisioning |
| [Notifications and channels](docs/guide/channels.md) | Terminal notifications; Telegram and Discord |
| [Security notes](docs/guide/security.md) | Protected files and directories |
| [Troubleshooting](docs/guide/troubleshooting.md) | Known problems and fixes |
| [Upgrading to 2.0](docs/guide/upgrading-to-2.0.md) | Migrating 1.x sandboxes |

Also: the [threat model](docs/security/THREAT_MODEL.md), the full [specification](SPECIFICATION.md), and the [machine-readable output contract](SPEC_INTROSPECTION.md) for tools built on sandy.

## Deprecated

Everything here not struck through still works. Each entry was announced in the major release named, and **may be removed in any later `X.Y.0`** — so if you depend on one, plan the move rather than waiting for it to break.

Sandy's rule: an entry can only be **added** to this list in an `X.0.0` release, and nothing is ever removed that was not listed here first. Reading this section after a major upgrade tells you everything that may disappear during that line.

An entry may also be **withdrawn** in any release — it is struck through and marked *kept*. Withdrawal is allowed in a minor because it **strictly reduces** what you have to plan for: it retracts a threat rather than creating one, which is the opposite of what the add-only rule guards against.

**One written exception (2.5.0, #382):** a surface may be announced here in a *minor* only if it was shaped around a single consumer's protocol (it fails the consumer-boundary test in `CLAUDE.md`) **and** every known consumer is named and has released its migration off it before removal. Such rows say `2.5.0 (exception)` in the *since* column, and every one that sandy can detect in use **warns at launch** for at least one minor before removal, because this list alone cannot reach someone who does not read it. Anything else still waits for a major. The exception's first use — the relay-era surfaces below — completed on exactly that timeline: announced 2.5.0, removed 2.6.0.

| deprecated | since | use instead |
|---|---|---|
| ~~`SANDY_HANDOFF_DIRS`, and the `~/.handoff/{inbox,outbox,peer,relay}` tree it mounts~~ **— REMOVED in 2.2.0** | 2.0.0 | a feature manifest's `mounts` — it names its own directories instead of using sandy's four fixed ones |
| ~~`SANDY_HANDOFF_*` container env vars (`_INBOX`, `_OUTBOX`, `_PEER`, `_RELAY_STATE`)~~ **— REMOVED in 2.2.0** | 2.0.0 | a mount's `export`, which names the variable the feature wants |
| ~~`SANDY_HANDOFF_RELAY` and the `relay-bin/` slot~~ **— REMOVED in 2.2.0** | 2.0.0 | a feature manifest's `entry`. Setting the key, or leaving an executable in the slot, is now a **hard error** naming the replacement. The *variable* survived as the manifest entry's internal channel after this row's removal; that channel was itself removed in 2.6.0, see below |
| ~~`relay{}` in `/etc/sandy-session.json` and `--print-state`~~ **— WITHDRAWN, kept; RE-ANNOUNCED in 2.5.0, REMOVED in 2.6.0, see the `relay{}` row below** · `handoff_relay`, `relay.slot` **— REMOVED in 2.2.0, `schema_version` 3** (`relay.disabled_by` is NOT removed by *this* row — see below) | 2.0.0 | **`relay{}` stayed through 2.2.0–2.5.x.** Its stated replacement, "the feature's own entry in `--print-state`", was never built when 2.2.0 shipped, and the premise for it — a sandbox runs exactly one relay — stopped holding once a sandbox could adopt more than one feature entry (2.4.0, #381): `relay{}` dual-reported the first entry in sorted feature-directory order, byte-identical to before #381, while every entry (including that one) was additionally reported under `feature_entries.<name>`. What went in 2.2.0 was only the dead field inside it — `slot` described the `relay-bin` slot, removed that release. `relay{}` itself, and its two companion fields, are gone as of 2.6.0 — see the `relay{}` row below |
| ~~`handoff_enabled` and `handoff{}` in `--print-state`~~ **— REMOVED in 2.2.0, `schema_version` 3** | 2.0.0 | they report on the handoff tree above, so they go with it — and their removal bumps `schema_version` for the same reason |
| ~~the `.handoff-enabled` sandbox marker~~ **— REMOVED in 2.2.0** | 2.0.0 | nothing: it forces the handoff tree on for one sandbox, and the tree is what is going. A feature manifest selects per sandbox instead |
| `SANDY_SCREENSHOT_DIR` | 2.0.0 | intended to become a feature manifest; the design is not settled (#317), and the key stays until it is |
| `SANDY_EGRESS_PROXY` | 2.0.0 | `SANDY_EGRESS=off\|permissive\|strict`. It has warned since 0.14.0; listing it here is what finally gives its removal a date |
| `SANDY_EGRESS_NO_ISOLATION` | 2.0.0 | `SANDY_EGRESS=off` — same posture, same approval gate, one key instead of two mutually exclusive booleans |
| `SANDY_EGRESS_STRICT` | 2.0.0 | `SANDY_EGRESS=strict` (or `permissive`) |
| `SANDY_CHANNELS`: the `plugin:<name>@<marketplace>` form | 2.0.0 | bare comma-separated names. The key itself is **not** deprecated — only that spelling of its value |
| ~~`relay{}` in `/etc/sandy-session.json` and `--print-state`, every field~~ **— REMOVED in 2.6.0, `schema_version` 4** — together with `feature_entries.<name>.relay_alias` and `feature_entries.<name>.disabled_by`, which were never listed separately: they existed only as companions of `relay{}` (`relay_alias` pointed at the entry `relay{}` described; `disabled_by` recorded `SANDY_RELAY=0`), and removing them in the same bump was an operator decision to avoid a second `schema_version` bump | 2.5.0 (exception) | `feature_entries.<name>` (2.4.0), which reports every feature entry uniformly. Its replacement now exists, which is what the 2.0.0 withdrawal above was waiting for |
| ~~`SANDY_RELAY`~~ **— REMOVED in 2.6.0** | 2.5.0 (exception) | a feature manifest's `"sandboxes": {"exclude": [...]}` takes a sandbox out of a feature. There is deliberately no per-feature off switch. Setting the key from any source (environment, host config, or a workspace `.sandy/config`) is now a **hard error** naming the replacement |
| ~~`SANDY_RELAY_STATE` and the `/opt/sandy/relay-state` mount~~ **— REMOVED in 2.6.0** | 2.5.0 (exception) | `SANDY_FEATURE_STATE` (exported to each entry's own process) and `/opt/sandy/feature-state/<feature>` — every entry uses this now, uniformly; there is no longer a designated entry that used the old path |
| ~~`SANDY_CROSS_SESSION_INBOUND`: the relay-conditional unset default (`cross_session_inbound_source: "relay-legacy"`)~~ **— REMOVED in 2.6.0** | 2.5.0 (exception) | declare `"receives": ["cross_session"]` in the feature's manifest (2.4.0, #380), or set the key explicitly. The key itself is **not** deprecated — only this way of defaulting it was, and it is now removed. An entry alone now resolves `refuse` |
| ~~`SANDY_HANDOFF_RELAY` as the internal channel a manifest `entry` travels through~~ **— REMOVED in 2.6.0** | 2.5.0 (exception) | the per-feature entry plumbing (`SANDY_FEATURE_ENTRIES`), which every adopted entry now travels through identically — there is no longer a single designated entry for this variable to carry. Already a hard error as a configuration key since 2.2.0; this row was about the internal variable, which is now gone too |
| ~~`/usr/local/bin/sandy-handoff-sessions`~~ **— REMOVED in 2.6.0** | 2.5.0 (exception) | a consumer's own copy, built on the published pane-identity contract (`SPECIFICATION.md`, #378) |

Removals are loud where sandy can see them: a removed config key is a hard error naming its replacement, a removed mechanism warns first, and a removed introspection field bumps `schema_version`.

*(For maintainers: a deprecation warning in `sandy` names the deprecated thing **first**, before any replacement — `run-tests.sh` §138 reads the first `SANDY_*` token on the line and requires it to appear in the table above, so a deprecation added in code but never announced here fails the suite.)*
