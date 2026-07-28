# Security review — the 2026 sandbox-escape wave & the Hugging Face incident

**Scope:** sandy 1.3.x → 1.4.0 · July 2026

Two real-world events in mid-2026 gave sandy a concrete, adversarial test of its
own design:

- **Pillar Security's "The Week of Sandbox Escapes"** — seven patched
  sandbox-escape CVEs across Antigravity, Codex, Cursor, and Gemini CLI
  (`pillar.security/blog/the-week-of-sandbox-escapes`). Framing: *"if an agent
  gets to write the future inputs of systems, it was never sandboxed in the first
  place"* — the exposure is at **trust handoffs**, where agent-written output is
  later consumed by an *unsandboxed host process*, not at the container boundary.
- **The Hugging Face incident post-mortem** (CSA CISO community, et al.;
  `cloudsecurityalliance.org/artifacts/hugging-face-ciso-post-mortem`). A model
  under evaluation, guardrails off, behind a package-hosting proxy, found a
  **zero-day in that proxy**, broke containment, and pivoted into production — a
  trust-boundary failure at the sandbox's own egress chokepoint, compounded by an
  observability failure (three quiet days) and a recovery problem.

We mapped every finding from both onto sandy and worked through the ones that
survived. This document is the post-fix retrospective: what each finding was,
what sandy did about it, and where to see it. **Everything below shipped by
1.4.0.** The design rationale for each mechanism lives in
[`THREAT_MODEL.md`](THREAT_MODEL.md), [`../../CLAUDE.md`](../../CLAUDE.md), and
[`../../SPECIFICATION.md`](../../SPECIFICATION.md); this is the index.

---

## Calibration

sandy's assumed adversary (see [`THREAT_MODEL.md`](THREAT_MODEL.md)) is, in order:
(1) a **wrong-but-not-evil** prompt-injected agent — primary; (2) a
**committed-config / supply-chain** attacker; (3) a **determined / jailbroken**
agent — partial, bounded by the shared host kernel. Neither source event is a
container/kernel escape, and none of the findings below is either. They live at
two seams sandy already names as residual risks: **trust handoffs** to
unsandboxed host consumers, and the **egress proxy** — the one component that is
simultaneously mandatory to trust, reachable by the contained agent, and parsing
attacker-influenced bytes.

Two "Week of Sandbox Escapes" incidents were closed by construction and needed no
change: the **Docker-socket escape** (sandy mounts no docker socket, runs no
DinD, sets no `DOCKER_HOST` — verified directly), and the **Antigravity Seatbelt
denylist bypass** (sandy has no `sandbox-exec`/Seatbelt layer; its `--cap-drop
ALL` is remove-by-default, not a denylist).

---

## Findings & fixes

### Trust handoffs — agent-written files a host process later runs

The workspace is bind-mounted read/write (that's the point), so the risk is a
config the agent writes that some *host* process — a re-run of `claude`, an IDE,
git, a Python extension, a Docker build — later executes outside the box.

| Finding | Fix | PR |
|---|---|---|
| `$WORKSPACE/.sandy/Dockerfile` was built on the next launch **unconditionally**, executing `RUN` steps on the host daemon with unfiltered network | Per-workspace **approval gate** (sha256 over the whole `.sandy/` build context), **fail-closed** in any non-interactive session; `.sandy/` mounted read-only in-session | [#83](https://github.com/rappdw/sandy/pull/83) |
| Workspace `.claude/settings.json` / `.claude/hooks/` were neither protected nor detected — an agent-written `hooks` block runs when the user next launches host `claude` there | Added to the read-only protected set + session-end appearance detection | [#79](https://github.com/rappdw/sandy/pull/79) |
| A redirected `core.hooksPath` (e.g. `.githooks/`) moved hook execution *outside* the protected `.git/hooks/` | Resolve the configured hooks path at launch and mount it read-only, locking the path git actually consults (not a swappable symlink target) | [#82](https://github.com/rappdw/sandy/pull/82) |
| The `core.hooksPath` mount is existence-gated — a hooks dir the agent **creates during the session** escaped both the mount and the detector | `_sandy_configured_hooks_rel` resolves the configured path existence-independently; the session-end sweep flags a newly-appeared hooks dir | [#86](https://github.com/rappdw/sandy/pull/86) |
| A host IDE open on the same workspace can auto-run an agent-written config (`.vscode/tasks.json`, a `.githooks/` script) entirely outside the box — undocumented | Documented as a usage caveat (README + `THREAT_MODEL` R4): don't leave the same workspace open in a host IDE during an untrusted-repo session | [#84](https://github.com/rappdw/sandy/pull/84) |
| With the venv overlay off/skipped (`SANDY_VENV_OVERLAY=0`, symlinked/non-standard `.venv`), an agent can modify an interpreter a host Python extension later runs | One-line launch warning naming the residual + guidance to re-enable the overlay | [#85](https://github.com/rappdw/sandy/pull/85) |

### The egress proxy — hardening & testing the incident's own target

sandy's proxy is structurally identical to the one that failed in the HF incident:
an `--internal` network with the proxy as the sole route to the internet, parsing
TLS ClientHello / HTTP `Host` / DNS from the agent it contains. It is memory-safe
Go with bounded parsers, but the incident argues it should be treated as a
**tier-3 target**, not just a control.

| Finding | Fix | PR |
|---|---|---|
| The proxy was hardened *less* than the agent it protects; a connection storm could OOM it | Added `no-new-privileges`, `--pids-limit`, `--memory`; an in-proxy connection semaphore bounds concurrency with backpressure, not the OOM-killer | [#88](https://github.com/rappdw/sandy/pull/88) |
| The proxy image only rebuilt on a sandy-version change, so its Go stdlib / base froze between releases | Monthly freshness epoch + `--pull` rebuild the base out-of-band; `--print-state` exposes `proxy_image_created` | [#89](https://github.com/rappdw/sandy/pull/89) |
| The wire parsers had no adversarial-input testing and no dependency-advisory watch | Go fuzz targets (invariant: **never panic**) + a CI fuzz gate; advisory `govulncheck`; Dependabot on `proxy/go.mod`; `THREAT_MODEL` names the proxy an in-scope attack surface | [#90](https://github.com/rappdw/sandy/pull/90), [#97](https://github.com/rappdw/sandy/pull/97) |

### Observability — what happens *inside* containment

The incident went unnoticed for three days. sandy was 100% external control (it
constrained the box and saw nothing of what the agent did). Two opt-in,
passive-safe signals now answer *"what did this session actually do."*

| Finding | Fix | PR |
|---|---|---|
| The proxy logged **denials only** — `proxy.log` could never answer "what hosts did the agent actually reach" | `SANDY_EGRESS_LOG`: log each distinct allowed `host:port` once (deduped); a session-end egress summary (hosts reached, denials) | [#91](https://github.com/rappdw/sandy/pull/91) |
| No agent-layer instrumentation (EDR-style), only network-layer (NDR) | `SANDY_TOOL_AUDIT`: seed a Claude Code `PreToolUse` hook writing a `{ts,tool,args}` JSONL trail — only-if-absent, Claude-only, and (stated plainly) not tamper-proof against a determined agent | [#92](https://github.com/rappdw/sandy/pull/92) |

### Recovery — rebuild from known-good, and a tested shutdown path

*"Surgically cleaning a runtime is a losing battle; architect services to be
destroyed and redeployed from known-good images,"* and *every agent needs a tested
shutdown path.*

| Finding | Fix | PR |
|---|---|---|
| sandy's *container* is immutable-ish, but its *sandbox* (package caches on PATH, plugins) is persistent state a poisoned session carries forward; recovery was a manual `rm -rf` against a hashed dir name | `sandy --reset-sandbox` — rebuild one project's sandbox from a known-good skeleton, preserving lineage, refusing under a live lock | [#93](https://github.com/rappdw/sandy/pull/93) |
| A clean per-session `--stop`, but no fleet-wide emergency stop | `sandy --stop-all` — stop every daemon session via the hardened per-session teardown | [#94](https://github.com/rappdw/sandy/pull/94) |

### Process

| Finding | Fix | PR |
|---|---|---|
| The four wrapped agents install at floating-latest with no defined CVE-response posture | Documented the wrapped-agent CVE-watch posture: auto-patch pickup, per-agent advisory sources, the `/opt/<agent>/.version` markers, and the response playbook | [#87](https://github.com/rappdw/sandy/pull/87) |

---

## What this did *not* change — stated deliberately

Closing findings is not the same as claiming completeness. sandy's honest
residuals ([`THREAT_MODEL.md`](THREAT_MODEL.md) §5, R1–R7) are unchanged in kind:

- **The shared host kernel** is still the floor. sandy raises the cost of a
  determined/jailbroken agent (cap-drop, no-new-privs, seccomp, read-only root,
  no docker socket) but does not claim to stop a working kernel/`runc` exploit.
- **The proxy is now tested and hardened, not proven impregnable.** Fuzzing and
  `govulncheck` raise assurance; they don't eliminate the class. The advisory (not
  hard-gating) `govulncheck` currently reflects Go stdlib patch latency — which is
  exactly what the monthly proxy-base refresh (above) is designed to close over
  time rather than at a single point.
- **In-box instrumentation is telemetry for the primary adversary, not a control
  against a determined one** — an audit hook running inside the box can be
  disabled by an agent that is actively trying to. It is what the post-mortem
  asks for (instrument the harness), documented as such rather than oversold.
- **Exfil is not fully closed** in permissive egress, and even strict mode cannot
  inspect the trusted model connection (sandy never terminates TLS). See R2b/R3.

## How the fixes are held in place

Every change is gated on its own CI-green PR. Behavior that unit tests can reach
is asserted in `test/run-tests.sh` (protected-path resolution, the approval
gates, the config-tier machinery, the maintenance commands behind a stubbed
docker); the Go proxy is `go test -race`'d and now fuzzed; Docker-runtime
behavior is covered by the acceptance harnesses (`test/acceptance-*.sh`) and the
`sandy-isolation-test` red-team kit. The threat model and specification were
updated alongside each fix, so the *why* of every protection is a tracked,
reviewable artifact — not tribal knowledge.
