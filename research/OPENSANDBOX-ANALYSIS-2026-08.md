# OpenSandbox vs. sandy — overlap, what to steal, what to offer (August 2026)

**Subject.** `research/OpenSandbox` submodule @ `b88a1aa0`, https://github.com/opensandbox-group/OpenSandbox (Alibaba-originated, CNCF Landscape, OpenSSF Best Practices). 2158 files: 661 Python, 610 Go, 194 Markdown, 113 YAML, plus Kotlin/C#/TS SDKs.

**Observation / inference / recommendation kept distinct; confidence H/M/L.** Everything below is from reading the repo — no code was run.

---

## 1. They are not a competitor; they are the other half of the market

**Observation.** OpenSandbox is a **platform**: `opensandbox-server` + Docker/Kubernetes runtimes + five language SDKs + an `osb` CLI + an MCP server + an ingress gateway + a 19-document OSEP process. Sandboxes are created *programmatically by an application* against a REST lifecycle API, keyed by `SANDBOX_API_KEY`. Their own Claude Code example is the tell: `pip install opensandbox`, start a server, then a Python script that creates a sandbox, `npm i -g @anthropic-ai/claude-code`, and runs `claude "Compute 1+1=?."` one-shot with `ANTHROPIC_AUTH_TOKEN`.

Sandy is a **developer tool**: one bash file, no server, no SDK, no API key, wrapping *your own workspace on your own machine* with *your own OAuth credentials*, interactive TUI, multi-agent tmux.

**Inference (H).** The overlap is not the product — it is the **middle layer** both had to build: egress control, credential handling, secure runtimes, mount policy. Their target user builds an AI product that needs to run untrusted generated code at scale; sandy's target user *is* the developer, running a trusted-ish agent against code they care about. Neither displaces the other, and the near-term risk of them "eating" sandy is low (M-H): nothing in their roadmap points at a single-binary local dev-workspace wrapper, and their `Not Currently Planned` list is about API stability and governance, not scope expansion downward.

**The one place this could invert (M).** If someone wrapped their Docker runtime + egress sidecar in a thin local CLI, that would be a sandy-shaped thing built on their platform. Their components are the hard part and they are already built. Worth watching; not worth reacting to.

---

## 2. Overlap map

| Concern | OpenSandbox | sandy | Verdict |
|---|---|---|---|
| Egress control | DNS proxy (NXDOMAIN) + nftables dynamic-DNS sets, sidecar in the pod netns, `CAP_NET_ADMIN` on sidecar only | Dual-homed proxy container + `--internal` network; SNI/Host demux, CONNECT, no iptables in proxy mode | **Deep overlap, different mechanism** |
| Credential isolation | **Credential Vault**: real secrets live in the sidecar, workload gets fakes, transparent MITM injects auth headers on the way out | Credentials mounted ephemerally `:ro` into the container; the agent *holds* them | **They are ahead** — see §3.1 |
| Stronger isolation | gVisor / Kata (QEMU, CLH, Firecracker) documented with an overhead + compatibility matrix | `SANDY_RUNTIME=runsc\|kata` proposed (#127), spike-gated, unbuilt | **They are ahead, and they answered our gate** — §3.2 |
| Pause / resume | OSEP-0008 rootfs snapshot, OSEP-0015 pod snapshot | #125 daemon `docker pause/unpause` for idle sessions | Overlap, theirs far more ambitious |
| Host mounts | OSEP-0003 volumes incl. hostPath, with allowlist prefixes, traversal bans, `readOnly` | Existence-gated `:ro` protected paths, sandbox overlays, `SANDY_MOUNTS` proposed (#139) | Convergent instincts |
| Introspection | `specs/diagnostic-api.yml`, OTLP instrumentation (OSEP-0010) | `--print-schema` / `--print-state` / `--validate-config` | Overlap in spirit |
| In-sandbox attestation | **None found** | `/etc/sandy-session.json` `:ro` + nonce | **Sandy is ahead** — §4.1 |
| Governance | OSEP process, umbrella release governance, Cosign-signed images with provenance | `CLAUDE.md` + issues + semver discipline | Theirs is a real project process; ours is a solo-maintainer one |

---

## 3. What sandy might take

### 3.1 Credential Vault is the design sandy has been circling — **REC: read hard before building #121/#130** (confidence H)

**Observation.** Sandy already has `research/credential-broker-cb4a.md` and two open issues (#130 `SANDY_SUSPICIOUS`, and the broker in `POST_1.0_IDEAS.md`) whose motivation is exactly: *OAuth tokens sit readable on disk inside the sandbox, and a prompt-injected agent can exfiltrate them.* OpenSandbox shipped the answer. Their model:

1. Host-side SDK writes real credentials + bindings into the egress sidecar's vault (Unix socket, not reachable from the workload).
2. The workload runs with **fake or empty** credential env vars.
3. Transparent MITM inspects outbound HTTPS; if exactly one binding matches scheme/host/port/method/path, the sidecar injects the auth header.
4. Secret values are redacted from vault responses and response headers.
5. Refuses to activate unless `mode = "dns+nft"` — because DNS-only can be bypassed by direct-IP connections. Requires `defaultAction="deny"` with every credential-bound host explicitly allowed.

**Why this matters more than it looks.** Point 5 is the part sandy should internalize regardless of whether it builds a vault: **a credential broker is only as good as the egress policy underneath it.** Sandy's egress default is *permissive* (block private, allow all internet). A sandy credential broker layered on permissive egress would be close to security theater — the agent could not read the token, but could ask any host on the internet to receive whatever the token fetched. OpenSandbox refusing to activate the vault in the weaker mode is the right instinct and sandy should copy the *refusal*, not just the feature.

**The hard trade sandy has to make consciously.** Their injection requires **terminating TLS** (mitmproxy). Sandy's proxy has a documented invariant that it *never* terminates TLS, never logs payload, never caches — and that invariant is load-bearing for user trust in a tool that runs on a developer's own machine against their own repos and their own personal OAuth tokens. Their context (an operator running a platform for their own application's workloads) makes MITM far more palatable than sandy's (a developer's laptop). So:

- **REC (H): do not adopt MITM by default.** It would trade sandy's clearest trust property for a threat most sandy users are not facing.
- **REC (M): if a broker is built, make TLS termination an explicit opt-in posture** (`SANDY_CREDENTIAL_BROKER=1` implying strict egress + a named CA the user installs), documented as "sandy reads your HTTPS to your model provider so the agent never holds your token." Alternatively pursue the narrower #130 slice (strip the refresh token, ship an access-token-only credential) which needs no MITM and no TLS trust change.

### 3.2 They answered sandy's #127 spike gate — and the answer is better than we assumed (confidence M-H)

**Observation.** Sandy's #127 (`SANDY_RUNTIME=runsc|kata`) carries an explicit unverified gate: *"does gVisor's netstack break the proxy's DNS/SNI/CONNECT path? Unverified — must soak-test before shipping."* OpenSandbox hit this and documented the mechanism precisely:

> gVisor's netstack implements the `filter` and `mangle` iptables tables but does not implement the `nat` table. The egress sidecar uses a REDIRECT rule in the `nat` table to intercept DNS queries (port 53 → 15353), so it cannot start under gVisor. ([gvisor#170](https://github.com/google/gvisor/issues/170))

Their server hard-rejects `secure_runtime.type = "gvisor"` together with `network_policy` (HTTP 400). Kata works unchanged — a full kernel per pod. Their compatibility matrix also flags gVisor: **no GPU**, no privileged mode, no systemd, partial syscall compatibility.

**Inference (M-H).** *The specific failure does not obviously apply to sandy*, and the reason is a design choice sandy already made: **sandy does not use in-container iptables NAT.** In proxy mode sandy applies no iptables at all — the isolation is the `--internal` network topology, and DNS is redirected by the `--dns` flag on `docker run`, i.e. resolver configuration, not a NAT REDIRECT. The host-side RFC1918 DROPs in legacy mode, and the `SANDY_LOCAL_LLM_HOST` ACCEPT rule, are installed in the *host* namespace, not the guest.

**REC (M-H).** Rewrite #127's spike gate from the open-ended *"does the proxy path survive gVisor"* to three narrow, testable questions:

1. Does the agent container's outbound TCP to a fixed proxy IP work under `runsc`? (Expected yes — no NAT involved.)
2. Does `--internal`'s non-TCP L3 drop still hold when the *agent* runs under `runsc`? (The drop is on the Docker bridge, host-side, so expected yes — but this is sandy's documented non-TCP invariant and must be re-verified, not assumed.)
3. `SANDY_GPU` + gVisor is **incompatible** per their matrix — sandy must reject that combination the way their server does, rather than launching into a confusing failure.

That converts #127 from "unbounded spike" to "three checks," which is a meaningful de-risking. **Confidence is M-H, not H, because this is inference from their architecture to ours — nobody has run sandy under gVisor.**

### 3.3 Smaller, concrete borrowings

- **DoH/DoT blocking (REC: consider, M).** They ship `BLOCK_DOH_443` + a DoH blocklist and drop `tcp/udp dport 853` outright. Sandy has no DoH story: in **permissive** mode (the default), an agent can reach any public DoH resolver over TCP/443 and resolve names sandy's DNS responder would have refused. Sandy's `--internal` non-TCP drop kills DoH-over-QUIC, and strict mode's allowlist bounds it — but permissive mode is the default and the gap is real. Worth an issue.
- **Fail-closed on enforcement-setup failure (REC: verify parity, M).** Their sidecar *exits* if it cannot install an enforced DNS redirect; optional subsystems (OTLP, hooks) degrade gracefully. Sandy has a proxy readiness gate (HEALTHCHECK + crash-loop detection), which is close — worth an explicit check that sandy fails the launch rather than proceeding un-isolated if the proxy never becomes healthy.
- **Denied-hostname webhook + OTLP (REC: no, note only, H).** Right for a fleet platform; wrong for a single-user CLI. Sandy's `SANDY_EGRESS_LOG` session-end rollup is the correctly-sized equivalent.
- **Refusing a silently-ignored security setting (REC: adopt as a rule, H).** Their lifecycle API *rejects* a per-request `networkPolicy` combined with `poolRef` rather than silently ignoring it. That is the same instinct as sandy's value-aware passive-config gating (*"a repo may tighten the sandbox, never loosen it"*) and sandy's non-TTY fail-closed approvals. Good independent convergence — cite it when that design is questioned.

---

## 4. What sandy might offer them

### 4.1 In-sandbox attestation — sandy has something they appear to lack (confidence M-H)

**Observation.** I found no runtime attestation surface: nothing that lets a process *inside* an OpenSandbox sandbox determine, from inside, whether an egress policy is active, which mode, or whether it is in a sandbox at all. (Grep hits for "attestation" are about **release** artifact signing — Cosign/provenance — not runtime.)

**Why sandy knows this is a real gap.** Sandy shipped `/etc/sandy-session.json` — a `:ro` bind-mounted JSON marker carrying `egress_mode`, `sandy_version`, `workspace`, a per-launch `session_nonce`, and now `effort` / `permission_mode` — precisely because a red-team run *inside* sandy concluded it was **not** in a sandbox: env vars are spoofable, absence of a path proves nothing, and uid/caps/mount heuristics all read as "ordinary VM." The nonce can be operator-pinned so an external harness can prove the run is the one it launched, and the `:ro` mount means a committed workspace config cannot forge it.

**REC (H): offer this as an OSEP-shaped suggestion.** For them the payoff is larger than for sandy: their sandboxes are created by an application, and an agent or eval harness inside one currently has no trustworthy way to assert "I am running under policy X." That matters for **RL training and agent evaluation** — two of their named use cases — where a benchmark that silently ran without the intended isolation produces results that are wrong in an undetectable way. That is exactly the failure sandy's `effort` field was added to catch.

### 4.2 A question about non-TCP scope in the nft allow rules (confidence M — offer as a question, not a finding)

**Observation.** In `components/egress/pkg/nftables/manager.go`, the dynamic and static allow rules are emitted as:

```
add rule inet <t> <c> ip daddr @dynAllowV4Set accept
add rule inet <t> <c> ip daddr @allowV4Set accept
```

— destination-IP only, with **no `tcp dport` / `meta l4proto` qualifier**, whereas the targeted DoH drops above them *are* protocol-scoped (`tcp dport 443`, `tcp/udp dport 853`). Their own doc states "UDP and QUIC entries are not connection-tracked."

**Inference (M).** Once a domain resolves and its IP enters an allow set, **any protocol and any port to that IP appears to be accepted** — including UDP/443. Two consequences worth their consideration:

1. **Credential Vault's MITM operates on TCP 80/443.** An HTTP/3-capable client talking to an allowed host would bypass the interception path entirely. That fails *safe* for credentials (no injection → the request is unauthenticated → it fails), but it also means the request is not inspected, which weakens the "single chokepoint" property the vault depends on.
2. **`BLOCK_DOH_443` drops `tcp dport 443` only.** DoH-over-HTTP/3 (UDP/443) to a resolver whose IP is in an allow set would not be caught by that rule, which is a potential bypass of Layer 1 (DNS policy) — the layer the whole design rests on.

**How to frame it.** As a question — *"is non-TCP egress to allow-set IPs intentional?"* — not as a vulnerability claim. I have not run their stack, and there may be a pod-level `NetworkPolicy` or CNI rule outside this file that handles it.

**What sandy can offer alongside it.** Sandy treats this as a documented invariant with test coverage: the `--internal` network is an L3, protocol-agnostic `FORWARD` DROP with no MASQUERADE, so QUIC/HTTP-3, raw UDP, ICMP and IPv6 all fail closed *before* reaching the TCP-only proxy — verified on macOS Docker Desktop and guarded by `test/spike/macos-internal-network-spike.sh` plus a Linux integration check. Sandy's own note is the transferable part: *"a future refactor must not make the proxy the only egress mechanism without re-adding a non-TCP block."*

### 4.3 Two smaller offers

- **The value-aware config tier** (M). Sandy's rule — *committed workspace config may make the sandbox tighter, never looser*, with weakening values routed through an approval prompt — is a governance primitive that maps onto their pool-template-vs-per-request-policy tension. Cheap to describe, and their `poolRef` rejection shows they would find it congenial.
- **Detection where prevention is impossible** (L-M). Sandy's session-end sweep for protected paths that *appeared* during a session is a pattern for the case where you cannot mount over a path that does not exist. Probably lower value to them (ephemeral sandboxes, no persistent host workspace to protect), so offer only if the volume/hostPath work in OSEP-0003 grows a persistent-workspace story.

---

## 5. What sandy should explicitly *not* take

- **The server/SDK/API-key architecture.** Sandy's single-file, no-daemon, no-account property is a feature — the `INTEGRATION-OPPORTUNITIES` rule applies verbatim: *sandy integrates by reusing what it already has, not by adopting another project's control plane.*
- **Kubernetes anything.** 322 files of it. Not sandy's problem.
- **Ingress gateway / secure access endpoint / multi-tenancy.** Sandy has exactly one tenant.
- **Becoming an OpenSandbox runtime.** Superficially attractive — implement `specs/sandbox-lifecycle.yml` and sandy becomes a local runtime for their platform — but it inverts the control flow (sandy is invoked by a human in a workspace, not by a scheduler) and would import their API surface as a compatibility burden for a user sandy does not have. **REC: no**, unless a real consumer asks.

---

## 6. Open questions

- **Is their Credential Vault actually usable without Kubernetes?** The requirements list `mode = "dns+nft"`, a sidecar sharing a netns, and `CAP_NET_ADMIN`. Docker mode exists, but I did not verify the vault works there. If it is effectively k8s-only, the lesson for sandy is architectural rather than adoptable.
- **Does their MITM path handle non-HTTP TLS** (git-over-SSH, model-provider streaming)? Sandy's CONNECT listener exists specifically for git-over-SSH; unclear how the vault treats protocols it cannot parse.
- **Unverified in §3.2:** nobody has run sandy under `runsc`. The inference that sandy dodges the `nat`-table problem is architectural reasoning, not a test result, and is the most likely error in this document.
- **License/provenance check not done.** Sandy borrows *ideas* here, not code; if any code were ever lifted, their LICENSE and CLA/DCO terms need reading first.
