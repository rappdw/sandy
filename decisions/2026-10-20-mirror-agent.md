# Decisions: Reflection AI's Mirror CLI as a sandy agent (2026-10-20)

Decided with the maintainer, one at a time, for #463 (the first cut). What the first cut leaves out is tracked as a separate issue, "Mirror: full support beyond the first cut".

Mirror (`reflection-oss/mirror`, Apache-2.0, PyPI `reflection-mirror`, binary `mirror`) was at **0.1.0**, its only release, and documented as early beta. Everything below rests on its docs (developers.reflection.ai `mirror-overview`, `mirror-cli-reference`, `mirror-models`, the quickstart, and `mirror-cli/README.md`) as of this date. The unknowns listed at the end are measured by `test/spike/mirror-spike.sh` before the build.

| # | Decision | Choice | Deciding reason |
|---|----------|--------|-----------------|
| 1 | Multi-agent | Single-agent image `sandy-mirror` only. `mirror` in a combo is refused, naming #463. `sandy-full` is unchanged. | A 0.1.0 beta's release churn and its PyPI install would otherwise rebuild, and could break, the image every combo user shares. Lifting the refusal later is additive. |
| 2 | Approval mode | Every launch passes `--approval-mode` explicitly: `auto` when `SANDY_SKIP_PERMISSIONS=true`, `approve` otherwise. Interactive and headless (`mirror exec`) alike. No repair of `~/.mirror/config.json`. | Mirror persists the mode in `config.json`, so one `auto` launch would otherwise outlive the setting. An explicit flag makes the posture a function of sandy's setting every launch. Headless `exec` fails any call that needs approval, so leaving it out there would ship a headless mode that cannot act. |
| 3 | Provider credentials | Only `REFLECTION_API_KEY` (new, privileged), via the 0600 secret env-file. Probe order: environment, then the sandbox's saved `mirror/reflection_api_key`, then the host's `~/.mirror/reflection_api_key` seeded into the rw sandbox (sandbox copy wins, like codex `auth.json`). `FIRECRAWL_API_KEY` and `OPENROUTER_API_KEY` are reachable through `SANDY_EXTRA_ENV`. No `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`, no ChatGPT-plan auth. | The one-credential rule (#429): keys the host holds for other agents do not ride into a beta agent that never calls those providers. `SANDY_EXTRA_ENV` refuses names sandy recognizes, so the two it can carry are exactly the two that are not already sandy keys. |
| 4 | Protected path | All of `.mirror/` joins the protected directories (existence-gated, session-end detection like the rest). | `.mirror/extensions/` is executable Python loaded from the workspace, and the rest of `.mirror/` is undocumented beta surface. Default-deny covers what a later Mirror adds there; the existence gate makes it free in a repository without `.mirror/`. |
| 5 | Effort | `SANDY_EFFORT` maps to `--reasoning-effort` by identity. Unset passes nothing, and the docs say Mirror's own default is `max`. | A pinned default would override the user's saved `/effort` on every relaunch, since launch flags win for that launch. Every other agent also gets nothing when `SANDY_EFFORT` is unset. |
| 6 | Local LLM | Not wired. Documented recipe: `--api openai-chat-completions --base-url http://host.docker.internal:<port>/v1 --model <name>` in `$SANDBOX_DIR/agent-args.mirror`. | `SANDY_LOCAL_LLM_HOST` already opens the network path for any agent. Auto-wiring would let a host-wide setting kept for opencode silently switch Mirror off Reflection. |

Defaults assumed without a round:

- `SANDY_AGENT=all` is unchanged (`claude,gemini,codex,opencode`); Mirror is opt-in, like grok. The 4-agent cap is unchanged.
- `MIRROR_SKIP_UPDATE=1` always. `--no-update` alone still selects a newer cached release under `$XDG_DATA_HOME/mirror/releases/public`, which would land on the tmpfs home outside the image.
- Sandy never passes `--api-key` (argv), `--trust-extensions`, or `--log-level debug` (its logs carry request headers, including the key, and would persist in the sandbox).
- `api.reflection.ai` joins the strict-egress allowlist.
- Interactive auto-continue mirrors codex (#427): `--continue` only when the sandbox holds a conversation for this workspace; `sandy --new` starts fresh. Headless is never resumed (`exec` cannot).
- The first-run usage, folder-trust and extension notices are pre-seeded once the spike shows where they are recorded, and a `--start` launch is verified to reach a live prompt.
- Install: `uv tool install --python-preference system reflection-mirror` with `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR`, the shape synthkit already uses; the version file comes from `mirror --version` and an empty one fails the build (#201).

Options considered and not taken:

- **1:** install in `sandy-full` (as grok was); a `sandy-full` variant built only when `mirror` is selected.
- **2:** the flag plus a per-launch repair of `config.json` (codex §118 shape); interactive-only mapping.
- **3:** forward every provider key that is set (opencode's shape); a passive provider selector `SANDY_MIRROR_API` forwarding exactly the chosen provider's key.
- **4:** `.mirror/extensions/` only; `.mirror/` plus `.agents/skills/` (a cross-agent policy question, left for the Pi agent, #460).
- **5:** pin `high` when unset.
- **6:** auto-wire when `SANDY_LOCAL_LLM_HOST` is set; an opt-in selector value.

To measure before building (`test/spike/mirror-spike.sh`, host-run):

- where the usage, folder-trust and extension acceptances are recorded, and whether seeding them lets `mirror exec` and an interactive launch start with no prompt;
- whether `--approval-mode approve` overrides a saved `auto`;
- what `--continue` does with no prior conversation, and how a conversation's workspace is recorded in `state.db` (for the auto-continue probe);
- `mirror exec` exit codes;
- whether Mirror starts with `MIRROR_SKIP_UPDATE=1` and no network, on a read-only root filesystem, as a non-root uid;
- the real flag set (`mirror --help`).
