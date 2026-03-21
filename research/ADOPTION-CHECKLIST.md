# Feature Adoption Checklist

**Last Updated:** 2026-03-20
**For:** Sandy maintainer
**Quick Reference:** Which features from srt/OpenShell to adopt, effort/value matrix

---

## Executive Priority Matrix

```
┌─────────────────────────────────────────────────────────────────┐
│                    EFFORT vs. VALUE MATRIX                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  HIGH VALUE,          Domain Filtering (P0)                      │
│  HIGH EFFORT          Effort: 2-3d  Value: Critical              │
│                       Status: TODO (in existing TODO.md)         │
│                                                                   │
│  HIGH VALUE,          Violation Logging (P0)                     │
│  MED EFFORT           Effort: 1-2d  Value: High (debugging)      │
│                       Status: TODO (new proposal)                │
│                                                                   │
│  MED VALUE,           YAML Policies (P1)                         │
│  MED EFFORT           Effort: 1-2d  Value: UX improvement        │
│                       Status: TODO (new proposal)                │
│                                                                   │
│  MED VALUE,           Config Validation (P2)                     │
│  LOW EFFORT           Effort: <1d  Value: Prevents mistakes      │
│                       Status: TODO (trivial)                     │
│                                                                   │
│  LOW VALUE,           L7 Enforcement, Per-Command Sandboxing     │
│  HIGH EFFORT          Status: SKIP (not applicable to sandy)     │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## By Source

### From srt (Anthropic Sandbox Runtime)

| Feature | Effort | Value | Decision | Notes |
|---------|--------|-------|----------|-------|
| **Domain-based network filtering** | 2-3d | Critical | ✅ ADOPT (P0) | Proxy-based HTTP/SOCKS5 filtering; prevents data exfiltration |
| **Violation logging** | 1-2d | High | ✅ ADOPT (P0) | Log blocked connections, failed writes; essential for debugging |
| **Configuration validation (Zod)** | <1d | Medium | ✅ ADOPT (P2) | Prevent typos in domain allowlists; early error detection |
| **Dynamic config updates** | 1-2d | Low | ⚠️ DEFER | Only useful for long-running daemons; sandy sessions are ephemeral |
| **MITM proxy support** | 2-3d | Low | ❌ SKIP | Enterprise feature; not in scope for developer tool |
| **Per-command sandboxing** | Major | Low | ❌ SKIP | Fundamental architecture difference; srt is per-command, sandy is per-session |

### From OpenShell (NVIDIA)

| Feature | Effort | Value | Decision | Notes |
|---------|--------|-------|----------|-------|
| **Declarative YAML policies** | 1-2d | Medium | ✅ ADOPT (P1) | Better UX than bash env vars; self-documenting; future-proof |
| **Credential providers** | 2-3d | Medium | ⚠️ DEFER (P2) | Nice-to-have; lower priority than filtering & logging |
| **L7 (method + path) enforcement** | High | Low | ❌ SKIP | Too granular for developer tool; domain filtering is 80% of value |
| **Hot-reloadable policies** | Moderate | Low | ❌ SKIP | Not applicable; sandy containers are ephemeral (no long sessions) |
| **Terminal UI / Real-time dashboard** | High | Low | ❌ SKIP | Useful only for multi-sandbox operations; overkill for local dev |
| **Kubernetes-based deployment** | Major | N/A | ❌ SKIP | Fundamentally different target (production multi-tenant vs. local dev) |

---

## Implementation Roadmap

### Prerequisites: Fix Security Issues First

Before adding new features, resolve 5 critical findings from security audit:

```
[ ] IPv6 network isolation bypass (add ip6tables rules)
[ ] SSH agent socket permissions (chmod 600 instead of 777)
[ ] Credential exposure via env vars (mount files with restricted perms)
[ ] Concurrent instance race (use per-instance Docker networks)
[ ] iptables failure should be fail-closed (not fail-open)
```

**Timeline:** 1-2 days
**Priority:** Critical (blocks v1.0 release)

---

### Phase 1: Domain-Based Network Filtering (P0)

**Goals:**
- Add HTTP/SOCKS5 proxy inside container
- Implement domain allowlist/denylist
- Configuration via `.sandy/network.conf` JSON or env var
- Default allowlist: github.com, npmjs.org, pypi.org, api.anthropic.com, etc.

**Deliverables:**
- [ ] HTTP proxy (~150 lines)
- [ ] SOCKS5 proxy (~100 lines)
- [ ] Config parser (~50 lines)
- [ ] Container integration (~100 lines)
- [ ] Tests (~100 lines)
- [ ] README documentation

**Effort:** 2-3 days
**Impact:** Blocks data exfiltration to arbitrary domains
**Dependencies:** Config system (see Phase 3)

**Success Criteria:**
- `sandy -p "curl https://attacker.com"` → blocked
- `sandy -p "curl https://github.com"` → allowed (in default list)
- `.sandy/network.conf` with custom domains works
- Proxy errors logged with reason

---

### Phase 2: Violation Logging & Monitoring (P0)

**Goals:**
- Log all blocked network connections
- Log write attempts to protected files
- Store in `~/.sandy/sandboxes/<project>/violations.log`
- Provide `sandy logs <project> --tail` command

**Deliverables:**
- [ ] Proxy violation logging (~50 lines)
- [ ] Filesystem violation hooks (~50 lines)
- [ ] Log file management (ring buffer)
- [ ] CLI command for viewing logs
- [ ] Tests

**Effort:** 1-2 days
**Impact:** Visibility into what was blocked; critical for debugging
**Dependencies:** Domain filtering (Phase 1)

**Success Criteria:**
- Blocked DNS/TCP shows in violation log
- `sandy logs myproject` shows recent violations
- Log format is both human and machine-readable

---

### Phase 3: Declarative YAML Policy Files (P1)

**Goals:**
- Introduce `.sandy/policy.yaml` as config format
- Keep env vars as fallback (backward compatible)
- Merge YAML + env vars (env vars override)

**Example `.sandy/policy.yaml`:**
```yaml
version: 1
network:
  allowedDomains:
    - github.com
    - "*.github.com"
    - api.github.com
    - npmjs.org
    - api.anthropic.com
  deniedDomains: []
  logLevel: info
ssh:
  mode: token  # or "agent"
  agentSocketPath: /tmp/ssh-agent.sock
workspace:
  readOnly: false
```

**Deliverables:**
- [ ] YAML parser (~50 lines, use existing lib)
- [ ] Config merging logic (~75 lines)
- [ ] Example `.sandy/policy.yaml`
- [ ] Tests

**Effort:** 1-2 days
**Impact:** Better UX; self-documenting config
**Dependencies:** Config validation (see below)

---

### Phase 4: Configuration Validation (P2)

**Goals:**
- Add schema validation for all config files
- Catch typos and invalid values early
- Clear error messages

**Example Validation:**
```
✗ Error: /workspace/.sandy/policy.yaml
  network.allowedDomains: must be array of strings
  ssh.mode: must be "token" or "agent", got "ssh_key"
```

**Deliverables:**
- [ ] Schema definition (~100 lines)
- [ ] Validator (~100 lines)
- [ ] Error message formatter
- [ ] Tests

**Effort:** <1 day
**Impact:** Prevents silent configuration failures
**Dependencies:** YAML parser (Phase 3)

---

### Phase 5+: Advanced Features (Defer)

| Feature | Effort | Priority | When |
|---------|--------|----------|------|
| Credential providers (OpenShell-style) | 2-3d | P2 | Q4 |
| Dynamic config reload | 1-2d | P3 | Q4 |
| L7 enforcement | High | P4 | Future |
| Per-command sandboxing | Major | P4 | Future |

---

## Decision Guide: Apply to Your PR/Issue

### Should this feature be adopted?

1. **Is it already in TODO.md?**
   - YES → Follow existing priority
   - NO → Use matrix below

2. **Does it block or improve security?**
   - Critical gap → P0 (domain filtering, logging)
   - Nice-to-have → P1-P2

3. **Does it improve UX without adding complexity?**
   - YES → P1-P2 (YAML policies)
   - NO or complex → Defer

4. **Is it fundamental to sandy's architecture?**
   - NO (e.g., per-command) → SKIP
   - YES → ADOPT if high-value

---

## Test Plan for Each Feature

### Domain Filtering (Phase 1)
```bash
# Allowed domain
sandy -p "curl -s https://api.github.com/zen" # Should succeed

# Blocked domain (not in allowlist)
sandy -p "curl -s https://attacker.com" # Should fail with "blocked by allowlist"

# Custom config
echo '{"allowedDomains":["example.com"]}' > .sandy/network.conf
sandy -p "curl https://example.com" # Should succeed
sandy -p "curl https://github.com" # Should fail (not in custom list)
```

### Violation Logging (Phase 2)
```bash
sandy -p "curl https://attacker.com"
sandy logs myproject
# Output: [BLOCKED] network: attacker.com:443 not in allowlist
```

### YAML Policies (Phase 3)
```bash
cat > .sandy/policy.yaml <<'EOF'
version: 1
network:
  allowedDomains:
    - github.com
    - npmjs.org
EOF

sandy # Should load policy.yaml automatically
```

---

## Known Limitations (By Design)

### What Sandy Does NOT Do (and Why)

| Gap | Reason | Workaround |
|-----|--------|-----------|
| L7 (HTTP method) filtering | Requires HTTPS MITM; risky and complex | Domain filtering + API design discipline |
| Per-command sandboxing | Different architecture (session vs. command) | Use srt for individual commands |
| Hot-reload without restart | Ephemeral containers (no state to preserve) | Restart session to apply new policy |
| Multi-user/multi-tenant | Single-user developer tool | Use OpenShell for enterprise deployments |
| Fully air-gapped (no network) | Defeats Claude Code's purpose | Use `SANDY_ALLOWED_DOMAINS=[]` to disable network |

---

## FAQ

**Q: Why not adopt OpenShell's full architecture?**
A: OpenShell is built for production multi-tenant deployments (Kubernetes, gRPC control plane). Sandy is a single-user developer tool. Docker provides better isolation for sandy's use case.

**Q: Why not implement L7 filtering?**
A: Would require decoding HTTPS (MITM), which is:
- Complex to implement correctly
- Adds security risk (custom MITM proxy)
- Maintenance burden (API rules change frequently)
Domain filtering + API design discipline is 80% of the value.

**Q: Can users disable network filtering?**
A: Yes, set `SANDY_ALLOWED_DOMAINS=[]` or omit network config.

**Q: Is violation logging real-time?**
A: Can be made real-time via `sandy logs --tail`, but bulk detection is poll-based for performance.

**Q: Why not use srt instead of extending sandy?**
A: srt is per-command; sandy is per-session. Different use cases.
Users who want per-command sandboxing should use srt.

---

## Summary

| Phase | Feature | Timeline | Value | Status |
|-------|---------|----------|-------|--------|
| 0 (Urgent) | Fix critical security issues | 1-2d | Blocking | TBD (not in this analysis) |
| 1 | Domain filtering + logging | 3-4d | Critical ✅ | ADOPT |
| 2 | YAML policies + validation | 2-3d | High ✅ | ADOPT |
| 3+ | Credential providers, L7, etc. | Future | Medium ⚠️ | DEFER |

**Immediate Action:** Start with Phase 0 security fixes, then Phase 1 (filtering + logging).

---

**Document:** `/sessions/laughing-clever-cannon/mnt/sandy/research/ADOPTION-CHECKLIST.md`
**For:** sandy maintainer + contributors
**Companion:** `FEATURE-ADOPTION-ANALYSIS.md` (detailed analysis)
