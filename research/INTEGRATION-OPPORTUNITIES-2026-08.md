# Sandy — Potential Integration Opportunities (August 2026)

Companion to `sandbox-landscape-synthesis-2026-08.md`. Where the synthesis asks *"who competes and what do we steal,"* this doc asks *"what could sandy plug into, ride on, or be plugged into"* — ranked by leverage, each with the concrete mechanism, effort, spike-gate, and recommendation. **Observation / inference / recommendation kept distinct; confidence H/M/L.**

The guiding rule from the corpus holds: **sandy integrates by reusing what it already has (a container it can swap the runtime under, a proxy it already owns, an introspection surface others can call) — not by adopting another project's control plane, backend abstraction, or agent loop.** Every "integration" that would import that complexity is rejected below, by name.

---

## 1. Coexist cleanly with Claude Code's native `/sandbox` — *near-term, cheap, timely* — **REC: DO**

- **Observation.** Claude Code now ships its own Bash-tool OS sandbox (`sandbox.*` in settings.json), including an HTTP/SOCKS egress proxy and a `enableWeakerNestedSandbox` mode explicitly for running *inside* Docker. Sandy already seeds `settings.json` every launch and points the agent's DNS at *its own* Go egress proxy.
- **Risk (inference).** Two uncoordinated proxies (sandy's DNS-redirect proxy vs CC's own HTTP/SOCKS proxy) can collide or double-prompt; CC's sandbox `/sandbox` prompts and `dangerouslyDisableSandbox` fallback can confuse sandy's own posture. CC docs also note `docker` commands fail inside its sandbox — irrelevant in-container but a symptom of the fragility.
- **Mechanism.** In the seeded settings.json, explicitly set CC's native sandbox to a known state — most likely **`sandbox.enabled: false` in-container**, since sandy's container *is* the isolation boundary and the inner sandbox is redundant/conflicting (this is precisely the scenario `enableWeakerNestedSandbox`'s own caveat describes: "only when the outer container already provides the boundary"). Add a `run-tests.sh` assertion pinning the coexistence choice.
- **Effort:** **S** (one settings.json key + one structural test). **Spike:** none. **Confidence:** H.

## 2. `SANDY_RUNTIME=runsc|kata` — the honest "stronger boundary" opt-in — *reinforces POST_1.0* — **REC: DO (spike first)**

- **Observation.** The realistic escalation past shared-kernel namespaces is an **OCI runtime swap**, not a microVM library: `--runtime=runsc` (gVisor userspace kernel) or `--runtime=kata-runtime` (real lightweight VMs) both preserve sandy's entire model — same images, same `docker run` flags, same mounts, same proxy topology — and only need a `docker info` runtime-presence probe + a documented env knob.
- **Explicitly not hyperlight.** Hyperlight isolates *typed function calls* in a kernel-less VM for FaaS; it has no OCI image, no process model, no filesystem/network stack, and guests must be purpose-compiled. `SANDY_RUNTIME=hyperlight` is not buildable. (Confidence: H — from hyperlight's own README disclaimer.)
- **Mechanism (already sketched in `POST_1.0_IDEAS.md`).** After config load, if `SANDY_RUNTIME` set and present in `docker info --format '{{.Runtimes}}'`, append `--runtime`; warn-and-continue if absent. Privileged-tier.
- **Effort:** **M.** **Spike (the real gate, already flagged):** does gVisor's netstack break the proxy's DNS/SNI/CONNECT path? Unverified — must soak-test before shipping. **Confidence:** H on the mechanism, M on gVisor compatibility.

## 3. `srt` nested as in-container defense-in-depth — *new, spike-gated* — **REC: SPIKE, then decide**

- **Observation.** Anthropic's `srt` ships `enableWeakerNestedSandbox`, documented and end-to-end tested for unprivileged containers, giving per-syscall filesystem + network policy *inside* an existing container — a second, syscall-granular layer under sandy's own container boundary, covering non-Bash paths CC's own sandbox doesn't.
- **The open technical risk (inference).** srt's nested mode was tested under `seccomp=unconfined`; whether unprivileged user-namespace creation works under sandy's **`--cap-drop ALL` + default Docker seccomp** posture is **unverified**. That is the gate, not a blocker in principle.
- **Mechanism (if the spike passes).** Bake `bubblewrap`+`socat`+`@anthropic-ai/sandbox-runtime` into `sandy-base`; wrap the agent (or its Bash subprocesses) under an `srt` policy mapping sandy's existing protected-path list. Belt-and-suspenders inside sandy's boundary.
- **Effort:** **M** (plus the spike). **Recommendation:** run the spike; if unprivileged-userns fails under sandy's stock posture, drop it (don't relax the container's seccomp/caps to make it work — that trades away more than it buys). **Confidence:** M.

## 4. Sandy as the hardening layer *others call* — *reinforces the transparent-launch primitive* — **REC: HIGH-LEVERAGE, DO**

- **Observation.** Two concrete callers emerged this round. (a) **alice**'s `alice_forge.dispatcher` spawns a raw `claude` to write diffs for selected issues overnight — the single riskiest, least-isolated step in an otherwise home-trusted agent; swapping that spawn to `sandy -p "<task>"` isolates exactly that step. (b) The broader **worktree-manager ecosystem** (cmux, vibe-kanban, Superset, …) already interoperates with sandy at the terminal level and would call a transparent launch.
- **Mechanism (already in the July doc).** A **transparent-launch primitive** — `SANDY_LAUNCH=raw` / `sandy --exec` (no inner tmux, headless-clean stdio) — is the seam that turns orchestrators from bystanders into "point-and-harden front-ends." alice's catch: its dispatcher runs *inside* alice's own container today, so wiring it to sandy needs either a docker-socket mount into that container (an ironic trust expansion) or relocating the spawn to the host — a decision for alice, not sandy.
- **Effort:** **M** for the primitive (sandy side). **Confidence:** H that the primitive unlocks the pattern; M on any single caller adopting it.

## 5. Embed nono (`SANDY_NONO=1`) — *possible but low-priority* — **REC: SKIP for now, steal the patterns instead**

- **Observation.** nono's own docs endorse "container + nono inside," and it ships a Docker example. Sandy *could* run the agent as `nono run --profile claude -- claude` for Landlock-on-top-of-Docker defense-in-depth.
- **Why low-priority (inference).** It duplicates srt's role (§3) with a second toolchain and a second egress proxy that would fight sandy's own. The *value* in nono is its **patterns** (phantom-token credentials → #121; hash-chain audit → new issue), which sandy can adopt into its own proxy/audit hook without embedding nono. **REC:** steal the patterns; revisit embedding only if the srt spike (§3) fails and a Landlock layer is still wanted. **Confidence:** M.

## 6. Explicitly rejected integrations (do not revisit without new signal)

- **agentbox** — no clean library/interop boundary; its box *is* a live git-worktree bind-mounted against host `.git/` with a host relay. Bolting sandy's proxy onto it would be a reimplementation, not reuse. (Its **UX** — pause/checkpoint/IDE-attach — is worth *stealing* as features, per the synthesis; the *project* is not an integration.)
- **OpenShell** — adopting any of its machinery (gRPC gateway, OPA policy, Z3 prover, compute-driver abstraction) is the exact "platform" complexity sandy's anti-roadmap rejects. Watch-item only.
- **openworker** — has *less* isolation than sandy (zero container/VM); nothing to consume. Its agent loop + connectors are coupled to its own `aisuite` engine; sandy wraps *other* agents' CLIs and doesn't own the loop.
- **hyperlight** — different problem category (see §2); not an option.
- **Docker Sandboxes (`sbx`) as a backend** — carried-forward open question (compete/compose/coexist), unresolved; not actioned here.

---

## 7. Recommended sequencing

1. **Now / cheap:** §1 CC-sandbox coexistence guard (S) + the tamper-evident audit log and `--doctor` from the synthesis (S–M) — all additive, no spike.
2. **Next / spike-gated:** §2 `SANDY_RUNTIME` (gVisor-netstack spike) and §3 `srt` nested (unprivileged-userns spike) — run both spikes before committing.
3. **Strategic / larger:** §4 transparent-launch primitive (unlocks the orchestrator-calls-sandy pattern, incl. alice) and the phantom-token/Family-2 broker (#121) — the two moves that most extend sandy's reach and close its credential-visibility gap.
