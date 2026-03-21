# Executive Summary: sandy Pre-Release Analysis

**Date:** 2026-02-16
**Verdict:** GO WITH CAVEATS

---

## Release Readiness

Sandy is a well-engineered tool with solid architecture, good defensive programming, and a thoughtful design. However, it is marketed as a **security isolation tool**, and the security audit identified gaps that undermine its core promise. We recommend releasing with targeted fixes and clearly documented limitations.

**Recommendation:** Fix the highest-impact security issues (estimated 1-2 days), document known limitations, and release as a **beta/preview** rather than a production-ready security tool.

---

## Critical Findings Requiring Fix Before Release

These issues directly contradict sandy's security guarantees and should be addressed before any public release:

### 1. IPv6 Network Isolation Bypass (CRITICAL — Security)
All iptables rules are IPv4 only. On IPv6-enabled networks, containers can reach LAN hosts over IPv6, completely bypassing the "NO LAN access" guarantee.
**Fix:** Add `ip6tables` rules mirroring the IPv4 rules, or disable IPv6 on the Docker network (`--ipv6=false` at network creation, plus `sysctl net.ipv6.conf.all.disable_ipv6=1` in the container).

### 2. SSH Agent Socket Permissions 0777 (CRITICAL — Security)
When `SANDY_SSH=agent` is used, the SSH agent socket is created with world-readable/writable permissions. Any process in the container can use the host's SSH keys.
**Fix:** Change `chmod 777` to `chmod 600` with `chown claude:claude` on the socket.

### 3. Concurrent iptables Race Condition (CRITICAL — Architecture)
Multiple sandy instances share a single bridge and iptables rule set. Instance B's startup cleanup deletes Instance A's rules, leaving A's container unprotected. Instance A's exit cleanup then deletes B's rules.
**Fix:** Use per-instance Docker networks (`sandy_net_$$`) so each instance manages its own isolation independently, or use `--opt com.docker.network.bridge.enable_icc=false` on a shared network.

### 4. iptables Failure Should Be Fail-Closed (HIGH — Security)
If iptables rules can't be applied (no sudo, no DOCKER-USER chain), sandy warns but launches anyway with full LAN access. A security tool should refuse to run without its security controls.
**Fix:** On Linux, exit with error if iptables rules cannot be applied. Make the current warn-and-continue behavior opt-in via `SANDY_ALLOW_NO_ISOLATION=1`.

### 5. `--dangerously-skip-permissions` Is Hardcoded (HIGH — Security)
Claude Code's permission system is unconditionally bypassed. Users cannot opt into permission prompts. This removes a safety layer within the sandbox — Claude can `rm -rf /workspace` or `git push --force` without confirmation.
**Fix:** Make this configurable via `SANDY_SKIP_PERMISSIONS=true` (default) so users can set it to `false`. Document the trade-off clearly.

---

## Recommended Improvements for Post-Release

### Security Hardening (Priority Order)
| # | Issue | Severity | Effort |
|---|-------|----------|--------|
| 1 | Pass credentials via mounted files instead of env vars (visible in `docker inspect`, `/proc`) | HIGH | 2h |
| 2 | Add `--cap-drop ALL` and add back only needed capabilities | MEDIUM | 1h |
| 3 | Document macOS LAN isolation limitations (relies on Docker Desktop VM, unverified) | HIGH | 30m |
| 4 | Secure macOS SSH agent TCP relay (no auth, any local process can connect) | HIGH | 4h |
| 5 | Use `git credential helper` instead of embedding token in git config | HIGH | 2h |
| 6 | Add `--pids-limit` to prevent fork bombs | LOW | 5m |
| 7 | Resolve workspace path with `pwd -P` to prevent symlink-based mount escapes | MEDIUM | 15m |
| 8 | Add DNS rate limiting to mitigate DNS exfiltration | MEDIUM | 1h |
| 9 | Add installer checksum verification | HIGH | 2h |

### Operational Improvements
| # | Issue | Severity | Effort |
|---|-------|----------|--------|
| 1 | Add `--version` flag | MEDIUM | 5m |
| 2 | Add explicit Docker daemon check (not just binary) | MEDIUM | 10m |
| 3 | Document minimum Bash version (4.0+) and add runtime check | MEDIUM | 15m |
| 4 | Document `SANDY_SSH` env var in README | MEDIUM | 10m |
| 5 | Add uninstall instructions to README | LOW | 10m |
| 6 | Add `SANDY_DEBUG=1` verbose mode (`set -x`) | LOW | 5m |
| 7 | Validate macOS SSH relay actually started (check port file) | HIGH | 15m |
| 8 | Add `trap cleanup EXIT INT TERM HUP` for broader signal coverage | HIGH | 5m |
| 9 | Add sandbox management (`--list`, `--clean`, `--reset`) | LOW | 2h |

---

## Summary Risk Assessment

| Category | Rating | Notes |
|----------|--------|-------|
| **Architecture** | GOOD | Clean lifecycle, hash-based caching, ephemeral credentials, good separation of concerns |
| **Network Isolation (Linux)** | MODERATE | IPv4 rules solid but IPv6 unblocked; concurrent instance race; fail-open on error |
| **Network Isolation (macOS)** | WEAK | No enforcement — relies entirely on undocumented Docker Desktop VM behavior |
| **Credential Security** | MODERATE | Ephemeral loading is well-designed; env var exposure and git config embedding are risks |
| **Container Hardening** | GOOD | Read-only rootfs, no-new-privileges, resource limits; could add cap-drop and seccomp |
| **Installer Security** | MODERATE | Standard curl-pipe pattern; no integrity verification |
| **Error Handling** | GOOD | `set -euo pipefail`, defensive cleanup, graceful degradation |
| **Cross-Platform** | MODERATE | Linux well-supported; macOS has isolation gaps; WSL2 untested |
| **Code Quality** | EXCELLENT | Consistent quoting, clear naming, good comments, readable structure |
| **Documentation** | GOOD | Accurate but missing some env vars, requirements, and security caveats |

### What Sandy Protects Against (Today)
- Filesystem access outside the working directory (strong)
- Accidental modification of host system (strong)
- Resource exhaustion of host (moderate)
- Direct TCP/UDP connections to LAN IPv4 addresses on Linux (strong)

### What Sandy Does NOT Protect Against (Gaps)
- IPv6 LAN access (no rules)
- macOS LAN access (no enforcement)
- DNS-based data exfiltration
- Credential theft via `/proc` or `docker inspect`
- SSH key misuse when `SANDY_SSH=agent` is enabled
- Destructive operations within the workspace (skip-permissions hardcoded)
- Concurrent instance interference (shared iptables rules)

---

## Verdict: GO WITH CAVEATS

Sandy is a well-built tool that delivers real value. The architecture is sound, the code quality is high, and the user experience is polished. However, as a security tool, it must meet its own security promises.

**Ship if:**
1. The 5 critical/high fixes above are applied (~1 day of work)
2. The release is labeled **beta** or **preview**
3. A "Security Model" section is added to README documenting what is and isn't protected
4. macOS limitations are clearly disclosed

**The tool has good bones.** The issues identified are fixable without architectural changes, and the team has clearly thought carefully about isolation. With the targeted fixes above, sandy would be a credible security sandbox for general use.

---

## Report Index

| Report | Author | File |
|--------|--------|------|
| Architecture Review | Codebase Architect | [`01-architecture-review.md`](./01-architecture-review.md) |
| Security Audit | Security Analyst | [`02-security-audit.md`](./02-security-audit.md) |
| QA & Release Readiness | QA Reviewer | [`03-qa-release-review.md`](./03-qa-release-review.md) |
