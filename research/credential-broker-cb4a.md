<!--
  PROVENANCE: external research, received 2026-07-29 via email from
  agent.research@thatsarapp.org (forwarded by Dan), stored verbatim as a
  reference input. THIRD-PARTY CONTENT — reference material, not sandy's own
  position. Sandy's evaluation of and decisions about this research live in
  docs/security/CREDENTIAL_BROKER_EVALUATION.md (milestone #12).
-->

# Credential Brokering for Agents (CB4A / Posta) — For Use in Sandy

**Source:** Christian Posta (Global Field CTO, Solo.io) LinkedIn post on agent credential security, advocating the IETF draft **CB4A — "Credential Broker for Agents"** (`draft-hartman-credential-broker-4-agents-00`, exp. 2026-09-30), plus Posta's blog on SPIFFE-for-agent-identity.

## Why this lands squarely on Sandy right now
The last three Sandy entries kept arriving at the same unmet need — **the sandboxed agent should not hold raw, replayable secrets** (`hf-agent-intrusion-defender-lessons-sandy/`: "stolen signing key = identity forgery; keep roots-of-trust out of the sandbox"; `seldo-agent-sandboxes-sandy-robustness/` Q2: "secrets never enter the sandbox"; `owasp-agentic-skills-top10-sandy/` AST03: least-privilege creds; `agent-outbound-api-key-leakage/`: agents leak keys). **CB4A is the concrete, standards-track architecture for exactly that.** This entry is the "how," where those were the "why."

## The core argument
Posta: giving an AI agent a **long-lived bearer token is fundamentally unsafe** — agents are "goal-oriented, stochastic systems" that can be socially-engineered (prompt injection) into leaking or misusing credentials while believing they're solving the task. A bearer token is "anyone who holds it" access; an agent is exactly the wrong thing to hand one to.

**CB4A's fix:** the agent **never holds a real long-lived credential.** A **broker** mediates every access and issues **short-lived, narrowly-scoped, sender-constrained, auditable** proxy credentials.

## The architecture (CB4A + Posta)
- **Broker-not-mount.** Agent authenticates to a broker and requests access; the broker returns a minimal, time-boxed token (or wraps the credential opaquely to the target). The raw secret stays with the broker.
- **PDP / CDP separation** (Policy Decision Point vs. Credential Delivery Point), per NIST SP 800-207 Zero Trust — deciding *whether* access is allowed is separated from *delivering* the credential (separation of duties).
- **SPIFFE/SPIRE workload identity** as the foundation — the agent proves *who it is* without holding a secret (secretless auth). Posta argues (separately) that agents need **per-instance** identity, not shared pod-replica identity, for attribution/audit.
- **DPoP (RFC 9449) sender-constrained tokens** — proof-of-possession binds the token to the holder's key, so a **stolen or leaked token is non-replayable** by anyone else.
- **Money quote (the security property):** *"If the agent is compromised by prompt injection, the attacker has a single token that expires in under a minute and cannot pivot to other services because those credentials do not exist yet."*
- **Acknowledged tradeoff:** the broker/vault becomes a **high-value single target** — mitigated by the PDP/CDP separation-of-duties and by hardening the broker.

## How each piece maps to Sandy (and the prior findings)
| CB4A pattern | What it fixes for Sandy | Ties to |
|---|---|---|
| **Agent never holds the raw secret; host-side broker mediates** | Sandy today *mounts* ephemeral creds into the container — the agent **holds a live bearer token for the whole session**, stealable while active. Broker-not-mount removes the raw secret from the sandbox entirely. | HF #3 (keep roots-of-trust out); seldo Q2 (secrets never enter the sandbox) |
| **Short-lived (<1 min) + narrowly-scoped, minted per-use** | A stolen token expires almost immediately and can't pivot — "other services' creds don't exist yet." Least-privilege by construction. | AST03 |
| **DPoP / sender-constrained** | A leaked/stolen token is **non-replayable** — directly kills the HF "stolen credential → replay / forged identity" chain and neutralizes the outbound-key-leak scenario. | HF (stolen-cred replay); `agent-outbound-api-key-leakage/` |
| **SPIFFE per-instance agent identity** | Gives each Sandy sandbox a **distinct identity** — which is the missing prerequisite for the **per-decision "which identity made which call" forensic log** the HF incident proved you need. | HF #2 (externalized per-identity audit log) |
| **PDP/CDP separation, broker host-side** | The broker lives *outside* the sandbox; a compromised sandbox can't reach the policy engine or the vault. Fits Sandy's host/container split cleanly. | Sandy's existing host-side cred seeding |

**Net:** CB4A is the architecture that upgrades Sandy's credential story from "ephemeral secret *mounted in*" to "no secret in the sandbox at all, brokered per-use, non-replayable if leaked" — which is where the HF and seldo findings said Sandy needs to go.

## Calibration — adopt the principles, not the whole enterprise stack
CB4A/SPIFFE/SPIRE/PDP/CDP/DPoP is a **heavyweight enterprise / K8s-fleet** pattern. **Sandy is a single-developer Docker tool**, not a multi-tenant cluster — so the full stack (SPIRE server, external PDP, standards-grade DPoP) is disproportionate. The right read is to take the **principles at Sandy's scale**:
- **Do (high value, low lift):** broker-not-mount — a small **host-side credential broker** the sandboxed agent calls over a localhost socket for **short-lived, scoped** tokens, so the raw long-lived secret (OAuth token, API key) never enters the container. This alone captures most of the benefit and directly implements the HF/seldo lessons.
- **Do for high-value creds:** **sender-constraint / proof-of-possession** on the highest-value credentials (the "root-of-trust" class from HF #3), so a leak is non-replayable — even a lightweight bound-token scheme helps.
- **Do lightweight:** a **distinct per-sandbox identity** (doesn't need full SPIFFE/SPIRE) so the externalized audit log can attribute actions per agent instance.
- **Probably skip / over-engineered for now:** full SPIRE deployment, a separate enterprise PDP, standards-complete DPoP — track CB4A as it matures (IETF draft, exp. Sept 2026) but don't take a dependency on the whole thing for a single-user dev sandbox.

## Convergence worth noting
CB4A (Hartman) is part of a **cluster of "beyond bearer tokens for agents"** work already tracked in this library: **AAuth** (Dick Hardt — `aauth-agent-identity/`, `aauth-night-beyond-oauth/`: signed requests, no bearer tokens, verifiable delegation), Posta's **SPIFFE-for-agents**, and hardware HITL (`yubikey-ai-agent-authorization/`). They're converging on the same thesis — *agents shouldn't hold long-lived bearer credentials; use short-lived, sender-constrained, brokered, attributable access.* Worth watching which standard wins (CB4A vs. AAuth vs. OIDC-A); the *pattern* is safe to adopt regardless of which draft prevails.

## Score / take
Directly actionable, standards-track, and it's the architectural answer to credential questions the last several Sandy entries raised. The single highest-leverage adoption: **a host-side credential broker so no raw secret ever enters the sandbox** — pairs with the externalized audit log (HF #2) and egress-below-the-agent (HF #4) as the three-part credential/identity upgrade for Sandy.

## Sources
- [Christian Posta — LinkedIn post (credentials/vault/security)](https://www.linkedin.com/posts/ceposta_credentials-vault-security-share-7487737108825288704-g6Dc/) (source of this request)
- [CB4A — Credential Broker for Agents, IETF draft (draft-hartman-credential-broker-4-agents-00)](https://datatracker.ietf.org/doc/draft-hartman-credential-broker-4-agents/)
- [Why Your Agent Needs a Credential Broker — Introducing CB4A — Kenneth G. Hartman](https://kennethghartman.com/blog/why-your-agent-needs-a-credential-broker/)
- [Your AI Agent Is an Easily Confused Deputy: Why Cloud Security Needs a Credential Broker — SANS](https://www.sans.org/blog/your-ai-agent-easily-confused-deputy-why-cloud-security-needs-credential-broker)
- [Agent Identity and Access Management — Can SPIFFE Work? — Christian Posta](https://blog.christianposta.com/agent-identity-and-access-management-can-spiffe-work/)
- Standards referenced: NIST SP 800-207 (Zero Trust), RFC 9449 (DPoP), SPIFFE/SPIRE.

## Cross-references in the research library
- `hf-agent-intrusion-defender-lessons-sandy/` — the "keep roots-of-trust out of the sandbox" + per-identity-logging lessons this operationalizes.
- `seldo-agent-sandboxes-sandy-robustness/` — Q2 "secrets never enter the sandbox" = CB4A Model A, formalized.
- `owasp-agentic-skills-top10-sandy/` (AST03), `openai-sandbox-escape-huggingface-breach/` (stolen-cred chain), `agent-outbound-api-key-leakage/` — the credential-exposure problems CB4A's short-lived + sender-constrained tokens neutralize.
- `aauth-agent-identity/`, `aauth-night-beyond-oauth/`, `yubikey-ai-agent-authorization/` — the converging "beyond bearer tokens for agents" cluster.

*Note on process (from the original research): LinkedIn post via WebFetch + search; primary detail from the CB4A IETF draft and Posta's blog (both fetched/searched directly). No embedded instructions or injection attempt found in fetched content.*
