# Security Policy

Sandy is a security tool — its job is OS-enforced isolation of coding agents. We
take reports about that boundary seriously, and we'd rather hear about a weakness
privately than read about it in a public issue.

## Supported versions

Sandy is currently in its `1.0.0` release-candidate window: the latest `rc` is a
GitHub **pre-release** soaking toward the final `1.0.0`. Until `1.0.0` ships,
security fixes land on the current release candidate. Once `1.0.0` ships, the
`1.x` line is the supported line.

| Version | Supported |
|---|---|
| `1.0.0-rc*` (current pre-release) | Yes — fixes land on the next `rc` |
| `1.x` (after `1.0.0` ships) | Yes |
| `0.x` (pre-1.0) | No — upgrade to the current release |

Sandy is a single-file launcher and updates in place with `sandy --upgrade`, so
"supported" in practice means: run a current version.

## Reporting a vulnerability

**Do not open a public GitHub issue for a security vulnerability.** A public
issue discloses the weakness before there's a fix.

Report privately through either channel:

- **Email:** rappdw@gmail.com
- **GitHub private security advisory:** open a draft advisory via the
  repository's **Security → Advisories** tab.

Please include what you have:

- A description of the issue and the isolation boundary it crosses (filesystem,
  network egress, credentials, process/privilege, config trust-tier, …).
- Reproduction steps — ideally the minimal `.sandy/config`, workspace layout, or
  command sequence that triggers it.
- Impact: what an attacker (or a wrong-but-not-evil agent) gains.
- Your host OS and Docker runtime, since some findings are platform-specific
  (see the macOS caveat below).

### What to expect

- We aim to **acknowledge your report within a few business days**.
- We'll confirm whether we can reproduce it, discuss severity, and keep you
  posted as a fix is worked out.
- With your permission we'll **credit you** in the release notes or advisory.
  If you'd rather stay anonymous, say so and we'll respect that.

## Scope and threat model

Sandy bounds the *blast radius* of a coding agent running with its in-session
permission prompts disabled. It does **not** claim to stop every adversary. Read
these before reporting so we can talk about the same boundary:

- [`docs/security/THREAT_MODEL.md`](docs/security/THREAT_MODEL.md) — the assumed
  adversary (primary: a wrong-but-not-evil, prompt-injectable agent; secondary: a
  committed-config / supply-chain attacker; partial: a determined/jailbroken
  agent), the assets protected, and the honest residual risks (R1–R7). Several
  residuals are **known and accepted** — a report that restates one of them is
  useful mainly if it shows the risk is worse or more reachable than documented.
- [`docs/security/ISOLATION_STRESS.md`](docs/security/ISOLATION_STRESS.md) —
  empirical bypass attempts, including findings already closed (F1
  host-exec-via-git-hooks) and platform caveats (F2 macOS LAN reach).

### Known platform caveat (not a vulnerability)

On **macOS with the egress proxy turned off** (`SANDY_EGRESS_PROXY=0` /
`SANDY_EGRESS_NO_ISOLATION=1`), Docker Desktop provides **no LAN isolation** — the
container can reach the host's loopback services and the physical LAN. This is
documented in the [README](README.md#macos-docker-desktop--not-isolated-when-the-proxy-is-off)
and the threat model, and the default (`permissive` egress proxy) closes it on
both platforms. Reports that this specific documented, opt-in configuration is
unisolated aren't new findings — but reports that the **default** posture leaks,
or that the proxy itself can be bypassed, very much are.

## Out of scope

Consistent with the threat model:

- Application-layer agent behavior (the agent misusing its *legitimate*
  capabilities, or model-layer prompt-injection defense).
- Attacks assuming a malicious host or maintainer — sandy protects the host from
  the agent, not the other way around.
- Side-channel / speculative-execution / nation-state-grade attacks.
- A working shared-kernel exploit (`runc`/kernel escape) is a known residual
  (R1), not a surprise — though a *novel, practical* one is still worth reporting.
