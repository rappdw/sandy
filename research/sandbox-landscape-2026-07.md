# sandy — competitive positioning brief: the AI-coding-agent sandbox / isolation landscape

*Researched 2026-07-04. Every row is cited; unverified items are flagged in Caveats.
Surfaced from a LinkedIn launch-thread exchange (a prospect referenced Daytona +
nool.dev). Companion to `POSITIONING-DEEP-DIVE-2026-07.md` and
`per-project-isolation-landscape.md`.*

## 1. Comparison table (sandbox / runtime-containment category)

| Tool | Open source? | Local vs cloud | Isolation tech | Runtimes / platforms | Pricing (free tier?) | Target user |
|---|---|---|---|---|---|---|
| **sandy** *(reference)* | Yes, MIT | **Local** (your machine) | Container hardening: `--cap-drop ALL`, read-only rootfs, `--internal` net + egress-proxy sidecar, ephemeral per-project cred mounts | **Any `docker` CLI**: Docker Desktop, Rancher, Colima, Lima, OrbStack; macOS + Linux | **Free** (self-hosted) | Individual dev running coding agents locally |
| **Daytona** | AGPL-3.0, but **repo frozen — core went closed-source June 2026** [1][2] | **Cloud/SaaS** first (managed infra; on-prem for enterprise) [1][3] | "Full composable computer" — dedicated kernel/FS/net stack (microVM-class) [3] | Managed cloud (regions); on-prem for enterprise [3] | Cloud free tier: $200 credits + 5 GB, then per-second (~$0.083/hr for 1vCPU+2GB) [4] | Agent builders / enterprise fleets [3] |
| **Docker Sandboxes** (`sbx`) | Not stated (appears closed tool) [5] | **Local** (standalone `sbx` CLI) [5] | **microVM** per sandbox (own kernel/daemon/FS/net); host-side credential proxy [5][6] | Standalone CLI, **not** Docker-Desktop-required; macOS + Windows installers shown, Linux unclear [5] | Free core; **paid** team admin (net/FS policy) [5] | Dev running coding agents in "YOLO mode" [7] |
| **E2B** | Yes, OSS core [8] | **Cloud/SaaS** (self-host = enterprise) [8] | **Firecracker microVM** (<200ms start, up to 24h) [8] | Cloud SDK; BYOC/on-prem/self-host on Enterprise [8] | Hobby free ($100 one-time credit); Pro $150/mo; Enterprise custom [8] | Agent/LLM-app builders, enterprise [8] |
| **Modal** | No (closed SaaS) [9] | **Cloud/serverless** | Sandboxes within broader ML infra; ~25ms cold start [9] | Cloud only; Python-first | $200 free credit, then per-second; **sandbox rate ~3× base** [9] | Enterprise / GPU + agent workloads [9] |
| **hopx.ai** | Partial (GitHub org exists) [10] | **Cloud** (also powers Bunnyshell's sandbox infra) [11] | **Firecracker microVM**, ~100ms [10] | Cloud; Python/JS/Go [10] | $200 early credits; per-second rates **contact-sales** [10] | Agent builders [10] |
| **Bunnyshell** | No (commercial EaaS) [11] | **Cloud** + **self-host onto your own k8s** [11] | Firecracker microVM sandboxes; ~100ms [11] | Deploys to your Kubernetes (AWS/GCP/Azure/on-prem) [11] | $0.007/min running; $0 sleeping [11] | Teams / enterprise [11] |
| **yoloai** (kstenerud) | Yes (Go; license unconfirmed) [12] | **Local** (disposable docker container) | Container, but **all caps + seccomp/AppArmor unconfined** (deliberately permissive; relies on disposability) [12] | Local docker; multi-agent (Claude/Codex/Gemini/Aider/OpenCode) [12] | Free | Individual dev wanting throwaway "full-send" containers [12] |

## 2. Where sandy sits

sandy occupies a distinct whitespace: **local, runtime-agnostic, free/OSS, individual-developer-first runtime containment expressed as one auditable bash script over standard `docker run` primitives.** The cloud players (Daytona, E2B, Modal, hopx, Bunnyshell) all optimize a different axis — *elastic fleets of ephemeral microVMs* for programmatic, at-scale agent code execution, billed per-second — which is genuinely stronger for cloud burst, thousands of concurrent sessions, and team governance/audit trails, but means your code leaves your machine and you pay to run. Against the *local* peers, sandy's differentiators are sharper: **Docker Sandboxes** delivers stronger microVM isolation but is a closed `sbx` binary with paid team controls and no clear Linux story, whereas sandy is fully inspectable and cross-runtime; **yoloai** shares the local-OSS-disposable model but runs *unconfined* (all caps, seccomp/AppArmor off) and leans on throwaway containers, where sandy instead *hardens* the container (cap-drop, read-only rootfs, network egress control, credential trust-tiering). Be honest about the trade: a shared-kernel hardened container is a weaker boundary than a per-sandbox microVM — the microVM crowd wins on raw isolation strength and on managed scale; sandy wins on auditability, zero cost, no data egress, and "works on the docker you already have."

## 3. One-line positioning statement

> **sandy is the free, open-source, single-script way to run any coding agent inside a hardened local Docker container — runtime containment you can audit line-by-line, on the Docker you already have, with nothing leaving your machine.**

(Alt, sharper contrast: *"The cloud sandboxes rent you a microVM fleet; sandy hardens the container on your own laptop — auditable, free, and offline-friendly."*)

## 4. nool complement note (governance — NOT a competitor)

nool.dev operates at a **different layer**: it bounds blast radius on the *codebase*, not the *machine*. It does semantic blast-radius / intent-drift analysis of an agent's diff against its declared scope, Git-native, with an immutable intent ledger (`nool propose` / `blast-radius` / `visualize`) — commercial, hybrid local-eval + SaaS [13]. It answers "did the agent change more than it was supposed to?", while sandy answers "the agent physically cannot touch your host, network, or credentials." They **stack**: run sandy for runtime containment and nool for change governance — complementary guardrails, not overlapping ones.

## 5. Caveats (unverified / soft)

- **Daytona OSS status is the big one:** the AGPL-3.0 repo is still public and forkable, but Daytona explicitly announced going closed-source, with the public repo receiving **no further updates/fixes/releases as of June 2026** [1][2]. Treat "Daytona is open source" as *effectively deprecated OSS + closed cloud product*. Its exact isolation tech (microVM vs. hardened container) is described as "dedicated kernel" but never explicitly named [3].
- **Docker Sandboxes:** product page says Docker Desktop is *not* required and it installs standalone [5] — so an earlier assumption of Docker-Desktop-lock is **wrong**; correct the pitch accordingly. But its OSS status is **not stated** (appears to be a closed tool with its own bundled microVM runtime), and no Linux installer is shown — both unconfirmed.
- **hopx.ai / Daytona / Modal exact pricing:** hopx per-second rates are contact-sales / not marketplace-verified [10]; Modal's effective sandbox cost carries multipliers over advertised base [9] — cite as "per-second, premium applies," not exact.
- **yoloai license** (MIT vs other) not confirmed from the search snippet — verify on the repo before quoting [12].
- **E2B self-host** exists on Enterprise (BYOC/on-prem) but practical difficulty/cost not established [8]; "OSS core" is accurate but self-hosting the full stack is non-trivial.
- All per-second cloud prices are **as-advertised** and move; re-check before publishing.

## Sources

[1] https://github.com/daytonaio/daytona · [2] https://www.daytona.io/dotfiles/updates/daytona-is-going-closed-source · [3] https://www.daytona.io/ · [4] https://blaxel.ai/blog/daytona-dev-environment-pricing-alternatives · [5] https://www.docker.com/products/docker-sandboxes/ · [6] https://docs.docker.com/ai/sandboxes/security/isolation/ · [7] https://www.docker.com/blog/docker-sandboxes-run-agents-in-yolo-mode-safely/ · [8] https://e2b.dev/ · [9] https://modal.com/resources/best-code-execution-sandboxes-ai-agents · [10] https://hopx.ai/ · [11] https://www.bunnyshell.com/ai-sandbox-environments/ · [12] https://github.com/kstenerud/yoloai · [13] https://www.nool.dev/
