<!--
  DRAFT — design evaluation for milestone "1.7.0 — Secretless credentials".
  Companion to the CB4A/broker research (agent.research, 2026-07-29) and to
  the HF defender-side lessons (internal analysis, unpublished) — esp. the
  "keep roots-of-trust out of the sandbox" lesson this operationalizes.
  Not github issues — the milestone is created; sub-issues are proposed at the
  end for Dan to file after review.
-->

# Secretless credentials for sandy — approach evaluation

**Milestone:** #12 "1.7.0 — Secretless credentials (broker-not-mount)"
**Question posed:** "completely move credentials out of the sandy container — evaluate approaches. Is `egress.container` the right place to proxy credentials?"
**Source research:** [`research/credential-broker-cb4a.md`](../../research/credential-broker-cb4a.md) — the CB4A writeup this evaluation responds to (read it for the full pattern + sources).

## Background: what CB4A is

**CB4A** = **"Credential Broker for Agents"**, an IETF draft (`draft-hartman-credential-broker-4-agents-00`, exp. 2026-09-30) popularized by Christian Posta (Solo.io). Its thesis: handing an AI agent a **long-lived bearer token is unsafe** — an agent is a stochastic, prompt-injectable system, and a bearer token is "whoever holds it" access, so the agent is exactly the wrong thing to give one to. Instead, the agent **never holds a real durable credential**; a **broker** mediates every access and issues **short-lived, narrowly-scoped, sender-constrained, auditable** per-use tokens. Its headline property: *"if the agent is compromised by prompt injection, the attacker has a single token that expires in under a minute and cannot pivot to other services because those credentials do not exist yet."*

The full pattern is a heavyweight enterprise/K8s stack — **broker-not-mount**, PDP/CDP separation (NIST SP 800-207), SPIFFE/SPIRE workload identity, and DPoP (RFC 9449) sender-constrained tokens. Sandy is a single-dev Docker tool, so this evaluation adopts the **principles** at sandy's scale, not the whole stack (the research's own calibration). Every CB4A term used below — broker-not-mount, PDP/CDP, DPoP, SPIFFE — is defined in the source research doc linked above.

## The one fact that drives every answer

To make the container *never hold* a credential, something **outside** the container must put the credential on the wire. The only thing on the egress path outside the container is the proxy sidecar. **So "no secret in the container at all" and "the proxy injects the credential" are the same statement** — you cannot have the first without the second, for any credential carried in an HTTPS request header.

And injecting a header into an HTTPS request means **decrypting it** — i.e. the proxy must *terminate TLS* for that host. That collapses the proxy's central, tested invariant: *"never terminated — no MITM, no cert surgery"* (`proxy/config.go:17,25`). There is no free lunch here; every "true secretless" design pays this price, and every design that refuses to pay it leaves *some* token transiting the container.

The useful move is therefore **not** one big yes/no, but recognizing there are two separable jobs the research conflates, with different right-homes:

| Job | Right home | Touches the proxy? |
|---|---|---|
| **Storing the durable secret + deciding/minting** (the broker / vault / PDP) | A **separate host-side process**. Bloating the security-critical forwarding binary with secret storage + policy violates CB4A's own PDP/CDP separation. | No |
| **Putting a credential on the outbound wire so the agent never holds it** (injection) | The **egress proxy** — it is the *only* component positioned to do this. | Yes — and only via a new selective-TLS-terminating mode |

So the crisp answer to "is `egress.container` the right place to proxy credentials?":
- **As the injection point** (if/when we go full-secretless): **yes, it's the only place it *can* live** — but only by adding a deliberate, scoped, selective-MITM mode for an allowlist of provider hosts, which is an architectural fork away from the current no-MITM design, not a natural extension. The MITM CA **private key must stay host-side in the proxy, never in the container** (or we've just recreated HF #3 one layer down).
- **As the broker/vault itself: no.** Keep that a distinct host-side process the agent calls over a localhost socket. The highest-value first step (below) doesn't touch the proxy at all.

## The reality check the research under-weights: issuers don't mint short-lived tokens for us

CB4A's headline property — *"a single token that expires in under a minute and cannot pivot"* — requires the credential **issuer** to support minting short-lived, scoped tokens (STS / token exchange). For sandy's **primary** credentials this is simply not on offer:

- **Anthropic API key, xAI `XAI_API_KEY`, Google AI Studio key** — long-lived bearer keys, no "give me a 60-second scoped version" endpoint. Sandy cannot conjure one. For these, the *only* way to keep the secret out of the container is **proxy-side injection of the long-lived key** (Phase 2). You get "agent never holds it," **not** "expires in <1 min."
- **Where the issuer *does* cooperate:** GitHub (`gh auth token` today; GitHub Apps mint short-lived installation tokens), Google ADC/service-accounts (STS → short-lived access tokens), and — the big one — **OAuth-based agent auth (Claude Max, Gemini OAuth): the access token is *already* short-lived; the durable secret is the *refresh* token.**

That last point is the opportunity hiding in plain sight. **By default sandy mounts the entire `.credentials.json` — including the refresh token, the durable root-of-trust — into the container**, even though the access token it also contains is already short-lived and self-expiring. Keeping the refresh token host-side and handing the container only the short-lived access token needs **no provider cooperation, no TLS termination, and no proxy change** — and it removes exactly the credential worth stealing.

> **Since this was written (1.9.0, 2026-08).** A first slice of exactly this shipped as **`SANDY_SUSPICIOUS`** (#130): for a workspace you distrust, sandy rewrites the mounted `.credentials.json` to **drop `claudeAiOauth.refreshToken`** before mounting (access token only), verifies the strip and **fails closed** if it can't, and records the resolved posture as **`cred_mode`** in the session marker — the `sandy-session.json` field this section anticipates. Also in 1.9.0, **`SANDY_CLAUDE_CONNECTORS`** (#129) suppresses claude.ai account connectors by default. Two things this does *not* yet do, which keep the A1/A2/A3 analysis below live: it is **opt-in** (the default posture still mounts the full file — `cred_mode: full`), it is a **strip, not a host-side broker** (the access token still transits the container and can't be renewed in-session), and it does **not** touch the durable GitHub token (`gh auth token`). The full host-side broker — refresh token and GitHub token never entering the container — is tracked as **#121** (the OAuth-refresh case is the highest-value first target A1 names).

## The approach spectrum

- **A0 — today.** Raw secret (incl. OAuth refresh token / long-lived API key) mounted or env-forwarded into the container; agent holds the durable root-of-trust for the whole session. Stealable while active — the HF stolen-cred→forgery shape.

- **A1 — Host-side broker for the *durable* credential (recommended Phase 1). No proxy change, no TLS termination, no provider cooperation.** A small host-side broker process holds the durable secret (OAuth refresh token, or a long-lived API key it declines to pass through) and exposes a **localhost/unix socket** into the container. For OAuth agents it hands in only the **short-lived access token**, refreshing on demand; the **refresh token never enters the container.** For raw API keys with no short-life path, A1 alone can't shorten them — they either stay mounted (unchanged from A0) or wait for A2.
  - **Buys:** removes the durable root-of-trust from the container for all OAuth-based auth (Claude/Gemini) — implements HF-defender #3 directly; gives a natural **per-sandbox identity** seam for the externalized audit log (HF-defender #2). Keeps the proxy pure. Low lift, low risk.
  - **Residual:** the short-lived access token still transits the container (stealable in-flight, but expires fast — precisely CB4A's intended property); raw API keys unaffected.

- **A2 — Proxy-side credential injection (true secretless; requires selective TLS termination).** The proxy terminates TLS for an **allowlist of provider hosts** (`api.anthropic.com`, `api.openai.com`, `api.x.ai`, `generativelanguage.googleapis.com`, GitHub API), injects the `Authorization`/`x-api-key` header from a host-held secret, re-encrypts upstream. The agent issues an **unauthenticated** request; the proxy authenticates it. The raw key **never enters the container**, even for issuer-uncooperative raw API keys.
  - **Buys:** the full "no secret in the container" goal, including raw API keys.
  - **Costs (large, deliberate):** abandons `never terminate TLS / no MITM` for those hosts; a MITM CA whose cert is trusted **in-container** while its private key stays **host-side**; per-provider header/auth logic; the proxy now sees provider-request plaintext (new attack surface — though the proxy is already the chokepoint, and the money moving here is the same it already routes). This is a security-model change, not a feature add — do it only if A1's residual is judged insufficient.

- **A3 — DPoP / sender-constraint + per-sandbox identity (CB4A full principles). Deferred.** Bind tokens to a per-sandbox key so a leaked token is non-replayable; a SPIFFE-lite per-sandbox identity for attribution. Only meaningful atop A1/A2 and only for issuers that support DPoP (few today). Per the research's own calibration: **track CB4A (IETF draft, exp. 2026-09), don't depend on it.** Skip for the milestone's first cut.

## Recommendation

**Phase 1 = A1** — the host-side broker for the durable credential. Highest leverage, lowest risk, proxy-preserving, needs no provider cooperation, and removes the single worst current exposure (the mounted OAuth refresh token). It also lays the per-sandbox-identity groundwork the HF-defender audit-log finding (#2) needs, so it composes with that work rather than competing.

**Phase 2 = A2** — proxy-side injection — only if, after A1, the residual (raw API keys still mounted; short-lived tokens still transit) is unacceptable. This is the point at which the egress proxy legitimately *becomes* the credential injection layer — but as a conscious invariant-changing fork, gated on a real decision, with the CA-key-stays-host-side rule as a hard requirement.

**Phase 3 = A3** — deferred; watch the standards race (CB4A vs AAuth vs OIDC-A — the research notes they converge, so the *pattern* is safe to adopt regardless of which draft wins).

**Direct answer to the question:** the egress container is the right place to *inject* a credential (Phase 2) — it's the only place injection *can* happen — but the wrong place to *be the broker/vault/policy*; and the best first move (Phase 1) is a **separate** host-side broker that doesn't touch the proxy at all. Don't put credential storage or policy inside the proxy binary; if we ever inject at the proxy, keep the MITM CA private key host-side.

## Proposed issue breakdown (for the milestone — file after review, not yet created)

1. **A1 broker core** — host-side broker process + localhost/unix-socket protocol; hold the durable secret host-side, serve short-lived tokens into the container. (large)
2. **A1 Claude/Gemini OAuth path** — hold the refresh token host-side, inject only the short-lived access token; stop mounting the full `.credentials.json`. (medium)
3. **A1 per-sandbox identity** — a distinct identity per sandbox stamped on broker-issued tokens + the audit log (composes with HF-defender #2). (small–medium)
4. **A2 spike (design-only)** — prototype selective TLS-terminating auth-injection for one provider host; measure the cost of breaking the no-MITM invariant; decide go/no-go. (spike)
5. **Docs/threat-model** — record the new credential trust boundary, the CA-key-host-side rule, and the issuer-cooperation reality (why raw API keys can't be short-lived without A2). (small)

## Cross-references
- [`nono-comparison.md`](nono-comparison.md) — [`nolabs-ai/nono`](https://github.com/nolabs-ai/nono) is a **shipped reference implementation** of this design (broker-not-mount, phantom tokens, L7 endpoint scoping, `cmd://` host-side OAuth capture, SPIFFE). It confirms the A2 trade-off here — injecting at the proxy requires terminating TLS — and its `cmd://` lazy-capture is a concrete blueprint for A1. Complementary to sandy (nono itself recommends a container/VM perimeter, which sandy provides).
- [`research/credential-broker-cb4a.md`](../../research/credential-broker-cb4a.md) — the source CB4A research; defines every CB4A term used here and carries the primary sources (IETF draft, Posta/Hartman blogs, NIST 800-207, RFC 9449).
- HF defender-side lessons (internal analysis, unpublished): "keep roots-of-trust out of the sandbox" (A1 implements it) and "externalized per-identity audit log" (A1's per-sandbox identity is its prerequisite).
- `CLAUDE.md` "Egress Proxy" / `proxy/config.go` (the no-MITM invariant A2 would fork), "Agent Selection" credential-probe orders (the per-agent secrets A1/A2 must cover: claude/gemini/codex/opencode/grok).
