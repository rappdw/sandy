# Sandy — Landscape Synthesis (August 2026)

## 0. Header / method note

- **Subject:** `sandy` @ ~`1.5.1-dev`, origin/main `459dade`, analysis date **2026-08-05**.
- **Scope:** delta pass triggered by two newly-added `research/` submodules (**nono**, **openworker**) plus a bump of every existing pin (claude-code v2.1.168, agentbox v0.15.0, alice, bulkhead v0.1.3, sandbox-runtime v0.0.54, hyperlight v0.15.x, OpenShell v0.0.57, nono v0.71.0). Builds on `POSITIONING-DEEP-DIVE-2026-07.md` (the prior authoritative synthesis) — this is the August delta, not a from-scratch survey.
- **Method:** one subagent per project/cluster (nono, openworker, agentbox, alice, bulkhead, sandbox-runtime+CC-native-sandbox, hyperlight+OpenShell) reading actual source, each answering the same three lenses (competitor / integration / ideas-to-steal), plus one agent digesting the prior corpus so findings are tagged **new** vs **reinforces-known**. Synthesis by the orchestrator (Opus).
- **Confidence** H/M/L on non-trivial claims. **Observation / inference / recommendation** kept distinct.
- **Anti-roadmap honored:** no re-proposal of the settled rejections (L7/TLS-MITM, deny-first default, YAML policy files, gRPC control-plane, persistent-service mode, driver/backend abstraction, Windows). Where a new idea grazes one (credential *masking* needs TLS termination), the tension is flagged, not hand-waved.

---

## 1. Executive summary

**The ground moved in one material way since July: the wrapped agent grew its own sandbox.** Claude Code now ships a first-party OS sandbox (`/sandbox`, `sandbox.*` in settings.json) built on the **exact same `srt` primitives** (bubblewrap/Seatbelt + seccomp) that Anthropic also publishes standalone. This **narrows sandy's oldest pitch** — "Claude Code has no isolation, you need a wrapper" — but only partially. CC's sandbox is **Bash-tool-only, single-agent, escape-hatchable** (`dangerouslyDisableSandbox` lets the model retry unsandboxed unless a *managed* admin config forbids it), and covers **none** of sandy's multi-agent, host-config-protection, per-project credential-sandbox, or daemon story. Sandy's positioning shifts from *"the only isolation"* to *"an **unconditional, whole-process, multi-agent, host-managed** boundary around agents that increasingly have their own partial, single-tool sandboxes."* That's a legitimate but **narrower** moat than three months ago, and it will keep narrowing if Anthropic extends OS enforcement past Bash — **the #1 trajectory item to watch.** (Confidence: H on scope, from the live CC docs.)

**The competitive relief valve:** of every *"competitor"* examined this round, **bulkhead, agentbox, and openworker all have zero outbound egress isolation** — none. Sandy's egress proxy + host-config protection remain the widest, most-defensible axis in the field; no local-launcher peer matches it.

**Most reinforced own-finding (unchanged from July):** `.env`/`.env.*`/`.env.local` secret-file protection is still missing (only `.envrc` is protected). Nothing this round changes that verdict; it remains the cheapest high-value gap.

**Genuinely-new adopt candidates this round (detail §4):** tamper-evident hash-chained audit log (nono); `sandy --doctor` (bulkhead); daemon `docker pause`/`unpause` (agentbox); clone-mode git isolation as *prevention* vs sandy's *detection-only* sweep (bulkhead); a settings.json coexistence guard for CC's native sandbox (srt/CC).

---

## 2. Competitor map (August delta)

| Project | Category | Verdict (one line) | Conf |
|---|---|---|---|
| **Claude Code `/sandbox`** (+ `srt`) | Vendor-native, **strategic** | Narrows the single-agent pitch; Bash-only, single-agent, escape-hatchable — can't touch multi-agent / host-config / daemon / cred-sandbox. **The trajectory to watch.** | H |
| **bulkhead** `pmembrey` | **Direct competitor — weaker** | Nearest framing-match (Rust, devcontainer, "fallible agent" threat model), but **no egress isolation** (own README) and protects almost no host config in default mode. Sandy is materially ahead. | H |
| **agentbox** `madarco` | Partial competitor | Great velocity UX (5 backends incl. Firecracker clouds, `pause`/checkpoint, VNC/IDE attach) but **no outbound egress control** and runs `SYS_ADMIN`/`seccomp:unconfined` for DinD. | H |
| **nono** `nolabs-ai` (NEW) | Partial competitor, different mechanism | OS-capability sandbox (Landlock/Seatbelt, no container), Sigstore team. Same "fallible agent" goal; its **credential-injection + tamper-evident audit are more rigorous than sandy's** — steal those. | H |
| **OpenShell** `NVIDIA` | Anti-sandy — **watch-item, growing** | ~8k★ (+600 since July), NVIDIA/GTC, same agent roster, but a gRPC/mTLS/K8s/OPA/Z3 control plane — the architecture sandy explicitly rejects. Not sandy's user; well-funded for the enterprise segment. | H |
| **openworker** `andrewyng` (NEW) | **Not a competitor** | Desktop "AI coworker" app, own agent engine, 25+ SaaS connectors — and **zero OS/container isolation** (its own code marks `ContainerExecutor` as unbuilt). Makes sandy look stronger by comparison. | H |
| **alice** `jcronq` | **Not a competitor — a consumer** | Persistent home-server personal agent (memory, Signal, self-merging PR pipeline). Its overnight "spawn a worker to write code" step is a candidate *caller* of sandy, not a rival. | H |
| **hyperlight** `hyperlight-dev` | **Not a viable backend** | Kernel-less microVM for *typed function calls* (FaaS), not general Linux userspace — cannot run an agent toolchain. The real "stronger boundary" path is gVisor/Kata (OCI runtime swap), not this. | H |

**Two corrections to the prior corpus's from-afar reads, now that the code was inspected:**
- **nono** was previously logged only by star-count as "ships L7 egress + credential broker — closest analog to sandy+broker+L7." Code inspection refines this: nono's isolation is **OS-capability (Landlock), not a container**, and its own docs recommend layering *inside* a container for real isolation — so it is a **partial competitor whose patterns to steal are credential-injection and audit-integrity**, not a "sandy+L7" substitute.
- **OpenShell**'s "vm-runtime" is genuinely just **one of four (Docker/Podman/K8s/VM) compute drivers, and the least mature** (libkrun, "experimental," CPU/mem limits unwired). The real isolation work happens *inside* the sandbox (Landlock/seccomp/OPA), not at the VM boundary — reinforcing "watch what it is (NVIDIA weight), ignore what it builds (control plane)."

---

## 3. Where sandy stands (positioning delta)

- **Still unique:** the *combination* — per-project credential-isolated whole-session sandbox wrapping **any** of 5 agents (or several side-by-side) in one hardened container with one uniform egress proxy + an unusually thorough untrusted-workspace posture. No project in this set matches the combination; most match zero of the egress + host-config axes.
- **Newly contested (narrowed, not lost):** "the isolation Claude Code lacks" — CC now has a partial one. Reframe the pitch to the *unconditional/whole-process/multi-agent/host-managed* framing above.
- **Honestly behind (say so):** kernel-grade boundary (shared-kernel container vs microVMs) — concede, and note the real opt-in path is `SANDY_RUNTIME=runsc|kata` (§ integration doc), **not** hyperlight; `.env` protection (must-fix); credential *visibility* in-container (a forwarded token is fully readable — the phantom-token/broker work addresses this).
- **Anti-roadmap reaffirmed** by this round: every "platform" peer (OpenShell) traded away the hardened-container edge for a control plane; every velocity-first peer (agentbox) traded away egress isolation. Sandy's single-file minimalism + egress-first posture remains the differentiator.

---

## 4. Ideas — prioritized (new vs reinforces-known)

**Top tier (new security wins, on-brand):**
1. **Tamper-evident audit log** — *new (nono)*. Extend `SANDY_TOOL_AUDIT`'s JSONL with a rolling hash-chain head + session-end Merkle root so the log is *provably un-edited*. Turns "what did this session do" into "prove it wasn't edited after." Effort **S–M**. → **new issue.**
2. **Phantom-token / credential masking** — *reinforces #121 + POST_1.0 broker*. nono **and** srt independently converged: agent never sees the real secret; injected only at the upstream hop. **Caveat:** LLM-API-key masking needs TLS termination (violates the never-terminate-TLS invariant) — but the **git/gh/SSH version is exactly the already-planned Family-2 Unix-socket broker**, so this is strong convergence evidence to prioritize the broker and to *scope out* the API-key case. → **enhance #121.**
3. **Clone-mode git isolation** — *reinforces-known, sharpened (bulkhead)*. `git clone --no-local --no-hardlinks` into a scratch dir so `.git/hooks`/workflows are never mounted: **prevention** vs sandy's current **detection-only** exit sweep (whose threat window sandy's own docs admit). Effort **M**. → **new issue.**

**Second tier (ops/ergonomics gaps competitors exposed):**
4. **`sandy --doctor [--fix]`** — *new (bulkhead)*. Standalone preflight diagnostics (docker reachable, buildx health, image staleness), callable independent of a launch. Effort **S**. → **new issue.**
5. **Daemon `docker pause`/`unpause`** — *new (agentbox)*. Pause on detach / unpause on `--attach` to cut idle CPU/RAM across a daemon fleet. Effort **S**. → **new issue.**
6. **Coexist with CC's native `/sandbox`** — *new (srt/CC)*. Seed settings.json so sandy's DNS-redirect proxy and CC's own HTTP/SOCKS proxy don't collide or double-prompt (likely `sandbox.enabled:false` in-container, since sandy *is* the boundary). Guard with a `run-tests.sh` assertion. Effort **S**, strategically timely. → **new issue.**
7. **`SANDY_RUNTIME=runsc|kata`** — *reinforces POST_1.0*. The honest microVM answer is an **OCI runtime swap**, not hyperlight. Effort **M** + the known gVisor-netstack-vs-proxy spike. → **new issue (from POST_1.0).**
8. **Unix-socket-creation seccomp block** — *new (srt)*. A compromised agent can open local Unix sockets the egress topology never sees; add a seccomp profile to the agent container. Effort **M**.

**Third tier (candidate follow-ups, not filed yet):** session rollback/undo (`SANDY_ROLLBACK`, nono); `sandy --code` VS Code / Dev-Containers attach (agentbox); pinned-agent-version knob (bulkhead — demand evidence for a POST_1.0 idea); denial→propose-`SANDY_ALLOW_HOSTS` `/allow-host` skill (OpenShell UX, no OPA); Signal channel (alice); `event-log` query CLI over the audit trail (alice); per-target "standing rule" approvals + persona manifests (openworker); `docker commit` checkpoint/warm-restart (agentbox — bigger design lift given `--read-only` root); devcontainer.json-compatible emission mode (bulkhead — reduced-fidelity companion, **L**).

**Unchanged top own-finding:** `.env`/secret-file protection (still the cheapest high-value gap; no project this round changes the verdict).

---

## 5. Open questions (carried forward, maintainer-only)

Unchanged from the July doc §8 and still live: growth ambition (solo vs scale); 2.0 appetite (batch broker + stronger-boundary runtime, or keep 1.x additive); alice-collaboration intent (now with a concrete "alice-calls-sandy" mechanism); willingness to ship a 2nd host-side helper (for the broker); Docker-Sandboxes stance (compete / compose / coexist); `.env` protect-by-default vs opt-in. **New for August:** how aggressively to reframe positioning now that Claude Code sandboxes itself — proactively ("layered defense around a self-sandboxing agent") or wait until CC's sandbox scope expands past Bash.
