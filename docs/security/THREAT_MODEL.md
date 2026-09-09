# Sandy Threat Model

This document states **what sandy defends against, and what it does not.**
"How secure is sandy?" has no answer without a stated adversary; this is that
adversary. Empirical attempts to break the boundary live in `ISOLATION_STRESS.md`
and are an ongoing exercise via the `sandy-isolation-test` red-team kit. The
implemented mechanisms are in `SPECIFICATION.md`; the design rationale is in
`CLAUDE.md`.

---

## 1. The adversary sandy assumes

Sandy runs coding agents (Claude Code, etc.) with their in-session permission
prompts disabled, so the agent acts freely *within the box*. The box exists to
bound the damage. The assumed adversary is, in order of how much sandy invests in
each:

1. **A wrong-but-not-evil agent (primary).** The agent is generally cooperative
   but is *occasionally* induced to do harmful things — by **prompt injection**
   (a malicious README, issue, web page, or tool output), a buggy skill/plugin,
   or simply a bad task. It is not running a curated exploit chain; it does
   plausible-looking things that happen to be dangerous. **Sandy is primarily
   engineered against this adversary, and against it sandy is strong.**

2. **A committed-config / supply-chain attacker (secondary).** A repository the
   user opens ships a hostile `.sandy/config`, `.git/hooks`, `.github/workflows`,
   `.envrc`, etc. — trying to weaken isolation or run on the host *before/around*
   the agent. Sandy invests real effort here (parse-not-source config, the
   privileged-key approval prompt, read-only protected paths).

3. **A determined / jailbroken agent (partial).** The agent is *actively* trying
   to escape — enumerating syscalls, probing the runtime, attempting kernel or
   `runc` exploits, hunting exfil channels. Sandy raises the cost (cap-drop,
   no-new-privs, seccomp, read-only root, no docker socket) but **does not claim
   to stop a working kernel/runtime exploit** — the container shares the host
   kernel. This tier is where the open hardening items below apply.

### Explicitly out of scope
- **Application-layer agent behavior.** Sandy bounds the *blast radius*; it does
  not stop the agent from *misusing its legitimate capabilities* (writing code
  you'll run, using its own credentials, reaching allowed hosts). Prompt-injection
  defense at the model layer is a separate problem.
- **A malicious host or maintainer.** Sandy protects the host *from* the agent,
  not the agent from the host. The person running sandy is trusted.
- **Side-channel / nation-state-grade attacks** (timing, speculative execution,
  cache). Not modeled.
- **Supply chain of sandy's own base images** (Docker Hub `golang`/`debian`).
  Pinned, but ultimately a trust assumption.

---

## 2. Assets protected

- **The host filesystem** outside the mounted workspace (config, keys, other
  projects, system files).
- **The host itself** — no code execution / privilege escalation on the host.
- **Other projects' data and credentials** (per-project isolation).
- **The host network / LAN** — the agent should not reach the LAN, the host's
  loopback services, or cloud metadata.
- **Credentials at rest** — session credentials should not persist where they
  weren't meant to, and one project's creds must not leak to another.

## 3. Trust boundaries

```
  HOST  (trusted)
   │  ├─ workspace dir ........ bind-mounted RW  ◀── the agent CAN write here (intended)
   │  ├─ protected paths ...... bind-mounted RO  ◀── shell/git/CI configs
   │  ├─ credentials .......... ephemeral mount  ◀── this session only, never persisted
   │  └─ everything else ...... NOT mounted      ◀── invisible to the container
   ▼
  CONTAINER  (untrusted: the agent)   ── shared host kernel ──┐
   ├─ non-root, cap-drop ALL, no-new-privs, seccomp, RO root  │ ← the runtime boundary
   └─ network: --internal sidecar ─▶ sandy-proxy ─▶ internet  │   (namespaces today)
                                                              ▼
                                              HOST KERNEL (the floor)
```
The two boundaries that matter most: the **mount scope** (only the workspace +
explicit mounts cross from host to container) and the **runtime boundary**
(namespaces + the hardening list, sitting on the shared kernel).

## 4. Layers → threats addressed

| Layer | Mechanism | Adversary it stops |
|---|---|---|
| Network egress | `--internal` + TCP-only proxy (permissive/strict); non-TCP dropped by topology | wrong-agent LAN/host/metadata reach; committed-config exfil widening |
| Filesystem | RO root, ephemeral tmpfs, workspace-only mount, RO protected paths | wrong-agent host-config tamper; committed hook/workflow execution |
| Credentials | per-project sandbox, ephemeral `.credentials.json`, RO OAuth mounts; **connectors off by default** (`SANDY_CLAUDE_CONNECTORS`); **refresh-token strip** (`SANDY_SUSPICIOUS`) | cross-project leak; credential persistence; ambient account-connector reach; refresh-token blast radius |
| Process/privilege | non-root + `gosu`, `--cap-drop ALL`, `no-new-privileges`, no docker socket, default seccomp/AppArmor | privilege escalation; trivial container escape |
| Resources | `--cpus`/`--memory`/`--pids-limit`, tmpfs caps | runaway resource use |
| Config trust-tier | parse-not-source, privileged-key approval, env-only keys | committed-config code-exec / silent isolation-disable |
| Per-instance | per-PID networks, workspace mutex, per-project sandbox | cross-session interference |

---

## 5. Residual risks (honest)

Judged against the **primary** adversary, these are mostly accepted; against the
**determined** adversary they are open. Empirical detail in `ISOLATION_STRESS.md`.

| # | Residual | Tier it bites | Status / mitigation |
|---|---|---|---|
| R1 | **Shared kernel.** Namespaces are a soft boundary; a kernel/`runc` exploit = host escape (Linux native). | determined | Open. Mitigation: optional **gVisor runtime** (see POST_1.0_IDEAS). macOS has a VM boundary to the Mac. |
| R2 | **Prevention vs detection (filesystem).** Absent protected paths (`.github/workflows/`, `.npmrc`, …) can be *created* and persist to the host, detected only at session end. | wrong-agent / committed-config | Detection covers both protected **dirs and files** (session-end appearance warning). Roadmap: **fanotify `FAN_OPEN_PERM`** for true prevention. |
| R2b | **Project secrets in `.env` are readable.** `.env`/`.env.*`/`.env.local` are *not* in the protected-paths list, so an agent can read a project's secrets. Exfil follows in permissive egress — and via the **hostile-LLM-provider** vector (demonstrated publicly by security researchers, 2026-07) even under *strict*, since the secret rides the trusted model connection, which no egress policy inspects (sandy never terminates TLS). Masking the **read** is therefore the only lever network policy can't provide. | wrong-agent / hostile-provider | **Prioritized — jumped the 1.1 queue (2026-07-08).** Add `.env*` to protected paths, **masked** (read-only only stops writes; reading is the risk). See `POST_1.0_IDEAS.md`. |
| R2c | **claude.ai account connectors were ambient across the box.** The mounted Claude OAuth token is **account-scoped**, so every account connector the user had enabled on claude.ai (Gmail, Drive, …) was reachable from **every** sandbox — including untrusted-repo sessions — with no additional prompt. Found in the field: a maintainer noticed all sandy instances could read their Gmail. | wrong-agent / committed-config | **Closed (2026-08, #129).** Suppressed by default via Claude Code's `disableClaudeAiConnectors`, seeded as a managed key overwritten in both directions (Claude resolves it any-source-true-wins, so writing `false` isn't enough); the `claudeAiMcpEverConnected` host metadata is stripped from the seed regardless. Opt back in per-instance with `SANDY_CLAUDE_CONNECTORS=1` (weakening → workspace approval). Claude-only; gates auto-fetched connectors, not an explicit `--mcp-config` server. |
| R3 | **Exfil not fully closed.** Permissive reaches any public host; strict's *allowlisted* hosts (GitHub gist, `npm publish`) are exfil channels. The agent holds its own session creds — notably a **durable, broadly-scoped GitHub token** (`gh auth token`, forwarded as `GIT_TOKEN` for git push/pull) that a prompt-injected agent could POST to any public host **in the default permissive posture**. | wrong-agent / determined | Partial. Sandy prints a launch note when a token is forwarded under permissive egress and recommends **strict** (`SANDY_EGRESS_PROXY=2`), which limits egress to the default allowlist. `gh` can't easily mint scoped/short-lived tokens (needs a GitHub App), so the GitHub-token half is accepted-with-disclosure. The **OAuth refresh-token** half now has a per-workspace lever: `SANDY_SUSPICIOUS=1` (#130) strips it before mounting, so a distrusted workspace holds only a short-TTL access token — an exfiltrated copy dies at `expiresAt`, cannot be renewed, and `cred_mode` in the session marker records which posture actually applied. This is blast-radius reduction, not elimination (the access token still transits; the durable GitHub token is untouched). Roadmap: **host-side phantom-token broker** (#121) — the refresh token and the GitHub token never enter the container at all. |
| R4 | **Workspace supply-chain.** The agent can poison the project (`package.json` deps, build scripts, `Makefile`) that the *user* later runs on the host — or an auto-execution config (`.vscode/tasks.json`, `.githooks/`, `.claude/settings.json` hook) that a **host IDE open on the same workspace** runs outside the box. | wrong-agent / determined | Semi-fundamental — the workspace must be writable. Mitigated only for auto-executing dotfiles (existence-gated `:ro` + session-end detection). **Caveat:** don't leave the same workspace open in a host IDE during an untrusted-repo session (README "a host IDE on the shared workspace"). |
| R5 | **Within-sandbox persistence.** RW persistent mounts (`cargo`/`npm`/`pip` bins on PATH, `.claude` plugins/commands) let a malicious tool fire in a later session for that project. | determined | Open; bounded to the sandbox (not the host). |
| R6 | **Coarse resource isolation.** No disk-IO / network-bandwidth caps; tmpfs is host-RAM-backed. | wrong-agent (noisy) | Accepted for now. |
| R7 | **Defense-in-depth left on the table.** Custom seccomp allowlist, `userns-remap`, custom AppArmor/SELinux, more `/proc` masking. | determined | Optional hardening, not yet applied. |

## 6. Hardening roadmap → which residual it closes

- **fanotify FAN_OPEN_PERM** (filesystem prevention) → closes **R2**. (Roadmap.)
- **Optional gVisor runtime** (`SANDY_RUNTIME=runsc`) → strongly mitigates **R1**
  (and raises the bar on R5/R7). See `POST_1.0_IDEAS.md`.
- **Refresh-token strip** (`SANDY_SUSPICIOUS`, #130) → **partially closes R3** (OAuth refresh token, per-workspace, shipped 2026-08).
- **Host-side phantom-token broker** (#121) → closes **R3** fully (refresh token and GitHub token never enter the container). (POST_1.0.)
- **Custom seccomp + userns-remap** → hardens **R1/R7** cheaply. (Optional.)

## 7. How this is validated

- **`ISOLATION_STRESS.md`** — point-in-time adversarial stress tests (the April
  2026 review found F1 host-exec-via-hooks and F2 macOS LAN reach; F2 was closed
  by the M2.7 egress proxy).
- **`sandy-isolation-test`** (red-team kit) — a repeatable, control-anchored
  exercise across all seven layers, run with the proxy on/off and across models.
  The residuals above (especially R1–R5) are testable hypotheses; let the
  red-team confirm which are real on a given platform before investing.
- **The egress proxy is itself an in-scope attack surface, not just a control.**
  The Hugging Face incident (2026-07) broke containment via a zero-day *in the
  sandbox's egress proxy* — the one component that is simultaneously mandatory to
  trust, directly reachable by the contained agent, and parsing attacker-influenced
  wire bytes (TLS ClientHello, HTTP `Host`, DNS). Sandy's proxy is in that same
  position, so it is treated as a **tier-3 target**: Go's memory safety removes
  the class the incident's zero-day most likely came from, its wire accessors
  return `ok=false` rather than panicking, `guard()` recovers per-connection
  panics, and its SNI/server-name/HTTP-Host parsers are fuzz-tested
  (`proxy/fuzz_test.go`) with `govulncheck` watching its dependency + stdlib
  call paths. The proxy's
  base image also auto-refreshes ~monthly so its Go stdlib doesn't freeze between
  releases (see SPECIFICATION.md / CLAUDE.md, HF-incident Issues 1–3). The
  `sandy-isolation-test` kit gaining an explicit "attack the proxy" scenario
  (malformed handshakes, oversized SNI, header smuggling, DNS abuse, connection
  exhaustion) is tracked there, in that repo.

**Bottom line:** against a wrong-but-not-evil agent and committed-config supply
chain, sandy's isolation is strong and the layers compose well. Against a
determined adversary, the boundary is the **shared host kernel** — the one
residual worth real investment if your threat model includes an actively
malicious or jailbroken agent.
