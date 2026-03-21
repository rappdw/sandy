# Sandy vs. Alternatives: Replacement Evaluation

**Date:** 2026-03-20 (updated 2026-03-20 — added Claude Code `/sandbox` analysis)
**Analysis Type:** Strategic comparison (Claude Code `/sandbox` vs srt vs OpenShell vs sandy)
**Verdict:** Sandy should be complemented, not replaced — but `/sandbox` changes the positioning.

---

## EXECUTIVE RECOMMENDATION: **NO, SANDY SHOULD NOT BE REPLACED**

Sandy should be **complemented**, not replaced. However, Claude Code's built-in `/sandbox` command (shipped October 2025, powered by srt) now provides baseline sandboxing out of the box. This shifts sandy's value proposition from "the way to sandbox Claude Code" to "production-grade isolation for autonomous agent workflows."

---

## 0. THE ELEPHANT IN THE ROOM: Claude Code's Built-In `/sandbox`

### What It Is

Claude Code shipped a native `/sandbox` command in **October 2025**, powered by Anthropic's open-source [Sandbox Runtime (srt)](https://github.com/anthropic-experimental/sandbox-runtime). It provides OS-level sandboxing of bash commands using native primitives (Seatbelt on macOS, bubblewrap on Linux) — no Docker required.

### What `/sandbox` Provides

- **Filesystem isolation:** Read/write limited to CWD by default; configurable allow/deny paths via `settings.json`
- **Network isolation:** Proxy-based domain filtering (allowlist model, more granular than sandy's IP-range blocking)
- **Auto-allow mode:** Sandboxed bash commands run without permission prompts (similar goal to sandy's `--dangerously-skip-permissions`)
- **Per-command scope:** Applies to bash commands and their subprocesses, not to Claude Code's own file operations
- **Configuration:** Via `/sandbox` menu, `.claude/settings.json` (project), or `~/.claude/settings.json` (user)
- **OS-level enforcement:** All child processes inherit sandbox restrictions (Seatbelt/bubblewrap)

### What `/sandbox` Does NOT Provide

| Capability | `/sandbox` | Sandy |
|-----------|-----------|-------|
| Per-project credential isolation | No (shared `~/.claude`) | Yes (isolated per-project `~/.claude` sandboxes) |
| Resource limits (CPU/memory) | No | Yes (Docker `--cpus`, `--memory`) |
| Protected files (read-only shell configs, git hooks, .claude/commands) | No | Yes (bind-mounted read-only) |
| Persistent dev environments across sessions | No | Yes (pip, npm, go, cargo, uv per-project) |
| Multi-language toolchain pre-installed | No (host-dependent) | Yes (Python, Node, Go, Rust, C/C++) |
| Auto-update Claude Code | No | Yes (detects new versions, rebuilds) |
| Git submodule support | No | Yes |
| No `dangerouslyDisableSandbox` escape hatch | N/A — has escape hatch | Yes — kernel-enforced, no escape mechanism |

### The Critical Security Difference: The Escape Hatch

`/sandbox` includes a built-in bypass mechanism called `dangerouslyDisableSandbox`. When a sandboxed command fails due to restrictions, Claude can autonomously retry it outside the sandbox. This goes through the normal permission flow — but combined with `bypassPermissions` mode, it means **Claude can silently execute commands outside the sandbox with zero prompts**.

Sandy has no equivalent escape hatch. Its isolation is kernel-enforced via Docker: read-only root filesystem, non-root user, `no-new-privileges`, and network iptables rules. There is no mechanism for Claude to opt itself out.

### Threat Model Comparison

| Threat | `/sandbox` | Sandy |
|--------|-----------|-------|
| Data exfiltration to arbitrary domains | Better (domain allowlist) | Weaker (allows all internet, blocks LAN only) |
| Prompt injection causing arbitrary code execution | Weaker (`dangerouslyDisableSandbox` escape) | Stronger (no escape, kernel-enforced) |
| Shell config injection (.bashrc, .zshrc) | Not protected | Protected (read-only mount) |
| Git hook injection (.git/hooks/) | Not protected | Protected (read-only mount) |
| Claude command tampering (.claude/commands/) | Not protected | Protected (read-only mount) |
| Credential leakage across projects | Not isolated (shared ~/.claude) | Isolated (per-project sandbox) |
| Approval fatigue / "click yes to everything" | Vulnerable (permission-based model) | Not applicable (no prompts needed) |
| Resource exhaustion (fork bombs, OOM) | No limits | CPU + memory caps |

### Impact on Sandy's Positioning

**Before `/sandbox`:** Sandy was "the way to sandbox Claude Code."

**After `/sandbox`:** Sandy is "production-grade isolation for autonomous agent workflows where approval fatigue is the threat model."

Sandy's README and messaging should acknowledge `/sandbox` exists and clearly articulate when each is appropriate:

- **Use `/sandbox`** for interactive development where you're reviewing Claude's actions, want domain-level network filtering, and trust the permission system to catch escapes.
- **Use sandy** for autonomous/unattended execution, multi-project credential isolation, environments where `--dangerously-skip-permissions` is needed but you still want kernel-enforced boundaries, and when you need persistent per-project dev environments.

### Feature Sandy Should Adopt FROM `/sandbox`

The domain-based network filtering that `/sandbox` gets via srt is **strictly superior** to sandy's iptables IP-range blocking for preventing data exfiltration. This is already in TODO.md as P0. The `/sandbox` launch makes this more urgent — sandy's network isolation story is now weaker than the built-in option.

---

## 1. MATURITY & STABILITY

| Factor | Sandy | `/sandbox` (CC built-in) | srt (standalone) | OpenShell |
|--------|-------|--------------------------|-------------------|-----------|
| Status | Stable, tested | **GA (ships with Claude Code)** | **Beta research preview** | **Alpha, single-player** |
| Production Ready | Yes | Yes (for its scope) | No | No |
| API Stability | Stable | Stable (Anthropic-maintained) | "APIs may evolve" | Immature |
| User Base | Small but active | **All Claude Code users** | Research/early adopters | Pre-release |
| Breaking Changes | Unlikely | Unlikely | Expected | Likely |

**Finding:** `/sandbox` is now the baseline — it ships with every Claude Code installation. Sandy and srt serve users who need isolation beyond what `/sandbox` provides. OpenShell targets enterprise.

---

## 2. INSTALLATION & DEPENDENCIES

| Factor | Sandy | `/sandbox` | srt | OpenShell |
|--------|-------|-----------|-----|-----------|
| Install | `curl \| bash` | **None (built-in)** | `npm install -g` | `curl \| bash` or `uv tool install` |
| Runtime Deps | Docker only | bubblewrap + socat (Linux) | npm, bubblewrap, socat (Linux), ripgrep | Docker + K3s cluster inside container |
| Dependency Risk | Very low | Very low | Medium (npm ecosystem) | High (Rust, Kubernetes) |
| Minimum Setup | ~30 seconds | **0 (run `/sandbox`)** | 5+ minutes (npm build) | ~2+ minutes (K3s bootstrap) |
| macOS | Requires Docker Desktop (Colima ok) | Works natively (Seatbelt) | Works without Docker | Requires Docker |
| Linux | Requires Docker | Native (bubblewrap) | Native (no Docker needed!) | Requires Docker + K3s |

**Finding:** `/sandbox` has the lowest barrier — zero install, built into Claude Code. Sandy's single bash script is next simplest. srt introduces npm dependency. OpenShell requires K3s orchestration (heavyweight).

---

## 3. SECURITY MODEL COMPARISON

### Sandy's Approach
- **Isolation method:** Docker container + iptables (Linux) + VM isolation (macOS)
- **Network:** Blocks LAN IPv4 ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16), allows internet
- **Filesystem:** Read-only root, per-project sandboxes, protected files (shell configs, .git/hooks, .claude/) mounted read-only
- **Violations:** Silent (no logging)

### srt's Approach
- **Isolation method:** OS-level (bubblewrap on Linux, sandbox-exec on macOS) — NO Docker
- **Network:** Proxy-based domain allowlist (fine-grained: allow github.com, deny malicious.com)
- **Filesystem:** Configurable read/write zones, mandatory deny paths prevent escapes, violation tracking
- **Violations:** Real-time monitoring (macOS native log store), manual strace (Linux)

### OpenShell's Approach
- **Isolation method:** Docker container + K3s + declarative policy engine
- **Network:** L7 HTTP filtering (GET /api/repos allowed, POST /repos denied)
- **Filesystem:** Declarative YAML policy, hot-reloadable
- **Violations:** Policy-enforced logs with hot-reload

**Finding:** srt offers **stronger** network isolation (domain-level filtering vs. IP blocking). Sandy is simpler but weaker. OpenShell is most comprehensive but heaviest.

---

## 4. FEATURE PARITY: What Sandy Provides That Alternatives DON'T

| Feature | Sandy | `/sandbox` | srt | OpenShell | Notes |
|---------|-------|-----------|-----|-----------|-------|
| Persistent dev environment (pip, npm, go, cargo, uv) | **✅ Strong** | ❌ No | ❌ No | ✅ Via container | Sandy isolates *per-project* packages — essential for developer UX |
| Multi-language toolchains pre-installed | ✅ Yes | ❌ Host-dependent | ✅ Yes (host-based) | ✅ Yes (image-based) | |
| Git/SSH auth out-of-box | ✅ Token + SSH agent relay | ✅ Host-native | ✅ Via config | ✅ Via providers | |
| Per-project credential sandboxes | ✅ `~/.sandy/sandboxes/{name}-{hash}` | ❌ Shared `~/.claude` | ❌ Global `~/.srt-settings.json` | ✅ Per-sandbox providers | |
| Auto-update Claude Code | ✅ Yes | ✅ Built-in | ❌ No | ❌ No | Sandy detects new versions and rebuilds |
| One-command launch from any directory | ✅ `sandy` | ✅ `/sandbox` | ⚠️ Requires config file | ⚠️ Requires commands | |
| Git submodule support | ✅ Yes | ✅ Host-native | ❌ No | ❌ No | |
| Protected files (read-only overlay) | ✅ Shell configs, .git/hooks, .claude/ | ❌ No | ✅ Via deny paths | ✅ Yes | Sandy prevents injection attacks |
| Domain-based network filtering | ❌ No (IP-range only) | **✅ Via srt proxy** | **✅ Strong** | ✅ L7 HTTP level | **Sandy's biggest gap** |
| No sandbox escape mechanism | **✅ Kernel-enforced** | ❌ `dangerouslyDisableSandbox` | ✅ OS-enforced (standalone srt) | ✅ Policy-enforced | **Sandy's key advantage** — `/sandbox` wraps srt but adds the escape hatch |
| Resource limits (CPU/memory) | ✅ Docker `--cpus`/`--memory` | ❌ No | ❌ No | ✅ Via K8s | |
| Per-command sandboxing | ❌ No (session-level) | ✅ Bash commands | **✅ Yes** | ⚠️ Pod-level | |
| Hot-reload policies | ❌ No | ❌ No | ❌ No (requires restart) | **✅ Yes** | OpenShell advantage |
| Multi-agent support | ❌ Claude only | ❌ Claude only | ❌ No | ✅ Claude, OpenCode, Copilot, Codex, Ollama | |
| Kubernetes-native | ❌ No | ❌ No | ❌ No | ✅ Yes | OpenShell positions for enterprise |

**Key Finding:**

Sandy's unique features:
1. **Persistent per-project dev environments** — essential for long-term project work
2. **One-command simplicity** — no config files, auto-detect based on working directory
3. **Auto-update detection** — automatically rebuilds when Claude Code version changes

srt's unique features:
1. **Domain-based network filtering** — stronger than IP-range blocking
2. **Per-command sandboxing** — not just full sessions
3. **No Docker requirement** — works on Linux natively with bubblewrap

---

## 5. PRACTICAL USE CASES

### When `/sandbox` Is Enough
- Interactive development where you're reviewing Claude's actions
- Single project, standard domain access needs (GitHub, npm, PyPI)
- You trust the permission system to catch sandbox escape attempts
- You don't need persistent dev environments or credential isolation
- You're on macOS or Linux and want zero-install sandboxing

### When Sandy Excels
- **Autonomous/unattended execution** where approval prompts aren't viable
- Long-running project work (multi-hour sessions) needing persistent environments
- Multi-project workflows with **different credential requirements per project**
- Relying on persistent npm/pip installs from previous sessions
- Need **kernel-enforced boundaries** without a sandbox escape mechanism
- Protection against prompt injection targeting shell configs, git hooks, or .claude/commands
- Resource-constrained environments where CPU/memory caps are needed

### When srt Excels
- Need fine-grained network filtering by domain (not just IP ranges)
- Running isolated commands, not full sessions (e.g., MCP server sandboxing)
- Security-first requirement (explicit domain allowlist)
- Monitoring/logging violations is important
- Linux-only environments (no Docker overhead)
- Existing investment in srt configuration files

### When OpenShell Excels
- Enterprise/multi-tenant scenarios (planned future capability)
- Need hot-reload policies without restarting
- Kubernetes-native deployment
- Multiple agent support (Claude, Copilot, Codex, etc.)
- L7 HTTP filtering (method + path level precision)
- GPU compute requirements

---

## 6. COMPLEXITY & MAINTENANCE BURDEN

| Factor | Sandy | srt | OpenShell |
|--------|-------|-----|-----------|
| Codebase Size | 1,160 lines (bash) | ~4,700 lines (TypeScript) | ~10,000+ lines (Rust) |
| Language | Bash | TypeScript/JavaScript | Rust/Kubernetes YAML |
| Test Coverage | None mentioned | Jest + integration tests | Comprehensive |
| Dependencies | Docker, bash | npm + bubblewrap/socat/ripgrep | Rust toolchain, K3s, Docker |
| Maintainability | High (readable shell) | Medium (Node.js + proxy infrastructure) | Low (distributed Rust + K3s) |
| Maintenance Overhead | Single maintainer (manageable) | Anthropic (professional team) | NVIDIA (professional team) |
| Update Frequency | Ad-hoc | Beta releases expected | Alpha releases expected |

**Finding:** Sandy is simplest to maintain and most readable. srt adds significant npm ecosystem complexity. OpenShell is heaviest lift, requiring Rust expertise and K3s knowledge.

---

## 7. NETWORK ISOLATION STRENGTH

### Sandy (IP-Range Based)
```
✅ Blocks LAN IPv4 (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
❌ IPv6 LAN access UNBLOCKED (CRITICAL gap from security audit)
✅ Allows internet
❌ No domain filtering (can exfiltrate to any domain on internet)
✅ Simple iptables rules, easy to audit
```

### srt (Domain-Based Filtering)
```
✅ HTTP/HTTPS proxy filters by domain (allow github.com, deny malicious.com)
✅ SOCKS5 proxy for other protocols
✅ Violation monitoring (macOS native log store, strace on Linux)
✅ Unix socket restrictions via seccomp (Linux)
✅ Mandatory deny paths prevent sandbox escapes
⚠️ Linux "proxy bypass" risk if app doesn't respect HTTP_PROXY env vars
✅ Pre-generated seccomp filters (no runtime compilation needed)
```

### OpenShell (L7 HTTP Filtering)
```
✅ L7 HTTP filtering (GET /api/repos allowed, POST /repos denied)
✅ Hot-reloadable policies (no restart needed)
✅ Credential injection (strips caller creds, injects backend creds)
✅ Defense-in-depth (filesystem + network + process + inference layers)
❌ More complex rule authoring (YAML policy language)
❌ Requires K3s cluster (heavyweight)
```

**Finding:** srt's domain filtering is **strictly stronger** than sandy's IP filtering for preventing exfiltration. But srt's Linux implementation has proxy bypass vectors. OpenShell offers L7 control at significantly higher complexity cost.

---

## 8. SECURITY AUDIT FINDINGS (From Prior Analysis)

### Sandy's Identified Issues
- **CRITICAL:** IPv6 LAN access unblocked
- **CRITICAL:** SSH agent socket permissions 0777 (should be 0600)
- **CRITICAL:** Concurrent instances interfere with iptables rules
- **HIGH:** iptables failure is fail-open (should be fail-closed on Linux)
- **HIGH:** Permissions are hardcoded to skip (no opt-in for prompts)
- Many issues are fixable but require targeted work (~1 day estimated)

### srt's Design Strengths
- **By design**, domain-level filtering is stronger than IP filtering
- Mandatory deny paths prevent common sandbox escape techniques
- Violation logging is built-in and designed for visibility
- Pre-generated seccomp filters for x64/arm64 (no runtime compilation)
- Rigorous TypeScript + Zod schema validation

### srt's Known Limitations
- Linux "proxy bypass" if app ignores HTTP_PROXY env vars
- macOS Seatbelt integration may have bypass vectors (not publicly disclosed)
- Limited to bubblewrap (Linux) and sandbox-exec (macOS) capabilities

### OpenShell's Posture
- Defense-in-depth across four policy domains (filesystem, network, process, inference)
- Hot-reload prevents need to restart for policy changes
- Designed with multi-tenant in mind (future-proofing)
- Less mature, more potential for undisc overed issues

**Finding:** srt's security model is **stronger by design**. Sandy's issues are mostly fixable but require work. OpenShell is strongest but alpha-level maturity.

---

## 9. WHEN TO MIGRATE vs. STAY

### Keep Sandy If:
1. You value **one-command simplicity** (no config files needed)
2. You have **long-running sessions** needing persistent dev environments
3. You work **multi-project** with different auth/credential requirements
4. You want **minimal dependencies** (Docker only, no npm/K3s)
5. You need **stability now** (production-ready, not beta)
6. You're on **macOS** without Docker (use Colima/Rancher Desktop)
7. You like **small, readable** code you can audit and modify
8. You're a **single developer** or small team (vs. enterprise)

### Migrate to srt If:
1. You need **stronger network isolation** (domain-based filtering for exfiltration prevention)
2. You're **Linux-only** (avoid Docker overhead entirely)
3. You're sandboxing **individual commands** (not full sessions)
4. You need **violation logging/monitoring** for compliance
5. You have **static, predictable** domain allowlists
6. You want **Anthropic-maintained** and officially supported code
7. You're specifically protecting **MCP servers** or other service daemons
8. You can tolerate **beta API changes**

### Migrate to OpenShell If:
1. You're an **enterprise** with multi-tenant requirements
2. You need **hot-reload policies** without service restarts
3. You're **Kubernetes-native** already
4. You need **GPU compute** support
5. You support **multiple agents** (Claude, Copilot, Codex, Ollama, etc.)
6. You need **L7 HTTP filtering** (method and path-level precision)
7. You're willing to adopt **alpha software** with expected breaking changes
8. You have **NVIDIA infrastructure** already in place

---

## 10. RECOMMENDATION: COMPLEMENTARY, NOT REPLACEMENT

### Proposed Strategy

#### Acknowledge `/sandbox` exists:
- Update README to position sandy relative to `/sandbox` — sandy is not "sandboxing for Claude Code" anymore, it's "production-grade isolation for autonomous agent workflows"
- Be clear about when `/sandbox` is sufficient vs. when sandy is needed
- The key differentiator is the threat model: `/sandbox` trusts permission prompts, sandy trusts kernel boundaries

#### Keep sandy and improve it:
- Fix the 5 critical security issues from the audit (~1 day of work):
  1. Add IPv6 iptables rules (or disable IPv6 on Docker network)
  2. Fix SSH agent socket permissions (0600 instead of 0777)
  3. Use per-instance networks to prevent concurrent instance interference
  4. Make iptables failure fail-closed (not fail-open)
  5. Make permission skipping configurable
- **P0: Adopt domain-based network filtering from srt** — this is now urgent because `/sandbox` already offers it; without it, sandy's network isolation is weaker than the built-in option
- Market for developers running Claude autonomously with `--dangerously-skip-permissions`

#### Adopt srt's network filtering approach:
- Domain-based proxy filtering (HTTP/SOCKS5) is strictly better than sandy's IP-range iptables
- `/sandbox` already has this via srt; sandy should match or exceed it
- This is the single most important feature gap to close

#### Watch OpenShell for:
- Enterprise deployment scenarios (when multi-tenant features ship)
- Multi-agent support (if your team uses multiple agents)
- Hot-reload policy management (when product stabilizes)

### Why Full Replacement Fails

1. **Different user models:**
   - Sandy = interactive developer sessions, zero config, persistent environments
   - srt = per-command security, explicit domain allowlists, system-level isolation
   - OpenShell = enterprise orchestration, multi-tenant, policy-driven

2. **Persistent environments are unique to sandy:**
   - srt and OpenShell create fresh environments each time
   - Sandy's per-project pip/npm/cargo/uv persistence is essential for dev UX
   - This can't be replicated in srt/OpenShell without architectural changes

3. **Configuration burden:**
   - Sandy works zero-config from any directory (`sandy` command)
   - srt requires `~/.srt-settings.json` per-domain allowlist
   - OpenShell requires YAML policy authoring
   - Non-technical users prefer sandy's zero-config model

4. **Maturity:**
   - Only sandy is production-ready today
   - srt is beta with API churn expected
   - OpenShell is alpha with breaking changes likely

5. **Simplicity & maintainability:**
   - sandy's 1,160-line bash script is maintainable by one person
   - srt needs npm ecosystem, Node.js runtime, multiple dependencies
   - OpenShell needs Rust expertise, Kubernetes knowledge, K3s orchestration

6. **Use case focus:**
   - Sandy is optimized for what it does: simple session-based development
   - srt is optimized for command-level security and exfiltration prevention
   - OpenShell is optimized for enterprise multi-agent orchestration
   - They don't cannibalize each other; they complement

---

## FINAL ANSWER

**Should sandy be replaced entirely?** **No.**

**Should sandy be the only option?** **No.**

**What should happen?**

1. **Fix sandy's 5 critical issues** (IPv6, SSH perms, concurrent race, fail-open, hardcoded perms)
   - Estimated effort: 1 day
   - Result: Sandy becomes production-ready security tool

2. **Market sandy** for what it's good at
   - "The simplest, zero-config way to sandbox Claude Code sessions"
   - "Perfect for developers who need persistent per-project package environments"

3. **Use srt** alongside sandy for complementary use cases
   - MCP server isolation (srt's stated primary use case)
   - Linux environments where Docker is unavailable
   - Per-command sandboxing with domain filtering

4. **Watch OpenShell** as it matures
   - Consider for enterprise scenarios (when multi-tenant ships)
   - Monitor for stable 1.0 release and API freezing

---

## SUMMARY TABLE

| Criterion | Sandy | `/sandbox` | srt (standalone) | OpenShell |
|-----------|-------|-----------|------------------|-----------|
| **Maturity** | ✅ Production | ✅ GA (built-in) | ⚠️ Beta | ❌ Alpha |
| **Simplicity** | ✅ Excellent | ✅ Best (zero install) | ⚠️ Good | ❌ Complex |
| **Zero-Config** | ✅ Yes | ✅ Yes | ❌ No | ❌ No |
| **Persistent Env** | ✅ Yes | ❌ No | ❌ No | ⚠️ Partial |
| **Network Security** | ⚠️ IP-range | ✅ Domain-based | ✅ Domain-based | ✅ L7 HTTP |
| **No Escape Hatch** | ✅ Kernel-enforced | ❌ `dangerouslyDisableSandbox` | ✅ OS-enforced | ✅ Policy-enforced |
| **Credential Isolation** | ✅ Per-project | ❌ Shared | ❌ Global | ✅ Per-sandbox |
| **Resource Limits** | ✅ CPU + memory | ❌ No | ❌ No | ✅ Via K8s |
| **Protected Files** | ✅ Read-only mounts | ❌ No | ⚠️ Via deny paths | ✅ Yes |
| **Docker Required** | ✅ Yes | ❌ No | ❌ No | ✅ Yes |
| **Maintenance** | ✅ Solo feasible | ✅ Anthropic-maintained | ⚠️ Team needed | ❌ Team needed |
| **Recommended For** | Autonomous agents | Interactive dev | Command isolation | Enterprise |

---

**Conclusion:** The arrival of `/sandbox` as a built-in feature is the most significant competitive development for sandy. It means baseline sandboxing is now free and universal. Sandy's value is no longer "sandboxing for Claude Code" — it's "the hardened runtime for autonomous Claude Code workflows." Sandy's differentiators (no escape hatch, credential isolation, resource limits, protected files, persistent environments) are precisely the features that matter when running Claude unattended with `--dangerously-skip-permissions`. The most urgent action is adopting domain-based network filtering to close the gap where `/sandbox` is actually stronger than sandy today.
