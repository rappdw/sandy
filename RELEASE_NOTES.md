## sandy v0.15.2

**Claude auth: honor the OAuth-first preference.** A small but billing-relevant correctness fix. No new features, no new config keys.

Claude Code's own auth precedence resolves `ANTHROPIC_API_KEY` **ahead of** `CLAUDE_CODE_OAUTH_TOKEN`. So if you had *both* set (e.g. in `~/.sandy/.secrets`), sandy forwarded both and the **API key silently won** — routing you to per-use API billing and bypassing your OAuth/subscription path, even though sandy's documented probe order advertises OAuth-first.

Now, when a long-lived OAuth token (`claude setup-token`) is configured, sandy forwards **only the token** and **suppresses `ANTHROPIC_API_KEY`**, with a launch warning:

> `CLAUDE_CODE_OAUTH_TOKEN is set; not forwarding ANTHROPIC_API_KEY (it would take precedence in Claude Code and bill per-use). Unset the token to use the API key instead.`

The API key is still forwarded when no OAuth token is set, and `CLAUDE_CODE_OAUTH_TOKEN=` is still emptied to block host-env leakage. The opencode provider-key path (non-claude agents reading `ANTHROPIC_API_KEY`) is unaffected. Sandy's `--print-schema` probe order is now accurate in practice.

Guarded by `run-tests.sh §52(e)` (source structure + warning) and `run-integration-tests.sh §17` (runtime: the warning fires and the forwarded `RUN_FLAGS` carry the token but not the key).

---

## sandy v0.15.1

**Egress-proxy resilience + diagnosability.** A patch release hardening the egress proxy against the failure that surfaced during the 0.15.0 soak: the agent getting stranded with every request failing `FailedToOpenSocket`. No new features, no new config keys.

### The stranded-agent failure, fixed three ways

The proxy is the agent's only route off the `--internal` sidecar, so anything that removes or kills it strands the agent until the next launch. Three independent mechanisms could cause that, each now addressed:

- **Killed session left the agent running.** The agent runs `docker run --rm` in the foreground, but the container's lifetime belongs to the daemon — so a killed `docker run` client (closed terminal, dropped SSH, SIGHUP) left the agent running while `cleanup()` tore down its proxy. `cleanup()` now removes the **agent container first**, making agent + proxy teardown atomic.
- **Proxy died under a live agent.** The proxy launched with no restart policy, so a crash/OOM/reap was fatal for the rest of the session. It now runs with **`--restart on-failure:5`**; because the sidecar leg is pinned with a fixed `--ip`, the daemon resurrects it on the **same address** and the agent self-heals without a restart. The readiness gate now polls (rather than taking one instantaneous snapshot), catching a start-then-die proxy.
- **A panicking connection crashed the whole proxy.** The proxy runs one goroutine per connection over untrusted wire bytes (TLS ClientHello / HTTP Host), and an unrecovered panic in any goroutine crashes the entire Go process. Each per-connection handler is now wrapped in a panic-recovering `guard()` that recovers, logs the panic + stack, and drops just that connection — mirroring `net/http`'s Server.

### Diagnosing a proxy death

Proxy logs were ephemeral (wiped by the `docker rm -f` in `cleanup()`). Sandy now **streams the proxy's logs to `$SANDBOX_DIR/proxy.log`** (surviving teardown) and appends the container's final exit state, so an OOM (`oom=true`, exit 137) is distinguishable from a panic (non-zero exit + a `guard()` stack in the log) or an external kill.

### Test-harness safety

The integration suite assumed no concurrent real session existed. Running it alongside a live sandy session could **force-remove that session's proxy** (a substring `name=sandy-proxy-` filter), and its address-pool-leak assertion false-failed on the real session's networks. The harness now scopes all reaping/sweeping to throwaway `tmp.*` test resources and diffs the leak check against a pre-run baseline — so the suite never disturbs or false-fails on a real session.

---

## sandy v0.15.0

**M4 — surface stabilization + fail-cleanly hardening.** The last functional milestone before the 1.0 pre-RC soak. No new features and no new config keys (the freeze holds); this release locks down the *surface* sandy promises to keep stable through 1.x, makes the common launch failures fail with an actionable message instead of a cryptic one, and pins the multi-agent routing contract under test. Plus two bug fixes that surfaced during the 0.14.0 proxy soak.

### Stability surface declaration (PR 4.1)

Every config key now carries a **`since`** version and a **`stability`** tier (`stable` / `experimental`) in its schema metadata. `sandy --print-schema` emits both fields per key, and the auto-generated config tables in `CLAUDE.md` / `SPECIFICATION.md` gained **Since** and **Stability** columns. This is the machine-readable contract for what 1.0 promises not to break. Also: the `.sandy_created_version` sandbox marker is now regex-validated on read (a corrupt marker is treated as "unknown", not a crash), and the dead `CODEX_HOME` key was removed from the passive allowlist.

### Sandbox forward-compatibility promise (PR 4.2)

From 1.0, **a sandbox created by any `1.x` sandy works with any later `1.x` sandy.** The mechanism is `SANDY_SANDBOX_MIN_COMPAT` as a **hard floor**: a sandbox created *provably below* the floor now causes sandy to **refuse to launch** with the exact recreation command, instead of the pre-1.0 warn-and-limp (which let an incompatible sandbox run into silently-broken cached paths). Uncertainty fails open — an unknown or unreadable marker warns but launches. The promise constrains the floor itself: within `1.x`, `SANDY_SANDBOX_MIN_COMPAT` never advances above `1.0.0`; a layout change that would break a `1.x` sandbox is a `2.0` change.

### Fail cleanly, not cryptically (PR 4.4)

Three common launch failures used to produce confusing errors deep in the launch path. Sandy now catches them at preflight with a specific, actionable message and a non-zero exit:

- **Docker daemon down** (vs. not installed) — `docker info` probe → "the daemon isn't responding" + how to start it.
- **Corrupt `~/.claude/.credentials.json`** — validated as JSON before use; with no token present sandy prints a re-authenticate hint and exits; with a valid `CLAUDE_CODE_OAUTH_TOKEN` it drops the bad file and continues.
- **Read-only `$SANDY_HOME`** — a write-probe at preflight → "is not writable" + a `chmod u+rwx` hint, before any Docker work.

SPEC §E.1 documents the full guard table.

### Multi-agent matrix tests (PR 4.3)

The routing contract a multi-agent combo depends on is now pinned under test: `run-tests.sh §54` asserts that a combo selects the `sandy-full` superset image and that headless (`-p`) mode routes the prompt to the **first** agent only — for every combo in the matrix, without needing Docker. `run-integration-tests.sh §16` runs one live combo end-to-end and asserts the superset image was used. The interactive multi-pane cells stay manual (a multi-pane session needs a TTY to observe) and are tracked in `TESTING_PLAN.md` §4.0 with an RC sign-off checklist.

### Bug Fixes

**Egress-proxy concurrent-session ceiling 4 → hundreds** — the proxy sidecar picked its fixed IP from a hardcoded pool of 4 `/24`s, so the 5th concurrent proxied session on a host would fail to launch. The candidate pool is now every `/24` in `10.200.0.0/16` + `10.201.0.0/16` (plus two legacy `/24`s), ~512 in all, and on exhaustion sandy first reaps its own orphaned proxy networks (left by a SIGKILL'd session) and retries once. The proxy container is also now named `sandy-proxy-<sandbox-name>` (was PID-keyed), so `docker ps` shows a proxy right next to its session and an orphan is traceable to the workspace that leaked it.

**Expired host credential file forced a login prompt under `CLAUDE_CODE_OAUTH_TOKEN`** — when a long-lived OAuth token was set *and* the host's `~/.claude/.credentials.json` had expired, sandy mounted the expired file alongside the token and Claude Code prompted for login. Sandy now detects the expired-file case and skips mounting it when the token is present, so the token path works cleanly.

---

## sandy v0.14.0

**Cross-platform network isolation — the egress proxy (M2.7).** sandy now routes the agent through an `--internal` proxy sidecar, giving real network isolation on **both macOS and Linux** for the first time. Previously, macOS Docker Desktop provided no LAN isolation at all — an agent could reach your router, NAS, localhost services, and cloud-metadata endpoints. This release closes that gap (finding F2 from the isolation stress test).

### `SANDY_EGRESS_PROXY` — tri-state, default-on

| Value | Mode | Behavior |
|---|---|---|
| `1` (new default) | permissive | Blocks private/LAN/host/cloud-metadata destinations; allows all public internet. |
| `2` | strict | Allows only a built-in default allowlist (model providers, GitHub incl. SSH, npm/PyPI/crates/Go/Debian) + `SANDY_ALLOW_HOSTS`. |
| `0` | off | Legacy behavior: Linux iptables only; macOS has no isolation (warns at launch). |

The agent runs on a Docker `--internal` network with no route off it except through a dual-homed `sandy-proxy` sidecar — a tiny Go binary (`golang`→`scratch`, `--read-only --cap-drop ALL`). The proxy does DNS-redirect + transparent SNI/Host demux (TLS is **never** terminated — no MITM, no cert surgery) + CONNECT for git-over-SSH. Because it relies on `--internal` routing rather than iptables, it behaves identically on macOS and Linux.

- **macOS:** real network isolation by default, where there was none before.
- **Linux:** a security upgrade over the iptables path — closes DNS exfil and host-gateway reach, a single auditable chokepoint, no `sudo` required. The iptables path remains available as `SANDY_EGRESS_PROXY=0`.

**Extending reach:** `SANDY_ALLOW_HOSTS` (comma-separated `host`, `*.suffix`, or `host:port`) adds hosts to the allowlist beyond the defaults.

**Caveat worth knowing:** the permissive proxy carries HTTP/HTTPS, git-over-SSH, DNS, and the local-LLM forward — not arbitrary ports. A public host on a non-standard port (e.g. `:5432`, `:8443`) that worked under the old iptables path now needs `SANDY_ALLOW_HOSTS` (or `SANDY_EGRESS_PROXY=0`). On macOS, host-agent SSH key *signing* is unavailable under the proxy (git-over-SSH still works) — use `SANDY_SSH=token` for a fully-supported path.

### Also in this release

- **Headless agents no longer allocate a pseudo-TTY**, and stdin is attached only when actually piped. This fixes a Gemini busy-loop and a `codex exec` stdin block in `-p` mode — the long-standing cause of headless/CI hangs across agents.
- **Local-LLM passthrough** (`SANDY_LOCAL_LLM_HOST`) is forwarded through the proxy, no iptables hole needed.

See `CLAUDE.md` → "Egress Proxy", `SPECIFICATION.md` → "Egress Proxy (M2.7)" for the full design, and `TESTING_PLAN.md` §6 for the manual macOS validation checklist.

---

## sandy v0.13.0

M3 milestone — architectural cleanup. Two refactors that pay down structural debt the 1.0 code review surfaced, plus a default-model bump. No new features, no new config keys; the only user-visible change is the default Claude model.

### Architectural cleanup (M3)

**PR 3.1 — `user-setup.sh` heredoc mirrored to a lintable template.** The ~860-line bash heredoc inside `generate_user_setup()` (the script that runs container-side after Docker hands off) was unshellcheckable as a string literal — 860 lines of container-side bash no static analyzer had ever seen. It's now mirrored verbatim to `templates/user-setup.sh.tmpl`, which `shellcheck` lints as a real file with zero-warning enforcement in CI. The sandy script's embedded heredoc remains the source of truth, so single-file install and `sandy --upgrade` are unaffected — the template is a derivative used only for review and lint, kept in sync by a `test/regen-template.sh` drift check. shellcheck found and fixed 4 latent issues on first run (3 style, 1 SC2155 return-value masking); all behaviorally verified equivalent.

**PR 3.2 — `build_*_cmd` functions unified.** The four per-agent command builders (`build_claude_cmd`, `build_codex_cmd`, `build_opencode_cmd`, `build_gemini_cmd`) duplicated two concerns: a per-agent arg-translation loop (`-p`/`--print`/`--prompt`/`--continue` handling, which differs per agent) and an identical tmux-interactive exit-pause trailer (differing only in the agent label). Both extracted into shared helpers — `_sandy_translate_args` and `_sandy_wrap_cmd_exit_pause` — so the four agents stay in lockstep when new flags are added. Verified byte-identical output across all 80 input combinations (4 agents × 2 headless × 2 verbose × 5 arg patterns); no behavior change.

### Default model: `claude-opus-4-7` → `claude-opus-4-8`

The out-of-box default Claude model is now `claude-opus-4-8` (was `claude-opus-4-7`). This is an undated stable alias, so it auto-rolls forward to the latest 4.8 snapshot as Anthropic ships them; a future 4.9 will need another bump. Override per-user in `~/.sandy/config`, per-workspace in `.sandy/config`, or per-launch via `SANDY_MODEL=...` / `--model`. (README's table was also corrected — it had drifted to showing `claude-opus-4-6`.)

### Documentation

- **`CLAUDE.md`**: "user-setup.sh template mirror" subsection documenting the `test/regen-template.sh` workflow.
- **`SPECIFICATION.md`** / **`SPEC_INTROSPECTION.md`**: config-key default updated to `claude-opus-4-8`.

---

## sandy v0.12.0

A re-baseline cut. Between `v0.11.4` (2026-04-15) and this tag (2026-05-16), the "no new features until 1.0" rule from `ROADMAP_1.0.md` quietly stopped holding — useful work landed but it cumulatively reset the stability soak that 1.0 was meant to gate on. Rather than continue and pretend the roadmap was intact, `v0.12.0` formalizes a new feature-freeze point. Every milestone downstream of here (M3 heredoc extract → M2.7 egress proxy sidecar → M4 surface stabilization → M5 14-day pre-RC soak → `1.0.0-rc1`) now targets the version one minor higher than the original plan, and the 7-day M2.3 soak clock restarts against this tag. See the updated `ROADMAP_1.0.md` "Re-baseline (2026-05-16)" section for full context.

The work itself is solid — most of it has been daily-driven for weeks. The reset is about process honesty, not code quality.

### New: 4th agent (OpenCode)

`SANDY_AGENT=opencode` (single-agent) or `claude,opencode` / `all` (multi-agent combos) now works. New `sandy-opencode` image layers `opencode-ai` on top of `sandy-base`; multi-agent combos use the existing `sandy-full` image (now bundling all four CLIs). Tmux layout extended to 4 panes when all four agents are selected. Per-agent infrastructure:

- **Config keys**: `OPENCODE_MODEL` (provider/model format like `anthropic/claude-sonnet-4`), `SANDY_OPENCODE_AUTH` (auto/api_key/oauth), `CODEX_HOME` (override for `$CODEX_HOME` inside container).
- **Credential probe order**: env-provider keys first (since opencode reads `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`GEMINI_API_KEY`/etc. natively), then host `~/.local/share/opencode/auth.json` mounted `:ro`.
- **Sandbox layout**: opencode uses two XDG paths (`~/.config/opencode` and `~/.local/share/opencode`), so the sandbox dir has `opencode/{config,share}/` subdirs that mount accordingly.
- **Headless mode**: `-p`/`--print`/`--prompt` translate to `opencode run <prompt>`. `--continue`/`-c` silently dropped (no headless continuation in upstream opencode).
- **`SANDY_AGENT=both` alias removed** (had been deprecated). Use comma-separated combos; `all` is the alias for `claude,gemini,codex,opencode`.

### New: local-LLM passthrough (`SANDY_LOCAL_LLM_HOST`)

Set `SANDY_LOCAL_LLM_HOST=127.0.0.1:11434` (or any `host:port`) to open a single narrow iptables ACCEPT rule for that exact host+port against the Docker bridge gateway, allowing an in-container agent (typically OpenCode) to reach a local LLM server (Ollama, vLLM, etc.) without disabling LAN isolation entirely. Validates format, rejects world-open IPs (`0.0.0.0`, `::`) and out-of-range ports, and on Linux adds `--add-host=host.docker.internal:host-gateway` so the hostname resolves (Docker Desktop already does this on macOS).

Companion: when `SANDY_LOCAL_LLM_HOST` is set and the host has no `~/.config/opencode/opencode.json`, sandy now auto-generates one from a `curl http://host:port/v1/models` probe. Defines a `local` provider via `@ai-sdk/openai-compatible` pointing at `http://host.docker.internal:<port>/v1`, registers the served model id, and pins it as default. To customize, copy the generated config to `~/.config/opencode/opencode.json` and sandy will prefer the host file thereafter.

### New: `/ss` screenshot skill (cross-agent)

Set `SANDY_SCREENSHOT_DIR=<host-path>` (passive-safe, in `~/.sandy/config` or per-workspace `.sandy/config`) to mount a host folder of screenshots into the container at `/home/claude/screenshots` (read-only). When set, sandy generates a per-agent `/ss` skill at sandbox setup so the agent can "see" what the user just captured:

| Agent | Invocation | Format |
|---|---|---|
| `claude` | `/ss [N] [action]` | slash command |
| `gemini` | `/ss [N] [action]` | slash command (TOML) |
| `codex` | "look at my recent screenshot" | description-matched skill |
| `opencode` | manual: `opencode "explain $(sandy-ss-paths 1)"` | no slash-command surface in v0 |

Powered by `/usr/local/bin/sandy-ss-paths` (baked into the base image), which lists newest N image paths from `$SANDY_SCREENSHOTS_PATH`. Validation rejects shell metacharacters, literal `$HOME` or `/`; a non-existent directory warns and skips rather than letting Docker auto-create a stub on the host.

### New: user-defined env passthrough (`SANDY_EXTRA_ENV`)

Forward arbitrary env-var names from the host into the container, for tokens consumed by user-installed MCP servers or other in-container tooling that sandy has no opinion on. Set `SANDY_EXTRA_ENV=HA_TOKEN,LINEAR_API_KEY` in `~/.sandy/config` (privileged tier) or env, put the values in `~/.sandy/.secrets` (or `<workspace>/.sandy/.secrets`, or env), and they propagate. Source resolution order: env > workspace `.sandy/.secrets` > workspace `.sandy/config` > `~/.sandy/.secrets` > `~/.sandy/config`. Security boundary lives on the names (privileged tier triggers passive-privileged approval prompt from workspace sources); values can come from anywhere once the name is approved.

### New: introspection surface

Three machine-readable JSON commands for UI frontends, CI, and shell completions:

- `sandy --print-schema` — static schema: sandy version, config keys by tier (with type/default/description), CLI flags, agents + credential probe orders, protected path lists, skill packs, `schema_version: 1`.
- `sandy --print-state` — runtime state: installed images, per-sandbox metadata, approval files, `docker_reachable`, running sandy containers (filtered by image name prefix).
- `sandy --validate-config PATH` — parses a config file, classifies as privileged or passive by path, reports errors / unknown keys / privileged-from-passive keys requiring approval / target approval file path.

All three are fast-path handlers that exit before Docker, image builds, and workspace mutex acquisition — cheap to call from non-interactive contexts. Stability contract documented in the new `SPEC_INTROSPECTION.md`. Companion: `CLAUDE.md` and `SPECIFICATION.md` now embed config-key tables generated from `--print-schema` (regenerate with `test/regen-config-docs.sh`); test suite asserts no drift.

### Behavior change: hybrid protected-dirs model

The v0.11.1 S1.2 "always-mount with empty-fixture for absent protected directories" pattern is reverted. Both files and directories are now symmetrically existence-gated:

- Path exists on host → bind-mount `:ro` (kernel-level write prevention, no host artifact).
- Path absent → no mount. Agent CAN create files there during the session.

The replacement defense is **session-end detection**: sandy snapshots which protected dirs existed at launch in `$SANDBOX_DIR/.protected-existed-at-launch`, and on session exit walks the same paths looking for new appearances. Anything with content that didn't exist at launch produces a yellow warning naming the path with `rm -rf` remediation. No automatic deletion — we don't know whether the agent's write was legitimate ("set up `.vscode/settings.json` for this project") or a prompt injection.

Trade-off: weaker protection for paths the host doesn't have. The threat window is "between session end and the user's next operation that auto-executes that path" (`git pull` for hooks, `git push` for CI, IDE open for `.vscode`). For the realistic threat model — agent occasionally wrong via prompt injection or skill bug, not actively adversarial — detection at session end is sufficient.

Long-term direction (documented in `CLAUDE.md` "Protected Files" → "Long-term: `fanotify` FAN_OPEN_PERM"): kernel-level interception of write attempts via `fanotify` permission events. True prevention with no host artifact even for absent paths, honest `-EPERM` to the agent. On the roadmap, unscoped pending evidence the detection model is insufficient.

The legacy pre-existing-debris auto-cleanup at launch is unchanged — workspaces touched by older sandy versions get their empty stubs `rmdir`d under the 4-condition safety gate.

### Behavior change: workspace canonicalization + lock probing + env precedence

Workspace paths are now canonicalized via `pwd -P` for sandbox-name hashing — resolves symlinks and folds case-collisions on case-insensitive filesystems (default macOS APFS). So `cd ~/dev/myproject` and `cd ~/Dev/myproject` from the same physical directory now produce the same sandbox. Each sandbox writes `WORKSPACE.json` (non-hidden, visible in plain `ls`) recording the canonical path, the user-typed path (when different), and first/last launch timestamps + sandy versions. On launch sandy scans sibling sandboxes for matching `workspace_path` and warns when duplicates are found — manual cleanup only, no auto-merge.

Workspace mutex (`mkdir`-based lock on `$SANDY_HOME/sandboxes/.<name>.lock`) now records the holder PID and on second-launch contention probes liveness via `kill -0`. Stale locks (process died with `kill -9` or OOM) auto-clear; live locks fail fast with a clear error naming the pid. Theoretical PID-reuse case (OS recycled holder's PID to an unrelated process) prefers the false-positive error over a false-negative clobber.

Env var snapshot fix (`_SANDY_ENV_SET_KEYS`): before loading any config file, sandy snapshots which allowlisted keys are already in the process env, and subsequent file-load passes skip those keys. Lets `KEY=value sandy ...` and shell-level `export` cleanly override both host and workspace config. Previous behavior had a subtle bug where the first config-load pass exported values that later passes treated as "already set" — workspace config could never override host config.

### Bug Fixes

**Synthkit no longer treated as a plugin** — Earlier sandy installs recommended `/plugin install synthkit@sandy-plugins`; synthkit has since moved to a regular CLI tool (`uv tool install synthkit`) baked into the base image. The settings.json seed now strips deprecated `synthkit`, `synthkit@sandy-plugins`, and `synthkit@thinkkit` entries from `enabledPlugins` on every launch, silencing the confusing "✗ failed to load · 1 error" in `/plugin` for users carrying over old enablements. Idempotent and silent — no-op when those keys aren't present.

**Gstack state now per-workspace** — `~/.gstack/` inside the container is bind-mounted from `<workspace>/.gstack/` (host) rather than `$SANDBOX_DIR/gstack/`. Visible alongside `.git/` and `.venv/` and properly per-workspace (was per-sandbox-identity before, which collided with case-collision sandbox shares). One-shot migration on first launch after upgrade: existing `$SANDBOX_DIR/gstack/` content is `cp -a`'d to the new location and the legacy dir is renamed `gstack.migrated/` for manual cleanup. `git check-ignore` is consulted at launch (with `.gitignore` grep fallback) to warn if the workspace isn't yet gitignoring `.gstack/`.

**Codex default model bumped to `gpt-5.5`** — was `o4-mini`. New `~/.codex/config.toml` seeding writes `model = "gpt-5.5"` plus a full `[notice]` block suppressing first-run prompts. Existing `config.toml` files preserved (idempotent merge).

**Claude bypass-permissions on Claude Code 2.1.x** — Claude Code 2.1.x added a runtime gate that made the `--bypass-permissions` CLI flag insufficient on its own. Sandy now also sets `permissions.defaultMode = "bypassPermissions"` in `settings.json` when `SANDY_SKIP_PERMISSIONS=true` (and clears it on toggle to false). The settings value is the definitive source; CLI flag alone no longer suffices.

### Documentation

- **`CLAUDE.md`**: new sections for OpenCode (agent table, credential probe order, sandbox layout), `SANDY_LOCAL_LLM_HOST` (LAN-isolation interaction, opencode auto-config flow), `/ss` screenshot skill (per-agent UX table), `SANDY_EXTRA_ENV` (source-resolution order, security boundary), hybrid protected-files model (current + fanotify long-term direction). Existing sections updated to four-agent reality.
- **`SPECIFICATION.md`**: new Appendix E.11a (screenshot mount), E.11b (extra-env passthrough); §7 `user-setup.sh` step 4a for `/ss` skill seeding; agent and Dockerfile sections expanded for opencode; protected-files mount policy section rewritten for the hybrid model.
- **`README.md`**: env-var table additions (`SANDY_LOCAL_LLM_HOST`, `SANDY_SCREENSHOT_DIR`, `SANDY_EXTRA_ENV`, `OPENCODE_MODEL`, `SANDY_OPENCODE_AUTH`), new "Screenshot skill (`/ss`)" subsection, OpenCode agent section, plugin-marketplace section rewritten to clarify synthkit-is-no-longer-a-plugin.
- **`SPEC_INTROSPECTION.md`**: new file documenting the stability contract for `--print-schema` / `--print-state` / `--validate-config` JSON output.
- **`ROADMAP_1.0.md`**: re-baseline section added documenting the 8 off-roadmap features that shipped between `v0.11.4` and `v0.12.0`, with all downstream milestones shifted one minor version.

---

## sandy v0.11.4

Finishes the v0.11.2 protected-directories walk-back by removing the empty-stub debris those mounts leave on the host workspace. v0.11.2 accepted that "empty directories are benign on the host" as justification for always-mounting protected dirs with an empty-ro fixture; in practice the leftover `.vscode/`, `.idea/`, `.circleci/`, `.devcontainer/`, `.github/workflows/`, `.git/hooks/`, `.git/info/`, and `.claude/` stubs accumulated in every workspace sandy touched, cluttered `ls`, and misled tooling that treats directory presence as a signal.

### Bug Fixes

**Empty stub directories left behind on the host workspace** — Docker's bind-mount target auto-creation creates the host-side mountpoint for every `:ro` overlay sandy applies beneath the rw workspace bind. When the workspace had no `.vscode/` (etc.) before launch, sandy's ro overlay caused Docker to materialize an empty dir at that path, and nothing ever removed it. Added two cleanup mechanisms:

1. **Session-scoped cleanup.** Every stub sandy creates this session is appended to `$SANDBOX_DIR/.session-created-stubs`. The `cleanup()` EXIT trap reads the list and `rmdir`s each entry (plus walks the parent chain up to — but not including — `$WORK_DIR`, to catch cases like `.github/` after `.github/workflows/` was removed). `rmdir` no-ops on populated dirs, so legitimate in-session writes survive. Moved to the top of `cleanup()` so nothing earlier in the trap can short-circuit it. Covers the protected-dirs loop, submodule-gitdir `hooks/` fallback, the `.claude/{commands,agents,plugins}` and `.gemini/{extensions,commands}` sandbox overlays, and `.claude/` itself (which `user-setup.sh` unconditionally `mkdir -p`s inside the container).

2. **Pre-existing debris cleanup.** Workspaces touched by earlier sandy versions are already littered. On launch, sandy walks the protected-dirs list and `rmdir`s any that are empty and, in a git repo, untracked. Initial design gated this on "is a git repo" — relaxed because a workspace whose only `.git/` content is empty stubs of `.git/hooks` and `.git/info` isn't detected as a repo by `git rev-parse`, so debris in those workspaces persisted forever. Name-match against the small protected-dirs list + empty check is a sufficient safety bar on its own.

3. **Empty host dirs at the sandbox-overlay boundary.** The `.claude/{commands,agents,plugins}` and `.gemini/{extensions,commands}` overlay loops previously treated any existing host subdir as "user content", so prior-session debris took the `cp -r` seeding path and was never recorded as a stub. They now treat empty host dirs as debris — still overlaid, but recorded for cleanup.

**Debug flag for investigating cleanup failures** — `SANDY_DEBUG_CLEANUP=1` prints the stub count processed on exit plus any `rmdir` failures with their errno messages, and distinguishes "no stubs file" from "file present but empty" from "file populated but rmdir refused". Zero overhead when unset.

### Documentation

**CLAUDE.md, SPECIFICATION.md** — Mount policy section replaces the pre-0.11.4 "empty directories are benign" rationale with the new session-stub tracking + pre-existing-debris auto-clean behavior. Spec version header resynced (was stuck at 0.11.1-dev).

---

## sandy v0.11.3

Stabilizes the isolation hardening that shipped in v0.11.1/v0.11.2. Two bug fixes that surfaced during daily-driver use of v0.11.2. This is the target for the M2.3 7-day soak before work on M3 (user-setup.sh heredoc extraction) or the Sprint 3 egress proxy sidecar begins.

### Bug Fixes

**Empty-ro fixtures missing on fast-path launches** — `ensure_build_files()` creates `$SANDY_HOME/.empty-ro-file` and `$SANDY_HOME/.empty-ro-dir/` for the protected-path overlay mounts added in v0.11.1. When sandy hit the cached-image fast path, the fixture-creation block ran *after* the fast-path exit, so brand-new `$SANDY_HOME` directories (fresh installs, `rm -rf ~/.sandy` recovery) would launch with the fixtures missing and `docker run` would fail on the first ro-overlay mount. Moved fixture creation before every fast-path exit so it runs unconditionally.

**`/plugin install` EROFS crash and user-setup.sh ENOENT race** — The v0.11.1 S2.1 implementation mounted a sidecar `:ro` at `~/.claude/settings.json` inside the container so sandy could re-seed it every launch without giving the agent write access. This broke `/plugin install` (and any in-session `claude plugin marketplace add`) because Claude Code writes the updated `enabledPlugins` list back to `settings.json` — EROFS on a read-only mount. Walked back the strict `:ro` sidecar: the file is now rw inside the container, sandy re-reads the host copy every launch and re-overwrites the sandy-managed keys (`extraKnownMarketplaces`, `teammateMode`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, cmux hooks) while preserving `enabledPlugins` from the previous sandbox session so `/plugin install` survives relaunches. Also fixed a related ENOENT race where `user-setup.sh` could run its settings-merge block before the sandbox `claude/` dir existed on a first launch.

**`/ultrareview` and cloud features fail with 404 inside sandy** — Three issues combined to break Claude Code's cloud features (like `/ultrareview`) inside sandy:

1. **`ENABLE_CLAUDEAI_MCP_SERVERS=false`** (primary cause) — sandy's entrypoint disabled Anthropic's cloud MCP servers with the rationale that "cloud MCP connectors can't work in the sandboxed network." That rationale was wrong: sandy blocks LAN, not internet; Anthropic's servers are fully reachable. `/ultrareview` coordinates parallel review agents server-side via this infrastructure. Fixed: removed the flag entirely. **This change requires an image rebuild** (`sandy --rebuild`).

2. When `CLAUDE_CODE_OAUTH_TOKEN` was set, sandy skipped the credential file flow entirely — no `.credentials.json` was mounted. Cloud features need the full OAuth object (refresh token, scopes, subscription info) that the env var alone doesn't carry. Fixed: sandy now always loads and mounts the credential file alongside the env var.

3. The v0.11.1 S1.5 change mounted `.credentials.json` read-only, which would block token refresh/scoping writes. Fixed: reverted to rw. The tmpdir is ephemeral (fresh each launch, `rm -rf` on exit), so in-session writes don't persist to the host. Codex and Gemini credential mounts remain `:ro`.

### Documentation

**CLAUDE.md** — "Per-project Sandboxes" and "Protected Files" sections updated to describe the current (walked-back) settings.json semantics and the 0-byte stub detection helper.

---

## sandy v0.11.2

Refinements to the v0.11.1 isolation hardening: a protected-files regression walk-back, a more user-friendly passive-config approval flow, and a test-harness escape hatch.

### Bug Fixes

**Protected-files always-mount created 0-byte host stubs** — The v0.11.1 S1.2 pattern tried to mount `$SANDY_HOME/.empty-ro-file` over missing `.bashrc`/`.envrc`/etc. so the agent couldn't create them in-session. Under Docker's bind-mount target auto-creation semantics, the missing target materialized as a real 0-byte file on the host workspace whenever the ro mount was applied beneath the rw workspace bind. That broke direnv (which blocks on empty `.envrc`), polluted `git status`, and tripped every tool that checks for file presence as a meaningful signal. Reverted to existence-gating for protected **files**; protected **directories** keep the always-mount behavior from v0.11.1 because empty dirs are benign on the host (git doesn't track them and no tool reacts to their mere presence).

Residual F3 gap: an agent can still create `.bashrc`/`.envrc`/etc. in-session if the host didn't have one. The mitigation is that the newly-created file shows up in `git status` on the host for review, which is the detection path. Sandy now also detects leftover 0-byte stub files from earlier buggy builds (untracked by git and matching the protected-files list) and prints a one-shot `rm` command to clean them up. Stubs are not auto-removed — a 0-byte file could be intentional.

**Silent socat stderr on SSH relay shutdown** — The macOS SSH-agent TCP relay helper was printing "socat[pid] E Connection reset by peer" on every normal container exit because the in-container `socat` closes the forwarded socket before the host-side helper sees EOF. Pure noise. Piped the helper's stderr through a filter that drops the expected shutdown message while preserving real errors.

### New Features

**Per-workspace passive-key approval prompt** — v0.11.1's config tier-split silently *dropped* any privileged key set from a workspace `.sandy/config` (e.g. `SANDY_SSH=agent` committed to a repo). That was too strict: users with legitimate reasons to set `SANDY_SSH=agent` at workspace scope had no way to opt in without moving the key to `$HOME/.sandy/config` (which is wrong — it's per-workspace state). Replaced the silent-drop with an interactive approval prompt the first time sandy sees a privileged key from a passive source. The exact `KEY=VALUE` set is printed and the user approves explicitly. Approvals are persisted to `$SANDY_HOME/approvals/passive-<workspace-hash>.list` (first line is a sha256 of the sorted `KEY=VALUE` set). Subsequent launches with the same set are silent; any edit to `.sandy/config` that changes a privileged key re-prompts. Revoke with `rm $SANDY_HOME/approvals/passive-<hash>.list`. Headless mode (`-p`/`--print`/`--prompt`) and non-TTY stdin fail closed — the keys are dropped with a pointer to "launch sandy interactively once from this directory to approve."

**`SANDY_AUTO_APPROVE_PRIVILEGED` escape hatch** — CI / test harnesses that run headless can't hit the interactive prompt, and sandy's own `test/run-tests.sh` and `test/run-integration-tests.sh` run from the sandy repo directory which has a committed `.sandy/.secrets` with `GEMINI_API_KEY`. Added an env-only escape hatch (`SANDY_AUTO_APPROVE_PRIVILEGED=1`) that bypasses the prompt and exports all collected passive privileged keys in-memory. Intentionally env-only — the passive config allowlist does not include this key, so a committed `.sandy/config` cannot set it. Only a trusted shell or test harness can.

### Documentation

**SPECIFICATION.md** — Sync of the protected-files revert and the new approval flow across Appendices C.2, D, and E.

---

## sandy v0.11.1

**1.0-rc1 isolation hardening.** Closes the Critical/High findings from the ISOLATION_STRESS.md audit (Sprints 1 and 2 of the remediation plan). Seven findings are fully closed; one (F2 macOS network) is mitigated and documented honestly, with a full fix scheduled for a new Sprint 3 egress-proxy sidecar that's now in scope for rc1.

### Isolation hardening — Sprint 1

**Submodule gitdir protection (F1, Critical)** — `.git/modules/<sub>/hooks/`, `.git/modules/<sub>/config`, and `.git/modules/<sub>/info/` were fully writable in v0.11.0. A planted `post-checkout` hook under a submodule's gitdir would have run on the host the next time the user ran `git submodule update` or `git pull --recurse-submodules` — a clean host RCE. Sandy now walks `$WORK_DIR/.git/modules` (and the gitdir-side `modules/` for `--separate-git-dir` / worktree-of-submodule layouts) at launch and mounts each submodule's `config`, `hooks/`, and `info/` read-only. Handles nested submodules up to maxdepth 6.

**Top-level `.git/` protection extended** — Added `.git/HEAD`, `.git/packed-refs`, and `.git/info/` to the ro-overlay set. `.git/info/attributes` is a known filter-driver injection vector; closing it was the specific reason for adding `.git/info/`.

**Always-mount protected directories (F3, High)** — Protected **directories** (`.git/hooks`, `.vscode`, `.idea`, `.github/workflows`, `.circleci`, `.devcontainer`) are now mounted read-only unconditionally. When the host has no corresponding directory, sandy mounts a zero-byte `$SANDY_HOME/.empty-ro-dir` as an empty ro stand-in. This closes the bypass where an agent could create `.vscode/` (or any other missing protected dir) inside the container, leaving a config file that would execute the next time the host IDE opened the workspace. (See v0.11.2 for the walk-back on the corresponding file-level always-mount.)

**Expanded protected files list (F4, High)** — Added `.envrc`, `.tool-versions`, `.mise.toml`, `.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pypirc`, `.netrc`, `.pre-commit-config.yaml`. Added `.github/workflows/`, `.circleci/`, `.devcontainer/` as protected directories. `.github/workflows/` is particularly dangerous because the escape fires on `git push` — long after the session ends; set `SANDY_ALLOW_WORKFLOW_EDIT=1` in `.sandy/config` to opt in to editing workflows when the agent is doing legitimate CI work.

**Config tier-split (F5, High)** — `_load_sandy_config()` now takes a `tier` argument: `privileged` for `$HOME/.sandy/config` and `$HOME/.sandy/.secrets`, `passive` for `$WORK_DIR/.sandy/config` and `$WORK_DIR/.sandy/.secrets`. Privileged-only keys (`SANDY_SSH`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_ALLOW_LAN_HOSTS`, credential env vars, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) are dropped when encountered in a passive source. Workspace `.sandy/config` committed to a repo can no longer disable isolation, extract credentials, or enable agent-teams for the next launch. (v0.11.2 softens the silent-drop into an interactive approval prompt.)

**`SANDY_ALLOW_LAN_HOSTS` use-site validation** — Rejects world-open CIDRs (`0.0.0.0/0`, `::/0`) with a hard error at launch, regardless of source. Even a privileged user writing that in their host config is almost certainly a mistake.

**Credential mount `:ro` symmetry (F7, Medium)** — `~/.claude/.credentials.json` and `~/.gemini/oauth_creds.json` are now mounted `:ro` inside the container, matching the existing Codex `auth.json` treatment. Prevents token leakage back to the host tmpfile via a compromised session and prevents stale-token races on exit. In-session token refresh still works — Claude Code's retry logic hits the remote refresh endpoint, not the creds file.

**Cleanup trap expanded** — `trap cleanup EXIT INT TERM HUP QUIT ABRT`. `QUIT` and `ABRT` are the main signals that previously bypassed the cleanup block; `SIGKILL` still can't be trapped but the residual window is now minimal.

**Symlink scan depth** — Bumped from maxdepth 5 to maxdepth 8. The walker already excludes `node_modules/`, `.venv*/`, and `.git/`, so the extra depth is cheap and covers modern monorepo layouts.

### Isolation hardening — Sprint 2

**Persistent symlink approval (F8, Medium)** — Dangerous symlinks (absolute links, or relative links that escape the workspace via `..`) are surfaced at launch. On first encounter sandy prints a y/N prompt listing each link and its target; on approval the set is persisted to `$SANDBOX_DIR/.sandy-approved-symlinks.list`. Subsequent launches with the same-or-reduced set proceed silently. A **new** escape (e.g. `ln -s /etc/shadow new-link` created after initial approval) causes a **hard error** at the next launch — sandy refuses to re-prompt, because a y/N that fires every session can be trained past, whereas a hard error forces a deliberate action.

**Settings.json re-seeding** — `~/.claude/settings.json` is now regenerated from the host copy on every launch with merge-preserving semantics: sandy-managed keys (`extraKnownMarketplaces`, `teammateMode`, `spinnerTipsEnabled`, `skipDangerousModePermissionPrompt`, cmux hooks) are re-overwritten, host-side edits to other keys propagate, and `enabledPlugins` is preserved from the previous sandbox session. The original Sprint 2 plan mounted this `:ro` to prevent in-session mutation entirely, but see v0.11.3 for why that got walked back.

### macOS network honesty (F2, Critical — documented + mitigated, full fix deferred)

**Launch warning banner** — On macOS sandy now prints a loud warning at every launch announcing that network isolation is not active (Docker Desktop's VM does not isolate the container from the host LAN or `host.docker.internal`; Linux iptables DROP rules cannot be applied from macOS). This replaces the previous SPECIFICATION.md claim that "Docker Desktop's VM provides LAN isolation by default" which the stress test disproved.

**Magic-hostname nullification** — On macOS, sandy adds `--add-host gateway.docker.internal:127.0.0.1` and `--add-host metadata.google.internal:127.0.0.1` to every container. When `SANDY_SSH!=agent`, sandy also nullifies `host.docker.internal:127.0.0.1` (but not in SSH agent mode, because sandy's own TCP agent relay uses that hostname). This is defense-in-depth — raw-IP access to the host LAN is unaffected — but it removes the easiest default-hostname path and anything that calls by name.

**Full fix is Sprint 3, now in scope for 1.0-rc1.** An egress proxy sidecar implementing HTTP CONNECT + DNS allowlist will land as part of the rc1 cut. Until Sprint 3 ships, treat macOS sandy as "process and filesystem isolation only; no network isolation."

### New Features (unrelated to isolation)

**`--agent` CLI flag** — Overrides `SANDY_AGENT` for a single invocation without editing `.sandy/config`. Accepts the same comma-separated syntax: `sandy --agent claude,codex`. Takes precedence over both `.sandy/config` and the environment.

**`doctor.sh`** — New host readiness check script at `doctor.sh`. Inspects Docker availability, image store, sandy installation, credential sources, and known problem patterns on the current host. Intended as the first thing to run when something doesn't work; exits non-zero if anything blocking is found.

### Breaking Changes

**`SANDY_AGENT=both` alias removed** — The `both` alias was removed in favor of the comma-separated syntax (`claude,gemini`). Sandy now errors out on `both` with a pointer to the new form. If you have `SANDY_AGENT=both` in a `.sandy/config`, update it to `SANDY_AGENT=claude,gemini`.

### Tests

Eighteen new isolation regression tests (T14–T31) in `test/run-tests.sh` covering: submodule gitdir hook/config readonly-ness, `.git/info/` protection, `.vscode/` blocking when absent on host, `.envrc` blocking, `.github/workflows` protection + `SANDY_ALLOW_WORKFLOW_EDIT` opt-out, privileged-key drops from passive sources, `SANDY_ALLOW_LAN_HOSTS=0.0.0.0/0` hard error, Claude credentials `:ro`, macOS launch banner presence, conditional `host.docker.internal` nullification under SSH agent mode, and persisted symlink approval + new-escape hard error.

### Documentation

**ISOLATION_STRESS.md** — Preserved as-is for historical reference; findings status tracked in the new Sprint 3 section of ROADMAP_1.0.md.

**SPECIFICATION.md** — Major rewrite of Appendices C.2 (settings.json), D.1 (macOS vs Linux), E.4 (run flags), E.9 (mounts), E.10 (creds), and E.11 (network).

**CLAUDE.md** — New sections on config tiers, protected files, submodule gitdir protection, macOS network limitation, and persistent symlink approval.

---

## sandy v0.11.0

PR 2.1 — venv overlay hardening. Fixes the `.venv` overlay that shipped in v0.10.0 so it actually materializes cleanly and handles concurrent launches without corrupting sandbox state.

### Bug Fixes

**`.venv` overlay never materialized** — The overlay dir is a bind mount, so the target `$WORKSPACE/.venv` always exists as a directory. `uv venv` refuses to create a venv into any existing directory with "A directory already exists at: .venv", so the first-launch materialization silently failed and every session fell back to the system Python. Fixed by invoking `uv venv --clear` (wipes contents in place without rmdir-ing the mount point). The `--clear` flag is now a regression-guarded invariant in `run-tests.sh` §9k. Also: `uv venv` stderr was being suppressed, so the actual error was invisible to users — it's now captured and printed on failure.

**Python version precedence** — Sandy was parsing `pyvenv.cfg` for the host Python version, but `.python-version` (if present) is the authoritative user-maintained pin and should win. `.python-version` is now checked first, `pyvenv.cfg` is the fallback. The parsed value is validated against `^[0-9]+\.[0-9]+$`; garbage is dropped and the container defaults to `3.12`.

**Symlinked `.venv/`** — Overlay detection now explicitly skips symlinked `.venv/` with an info message. Overlaying a symlink would shadow whatever the target happens to point at — too risky to do silently.

**Version drift warning** — On relaunch, sandy now compares the overlay's actual `pyvenv.cfg` version against the host's wanted version (from `.python-version` / host `pyvenv.cfg`). A mismatch (e.g. the user bumped `.python-version` after the overlay was built) prints a warning with the recreate command. Auto-recreate is deliberately not done — it would silently nuke installed packages.

### New Features

**Workspace mutex** — Only one sandy may run against a given workspace at a time. On launch, sandy takes a per-workspace lock (`mkdir` on `$SANDY_HOME/sandboxes/.<name>.lock` — atomic on every POSIX filesystem, no external dependency). A second launch fails fast with a clear error naming the holding pid and the command to clear a stale lock (e.g. after `kill -9`). The lock is released by the cleanup trap on normal exit, Ctrl-C, or crash. Two agents editing the same codebase would step on each other's edits anyway; deliberate parallelism should use separate workspaces.

### Tests

**Integration test image-build gating** — `run-integration-tests.sh` sections 4/6/7b (in-container PATH/version/synthkit/WeasyPrint checks for codex/gemini/claude) were gated on `docker image inspect` and silently skipped when the image wasn't pre-built. They don't actually need credentials — only the image — so a developer without e.g. `OPENAI_API_KEY` would never exercise the sandy-codex image at all. Added an `ensure_image_built` helper that invokes `sandy --build-only` from a throwaway workspace; skip branches are now `fail` so a broken build is loud.

**§9k/§9l regression guards** — `uv venv --clear` is asserted present; the workspace mutex is asserted to use `mkdir` (not flock) and release in the cleanup trap; `CONTAINER_NAME` is asserted deterministic (no PID suffix); the previous `_SANDY_HAVE_FLOCK` gating is asserted removed.

### Documentation

**CLAUDE.md** — "Workspace `.venv` overlay" section rewritten to describe the new materialization flow (`uv venv --clear`, no in-container locking, drift check). New "Concurrent launches" paragraph documenting the mutex.

**SPECIFICATION.md** — New Appendix E.0 (Workspace Mutex). Appendix E.7a updated for the simplified `user-setup.sh` flow.

---

## sandy v0.10.1

M1 blocker fixes from the code review on the `codex-support` branch, on the road to 1.0-rc1.

### Bug Fixes

**Resume fallback misfires on Ctrl-C** — `build_claude_cmd` appended a `|| $cmd_base` fallback after `claude --continue` so a missing-session-file race would re-launch without `--continue`. In practice, **any** non-zero exit triggered the fallback — Ctrl-C, `/exit`, a failed headless prompt — so users would see an unexpected fresh Claude session appear after exiting a resumed one. Dropped the fallback entirely; the session-detect check at sandy:1213 already guarantees `--continue` is only added when a session file exists.

**grep-regex injection in codex trust-entry check** — The idempotency check for the `[projects."..."]` block in `~/.codex/config.toml` was `grep -q "^\[projects\.\"${SANDY_WORKSPACE}\"\]"`, interpolating the workspace path into a grep BRE unescaped. The `/` and `.` characters in the path are regex metacharacters, so two workspaces differing only in those positions could falsely appear identical and skip the append. Switched to `grep -qF --` (fixed-string match).

### Tests

**In-container checks build images on demand** — `run-integration-tests.sh` sections 4/6/7b (codex/gemini/claude in-container image checks — PATH, version file, synthkit, WeasyPrint) were gated on `docker image inspect` and silently skipped when the image wasn't pre-built. They don't actually need credentials — only the image — so a developer without e.g. `OPENAI_API_KEY` would never exercise the sandy-codex image at all. Added an `ensure_image_built` helper that invokes `sandy --build-only` from a throwaway workspace; skip branches replaced with `fail` so a broken build is loud.

**Regression guards in `run-tests.sh` §9h** — Assert that `build_claude_cmd` has no `cmd || cmd_base` fallback pattern, that `cmd_base` is not referenced, and that the codex trust-entry check uses `grep -qF`.

---

## sandy v0.10.0

### New Features

**OpenAI Codex CLI support** — Sandy now supports the OpenAI Codex CLI alongside Claude Code and Gemini CLI. Select it with `SANDY_AGENT=codex` in `.sandy/config` or as an environment variable. Credentials are probed in order: `OPENAI_API_KEY` env var (what codex CLI reads natively), then the host's `~/.codex/auth.json` (copied ephemerally and mounted **read-only** — prevents token leakage back to host and prevents stale-token races). On first launch, sandy seeds `~/.codex/config.toml` with `sandbox_mode = "danger-full-access"` (sandy provides outer isolation; codex's Landlock sandbox does not nest cleanly in Docker) and a `[notice]` block to suppress first-run prompts. Project trust entries are appended at session start.

**Multi-agent mode** — Any combination of Claude Code, Gemini CLI, and Codex CLI can now run side-by-side in a tmux multi-pane layout. Set `SANDY_AGENT` to a comma-separated list: `claude,codex`, `gemini,codex`, `claude,gemini,codex`, etc. Aliases: `both` = `claude,gemini`, `all` = `claude,gemini,codex`. Multi-agent combos use a new `sandy-full` Docker image that includes all three agents; single-agent modes continue to use their dedicated images. The sandbox directory has sibling `claude/`, `gemini/`, and `codex/` subdirs mounted at the respective home paths; v1 layouts are auto-migrated on launch.

**Workspace `.venv` overlay** — Projects with a host-created `.venv/` (from `uv venv` or `python -m venv`) no longer break inside sandy. The host venv's `bin/python` symlink points at a host-only interpreter path that doesn't exist in the Linux container; sandy now shadows the host `.venv/` with a sandbox-owned overlay mount. The overlay contains a fresh venv matching the host's Python version (parsed from `pyvenv.cfg`), materialized on first launch and persisted across sessions. Host venv is never modified. Opt out with `SANDY_VENV_OVERLAY=0`.

**Sandbox version tracking** — Every sandbox now gets a `.sandy_created_version` marker on creation and `.sandy_last_version` refreshed per launch. When a sandbox predates a known breaking change (currently the v0.7.10 workspace mount path change from `/workspace` → `/home/claude/<rel>`), sandy warns on launch with the recreation command. The threshold is controlled by `SANDY_SANDBOX_MIN_COMPAT` in the script and bumps alongside future breaking changes.

**Strengthened Gemini CLI support** — Gemini credential probing now covers three sources in order: `GEMINI_API_KEY` env var, host `~/.gemini/tokens.json` (copied ephemerally), and host `~/.config/gcloud/application_default_credentials.json` (Google ADC / Vertex AI). Override the source with `SANDY_GEMINI_AUTH=auto|api_key|oauth|adc`. Gemini now auto-trusts the workspace via a seeded `trustedFolders.json` (no more per-launch trust prompts), and `SANDY_GEMINI_EXTENSIONS` supports automated installation of Gemini extensions at session start.

### Bug Fixes

**Session auto-resume for paths with `_` or `.`** — Claude Code normalizes any non-alphanumeric character in the workspace path to `-` when naming its project directory (`~/.claude/projects/-home-claude-dev-equity-analyzer`), but sandy was only transforming `/`. For workspaces whose paths contained `_` or `.`, `--continue` looked at the wrong directory and silently started a fresh session. Both the auto-resume check and the project-dir pre-creation now use `sed 's/[^a-zA-Z0-9]/-/g'` to match Claude Code's transform.

**`gh` multi-account auto-switch** — When multiple GitHub accounts are configured, sandy now detects the repo owner from the workspace remote URL and switches `gh` to the matching account on session start. Previously, the last-logged-in account was active and pushes failed when the owner was different.

**Codex `auth.json` empty-file crash** — Codex creates an empty `auth.json` on first run when using API-key auth, then crashes on subsequent launches trying to parse it. Sandy now removes empty `auth.json` files from the sandbox on launch.

**Codex `config.toml` corruption recovery** — Empty or corrupt `config.toml` files in the sandbox are now detected and re-seeded, instead of causing codex to launch with broken configuration.

**Codex git-repo-check** — Added `--skip-git-repo-check` to the codex launch so sessions in non-git workspaces don't fail with a spurious check error.

**Codex auth env var** — Corrected the environment variable name passed to codex: `OPENAI_API_KEY` (what the CLI actually reads), not `CODEX_API_KEY`.

### Tests

**Integration test suite** — New `test/run-integration-tests.sh` runs end-to-end Docker-based tests exercising real sandy launches, credential flows, and agent invocations. Complements the existing `test/run-tests.sh` which continues to cover script-level assertions.

**Expanded script tests** — `test/run-tests.sh` gained coverage for the `.venv` overlay detection logic (allowlist, `pyvenv.cfg` parsing with both `version` and `version_info` keys, symlinked `.venv` skip, opt-out via `SANDY_VENV_OVERLAY=0`).

### Documentation

**`ROADMAP_1.0.md`** — The path from this release to `1.0.0-rc1` is captured as a discrete sequence of PRs with exit criteria, soak gates, and target versions. Five milestones: `0.10.1` (blocker fixes from code review), `0.11.0` (venv overlay hardening + 7-day soak), `0.12.0` (architecture cleanup), `0.13.0` (surface stabilization), `1.0.0-rc1` (14-day pre-RC soak).

**Updated `CLAUDE.md` and `SPECIFICATION.md`** — New sections covering the `.venv` overlay, sandbox version tracking, multi-agent mode, and the full list of allowlisted config variables (now 40+ keys spanning all three agents).

### Known Issues

The following are tracked in `ROADMAP_1.0.md` as **PR 1.1** and will ship as `v0.10.1`:

- **Resume fallback misfire**: the `claude --continue` fallback pattern spawns an unwanted fresh session on Ctrl-C. Fix: drop the fallback; the auto-detect already knows when sessions exist.
- **grep-regex injection in codex trust-entry check**: `$SANDY_WORKSPACE` is interpolated into a BRE without escaping. Fix: switch to `grep -F`.

---

## sandy v0.7.5

### New Feature

**GPU passthrough** — New `SANDY_GPU` config variable passes host GPUs into the container via `--gpus`. Set `SANDY_GPU=all` in `.sandy/config` or as an environment variable. Requires the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) on the host.

The base image stays lean — CUDA is layered per-project via `.sandy/Dockerfile`. A ready-to-copy example is included at [`examples/gpu/Dockerfile`](examples/gpu/Dockerfile) with full CUDA toolkit and PyTorch-only options. Works on x86_64 and arm64 (including DGX Spark).

---

## sandy v0.7.1

### Security Fix

**Plugin leakage** — Host-installed plugins (and their enabled state) no longer leak into the container. Previously, workspace `.claude/plugins/` was mounted read-only into the container, making host-installed plugins active inside sandy. The host's `enabledPlugins` in `settings.json` also survived into fresh sandboxes on hosts without `node` (the stripping code had no fallback).

### Changes

**Writable sandbox overlays** — `.claude/commands/`, `.claude/agents/`, and `.claude/plugins/` are now mounted as writable sandbox directories instead of read-only host mounts. All three start empty. Claude can create slash commands, agents, and install plugins freely; changes persist in the sandbox across sessions without touching the host filesystem.

**Marketplace configuration baked into image** — Both [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) and [sandy-plugins](https://github.com/rappdw/sandy-plugins) marketplaces are now configured inside the container via `user-setup.sh` (part of the Docker image). Previously, marketplace catalogs were seeded from the host's `~/.claude/plugins/marketplaces/` directory, which could carry unwanted state. Claude Code fetches marketplace catalogs from GitHub on first `/plugin` browse.

**jq fallback for settings merge** — The sandbox creation settings merge (defaults, `enabledPlugins` stripping) now falls back to `jq` when `node` is not available on the host. Previously, hosts without `node` got no settings manipulation, leaving host `enabledPlugins` intact in fresh sandboxes.

### Bug Fixes

- cmux test assertions now use `jq` instead of `node`, fixing test failures on hosts without Node.js
- Host marketplace catalog seeding removed (eliminates a class of state leakage from `~/.claude/plugins/`)

### Documentation

- Expanded README security section with per-file/directory table explaining what each mount protects against
- Documented [known Claude Code bug](https://github.com/anthropics/claude-code/issues/18949) where plugin skills don't appear in slash command autocomplete until first invocation

---

## sandy v0.7.0

### Breaking Changes

**Safe config parser** — `.sandy/config` is no longer `source`'d as a bash script. It is now parsed as plain `KEY=VALUE` lines with an allowlist of recognized variables. If your config used shell logic (e.g., `SANDY_MODEL=$(some_command)`), convert it to a static value. Supported keys: `SANDY_SSH`, `SANDY_MODEL`, `SANDY_SKIP_PERMISSIONS`, `SANDY_ALLOW_NO_ISOLATION`, `SANDY_CPUS`, `SANDY_MEM`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`. This change prevents arbitrary code execution on the host from untrusted workspace files.

### Security Hardening

**Capability dropping** — The container now runs with `--cap-drop ALL` and only adds back the minimum capabilities needed by the entrypoint (`SETUID`, `SETGID`, `CHOWN`, `DAC_OVERRIDE`, `FOWNER`). Previously Docker's full default capability set was retained.

**Process limit** — Added `--pids-limit 512` to prevent fork bombs inside the container from exhausting the host's PID space.

**Expanded protected paths** — `.git/config`, `.gitmodules`, `.gitconfig`, `.ripgreprc`, `.mcp.json`, and `.claude/plugins/` are now mounted read-only inside the container, in addition to the existing protected files. This blocks `.git/config` injection attacks (e.g., malicious `core.hooksPath` or `core.fsmonitor` directives that could execute code on the host).

**OAuth token isolation** — `CLAUDE_CODE_OAUTH_TOKEN` is now explicitly blocked from leaking into the container from the host environment. Sandy manages credentials via `.credentials.json`.

**Permission bypass consistency** — `skipDangerousModePermissionPrompt` in `settings.json` now respects `SANDY_SKIP_PERMISSIONS=false`, so users who opt into Claude's permission prompts get them consistently.

### Bug Fixes

- Auto-resume now works correctly for git submodule workspaces (previously always looked in `-workspace/` regardless of actual mount path)
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS` set in `.sandy/config` now correctly reaches the container (was missing from `docker -e` flags)
- `SANDY_CPUS` and `SANDY_MEM` are now overridable from `.sandy/config` (resource detection moved after config loading)
- macOS SSH agent relay preflight now checks for both `socat` and `python3` (previously only checked `socat` but used `python3` for port allocation)
- `docker network rm` no longer prints the network name to stdout on cleanup
- Cleanup no longer prints a spurious warning about the ACCEPT rule on normal exit

### Structural Improvements

**Entrypoint split** — The 149-line `bash -c '...'` block inside the entrypoint has been extracted into a standalone `user-setup.sh` script. This eliminates single-quote restrictions, enables ShellCheck analysis, and produces useful error line numbers when debugging.

**Function decomposition** — `ensure_build_files()` (363 lines) has been split into 5 focused generator functions: `generate_dockerfile_base()`, `generate_dockerfile()`, `generate_entrypoint()`, `generate_user_setup()`, `generate_tmux_conf()`.

**Helper functions** — Added `sha256()` (replaces 4 duplicate shasum patterns) and `json_merge()` (consolidates repeated node -e JSON manipulation boilerplate, with warnings on parse failure instead of silent data loss).

### Cleanup

- Removed dead python3 SSH relay fallback (~44 lines, unreachable after socat preflight)
- Removed stale `NODE_OPTIONS` from Dockerfile (Claude Code is now a native binary)
- Removed redundant `DISABLE_SPINNER_TIPS=1` (settings.json is authoritative)
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is now opt-in (set to `1` in `.sandy/config` to enable)
- Added `ENABLE_CLAUDEAI_MCP_SERVERS=false` in the container (cloud MCP connectors can't work in the sandboxed network)

### New Tests

- Config parser injection protection (verifies `source` is not used)
- `.git/config`, `.gitmodules`, `.claude/plugins/` write-protection
- Container hardening flags (`--pids-limit`, `--cap-drop ALL`, OAuth token blocking)
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS` passthrough verification

---

## sandy v0.6.0

### What's Changed

**Terminal notification support** — Sandy's inner tmux now has `allow-passthrough on`, so OSC escape sequences (9/99/777) from Claude Code flow through to the outer terminal. This enables notification rings, desktop alerts, and sidebar badges in [cmux](https://www.cmux.dev/), iTerm2, and other notification-aware terminals.

**cmux auto-setup** — When sandy detects it's running inside cmux (via `CMUX_WORKSPACE_ID`), it automatically installs a notification hook that emits OSC 777 sequences on Claude Code events. No manual configuration needed. Host-side Claude Code hooks (`~/.claude/hooks/`) are also mounted read-only into the container.

**Symlink protection** — Before launching the container, sandy scans the workspace for symlinks that point outside the project directory. If any are found, sandy warns and prompts for confirmation, preventing Claude from accessing files outside the sandbox via symlink traversal.

**Plugin marketplace** — The [sandy-plugins](https://github.com/rappdw/sandy-plugins) marketplace is pre-configured in every sandbox. Install plugins with `/plugin install synthkit@sandy-plugins`. The marketplace is seeded on every launch, so existing sandboxes pick it up automatically.

**Project name in tmux** — The tmux pane border and window title now show the project name (e.g., `sandy: my-project`) instead of a numeric index.

**Build improvements** — Claude Code version is cached at build time so the update check doesn't re-query npm on every launch. The update check has a 10-second timeout to prevent hangs on slow networks.

**Fixes:**
- git-lfs no longer initializes in non-git directories
- Output token limit raised from 32K to 128K (`CLAUDE_CODE_MAX_OUTPUT_TOKENS`)
- Fixed bash `!` escaping in `node -e` blocks that could cause SyntaxError on some systems

**Documentation** — Added comprehensive "What's in the Box" section to README enumerating all pre-installed toolchains, system tools, libraries, and the plugin marketplace.

**Test suite** — Added tests for terminal notification passthrough, cmux auto-setup (including idempotency), and symlink protection.
