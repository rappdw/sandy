# Alignment with Anthropic's Defending Code Reference Harness

**Assessed:** 2026-09-09, against [`anthropics/defending-code-reference-harness`](https://github.com/anthropics/defending-code-reference-harness) at commit `d3bea6b`, reading `docs/security.md`, `docs/agent-sandbox.md`, the blog post's §2 (sandboxing), `scripts/setup_sandbox.sh`, `scripts/egress_proxy.py`, `harness/sandbox.py`, `harness/docker_ops.py`, `harness/auth.py`, and `harness/agent_image.py`. Sandy at `main` post-1.10.0 (`1.11.0-dev`). Re-run this comparison when either side's runtime, egress, or credential handling changes.

**Tracking:** the four gaps below are #127, #244, #246, #245. Companion to `../../SECURITY_REVIEW_2026-09-04.md`, which this cross-references rather than repeats.

## 1. What the two things are — the framing that decides most rows

The reference is a **pipeline sandbox**: the target's source is built *into* the image at a pinned commit, agents run `claude -p` under gVisor on a docker `--internal` network, they emit files an orchestrator reads back over `docker exec`, and nothing of the operator's is mounted. Several of its rules are pipeline practices (verifier in a fresh container, `<untrusted_data>` wrapping of target-derived text, setup/attack snapshotting) that have no launcher equivalent.

Sandy is a **developer sandbox**: the workspace is mounted read-write on purpose, sessions are interactive or daemonized, and the agent is expected to edit and build the operator's own repository. That is exactly the case the reference's own docs describe as *"safe to run unsandboxed as long as you review and approve each tool use"* — sandy is strictly stronger than that baseline, and it is the thing you would run the reference's *interactive* skills inside.

The reference's actual container is worth stating precisely, because it frames every comparison: `harness/docker_ops.py` runs

```
docker run -dit --runtime runsc --network vp-internal --memory 4g [-e …] [-v …:ro] <image> /bin/bash
```

and nothing else — no `--read-only`, no `--cap-drop`, no `--security-opt no-new-privileges`, no `--pids-limit`. It leans entirely on gVisor for the boundary. Sandy has all of those and not gVisor. The two are complementary, not competing.

## 2. Rule by rule

Sources: the "Rules for running autonomous agents" list in `docs/security.md`, `docs/agent-sandbox.md`, and the blog's §2.

| Reference practice | Sandy | Verdict |
|---|---|---|
| Constraints enforced in code, not prompts | Config tiers, per-workspace approval gates, value-aware gating (*a repo may make the sandbox tighter, never looser*), `:ro` bind mounts as the boundary | **Aligned** |
| No `--privileged`, no host networking | Unprivileged via gosu, read-only rootfs, tmpfs home, per-instance networks | **Aligned** |
| `--internal` network + allowlist proxy as the only route out; denials logged | Same topology. Sandy's proxy additionally controls DNS (redirects permitted names to itself, refuses HTTPS/SVCB records), demuxes transparent `:443` by SNI and `:80` by Host so proxy-unaware tools cannot bypass it, resolves-then-checks (DNS rebinding), fails QUIC/UDP closed at L3, logs the *allow* side (`SANDY_EGRESS_LOG`), gates launch on a real healthcheck, and tears agent+proxy down atomically. The reference's proxy is a ~150-line Python CONNECT allowlist reached via `HTTPS_PROXY` | **Aligned, and stronger** |
| `bypassPermissions` inside the sandbox — the container is the boundary; auto mode only when unsandboxed | Identical reasoning (`harness/sandbox.py: permission_mode()` reads like sandy's own rationale). Sandy additionally re-pins every launch against Claude Code's auto-mode migration and reports drift (#151) | **Aligned** |
| Secrets never in `docker run` argv | `--env-file` in a 0600 file under a 0700 tmpdir (#13); the reference uses `-e KEY` read from the client env — equivalent | **Aligned** |
| Refuse to run unsandboxed; verify the sandbox is *up* before spawning agents | No unsandboxed mode exists. Proxy launch is health-gated on listeners binding; a configured relay that cannot start fails the launch; per-project `.sandy/Dockerfile` builds fail closed non-interactively; egress downgrades are approval-gated | **Aligned** |
| Per-container memory cap | `SANDY_MEM` / `SANDY_CPUS`; `--pids-limit` and `--memory` on the proxy | **Aligned** |
| No untrusted skills, plugins, or MCP servers; none that write to the outside world | claude.ai connectors suppressed by default (#129); `.mcp.json` and `.claude/settings*.json` mounted `:ro`. But `/plugin install` is allowed (rw `~/.claude`) and skill packs are fetched from GitHub (release-pinned). Sandy's posture is *allow with protections*, not prohibit — and the security review's R2 was found in this area | **Partial** |
| Match isolation to the task; **gVisor / Kata / Firecracker for anything that runs the target; "don't run autonomous agents in plain Docker (runc) — ordinary containers share your host's kernel"** | Sandy is runc plus hardening. On macOS (Docker Desktop / OrbStack) a Linux VM sits between the container and the host kernel regardless; on Linux the container shares the host kernel. No runtime-selection knob | **Diverges** → #127 |
| Default egress is the model API and nothing else (`api.anthropic.com:443`) | Default is **permissive** (all internet minus LAN / link-local / CGNAT / metadata). `SANDY_EGRESS_STRICT=1` still allows GitHub, npm, PyPI, crates, Go, Debian — which the blog, and sandy's own review (R3), name as exfil channels. No model-API-only posture exists | **Diverges** → #244 |
| **Never mount credential-bearing paths**; credentials via env only, scoped to the task | Sandy mounts `.credentials.json` (ephemeral, rw), seeds codex `auth.json` into the sandbox, mounts `~/.claude/hooks` `:ro`, and forwards **every** `gh` account's token. Mitigations the reference lacks: per-project credential sandboxes, `SANDY_SUSPICIOUS` refresh-token strip (#130), one-credential modes `SANDY_CLAUDE_AUTH=api_key\|profile`. The absolute rule cannot be met by a dev tool; the broker (#121) is the endgame | **Diverges, deliberately** → #246 (interim), #121 (endgame) |
| Pin everything — image tags, commit SHAs, dependencies, Claude Code version | Floating-latest for the wrapped agents, deliberately: auto-patch CVE posture over reproducibility (CLAUDE.md "Wrapped-agent CVE watch"). Proxy base is pinned to a supported Go minor with a monthly `--pull` | **Diverges, documented** |
| Clean slate per run; verifier in a fresh container with no shared filesystem | The container is fresh per launch; the **sandbox directory** (`pip/`, `npm-global/`, `.claude/plugins`) persists across sessions. Sandy documents this as a poisoning vector and ships `--reset-sandbox` | **Partial** |
| Verify isolation with concrete probes at setup (guest kernel ≠ host, host FS unreachable, API reachable, `example.com` blocked, direct egress blocked) | Sandy has the probes — `test/spike/macos-internal-network-spike.sh` A1d, integration §13b, the acceptance harnesses — but as **maintainer suites**. `--doctor` checks host readiness, not isolation; `/etc/sandy-session.json` records what was *pinned*, not what holds | **Gap** → #245 |
| Setup/attack phase split; snapshot then remove network | Image builds have network; sessions do not have a frozen snapshot and default to permissive egress. Closest analogue: `_sandy_build_allowed` (no build when build deps are unreachable) and the strict posture | **Partial** |
| Verifier independence, `<untrusted_data>` wrapping with per-call ids, human review of generated diffs | Pipeline practices. Sandy's analogues are structural: session-end protected-file detection, `SANDY_SUSPICIOUS` for a distrusted workspace | **N/A** |
| Usage marker header (`anthropic-cyber-runbook`), declared and removable | None; not applicable to a general launcher | N/A |

## 3. Where sandy exceeds the reference

Stated because it is true and bears on "alignment", not to soften §4. The reference has nothing resembling:

- **Protected-file mounts** (`.bashrc`, `.gitconfig`, `.git/hooks`, `.github/workflows`, IDE configs, submodule gitdirs, `core.hooksPath`) with **session-end detection** of newly created ones, and **symlink-escape approval** — because it never mounts a workspace.
- **Config tiering**: a committed repository config cannot loosen the sandbox. The reference's `config.yaml` is trusted operator input.
- **The attestation marker** `/etc/sandy-session.json` (`:ro`): an in-container proof of *being* in sandy and at what posture, with a per-launch nonce.
- Read-only rootfs, capability drop, `no-new-privileges`, pids limits.
- macOS support at all (the reference is Linux-only; it tells macOS users to use a VM or `--dangerously-no-sandbox`).
- Proxy provenance: built from the local checkout's audited source (`COPY`), not fetched at build time.

## 4. The four gaps, ranked, with their issues

1. **gVisor runtime — #127.** The reference's headline rule and the one sandy plainly does not meet on Linux. The reference is also *evidence*: it runs runsc + `--internal` + a CONNECT proxy in production, so gVisor's netstack carries CONNECT; sandy's transparent SNI/Host demux and DNS responder remain the spike. Two requirements copied from the reference are load-bearing: `--overlay2=none` (else `docker exec` cannot see in-container writes — sandy's tmux probe, `sandy-handoff-sessions`, and every harness depend on `docker exec`), and the `--ignore-cgroups` fallback for rootless/nested Docker (loses `--memory`; must be said out loud). Design input filed on the issue: a security knob that is configured but unavailable should fail the launch, not warn — the same rule sandy applies to a relay that cannot start.
2. **Model-API-only egress — #244.** Cheap; closes the registries-as-exfil channel the review already named; the natural default under `SANDY_SUSPICIOUS=1`.
3. **One gh account per sandbox — #246.** The R3 slice that does not need the broker. `SANDY_CLAUDE_AUTH=api_key\|profile` (1.10.0/1.11.0) already did the equivalent for Claude.
4. **`sandy --verify-isolation` — #245.** The reference's setup probes as a user command, run through the real launch assembly, asserting the *configured* posture, mutation-tested, and making the attestation marker checkable rather than merely readable.

## 5. Not comparable, and why that matters

Rows marked N/A are not sandy shortfalls; they are the reference doing its own job. If sandy is used to host a vuln-hunting pipeline, those practices belong in the pipeline, not the launcher — but the launcher should make them *possible*: a fresh container per verifier is a `sandy -p` launch; egress locked to the API is #244; the target living only inside an image is a `.sandy/Dockerfile`.

## 6. Cultural note

The reference states its residuals plainly — *"a mitigation, not a guarantee"*, *"`--ignore-cgroups`: container `--memory` caps are not enforced"*, *"Vertex support is currently untested"*. Sandy's documentation does the same throughout (every "Honest limits", "Residual, stated rather than glossed"). The philosophies match. The gaps in §4 are mechanisms, not attitude, and each has a testable acceptance criterion on its issue.
