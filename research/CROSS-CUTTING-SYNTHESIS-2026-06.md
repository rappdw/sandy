# Cross-cutting synthesis — research/ adoption review (2026-06-07)

A coordinator-level synthesis across all eight projects under `research/`, looking
for what emerges from the **totality** rather than each project in isolation. Each
project was analyzed by a dedicated sub-agent; this document captures the
cross-cutting themes, the prioritized action map, and what to deliberately ignore.

Projects reviewed: `claude-code`, `sandbox-runtime`, `OpenShell`, `gstack`,
`alice`, `agentbox`, `hyperlight`, and the `claude-code-sandboxing` stub.

This complements the older per-project analysis docs at `research/` root
(`FEATURE-ADOPTION-ANALYSIS.md`, `ADOPTION-CHECKLIST.md`,
`IMPLEMENTATION-SKETCHES.md`, `per-project-isolation-landscape.md`,
`sandbox-comparison-gemini-cli.md`); where they overlap, this is the newer read.

---

## Theme 1 — Four independent projects converged on the egress proxy sandy is building *now* (M2.7), and they hand us a bug-tax checklist

`sandbox-runtime`, `claude-code` (its native Bash sandbox), `OpenShell`, and the
`claude-code-sandboxing` stub **all independently built domain-allowlist egress
proxies.** That is strong validation that M2.7's direction is correct. More
usefully, they've already paid the bug tax, and several findings land directly on
sandy's in-flight proxy (PR #8 / 2.7.1):

- **Host canonicalization before allowlist matching** — `sandbox-runtime/src/sandbox/parent-proxy.ts:471` (`canonicalizeHost`), `sandbox-manager.ts:128`. They reject `inet_aton`/octal/hex/decimal/IPv6 encodings before matching (`2852039166` == `169.254.169.254`, the cloud-metadata address). **ADOPTED** into PR 2.7.1 (`proxy/allowlist.go` `normalizeHost`): reject malformed/encoded hosts; name path never authorizes a raw IP; IPs only via explicit canonicalized `host:port`.
- **Tagged-403 / deny visibility** — `sandbox-runtime/src/sandbox/request-filter.ts:116`; OpenShell's "narrowest-rule" denial→proposal loop (`architecture/sandbox.md:92`). A denied request should be distinguishable from a network failure so the agent doesn't flail. **PARTIALLY ADOPTED** into PR 2.7.1 (CONNECT returns 403; both paths log the deny). The exit-time aggregation ("agent tried X N times; allow with `SANDY_ALLOW_HOSTS=…`") is PR 2.7.3 — fits sandy's existing session-end-warning idiom.
- **SSH-over-proxy recipe** — `sandbox-runtime/src/sandbox/sandbox-utils.ts:315` shows `GIT_SSH_COMMAND` with `socat`/`nc -X 5`. This is exactly the ssh `ProxyCommand` PR 2.7.3 needs for `SANDY_SSH=agent`.
- **SOCKS5 for non-HTTP/non-SSH TCP** — flagged as load-bearing by multiple sources (`claude-code-sandboxing` → `sandbox-runtime/README.md:121`). Sandy's transparent+CONNECT hybrid covers the enumerated tool set, so the deferral to 1.0.1 holds — but it's confirmed as the right *next* thing, not optional forever.
- **Comprehensive proxy-env fan-out** (`ALL_PROXY`, `GRPC_PROXY`, `NO_PROXY`, gcloud/docker proxy vars) — `sandbox-runtime/src/sandbox/sandbox-utils.ts:315`. Mostly mooted by sandy's transparent model (no `HTTP_PROXY` needed), but `NO_PROXY` semantics and the SSH specifics inform PR 2.7.3.

**Takeaway:** the most time-sensitive finding folded straight back into the code being written. M2.7 is independently validated by four codebases.

## Theme 2 — The biggest *un-addressed* gap: credential exfiltration, and the two most sandy-like projects solved it identically

`agentbox` (`packages/sandbox-docker/scripts/git-shim` → host relay, `docs/host-relay.md`) and `OpenShell` (proxy credential injection, `architecture/sandbox.md:48`) **both keep credentials host-side so the agent never sees the token.** Sandy forwards `ANTHROPIC_API_KEY`, the `gh` token, and `SANDY_EXTRA_ENV` values *into the container env*, where a prompt-injected agent can read and exfiltrate them.

The totality insight: **Theme 1 (egress allowlist) and Theme 2 (host-side creds) are one defense-in-depth story** — the allowlist limits where a leaked credential can go; the host-relay stops the leak. M2.7 delivers the first half for free. The second half (a host-side git/gh credential broker with per-action approval prompts) is architecturally heavy for single-file bash, so it's a POST_1.0 candidate — but it's the highest-value non-trivial idea across all eight projects. agentbox additionally pairs it with per-action host-side confirm prompts (`docs/host-relay.md:18`) — a confused-deputy guard: a prompt-injected agent can *request* a push, but a human sees the real argv first.

## Theme 3 — Sandy's container hardening is best-in-class among peers — *protect that edge*

Read across the negative space:

- `agentbox` runs `--cap-add SYS_ADMIN/NET_ADMIN`, `apparmor:unconfined`, `seccomp=unconfined`, **no `--read-only`, no `--cap-drop`** (`packages/sandbox-docker/src/docker.ts:54`) — to enable in-box Docker-in-Docker.
- `OpenShell` *adds* caps (SYS_ADMIN/NET_ADMIN/SYS_PTRACE) for its in-container Landlock supervisor (`crates/openshell-driver-docker/src/lib.rs:1774`).
- `sandbox-runtime` / `claude-code` use OS primitives (Seatbelt/bubblewrap/seccomp) only because they have **no container** at all.

Sandy's `--cap-drop ALL` + read-only rootfs + non-root is **stricter than all of them at the container layer.** The cross-cutting conclusion: the temptation from these projects is to chase features that *require weakening this* (DinD, in-container privileged supervisors, nested sandboxes). **Don't.** Sandy's edge is the hardened container; every "platform" peer traded it away for capability. The adoptable surface is *patterns and proxy-hardening, not architecture.*

## Theme 4 — "Which version is actually running?" — a recurring cheap win

- `alice` stamps `sha256sum "$0" | head -c12` into its startup banner (`sandbox/host-claude-watcher/alice-host-claude-watcher.sh:59`).
- `OpenShell` verifies a checksum on every downloaded asset and gates breaking upgrades behind an explicit ack env var (`install.sh:311,605`).
- `claude-code` ships `requiredMinimumVersion`/`requiredMaximumVersion` (`CHANGELOG.md:236`).

Sandy's self-mutating single-file + `sandy --upgrade` model makes "which sandy is live" genuinely confusing (a second copy ahead on `PATH`, a clone checkout, a hand-edited curl install where `SANDY_COMMIT` is empty). These cluster into a cheap S-effort hygiene bundle; pairs with the `SANDY_AUTO_UPGRADE` entry already in `POST_1.0_IDEAS.md`.

## Theme 5 — Fail-closed discipline appears in nearly every project

`sandbox-runtime` `failIfUnavailable`; `claude-code` `failIfUnavailable` (`CHANGELOG.md:1749`, security fix at `:1908`); `agentbox`'s egress-IP probe that **throws rather than defaulting to `0.0.0.0/0`** (`packages/sandbox-hetzner/src/egress-ip.ts`); `OpenShell`'s hard-stop breaking-upgrade gate; `claude-code-sandboxing`'s proposed strict mode. Sandy's macOS posture is "warn and proceed." The convergent signal: the security-conscious default is **fail-closed with a named escape hatch.** Until M2.7 lands, a one-flag `SANDY_FAIL_IF_NO_ISOLATION=1` opt-in is a cheap win; once M2.7 lands, macOS *can* fail closed by default.

## Theme 6 — A real browser capability (secondary opportunity)

`gstack`'s `browse` daemon (`research/gstack/ARCHITECTURE.md`, `BROWSER.md`) is already isolation-shaped: localhost-only, bearer-token auth, random per-workspace port, 30-min idle shutdown, zero MCP token overhead, state in `<workspace>/.gstack/` (which sandy already bind-mounts). `agentbox`'s lazy-Chromium resolver (`Dockerfile.box:271`, `scripts/chromium-resolver`) reuses the project's *pinned* Playwright Chromium instead of baking one that goes stale. Combined, they're a blueprint for a **pack-independent sandy browser capability** — flagship potential, L-effort, post-1.0. (Both projects also have host-Chrome / cookie-import modes that are the *opposite* of sandy's isolation; adopt only the headless, lazy-resolved path.)

## What the totality says to ignore

Every "platform" peer is heavier than sandy by design, and the temptation is to platform-ify. The unanimous read: **single-file minimalism is the differentiator, not a limitation to grow out of.** Specifically skip:

- `hyperlight` — micro-VM library; no macOS support, can't run full agent toolchains (no OS/syscalls/fs/net), requires a Rust rewrite. Note its deny-all-plus-named-capabilities philosophy as validation of sandy's posture; adopt no code.
- `OpenShell`'s gateway/gRPC/mTLS control plane, OPA+Z3 prover, OCSF logging, multi-driver (Podman/K8s/MicroVM) — a heavyweight platform; the anti-sandy on the scope axis.
- `agentbox`'s multi-cloud provider abstraction, DinD-as-baseline, pnpm/turbo monorepo + GHCR image-pull install, VS Code/noVNC stack.
- `alice`'s s6 supervision, blue/green deploy, GitHub watcher, mind-repo, thinking-hemisphere cron, signal-cli — all artifacts of a *persistent singleton service*, where sandy is an *ephemeral per-launch sandbox*.
- `sandbox-runtime`'s container-free engine, seccomp-BPF AF_UNIX blocking, TLS-MITM/CA-injection, Windows WFP — solving problems sandy's container already handles, or out of scope.

## Prioritized action map (respecting the 1.0 freeze)

| When | Action | Source convergence | Status |
|---|---|---|---|
| Now — PR 2.7.1 (proxy in-flight, so in-scope hardening) | Host canonicalization + encoded-IP rejection; deny-logging | sandbox-runtime, OpenShell, claude-code-sandboxing | ✅ done (commit `0e21dd5`) |
| Now — PR 2.7.3 | ssh `ProxyCommand` via the `GIT_SSH_COMMAND`/socat recipe; exit-time deny aggregation → `SANDY_ALLOW_HOSTS` hint | sandbox-runtime, OpenShell | planned in roadmap |
| Now — tiny | `SANDY_FAIL_IF_NO_ISOLATION=1` opt-in (fail-closed on macOS until proxy lands) | 4 projects | candidate |
| Confirm/audit (no code) | Cross-check protected-path list vs srt deny list (sandy already broader — verify `.claude/agents/`); audit what `~/.ssh` copy actually lands in-container (`sandy:1509`) | sandbox-runtime, claude-code-sandboxing | candidate |
| POST_1.0_IDEAS | Host-relay credential broker (highest-value strategic); version-hygiene cluster; pack-independent browser; atomic tempfile+rename on state writes | agentbox, OpenShell, alice, gstack | captured in POST_1.0_IDEAS.md |
| gstack integration (independent of 1.0) | Pin gstack to a release tag (not `main`) — serves the stability freeze; generate Codex/Gemini skills for non-Claude panes | gstack | candidate |

## Bottom line

Sandy is on exactly the right track. Its in-flight M2.7 proxy is independently
validated by four codebases, and its hardened-container model beats every peer.
The work isn't to adopt their architectures — it's to (1) absorb their proxy
bug-tax into the proxy being built (done), (2) close the one real gap they all
expose — host-side credentials (POST_1.0), and (3) pick up a few cheap convergent
hygiene/fail-closed wins. Resist platform-ification; the single file is the point.
