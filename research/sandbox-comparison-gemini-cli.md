# Sandy vs Gemini CLI Sandboxing: Full Comparison

## Isolation Architecture

| | Sandy | Gemini CLI |
|---|---|---|
| **Model** | Whole-session Docker container | Two layers: per-tool (bwrap/seatbelt) + optional whole-session (Docker) |
| **Linux** | Docker with hardened flags | Bubblewrap per tool call, or Docker for full session |
| **macOS** | Docker Desktop | Seatbelt `sandbox-exec` per tool call |
| **Windows** | Not supported | Low Integrity tokens + Job Objects |

## Security Hardening

| Control | Sandy | Gemini CLI |
|---|---|---|
| **Capabilities** | `--cap-drop ALL`, add back only SETUID/SETGID/CHOWN/DAC_OVERRIDE/FOWNER | No capability restrictions |
| **Read-only root** | `--read-only` | bwrap: `--ro-bind / /`. Docker mode: **no** |
| **Privilege escalation** | `--security-opt no-new-privileges:true` | Not set |
| **Resource limits** | CPU, memory, PID limit (512) | **None** |
| **Seccomp** | Docker defaults | Custom BPF blocking `ptrace` (per-tool only) |
| **PID namespace** | Isolated (Docker default) | bwrap: `--unshare-all`. Docker: default |

**Verdict**: Sandy is significantly more hardened at the container level. Gemini's Docker mode is surprisingly permissive — no capability drops, no read-only root, no resource limits, no privilege escalation prevention.

## Network Isolation

| | Sandy | Gemini CLI |
|---|---|---|
| **Internet** | Allowed | Per-tool: **blocked by default**. Docker: allowed |
| **LAN blocking** | iptables DROP on RFC 1918, link-local, CGNAT/Tailscale | **None** |
| **Host access** | Blocked | Docker adds `--add-host host.docker.internal:host-gateway` (explicitly enabled!) |

**Verdict**: Sandy wins decisively on network. Gemini's per-tool sandbox blocks network by default (good for individual commands), but when network is granted, there's zero LAN isolation. Gemini's Docker mode actively adds host gateway access — an attacker with code execution could reach your local network services.

Sandy's approach (internet yes, LAN no) is the right tradeoff for coding agents: they need to `npm install` and `git push`, but shouldn't be able to hit your NAS, router, or internal APIs.

## Credential Protection

| | Sandy | Gemini CLI |
|---|---|---|
| **API keys** | Passed via env var, contained within Docker | Passed via env var, plus env sanitization blocks `TOKEN`/`SECRET`/`KEY` patterns from per-tool subprocesses |
| **OAuth tokens** | Ephemeral tmpfs mount, never persisted to sandbox | Cached in `~/.gemini/`, mounted read-write into Docker |
| **`.env` files** | Not specifically handled (container isolation is the boundary) | **Masked** — bwrap bind-mounts a zero-permission file over `.env*` files; seatbelt denies access via regex |
| **Git credentials** | `GIT_TOKEN` in env, `gh auth` per-session | gcloud config mounted read-only |

**Learning for Sandy**: Gemini's `.env` file masking is a good idea. Sandy relies on the container being the trust boundary, but Claude Code running with `--dangerously-skip-permissions` inside the container *can* `cat .env` files in the mounted project. Sandy should consider mounting `.env*` files read-only or masking them.

Gemini's environment variable sanitization (blocking `TOKEN`, `SECRET`, `KEY` patterns from reaching tool subprocesses) is also clever — it prevents accidental credential leakage through shell environment inheritance. Sandy doesn't need this as urgently since credentials are already isolated to the container, but it's defense-in-depth.

## Per-Project Isolation (Virtual Environment Equivalency)

| | Sandy | Gemini CLI |
|---|---|---|
| **Config isolation** | Per-project `~/.claude/` sandbox with hash-based directories | **None** — single shared `~/.gemini/` |
| **Plugin isolation** | Per-project — plugins installed in one project don't leak to another | **None** — shared across all projects |
| **Memory isolation** | Per-project auto-memory | **None** — shared `~/.gemini/memory/` |
| **Package persistence** | Per-project mounts for pip/npm/go/cargo/uv | **None** — Docker uses `--rm`, everything lost |
| **Settings isolation** | Per-project `settings.json` seeded from host | **None** — host `~/.gemini/settings.json` mounted read-write |
| **Credential isolation** | Per-project sandbox, credentials never persisted | Host `~/.gemini/` modified in-place |
| **Sandbox policy** | N/A (container is the policy) | `sandbox.toml` is **global** — approvals granted in project A apply to project B |

**Verdict**: Gemini CLI has **zero per-project isolation**. This is sandy's single biggest differentiator. Gemini's `~/.gemini/` is shared and mutable — a plugin installed for one project is active everywhere, memory bleeds between projects, and sandbox policy approvals are global. Gemini's Docker mode even mounts `~/.gemini/` read-write, so the agent can modify your host config.

## Protected Files

| | Sandy | Gemini CLI |
|---|---|---|
| **Shell configs** | `.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile` — read-only overlay | Not protected |
| **Git config** | `.gitconfig`, `.git/config`, `.gitmodules` — read-only | `.gitignore`, `.git/` — read-only (bwrap). `.gitconfig` read-only mount (Docker) |
| **Git hooks** | `.git/hooks/` — read-only overlay | Not explicitly protected |
| **IDE config** | `.vscode/`, `.idea/` — read-only overlay | Not protected |
| **MCP config** | `.mcp.json` — read-only overlay | Not protected |
| **Agent commands** | `.claude/commands/`, `.claude/agents/`, `.claude/plugins/` — sandbox-mounted writable copies | Not applicable |

**Verdict**: Sandy protects more attack surfaces. Git hook injection, shell config injection, and IDE config tampering are real attack vectors that sandy blocks. Gemini protects governance files (`.gitignore`) but misses hooks and shell configs.

## Per-Tool vs Whole-Session Sandboxing

Gemini's per-tool approach (bwrap/seatbelt wrapping each command) has one advantage sandy lacks: **granular permission escalation**. Each `shell_exec` runs in its own sandbox, so `ls` gets read-only access while `npm install` gets network + write. The agent can request broader permissions mid-session, and the user approves per-tool.

Sandy's approach is coarser: the entire session runs in one container with fixed permissions. But this is by design — sandy runs Claude Code with `--dangerously-skip-permissions`, meaning the agent has full autonomy *within* the container. The container boundary is the only control point.

**Tradeoff**: Gemini's per-tool approach gives finer control but adds overhead (every command spawns a bwrap/seatbelt process) and complexity (dynamic policy management, approval fatigue). Sandy's approach is simpler and faster but all-or-nothing.

## What Sandy Should Learn From Gemini

1. **`.env` file protection** — Mount `.env`, `.env.*`, `.env.local` files read-only (or mask them entirely). Low effort, meaningful security gain. The agent doesn't need to write to `.env` files, and reading them should be a conscious decision.

2. **Environment variable sanitization** — Consider filtering sensitive env vars (`*TOKEN*`, `*SECRET*`, `*KEY*`, `*PASSWORD*`) from the container environment. Sandy already does this for `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` (empties them if unset), but doesn't block arbitrary host env vars from leaking in.

3. **Secret file discovery** — Gemini scans 3 levels deep for `.env*` files and masks them. Sandy could do the same scan and add them to the read-only protected files list.

## What Gemini Should Learn From Sandy

Pretty much everything else:
- Per-project isolation (the virtual env model)
- LAN network isolation
- Container hardening (cap-drop, read-only root, resource limits, no-new-privileges)
- Credential ephemerality (never persist tokens to sandbox)
- Protected files coverage (hooks, shell configs, IDE configs)
- Persistent package storage across sessions

## Is Gemini Sandboxing Sufficient?

**For casual use**: The per-tool bwrap/seatbelt sandbox provides reasonable protection against accidental damage. Each command is isolated, network is off by default, and the user approves escalations.

**For `--yolo` / autonomous mode**: **No.** In yolo mode, all approvals are auto-granted, the per-tool sandbox runs with full permissions, and there's no container boundary. A malicious prompt injection could access `~/.ssh`, `~/.aws`, hit your LAN, modify `~/.gemini/` to persist changes, and install plugins that affect all future projects. The Docker sandbox mode helps but lacks hardening (no cap-drop, no resource limits, no LAN isolation, host gateway enabled).

**For per-project isolation**: **No.** Gemini has nothing equivalent. No virtual env model at all.

## Does Gemini Provide Virtual Env Equivalency?

**No.** This is sandy's unique value proposition. Gemini CLI shares all state globally across projects — plugins, memory, settings, sandbox policies, and credentials all live in one `~/.gemini/` directory with no per-project partitioning.
