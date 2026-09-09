# nono vs. sandy — comparison and transferable lessons

**Subject:** [`nolabs-ai/nono`](https://github.com/nolabs-ai/nono) — a Rust CLI that sandboxes AI coding agents with **OS-native kernel primitives** (no daemon, no container, no VM), from the team behind Sigstore.
**Why this doc:** nono ships working implementations of two things sandy had, at the time of this doc, only *evaluated* ([`CREDENTIAL_BROKER_EVALUATION.md`](CREDENTIAL_BROKER_EVALUATION.md) / milestone #12; a first strip-not-broker slice has since shipped as `SANDY_SUSPICIOUS`, #130) or *roadmapped* (the fanotify `FAN_OPEN_PERM` idea in `CLAUDE.md` → "Protected Files"). It is **complementary to sandy, not competing** — this doc records why, and what to borrow.

> **Provenance / caveat.** Everything below is drawn from nono's own public docs (`nono.sh/docs`, `github.com/nolabs-ai/nono`), read-only, on 2026-08-04. These are nono's *claims*, not independently verified by us.

---

## 1. What nono is (mechanism)

A per-process sandbox enforced by **OS-native primitives**, per platform:

- **Linux:** **Landlock LSM** (an *irreversible* filesystem "floor" — `restrict_self()`, kernel 5.13+, needs **no root / no `CAP_SYS_ADMIN`**) **layered with seccomp-notify**. A **supervisor** — the unprivileged *parent* process after `fork()` — traps `openat`/`openat2`, decides allow/deny, and **injects the file descriptor itself** (`SECCOMP_IOCTL_NOTIF_ADDFD`). Landlock is the floor that catches supervisor bugs; seccomp-notify is the dynamic gate. Only `openat*` is trapped; `read`/`write`/`connect`/`stat` are governed by Landlock or left open.
- **macOS:** Apple **Seatbelt** (`sandbox-exec`).
- **Windows:** WSL2.

Plus a **credential proxy** (below), **SPIFFE** workload identity, per-tool **child sandboxes** (delegated `git`/`gh`/`curl` get their own policies "outside the agent's control"), JSON **capability manifests**, and **Sigstore** attestation.

## 2. The credential proxy (the most transferable piece)

A **localhost reverse proxy** that injects the real credential on the fly:

> *"The agent talks to a local reverse proxy that injects real API keys on the fly. The credential never enters the sandbox, not even as an environment variable."*

- The agent gets a **phantom token** — a 256-bit per-session placeholder in `NONO_PROXY_TOKEN`. It calls `http://127.0.0.1:<port>/openai/...`; the proxy validates the phantom token, swaps it for the real key, and forwards **over TLS** to `https://api.openai.com`. SDKs are steered via `OPENAI_BASE_URL`/`ANTHROPIC_BASE_URL`, no code change.
- **L7 scoping:** `endpoint_rules` restrict a credential to specific **HTTP method+path** combinations — the token only works against whitelisted endpoints.
- **OAuth / durable creds stay on the host:** a `cmd://` route runs e.g. `gh auth token` **on the host** lazily (first matching request pauses, supervisor runs the command, caches with a TTL); the sandbox receives only the phantom token. Sources include `op://`, `bw://`, `keyring://`, `env://`, `cmd://`.
- Creds live in `Zeroizing<String>`, never on disk, never logged.

## 3. The decisive framing: nono says to wrap it in a container

nono is unusually honest about its boundary, and this is the whole "how it applies to sandy" answer:

> *"Not Firecracker, not a hypervisor, and not a container runtime… does not provide separate kernel boundary, hardware-level memory isolation, or full filesystem namespace separation… The sandboxed process shares the host kernel."*

> *"For multi-tenant isolation, run nono inside a container or microVM. That adds a guest/host boundary that nono does not provide on its own."*

> Recommended high-assurance deployment: *"a lightweight VM (Firecracker) or hardened container runtime (Edera, Kata) for the outer perimeter, and nono inside for fine-grained capability control."*

**So sandy's Docker container is exactly the outer perimeter nono recommends.** They are complementary layers:

| | **sandy** | **nono** |
|---|---|---|
| Isolation primitive | Docker container: PID/net/mount/user **namespaces**, `--read-only`, cap-drop, seccomp | Landlock + seccomp-notify supervisor (Linux) / Seatbelt (macOS) — **shared kernel** |
| Boundary strength | Namespace/guest-ish boundary (stronger vs. a jailbroken agent; R1 kernel-escape residual) | Same-user containment; **explicitly not** a guest/host boundary |
| Network isolation | egress proxy sidecar (`--internal` topology, TLS **passthrough**) | localhost reverse proxy, TLS **terminating**, L7 endpoint rules |
| Credentials | mounted ephemerally into the container (agent holds them; under `SANDY_SUSPICIOUS` the OAuth **refresh** token is stripped first, and account connectors are off by default) | **broker-not-mount**: phantom token in sandbox, real cred never enters |
| Identity | per-sandbox marker (`sandy-session.json`) | **SPIFFE** SVIDs |
| Dependency | **requires Docker** | no daemon / no container / cross-platform native |
| Attestation | — | Sigstore |

The stack nono *recommends* — **container outside, capability/credential control inside** — is literally **sandy + nono's ideas**.

## 4. What sandy should borrow (maps to existing work)

1. **Credential proxy / phantom tokens — a shipped proof of milestone #12.** nono is a working reference implementation of `CREDENTIAL_BROKER_EVALUATION.md`'s broker-not-mount design, *including the trade-off we already flagged*: injecting a credential at the proxy **requires terminating TLS** (nono's proxy is TLS-terminating; sandy's egress proxy is deliberately TLS-**passthrough**). nono validates the eval's **A2** analysis (real, buildable, cost = the no-MITM invariant) and the **`cmd://` lazy-capture** is a clean blueprint for **A1** (durable cred stays host-side; sandbox gets only a phantom/short-lived token). *(A1's strip slice shipped in 1.9.0 as `SANDY_SUSPICIOUS`/#130; the full host-side broker is tracked as #121.)*
2. **`endpoint_rules` L7 scoping** = sandy's strict-mode host-relay broker (currently POST_1.0) — scoping a token to specific API paths closes "exfil to an *allowed* host" (THREAT_MODEL R3).
3. **seccomp-notify supervisor** = an in-the-wild instance of sandy's **fanotify `FAN_OPEN_PERM`** roadmap (true prevention, not detection-only, for protected paths).
4. **Per-tool child sandboxes** — narrower blast radius than sandy's one-container-runs-everything model. Longer-horizon.

## 5. What sandy should NOT do

Don't adopt nono's *isolation primitive*. For sandy's threat model (determined/jailbroken agent, R1), a shared-kernel process sandbox is a **weaker** boundary than a container — and nono agrees. The transferable value is nono's **credential/identity layer**, which is *orthogonal* to the isolation primitive and is exactly where sandy is behind.

One honest data point: nono's zero-daemon / no-container / cross-platform model would sidestep the entire class of Docker-dependency friction sandy has (e.g. the Proxmox generic-CPU build hang, #117). Not a reason to switch — a weaker boundary — but confirmation that sandy's hard Docker requirement is a real adoption cost, and nono is the proof-of-concept of "the sandy use-case minus Docker."

## 6. Better-together

Because the two occupy **different, non-overlapping layers**, there's a clean complementary story: **container/namespace perimeter (sandy) + per-open capability & broker-not-mount credentials (nono)**. A cross-recommendation ("sandy for the container boundary; nono inside for fine-grained capability/credential control — and nono itself recommends a container/VM perimeter, which sandy provides") is technically accurate and mutually reinforcing, not marketing spin — **but gated on validating that nono actually runs inside a sandy container** (`--read-only`, cap-dropped, `no-new-privileges`, under Docker's seccomp profile), which is not a given. See [`nono-roadmap.md`](nono-roadmap.md) for the sequenced plan (validation spike → positioning → longer-horizon borrows) and the tracking issue for the credential-proxy borrow.

## Sources
- https://github.com/nolabs-ai/nono
- https://nono.sh/docs/cli/internals/security-model.md (Landlock + seccomp-notify, supervisor, stated limitations)
- https://nono.sh/docs/cli/features/credential-injection.md (proxy, phantom tokens, L7, `cmd://`)
- https://nono.sh/docs/cli/internals/{landlock,seatbelt,containers}.md, features/{networking,spiffe,sandboxed-oauth-logins}.md

## Cross-references
- [`CREDENTIAL_BROKER_EVALUATION.md`](CREDENTIAL_BROKER_EVALUATION.md) — sandy's broker-not-mount evaluation (milestone #12); nono is its working reference implementation.
- [`research/credential-broker-cb4a.md`](../../research/credential-broker-cb4a.md) — the CB4A/SPIFFE research nono independently instantiates.
- `CLAUDE.md` → "Protected Files" (the fanotify roadmap nono's seccomp-notify supervisor realizes) and "Egress Proxy" (the TLS-passthrough invariant nono's credential proxy would fork).
