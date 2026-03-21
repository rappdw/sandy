# Feature Adoption Analysis: `/sandbox` vs. srt vs. OpenShell vs. Sandy

**Date:** 2026-03-20 (updated 2026-03-20 — added Claude Code `/sandbox` analysis)
**Scope:** Identify features from Claude Code's built-in `/sandbox`, srt (Anthropic Sandbox Runtime), and OpenShell (NVIDIA) that should be adopted into sandy
**Target Audience:** Sandy maintainer, security-focused Claude Code users

---

## Executive Summary

Sandy is a well-designed Docker-based sandbox with solid fundamentals. However, Claude Code's built-in `/sandbox` command (shipped October 2025, powered by srt) now provides baseline sandboxing — including **domain-based network filtering** — out of the box. This makes sandy's network isolation gap more urgent to close.

The analysis of `/sandbox`, srt, and OpenShell reveals **5 high-value features** that would meaningfully improve security and observability:

| Priority | Feature | Effort | Value | Status in Sandy | Urgency |
|----------|---------|--------|-------|-----------------|---------|
| **P0** | Domain-based network filtering (HTTP/SOCKS proxy) | Significant | Critical security improvement | TODO (in TODO.md) | **Elevated** — `/sandbox` already has this |
| **P0** | Violation logging & monitoring | Moderate | Essential for debugging & compliance | TODO (in TODO.md) | Same |
| **P1** | Declarative YAML policy files | Moderate | Better UX than bash env vars | New proposal | Same |
| **P1** | Per-command sandboxing | Significant | Nice-to-have, lower priority | Out of scope | Same |
| **P2** | Configuration validation (Zod/schema) | Trivial | Prevents misconfiguration | New proposal | Same |
| **P2** | Hot-reloadable policies | Moderate | Useful for long sessions | New proposal | Same |

### Why `/sandbox` Changes the Calculus

Claude Code's `/sandbox` uses srt under the hood to provide OS-level sandboxing of bash commands. It includes proxy-based domain filtering — the single feature sandy lacks that `/sandbox` has. Without domain filtering, sandy's network isolation story is *weaker* than the built-in option (sandy blocks LAN ranges via iptables; `/sandbox` filters by domain via proxy). Sandy compensates with kernel-enforced boundaries, no escape hatch, credential isolation, resource limits, and protected files — but the network gap needs closing.

---

## Part 0: Claude Code's Built-In `/sandbox` Command

### Overview

Claude Code shipped `/sandbox` in **October 2025**. It's a CLI frontend for srt that provides OS-level sandboxing of bash commands using Seatbelt (macOS) and bubblewrap (Linux). Run `/sandbox` in a Claude Code session to configure, then sandboxed bash commands execute with filesystem and network restrictions automatically.

### Key Features Sandy Should Learn From

1. **Domain-based network filtering via proxy** — `/sandbox` inherits srt's proxy-based domain allowlist. This is the single capability where `/sandbox` is stronger than sandy. Sandy blocks IP ranges; `/sandbox` blocks by domain name. Domain filtering prevents exfiltration to arbitrary internet hosts, which sandy currently allows.

2. **Auto-allow mode** — `/sandbox` offers a mode where sandboxed commands auto-approve without permission prompts. Sandy achieves this differently (`--dangerously-skip-permissions` + kernel enforcement), but the UX concept is similar. No new feature needed.

3. **Settings-based configuration** — `/sandbox` uses `.claude/settings.json` for policy (filesystem allow/deny paths, network allowed domains). Sandy uses `.sandy/config` (bash env vars). The settings.json approach is more structured but coupled to Claude Code's config system. Sandy's independent config is actually an advantage for portability.

### What `/sandbox` Has That Sandy Should NOT Adopt

- **`dangerouslyDisableSandbox` escape hatch** — When a sandboxed command fails, Claude can retry outside the sandbox. This is antithetical to sandy's threat model. Sandy's whole point is that there's no escape.
- **Per-command granularity** — `/sandbox` only wraps bash commands, not file operations or other Claude Code tools. Sandy wraps the entire session. Different architectures, different tradeoffs. Sandy's model is simpler and more comprehensive.
- **Permission-prompt-based enforcement** — `/sandbox` falls back to permission prompts for unsandboxable operations. Sandy doesn't need this because kernel enforcement handles everything.

### Impact on Priority

The existence of `/sandbox` with domain filtering **elevates the priority of sandy's domain-based network filtering from "high value" to "urgent."** Without it, sandy's value proposition has an awkward gap: "We provide stronger isolation than `/sandbox` in every way... except network filtering, where `/sandbox` is actually better."

---

## Part 1: Anthropic Sandbox Runtime (srt)

### Overview

**srt** is a lightweight, OS-level sandbox wrapper for individual commands (not full session sandboxes like sandy). It enforces filesystem and network restrictions via native OS primitives (macOS `sandbox-exec` + Seatbelt, Linux `bubblewrap`). Key design: **proxy-based network filtering**. It is the engine behind Claude Code's `/sandbox` command.

**Architecture:** Runs HTTP and SOCKS5 proxies on the host; sandboxed process traffic routes through these proxies for domain filtering and violation detection.

---

### High-Value Features for Sandy

#### 1. Domain-Based Network Filtering (P0 — CRITICAL)

**Status in srt:** Fully implemented via HTTP/SOCKS5 proxy architecture
**Current state in sandy:** iptables IPv4 rules only; blocks RFC 1918 ranges but allows all other internet traffic

**Feature Details:**
- HTTP proxy intercepts HTTP/HTTPS traffic
- SOCKS5 proxy handles all other TCP (SSH, databases, etc.)
- Domain allowlist enforcement: only whitelisted domains can be reached
- Denylists override allowlists for fine-grained control
- Support for wildcard patterns: `*.github.com`, `*.npmjs.org`

**Why It Matters:**
- Current sandy model allows unrestricted outbound internet (only LAN blocked)
- An untrusted Claude Code prompt could exfiltrate data to arbitrary attacker servers
- srt's approach prevents data leakage to unexpected destinations
- Already identified in sandy's TODO.md as high-priority

**Example Config (from srt):**
```json
{
  "network": {
    "allowedDomains": [
      "github.com",
      "*.github.com",
      "api.github.com",
      "npmjs.org"
    ],
    "deniedDomains": ["malicious.com"]
  }
}
```

**Implementation in Sandy:**

**Approach A: Optional proxy layer (minimal Docker changes)**
- Start HTTP proxy and SOCKS5 proxy as sidecars in the container
- Set `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` environment variables in Claude Code process
- Configuration: `.sandy/network.conf` or `SANDY_ALLOWED_DOMAINS` env var
- Proxy listening on 127.0.0.1:3128 and 127.0.0.1:1080

**Approach B: Host-side proxies (closer to srt model)**
- Start proxies on the host (outside container)
- Bind mount proxy socket into container
- More complex setup but cleaner separation

**Effort Estimate:** 2-3 days
- ~200 lines for simple HTTP/SOCKS5 proxies (or reuse existing libraries)
- Config parsing & validation
- Integration into `sandy` launcher and container entrypoint
- Testing across Linux/macOS

**Implementation Sketch:**
1. Create `proxy/http.ts` and `proxy/socks5.ts` modules
2. Add domain matching logic (including wildcard support)
3. Config file format: `.sandy/network.conf` (JSON or YAML)
4. Default: allow only common domains (GitHub, npm, PyPI, Anthropic, etc.)
5. Optional: make proxy opt-in via `SANDY_NETWORK_FILTER=true`

**Risk:** Proxy could become a bottleneck for large package downloads. Mitigated by efficient streaming implementation and optional disabling.

---

#### 2. Violation Logging & Monitoring (P0 — HIGH)

**Status in srt:** Implemented with macOS system log integration, Linux strace-based detection
**Current state in sandy:** Silent blocking (iptables rules deny, no logging)

**Feature Details from srt:**
- macOS: Taps into system sandbox violation log store (real-time notifications)
- Linux: Uses `strace` to detect EPERM errors
- Logs: What operation was attempted, why it was blocked, when
- **In-memory violation store:** Tracks last N violations for debugging

**Why It Matters:**
- Users have no visibility into what was blocked
- Makes debugging permission issues harder
- Builds confidence in sandbox ("what is it protecting?")
- Compliance/audit trail: "what was attempted, what succeeded"
- Helps identify misconfigurations (e.g., "I forgot to allow /tmp write")

**Violations to Log:**
1. **Network violations:** Blocked outbound connections (if proxy is added)
2. **Protected file writes:** Attempts to write to .bashrc, .git/hooks, .claude/commands (already read-only)
3. **Protected directory writes:** Attempts to write to .git/config, .vscode/ (already read-only)
4. **Optional:** Write attempts outside workspace (would require audit hook)

**Example Log Output:**
```
2026-03-20T14:32:15Z [VIOLATION] network: blocked outbound connection to malicious.com:443 (not in allowlist)
2026-03-20T14:32:22Z [VIOLATION] filesystem: attempted write to .bashrc (protected file)
2026-03-20T14:32:45Z [INFO] network: curl to github.com:443 allowed (matches allowlist)
```

**Implementation in Sandy:**

**Approach: Simple file-based logging + optional JSON export**
- Log to `~/.sandy/sandboxes/<project>/violations.log`
- Format: timestamped plaintext + optional JSON for machine parsing
- Optional: streaming mode (`--tail-violations`) shows real-time logs

**Effort Estimate:** 1-2 days
- iptables rules already log via syslog (just need to parse)
- Add auditd hooks or use eBPF for filesystem write attempts (complex)
- **Simpler first pass:** Log only network violations and read-only file write attempts

**Implementation Sketch:**
1. For **network violations**: Parse `docker logs` output if proxy logs denials
2. For **filesystem violations**: Hook into read-only mount layer (challenging without seccomp)
   - Option: Use `audit` framework (requires CAP_AUDIT_WRITE in container)
   - Option: Monitor `/proc` for denied syscalls
   - Simpler: Just log after the fact in Claude Code error messages
3. Create violation store struct (in-memory ring buffer, last 100 violations)
4. Expose via API or tail logs with `sandy logs <project>`

**Trade-off:** Full syscall tracing is expensive; start with proxy + user-space logging.

---

#### 3. Configuration Validation (P2 — NICE-TO-HAVE)

**Status in srt:** Uses Zod schemas for strict validation
**Current state in sandy:** No config file format yet (uses env vars and .sandy/config)

**Feature Details:**
- Zod schema validation: Catches misconfigurations early
- Clear error messages: "allowedDomains must be array of strings, got undefined"
- Type safety: Enum values, ranges, required fields

**Why It Matters:**
- As sandy gains more configuration (network filters, policies), mistakes become likely
- Early detection prevents silent failures (e.g., typo in domain name silently allows everything)
- Schema-driven approach enables interactive config generation

**Example Schema (if sandy adds .sandy/network.yaml):**
```json
{
  "allowedDomains": {
    "type": "array",
    "items": { "type": "string" },
    "minItems": 1,
    "description": "Domains allowed for outbound connections"
  },
  "deniedDomains": {
    "type": "array",
    "items": { "type": "string" }
  },
  "logLevel": {
    "type": "enum",
    "values": ["debug", "info", "warn", "error"],
    "default": "info"
  }
}
```

**Effort Estimate:** Trivial (< 2 hours)
- Add a small validation library (zod is TypeScript; sandy could use JSON Schema or simple shell validation)
- Validate on `sandy` startup before container launch
- Fail fast with clear error message

---

### Medium-Value Features (Lower Priority)

#### Dynamic Config Updates (P2 — NICE-TO-HAVE)

**Status in srt:** Supports `--control-fd` for runtime permission changes
**Current state in sandy:** One container per session; config frozen at startup

**Relevance:** Sandy's model (ephemeral per-session containers) makes this less critical than long-lived daemon sandboxes. However, for long interactive sessions (hours), reloading policies without restart could be useful.

**Implementation:** Send signal to container to reload `.sandy/config`; would require supervising process in container.

**Effort:** 1-2 days. **Priority:** Low (sessions are ephemeral, restart is acceptable).

---

#### MITM Proxy Support (P3 — INFRASTRUCTURE)

**Status in srt:** Optional configuration to route HTTPS through custom CA-signed proxies for inspection
**Current state in sandy:** Not applicable

**Relevance:** Enterprises with network inspection requirements. **Not a priority for sandy's current scope** (individual developer tool).

---

### Low-Value / Not Applicable

#### Per-Command Sandboxing

**Status in srt:** Can sandbox individual commands, not just entire sessions
**Current state in sandy:** Session-level sandboxing

**Relevance:** srt's model is per-command (e.g., `srt curl https://...` wraps a single command). Sandy is per-session (full Claude Code session). These are different use cases. **Not applicable.**

---

## Part 2: OpenShell (NVIDIA)

### Overview

**OpenShell** is a full agentic sandbox platform: Kubernetes-based, multi-tenant, with declarative YAML policies. Designed for **production** deployment; sandy is a **developer tool**. Three key insights worth adopting:

1. **Declarative YAML policies** (vs. env vars)
2. **L7 (HTTP method + path) network enforcement**
3. **Credential providers** (named bundles, env var injection)

---

### High-Value Features for Sandy

#### 1. Declarative YAML Policy Files (P1 — GOOD-TO-HAVE)

**Status in OpenShell:** Central `.yaml` policy files define filesystem, process, and network rules
**Current state in sandy:** Configuration via bash env vars (.sandy/config sourced as bash script)

**Example OpenShell Policy:**
```yaml
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc]
  read_write: [/sandbox, /tmp]
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
  github_api:
    name: github-api-readonly
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        access: read-only
    binaries:
      - { path: /usr/bin/curl }
```

**Why It Matters:**
- Current sandy env var config is hard to read and parse
- YAML is self-documenting: structure is visible
- Enables future features (comments, examples, validation)
- Easier to share/version-control policies
- Tools can generate/validate YAML more easily than bash

**For Sandy:**
- Format: `.sandy/policy.yaml` (optional, default to env vars for backward compatibility)
- Minimal subset: network filters, allowed domains, workspace read-write rules
- NOT the full OpenShell complexity (no landlock, process isolation already fixed)

**Example sandy policy.yaml:**
```yaml
version: 1
network:
  allowedDomains:
    - github.com
    - "*.github.com"
    - npmjs.org
    - api.anthropic.com
  deniedDomains: []
  logLevel: info
workspace:
  readOnly: false
ssh:
  mode: token  # or "agent"
```

**Effort Estimate:** 1-2 days
- Add YAML parsing (use small library)
- Merge with env var config (env vars override YAML)
- Validation (schema-based, see section 3 above)

**Risk:** Adds a new config format to maintain. Mitigated by keeping env var support as default.

---

#### 2. Credential Providers (P1 — COMPLEMENTARY)

**Status in OpenShell:** Named credential bundles (`openshell provider create`); credentials injected as env vars at sandbox creation
**Current state in sandy:** Reads from host ~/.claude/ and ~/.ssh/; passes via env vars or mounts

**Key Insight:** OpenShell explicitly models credentials as **named, reusable providers** rather than per-sandbox setup. Example:

```bash
openshell provider create --type github --from-existing
# Creates named provider "github" from GITHUB_TOKEN in shell
openshell sandbox create --provider github -- claude
# Sandbox gets GITHUB_TOKEN injected
```

**For Sandy:**
- Sandy already does credential loading (ANTHROPIC_API_KEY, GIT_TOKEN)
- OpenShell's model is not a strict improvement for sandy's use case (single-user, per-project)
- However: Could support `.sandy/providers.json` as a more secure alternative to env vars
  - Example: Store provider definitions in config, load on demand
  - Prevents credentials from being visible in `docker inspect` output

**Implementation:** Advanced feature, not critical for sandy's current needs.

**Priority:** P2 (defer to post-domain-filtering)

---

#### 3. L7 (HTTP Method + Path) Network Enforcement (P3 — OVERKILL)

**Status in OpenShell:** Policies specify HTTP methods and paths:
```yaml
endpoints:
  - host: api.github.com
    port: 443
    access: read-only  # Implicitly allows GET, blocks POST/PUT/PATCH/DELETE
    rules:
      - allow:
          method: GET
          path: "/repos/*/readme"
```

**Current state in sandy:** Domain-only filtering; no method/path enforcement

**Relevance:** L7 enforcement prevents subtle exfiltration:
- Attacker can't POST data to allowed domain (but could GET it)
- Can lock down to specific API endpoints

**For Sandy:** **Too granular and maintenance-heavy** for a developer tool. Domain filtering is 80% of the value. L7 would require:
- Maintaining policy rules for every API
- Decoding/parsing HTTPS (MITM), complex and risky
- **Recommendation:** Skip for now. Document as a limitation and defer to future.

---

### Medium-Value Features

#### Hot-Reloadable Policies (P2 — NICE-TO-HAVE)

**Status in OpenShell:** `openshell policy set` updates network policies on running sandbox without restart
**Current state in sandy:** Ephemeral containers; can't reload without restarting

**Implementation:** Would require a persistent supervising process in the container that listens for config updates. **Low value** given sandy's per-session model.

---

#### Terminal UI / Real-Time Monitoring (P3 — INFRASTRUCTURE)

**Status in OpenShell:** `openshell term` provides a real-time k9s-like dashboard
**Current state in sandy:** No TUI

**Relevance:** Useful for multi-sandbox deployments. Not a priority for sandy (single-session, single-user).

---

## Part 3: Implementation Roadmap for Sandy

### Recommended Prioritization

| Phase | Feature | Effort | Value | Dependencies |
|-------|---------|--------|-------|--------------|
| **Now** | Fix security audit findings (IPv6, SSH socket, etc.) | 1-2d | Critical | None |
| **Q2** | Domain-based network filtering (proxy layer) | 2-3d | Critical | Config system |
| **Q2** | Violation logging & monitoring | 1-2d | High | Proxy layer |
| **Q3** | Declarative YAML policy files | 1-2d | Medium | Config parsing |
| **Q3** | Configuration validation (schema) | <1d | Medium | Policy YAML |
| **Q4+** | Credential providers (advanced) | 2-3d | Medium | Config system |
| **Future** | Per-command sandboxing | Major rework | Low | Architecture change |

---

### Phase 1: Prerequisite (Before Adding Features)

Sandy currently has **5 critical security issues** (from security audit in `/analysis/02-security-audit.md`):

1. **IPv6 network isolation bypass** — iptables rules don't block IPv6 private ranges
2. **SSH agent socket 0777 permissions** — world-writable, allows SSH key misuse
3. **Credential exposure via env vars** — visible in `docker inspect`, `/proc`
4. **Concurrent instance race condition** — shared iptables rules cause interference
5. **iptables failure is fail-open** — should fail-closed if rules can't be applied

**Timeline:** Fix these first (~1-2 days), then proceed with feature additions.

---

### Phase 2: Domain-Based Network Filtering (P0)

**Objectives:**
1. Add HTTP/SOCKS5 proxy layer to sandbox
2. Implement domain allowlist/denylist enforcement
3. Configuration via `.sandy/network.conf` or env var `SANDY_ALLOWED_DOMAINS`
4. Default allowlist: GitHub, npm, PyPI, Anthropic, etc.

**Design Decisions:**
- Proxy runs in container (simpler than host-side proxies)
- Optional feature: `SANDY_NETWORK_FILTER=true` to enable (default: disabled for backward compatibility)
- Config format: JSON (simpler than YAML for first iteration)
- Wildcard support: `*.github.com`, `*.npmjs.org`

**Effort Estimate:** 2-3 days
- HTTP proxy implementation: ~150 lines (reuse existing libraries)
- SOCKS5 proxy: ~100 lines
- Config parsing: ~50 lines
- Integration: ~100 lines
- Testing: 1 day

**Success Metrics:**
- `sandy -p "curl https://attacker.com"` → blocked (not in allowlist)
- `sandy -p "curl https://github.com"` → allowed (in default allowlist)
- Config: `.sandy/network.conf` with custom domains works
- Violation logging shows blocked attempts

---

### Phase 3: Violation Logging (P0)

**Objectives:**
1. Log all blocked network connections (from proxy)
2. Log write attempts to protected files (if feasible)
3. Output to `.sandy/sandboxes/<project>/violations.log`
4. Optional: `sandy logs <project> --tail` streams violations in real-time

**Design Decisions:**
- Format: Plaintext + optional JSON for machine parsing
- Retention: Last 10,000 violations per sandbox (ring buffer in memory)
- Real-time: Optional, for long-running sessions

**Effort Estimate:** 1-2 days
- Proxy logging: ~50 lines
- Log file writing: ~50 lines
- CLI integration: ~100 lines

---

### Phase 4: Configuration System (P1-2)

**Objectives:**
1. Introduce `.sandy/policy.yaml` as optional config format
2. Add schema validation (JSON Schema or simple validation)
3. Merge YAML + env vars (env vars override YAML)
4. Backward compatible (env vars still work)

**Effort Estimate:** 1-2 days
- YAML parsing: ~50 lines (use small library)
- Schema validation: ~100 lines
- Config merging logic: ~75 lines

---

## Conclusion: Feature Adoption Summary

### What to Adopt from srt
1. ✅ **Domain-based network filtering** — critical security improvement
2. ✅ **Violation logging** — essential for debugging & compliance
3. ✅ **Configuration validation** — prevents user mistakes
4. ⚠️ **Proxy architecture** — adopt the pattern, not all of srt's complexity

### What to Adopt from OpenShell
1. ✅ **Declarative YAML policies** — better UX than bash env vars
2. ⚠️ **Credential providers** — nice-to-have; lower priority than filtering
3. ❌ **L7 enforcement** — too granular for developer tool
4. ❌ **Hot-reload policies** — not applicable to ephemeral containers

### What NOT to Adopt
- Per-command sandboxing (different architecture)
- Full Kubernetes-based multi-tenant isolation (overkill for sandy)
- Interactive TUI (useful only for multi-sandbox ops centers)
- macOS native Seatbelt sandbox (Docker-based model is better)

### Recommended Timeline
- **Week 1-2:** Fix critical security issues (audit findings)
- **Week 3-4:** Implement domain-based filtering + violation logging
- **Week 5-6:** Add YAML policy files + validation
- **Week 7+:** Credential providers, advanced features

---

## Appendix: Quick Reference

### srt Key Insights
- **Proxy-based** network filtering: interception at HTTP/SOCKS5 layer
- **Violation store:** in-memory ring buffer of last N violations
- **Zod validation:** catches config mistakes early
- **Per-command** model: different from sandy's per-session

### OpenShell Key Insights
- **YAML policies:** declarative, self-documenting, version-controllable
- **Static vs. dynamic fields:** filesystem locked at creation, network hot-reloadable
- **Credential providers:** named bundles, environment variable injection
- **Kubernetes-based:** designed for production, not ideal for local development

### Sandy's Current Strengths
- Ephemeral per-project sandboxes (no persistent state leakage)
- Read-only filesystem protection (strong baseline)
- IPv4 network isolation (blocks RFC 1918 ranges)
- SSH agent and token forwarding options
- Multi-language toolchain support
- Three-phase Docker build (efficient rebuilds)

### Sandy's Current Gaps
- IPv6 network isolation (TODO)
- Domain-level filtering (TODO)
- Violation visibility (TODO)
- Credential exposure via env vars (TODO)
- SSH agent socket permissions (TODO)

---

**End of Analysis**
