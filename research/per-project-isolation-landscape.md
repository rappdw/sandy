# Per-Project Isolation Landscape: Claude Code Native vs Sandy vs Alternatives

**Date:** 2026-04-08
**Scope:** Analyze what Claude Code provides natively for per-project state isolation, survey the open source landscape of Claude Code sandboxing tools, and identify features sandy should learn from
**Target Audience:** Sandy maintainer, users evaluating sandbox options

---

## Executive Summary

Sandy's per-project sandbox model — isolated `~/.claude`, credentials, plugins, memory, and package storage per project — is analogous to Python virtual environments for AI coding agents. Claude Code natively provides **configuration layering** (project-level CLAUDE.md, settings.json, rules) and **per-git-repo auto memory**, but shares a single global `~/.claude/` directory for plugins, credentials, hooks, and session state across all projects.

The open source landscape has ~20+ projects in this space, but most focus on **security isolation** (filesystem/network containment for `--dangerously-skip-permissions`). Sandy is one of the few that treats **per-project state management** as a first-class concern alongside security. The closest competitors in scope are sbox (streamingfast), claudebox (RchGrav), and claude-sandbox (aldrin).

### Key Findings

1. **Claude Code has no native per-project sandbox isolation** — plugins, credentials, hooks, and session history are global
2. **Sandy's "venv for Claude Code" model is genuinely differentiated** — most alternatives don't isolate per-project state
3. **Docker Sandboxes (Docker, Inc.)** is the emerging platform play — microVM-based, multi-agent, but no per-project state isolation
4. **sbox** has the closest feature set and is worth monitoring for ideas
5. **kubernetes-sigs/agent-sandbox** and **alibaba/OpenSandbox** represent the cloud/enterprise direction

---

## Part 1: Claude Code Native Per-Project Capabilities

### What IS Isolated Per-Project (Natively)

| Aspect | Scope | Storage | Shared via git? |
|--------|-------|---------|-----------------|
| Project instructions | Project | `./CLAUDE.md` | Yes |
| Project settings | Project | `.claude/settings.json` | Yes |
| Project rules | Project | `.claude/rules/` | Yes |
| Local settings overrides | Project (personal) | `.claude/settings.local.json` | No |
| Auto memory | Per-git-repo | `~/.claude/projects/<project>/memory/` | No |

### What IS NOT Isolated Per-Project (Natively)

| Aspect | Scope | Storage | Impact |
|--------|-------|---------|--------|
| **Plugins** | Global | `~/.claude/plugins/` | All projects share installed plugins |
| **Skills** | Global (overridable) | `~/.claude/skills/` | Default discovery is global |
| **MCP servers** | Global + project | `~/.claude/settings.json` | Global config applies everywhere |
| **Hooks** | Global | `~/.claude/hooks/` | All projects trigger same hooks |
| **Credentials** | Global | `~/.claude/.credentials.json` or macOS Keychain | Single credential set for all projects |
| **Session history** | Global | `~/.claude/sessions/` | Not partitioned by project |
| **Context compaction** | Per-session | In-memory | Not persistent, but not isolated either |

### Authentication (Global, No Per-Project Isolation)

Claude Code's auth precedence (applies to all projects equally):

1. Cloud provider env vars (`CLAUDE_CODE_USE_BEDROCK`, etc.)
2. `ANTHROPIC_AUTH_TOKEN` env var
3. `ANTHROPIC_API_KEY` env var
4. `apiKeyHelper` script
5. OAuth (subscription credentials)

There is no mechanism for per-project credential isolation. If you have an API key set, every project uses it.

### Architecture Comparison

```
Claude Code (Native)                     Sandy (Docker Isolation)
========================                 ========================

~/.claude/                (GLOBAL)       ~/.sandy/sandboxes/
├── settings.json                        ├── project-a-a1b2c3d4/
├── CLAUDE.md                            │   └── .claude/         (ISOLATED)
├── .credentials.json                    │       ├── settings.json
├── plugins/              (shared)       │       ├── plugins/
├── hooks/                (shared)       │       ├── memory/
├── sessions/             (shared)       │       └── ...
└── projects/                            └── project-b-e5f6g7h8/
    ├── project-a/memory/                    └── .claude/         (ISOLATED)
    └── project-b/memory/
                                         Docker Container (per session)
project-a/                               ├── /home/claude/ (tmpfs)
├── CLAUDE.md             (per-project)  ├── ~/.claude/ → sandbox mount
└── .claude/settings.json (per-project)  ├── workspace (read-write)
                                         └── protected files (read-only)
```

### What Sandy Adds Over Native Claude Code

| Feature | Claude Code Native | Sandy |
|---------|-------------------|-------|
| Separate `.claude` directories | No (global) | Yes (per-project sandbox) |
| Per-project plugins | No (global) | Yes (sandbox overlay) |
| Per-project credentials | No (global) | Yes (ephemeral mount) |
| Per-project memory | Per-git-repo only | Per-sandbox |
| Per-project package installs | No | Yes (pip, npm, go, cargo, uv) |
| Filesystem isolation | OS sandbox (bash only) | Docker (entire session) |
| Network isolation | Domain proxy (bash only) | iptables + Docker bridge |
| Resource limits | No | Yes (CPU, memory, GPU) |
| Protected file overlay | No | Yes (read-only mounts) |

---

## Part 2: Open Source Landscape

### Tier 1 — Feature-Rich, Closest to Sandy

#### streamingfast/sbox
- **URL**: https://github.com/streamingfast/sbox
- **Approach**: Docker sandbox wrapper with two backends (Docker Sandbox microVMs + standard containers)
- **Per-project state**: Config stored at `~/.config/sbox/projects/<hash>/config.yaml`. Named volume persistence.
- **Strengths**: Dual backend strategy (microVM for security, containers for speed). CLI wrapper pattern similar to sandy.
- **Gaps vs sandy**: No skill pack system, no SSH agent relay, no git submodule support, no protected file overlays.
- **Worth monitoring**: Yes — closest in philosophy. Their microVM backend via Docker Sandbox is interesting.

#### RchGrav/claudebox
- **URL**: https://github.com/RchGrav/claudebox
- **Approach**: 15+ pre-configured development profiles (C/C++, Python, Rust, Go, Java, etc.)
- **Per-project state**: Per-project Docker images with isolated auth state, history, and configs.
- **Strengths**: Development profiles are a nice UX pattern. Per-project network firewall allowlists.
- **Gaps vs sandy**: Less comprehensive language env persistence. No skill packs.
- **Worth learning from**: The development profile concept could inspire sandy presets.

#### aldrin/claude-sandbox
- **URL**: https://github.com/aldrin/claude-sandbox
- **Approach**: Rust CLI. One-time `init` per project creates `.claude-sandbox/` with Containerfile.
- **Per-project state**: Each project gets its own container image (`claude-sandbox-<dirname>`).
- **Strengths**: Git hooks block commits from inside the sandbox (host retains git history ownership). Clean Rust implementation.
- **Gaps vs sandy**: Less mature, fewer features.
- **Worth learning from**: The git commit blocking approach is an interesting security posture worth considering.

#### trailofbits/claude-code-devcontainer
- **URL**: https://github.com/trailofbits/claude-code-devcontainer
- **Approach**: Devcontainer for running Claude Code in bypass mode. Security-audit focused.
- **Per-project state**: Per-project volumes for settings persistence.
- **Strengths**: Built by a respected security firm. VS Code devcontainer integration.
- **Gaps vs sandy**: Devcontainer-centric (requires VS Code or compatible tooling). Less standalone.

### Tier 2 — Simpler Docker Wrappers

These provide basic Docker isolation but limited per-project state management:

| Project | URL | Notes |
|---------|-----|-------|
| nezhar/claude-container | https://github.com/nezhar/claude-container | Persistent credentials via bind mount. Datasette integration for API request logging. |
| nikvdp/cco | https://github.com/nikvdp/cco | Auto-selects sandboxing: native OS (`sandbox-exec`/`bubblewrap`) or Docker fallback. Lightweight. |
| nkrefman/claude-sandbox | https://github.com/nkrefman/claude-sandbox | Basic Docker isolation. |
| Z7Lab/claude-code-sandbox | https://github.com/Z7Lab/claude-code-sandbox | Per-instance isolation. |
| todd-working/claude-code-container | https://github.com/todd-working/claude-code-container | Basic Docker sandbox. |
| tintinweb/claude-code-container | https://github.com/tintinweb/claude-code-container | Focused on `--dangerously-skip-permissions` mode. |
| koogle/claudebox | https://github.com/koogle/claudebox | macOS Keychain integration for auth. |
| boxlite-ai/claudebox | https://github.com/boxlite-ai/claudebox | Uses BoxLite micro-VMs instead of Docker containers. |

### Tier 3 — Platform / Enterprise Solutions

#### Docker Sandboxes (Docker, Inc.)
- **URL**: https://docs.docker.com/ai/sandboxes/
- **Launched**: Jan/Mar 2026
- **Approach**: Official Docker product. Each sandbox runs in a dedicated microVM with its own Linux kernel and private Docker daemon.
- **Supports**: Claude Code, Gemini CLI, Codex, Copilot, Kiro, OpenCode, Docker Agent.
- **Strengths**: Network isolation, credential proxy injection, Docker-in-Docker support. Backed by Docker.
- **Per-project state**: Not a primary concern — focused on runtime isolation.
- **Impact on sandy**: This is the emerging "good enough" option for many users. Sandy's differentiation increasingly lies in per-project state management, skill packs, and the self-contained single-script deployment.

#### kubernetes-sigs/agent-sandbox
- **URL**: https://github.com/kubernetes-sigs/agent-sandbox
- **Approach**: Kubernetes CRD and controller for managing isolated agent workloads. gVisor and Kata Containers for kernel-level isolation.
- **Target**: Production/cloud deployments. Google Cloud GKE integration.
- **Relevance to sandy**: Different audience (enterprise K8s operators vs individual developers).

#### alibaba/OpenSandbox
- **URL**: https://github.com/alibaba/OpenSandbox
- **Approach**: General-purpose sandbox platform. Docker/K8s/Firecracker runtimes. Multi-language SDKs.
- **Integrations**: Claude Code, Gemini CLI, Codex, LangGraph, Playwright.
- **Released**: March 2026. Apache 2.0 license.
- **Relevance**: Shows enterprise demand for agent sandboxing. Feature-rich but heavyweight.

#### textcortex/spritz (successor to claude-code-sandbox)
- **URL**: https://github.com/textcortex/spritz
- **Approach**: Kubernetes-native control plane for running AI agents in containers. Web UI. Plans for Slack/Discord/Teams adapters.
- **Relevance**: Moving toward agent orchestration, beyond just sandboxing.

### Tier 4 — Alternative Isolation Approaches (Not Docker)

| Project | URL | Approach |
|---------|-----|----------|
| webcoyote/clodpod | https://github.com/webcoyote/clodpod | macOS VM-based isolation (not Docker). Supports Claude Code, Codex, Cursor Agent, Gemini. |
| webcoyote/sandvault | https://github.com/webcoyote/sandvault | macOS `sandbox-exec` + user account isolation (no VM, no Docker). |
| Anthropic sandbox runtime | npm package (open source) | OS-level sandboxing via `sandbox-exec` (macOS) / `bubblewrap` (Linux). Built into Claude Code. Focuses on reducing permission prompts (84% reduction internally). |
| Cloudflare Sandbox SDK | https://developers.cloudflare.com/sandbox/tutorials/claude-code/ | Cloud-hosted sandbox option. |

---

## Part 3: Features Sandy Should Learn From

### High Priority

#### 1. Development Profiles (from claudebox)
claudebox offers 15+ pre-configured profiles (Python ML, Rust, Go, etc.) that auto-configure the container. Sandy has `.sandy/Dockerfile` for per-project customization, but curated profiles could lower the barrier to entry.

**Recommendation**: Consider shipping a `sandy init --profile python-ml` or similar that generates a `.sandy/Dockerfile` from a template library. This is lighter than baking profiles into sandy itself and keeps the single-script architecture.

#### 2. API Request Logging (from nezhar/claude-container)
claude-container integrates Datasette for visualizing Claude Code API request logs. This could be valuable for cost tracking and debugging across multiple sandy sessions.

**Recommendation**: Not a core sandy feature, but could be a skill pack or plugin that captures and visualizes API usage per project sandbox.

#### 3. Git Commit Authorship Control (from aldrin/claude-sandbox)
aldrin/claude-sandbox uses git hooks to block commits from inside the sandbox, ensuring the host user retains git history ownership. Sandy currently allows Claude to commit freely inside the container.

**Recommendation**: Consider as an opt-in `.sandy/config` option (e.g. `SANDY_GIT_COMMIT_POLICY=block|warn|allow`). Some users want Claude to commit; others want to review and commit themselves.

### Medium Priority

#### 4. microVM Backend Option (from sbox / Docker Sandboxes)
sbox supports both Docker containers and Docker Sandbox microVMs. Docker Sandboxes provide stronger isolation (own kernel, own Docker daemon). As Docker Sandboxes mature, sandy could offer it as an alternative backend.

**Recommendation**: Monitor Docker Sandboxes maturity. When the API stabilizes, consider adding `SANDY_BACKEND=docker|sandbox` to use microVMs where available. This is non-urgent — Docker containers with sandy's existing hardening are already strong.

#### 5. VS Code Devcontainer Integration (from Trail of Bits)
Trail of Bits' devcontainer approach integrates with VS Code's Remote Containers extension. Some sandy users may prefer IDE-integrated sessions.

**Recommendation**: Sandy could generate a `.devcontainer/devcontainer.json` that references the sandy Docker image. Low effort, additive, doesn't change the core architecture.

### Low Priority / Monitor

#### 6. Native OS Sandboxing Fallback (from cco)
cco auto-selects the best sandboxing method: native OS sandbox or Docker. For quick tasks where Docker startup overhead is unwanted, native sandboxing could be useful.

**Recommendation**: Not aligned with sandy's architecture (Docker is fundamental). But worth noting that Anthropic's own sandbox runtime now provides OS-level sandboxing built into Claude Code itself.

---

## Part 4: Competitive Positioning

### Sandy's Unique Strengths

1. **Per-project state isolation** — The "venv for Claude Code" model. Most alternatives focus on security isolation; sandy also provides state isolation (plugins, memory, credentials, packages).
2. **Three-phase Docker build with caching** — Base image, Claude Code layer, optional per-project layer. Efficient rebuilds.
3. **Skill pack system** — Pluggable Docker layers for curated skill collections. No competitor has this.
4. **SSH agent relay** — macOS socat workaround for SSH agent forwarding into Docker. Rare among alternatives.
5. **Git submodule awareness** — Detects `.git` files, resolves gitdir paths, mounts correctly. Unique.
6. **Protected file overlays** — Read-only mounts for security-sensitive files. More comprehensive than most.
7. **Self-contained single bash script** — No runtime dependencies beyond Docker. Easy to audit, easy to install.
8. **Per-project persistent package installs** — Separate pip/npm/go/cargo/uv mounts per sandbox. No competitor matches this breadth.
9. **Channel support** — Telegram/Discord integration via plugin auto-install. Unique to sandy.

### Where Sandy Lags

1. **No domain-based network filtering** — Sandy blocks IP ranges via iptables; `/sandbox` and srt filter by domain name via proxy. (Already tracked in FEATURE-ADOPTION-ANALYSIS.md as P0.)
2. **No microVM option** — Docker containers only. Docker Sandboxes and boxlite-ai offer stronger isolation via microVMs.
3. **No IDE integration** — No devcontainer.json generation or VS Code Remote Containers support.
4. **No built-in development profiles** — Users must write `.sandy/Dockerfile` from scratch (or copy from examples/).

### Market Positioning

The landscape is splitting into three segments:

1. **Platform plays** (Docker Sandboxes, K8s agent-sandbox, OpenSandbox) — target enterprise/cloud, multi-agent, heavyweight
2. **Simple wrappers** (most Tier 2 projects) — basic Docker isolation, minimal per-project state management
3. **Opinionated developer tools** (sandy, sbox, claudebox) — self-contained, per-project isolation, developer-focused

Sandy is well-positioned in segment 3. The "venv for Claude Code" framing is the strongest differentiator and should be emphasized in marketing/README. As Docker Sandboxes mature, the security-isolation-only projects (segment 2) will lose relevance, but sandy's per-project state management story remains valuable regardless of the underlying isolation mechanism.

---

## References

- [streamingfast/sbox](https://github.com/streamingfast/sbox)
- [trailofbits/claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer)
- [RchGrav/claudebox](https://github.com/RchGrav/claudebox)
- [aldrin/claude-sandbox](https://github.com/aldrin/claude-sandbox)
- [textcortex/spritz](https://github.com/textcortex/spritz)
- [nezhar/claude-container](https://github.com/nezhar/claude-container)
- [nikvdp/cco](https://github.com/nikvdp/cco)
- [boxlite-ai/claudebox](https://github.com/boxlite-ai/claudebox)
- [webcoyote/clodpod](https://github.com/webcoyote/clodpod)
- [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)
- [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)
- [alibaba/OpenSandbox](https://github.com/alibaba/OpenSandbox)
- [Anthropic Sandbox Runtime Blog](https://www.anthropic.com/engineering/claude-code-sandboxing)
- [Claude Code Sandboxing Docs](https://code.claude.com/docs/en/sandboxing)
- [Cloudflare Sandbox for Claude Code](https://developers.cloudflare.com/sandbox/tutorials/claude-code/)
