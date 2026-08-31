# nono exploration roadmap

Sequenced plan for exploring [`nolabs-ai/nono`](https://github.com/nolabs-ai/nono) in relation to sandy. Companion to [`nono-comparison.md`](nono-comparison.md) (what nono is + why it's complementary) and [`CREDENTIAL_BROKER_EVALUATION.md`](CREDENTIAL_BROKER_EVALUATION.md) (milestone #12).

**Thesis:** nono and sandy occupy **non-overlapping layers** — sandy is the container/namespace perimeter; nono is in-process capability control + a broker-not-mount credential proxy that nono's own docs say to run *inside* a container. Two independent tracks fall out: **(A) borrow nono's credential/identity *patterns*** (needs no nono dependency), and **(B) validate nono *running inside* sandy** (the precondition for any "better together" story). They can proceed in parallel; the relationship/positioning work is gated on (B).

**Legend:** ⛔ = gate (blocks downstream) · 🧩 = maintainer/Docker-required (I can't run it from inside sandy) · 🤝 = relationship move (via Alec / nolabs-ai) · ⏳ = post-1.x / research horizon.

---

## Phase 0 — ⛔🧩 Validate composition: does nono run *inside* a sandy container?

The whole "better together" claim rests on this, and it is **not** obvious it works — sandy's container is `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges`, under Docker's default seccomp profile. nono needs kernel primitives that may or may not survive that.

**Open technical questions to answer:**
1. **seccomp-notify** — nono's supervisor installs a seccomp filter with `SECCOMP_FILTER_FLAG_NEW_LISTENER`. Installing a filter needs *either* `CAP_SYS_ADMIN` *or* `no_new_privs=1`; sandy sets `no_new_privs=1`, so a filter *should* install without caps — **but** obtaining the user-notification listener fd can be gated (kernel/config-dependent, sometimes `CAP_SYS_ADMIN`). Does it work in sandy's cap-dropped container? **This is the single highest-risk unknown.**
2. **Landlock** — needs no privileges (kernel 5.13+), but Docker's default **seccomp profile must allow `landlock_create_ruleset` / `landlock_add_rule` / `landlock_restrict_self`**, and the **host kernel** (the container shares it) must have Landlock enabled. Verify both.
3. **Install path** — nono is a Rust binary; does it install/run on the sandy base image (Debian trixie, `/home` tmpfs, no root), or does it need baking into the image?

**Deliverable:** a one-page spike report — *runs / doesn't run inside sandy*, and if not, the **exact blocker** plus whether a **narrow** sandy change unblocks it (e.g. a seccomp-profile allowance) **without weakening sandy's posture**. I'll write the test script; a maintainer runs it on a real Docker host.

**Decision gate:**
- ✅ **Composes cleanly (or with a narrow, non-weakening tweak)** → Phase 2 (positioning) unlocks; consider documenting the combined stack.
- ⚠️ **Only composes by weakening sandy** (e.g. re-adding a dangerous cap, dropping no-new-privs) → **do not pursue "nono inside sandy."** Keep the comparison doc, pursue Phase 1 borrows only, and frame the relationship as "adjacent tools," not a stack.
- ❌ **Fundamentally incompatible** → same as ⚠️: Phase 1 only, no stack story.

*→ file as a spike issue.*

---

## Phase 1 — 🧩 Borrow the credential-proxy pattern (independent of Phase 0)

sandy adopts the *pattern*, not the tool — so this needs **no** nono dependency and can run fully in parallel with Phase 0. **Already tracked as issue #121** under milestone #12 (1.7.0).

- **A1 (first):** host-side broker + `cmd://`-style lazy capture — hold the durable credential (OAuth refresh, `gh auth token`) host-side, hand the container only a **phantom / short-lived token**. Record the resolved posture in `sandy-session.json` (mirrors the `effort` field).
- **A2 (gated on A1's residual):** proxy-side injection so the agent never holds even the short-lived token — **requires terminating TLS** (the no-MITM-invariant fork the eval's A2 describes; nono confirms the cost). Do only if A1's residual is judged insufficient.
- **L7 endpoint scoping** (nono's `endpoint_rules`) — closes exfil-to-allowed-host (THREAT_MODEL R3); rides A2.

**Success:** at least one credential (highest-confidence: the Claude/Gemini OAuth refresh→access case A1 already identified) brokered so the raw durable secret never enters the container, provably via the session marker.

> **Partially shipped (1.9.0, #130).** `SANDY_SUSPICIOUS` delivers the *strip* form of A1 for the Claude OAuth case: the refresh token is dropped before the file is mounted (never enters the container), and the resolved posture is recorded as `cred_mode` in `sandy-session.json` — so the "provably via the session marker" criterion is met. What remains for the full A1 broker (#121): make it the default rather than opt-in, refresh host-side so the access token can be renewed in-session, and extend `cmd://` capture to the durable `gh auth token`.

---

## Phase 2 — 🤝 Positioning / "better together" (⛔ gated on Phase 0 ✅)

Do **not** advertise a stack that hasn't been validated (Phase 0).

1. **README/docs "composes with nono" note** — factual, low-commitment: *sandy = container/namespace perimeter; for finer-grained per-open capability control + broker-not-mount credentials inside the container, nono composes (and nono's own docs recommend a container/VM perimeter, which sandy provides).* I can draft this PR the moment Phase 0 is ✅.
2. **Mutual cross-recommendation** — a relationship move via Alec / the nolabs-ai team (ex-Sigstore). Make the reciprocal ask **after** Phase 0, so it's backed by "we tested nono-inside-sandy, it works." Keep it a "these compose" note — **no code dependency, no formal partnership** — until there's integration evidence.

---

## Phase 3 — ⏳ Longer-horizon borrows (post-1.x / research)

Real but far past 1.6.0/1.7.0; track, don't schedule.

- **seccomp-notify supervisor ↔ sandy's fanotify `FAN_OPEN_PERM` roadmap** — nono is a working instance of the true-prevention (not detection-only) protected-path enforcement `CLAUDE.md` → "Protected Files" sketches. If Phase 0 shows seccomp-notify works in sandy's container, this becomes concretely reachable.
- **Per-tool child sandboxes** — narrower blast radius than sandy's one-container-runs-everything model.
- **SPIFFE per-instance identity** — composes with the Phase-1 broker (issue #121) *and* the HF-defender externalized-audit-log finding (#2, "which identity made which call").

---

## Sequencing at a glance

```
Phase 0 (validate) ─⛔─► Phase 2 (positioning + outreach via Alec)
                    └───► Phase 3 (seccomp-notify borrow, iff 0 ✅)

Phase 1 (credential-proxy pattern, issue #121) ──────► independent; parallel with Phase 0
```

**Do-first:** Phase 0 spike (unblocks the whole relationship track) **and** Phase 1 A1 (independent, highest standalone value). **Kill criterion:** if Phase 0 shows nono only runs in sandy by weakening sandy, drop the stack story and keep this to "adjacent, pattern-sharing tools."

## Cross-references
- [`nono-comparison.md`](nono-comparison.md) · [`CREDENTIAL_BROKER_EVALUATION.md`](CREDENTIAL_BROKER_EVALUATION.md) · [`research/credential-broker-cb4a.md`](../../research/credential-broker-cb4a.md)
- Issues: **#121** (credential-proxy pattern, Phase 1) — Phase 0 spike to be filed.
