# Handoff: session activity record for codex (follow-up to #487)

**Status:** handoff, nothing built yet. Whoever picks this up: implement it on this branch (`feat/codex-activity`). When you're done, delete this file and replace it with the real SPECIFICATION.md section. The maintainer merges; nothing auto-merges.

**Goal:** give codex sessions the same turn-state record that #487 (`d07b323`) gave Claude sessions. The line schema is already agreed with a downstream reader. Keep it byte-compatible, with `"agent":"codex"`, so one reader handles both agents.

## What #487 built (read these first)

| Piece | Where (search for the anchor) |
|---|---|
| Hook helper (Python, `-I`), baked into the base image | `sandy`: heredoc `CLAUDE_ACTIVITY_HELPER` in `generate_dockerfile_base`, with `LABEL sandy.claude_activity=1` above it |
| Registration in Claude Code's policy layer | `sandy`: `# BEGIN claude policy settings` … `# END claude policy settings` (writes `$(_sandy_launch_dir)/claude-policy/managed-settings.json`, mounted `:ro` at `/etc/claude-code`) |
| Stale-image warning | `sandy`: `# --- BEGIN stale-image activity warning` |
| Config key | `SANDY_CLAUDE_ACTIVITY` in `SANDY_PASSIVE_KEYS` and `_sandy_key_metadata` |
| Spec | SPECIFICATION.md C.2, "Session activity record" (schema, states, retention, safety) |
| Tests | `test/test_claude_activity.py` (15 tests, run by §210(1)); `test/run-tests.sh` §210; integration section 7 (the only proof the policy-layer hooks fire) |

**Schema** (unchanged for codex except `agent`): the helper writes to `<agent home>/activity/`.
- `activity-latest.json` is `{"v":1,"sessions":{<session_id>: entry}}`, replaced atomically under `.lock`.
- `activity-YYYY-MM-DD.jsonl` gets one line per change of state or of `subagents_active`, and is kept 14 days.
- Line: `{"v":1,"ts","sandbox","agent","session_id","session_name","seq","event","state","subagents_active","detail"}`.
- States: `working | waiting | idle | ended`.
- Each entry also carries `last_event`, `last_event_ts` and `subagent_ids`.
- An entry is pruned once it has been idle or ended for 24 h.
- New fields may be added (readers ignore unknown ones). Removing a field or changing a meaning needs `v` bumped, so check with the maintainer first.

## What codex offers, from its docs (NOT yet measured)

From https://learn.chatgpt.com/docs/hooks and https://learn.chatgpt.com/docs/enterprise/managed-configuration, read 2026-10-25. Strings checked in the codex-cli **0.164.0** linux-arm64 binary: all twelve event names, `requirements.toml`, `managed_dir`, `allow_managed_hooks_only`, `hook_event_name`, `turn_id`, and `/etc/codex` are present.

- **Hooks are on by default**, through feature `hooks`; `codex_hooks` is a deprecated alias.
- **Events:** `SessionStart`, `SessionEnd`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt`.
- **Payload:** `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`. Turn-scoped events add `turn_id`, subagent events add `agent_id`/`agent_type`, SessionStart adds `source`, and SessionEnd adds `reason`.
- **`Interrupt`** "runs when you interrupt an active turn on the main thread", but not for idle threads or subagents. This is the event Claude Code lacks: on Claude, Esc fires nothing and the state reads `working` until the next event. If codex really fires it, map it to `idle`.
- **`PermissionRequest`** runs just before codex asks for approval, so map it to `waiting`. With skip-permissions on, sandy passes `--ask-for-approval never` (#451), so expect it rarely.
- **Stdout matters.** Plain text from `SessionStart`, `UserPromptSubmit` and `SubagentStart` is added as **developer context**. Stdout from `Stop`, `SubagentStop` and `Interrupt` must be JSON. Exit `2` blocks. The helper already prints nothing and exits 0; keep it that way.
- **Trust.** Non-managed hooks (`~/.codex/hooks.json`, `[hooks]` in `config.toml`, and project or plugin hooks) must be reviewed and trusted in `/hooks` before they run. A `--start` daemon has nobody to do that, so it would come up without hooks, or worse, parked on a review. Managed hooks are "trusted by policy and can't be disabled from the user hook browser".
- **Managed layer.** `/etc/codex/requirements.toml` takes a `[hooks]` table with the same shape as Claude's (`[[hooks.<Event>]]` with `matcher`, then `[[hooks.<Event>.hooks]]` with `type = "command"`, `command`, and `timeout` in seconds, default 600). `managed_dir` names where the scripts live. There is no environment override for the path.

## Proposed design (yours to change, but say why in the PR)

1. **Key:** `SANDY_CODEX_ACTIVITY` (bool, default 1, passive-safe, codex-only). It mirrors the per-agent key family (`SANDY_CODEX_AUTH` and so on). Add it to `SANDY_PASSIVE_KEYS` and the metadata heredoc, then run `test/regen-config-docs.sh` and add a row to `docs/guide/configuration.md` (§119).
2. **Helper:** generalize the existing one rather than fork it. One helper, with the agent chosen by argument (for example `sandy-claude-activity --agent codex`, or rename it to `sandy-agent-activity` and keep the old name as a symlink so #487's policy files keep working).
   - The output dir for codex is `~/.codex/activity/`; on the host, `$SANDY_HOME/sandboxes/<slug>/codex/activity/`.
   - Add `Interrupt` to idle and `PermissionRequest` to waiting.
   - Consider recording `turn_id` as an additive field.
   - `session_name` stays `null` for codex: sandy's named sessions are Claude-only.
   - If the helper's stdin handling changes, add a new image label (for example `sandy.agent_activity=1`), so the stale-image warning still tells old images apart.
3. **Registration:** a new block, `# BEGIN codex managed requirements` … `# END`, beside the Claude one.
   - It writes `$(_sandy_launch_dir)/codex-policy/requirements.toml` containing only `[hooks]` (plus `managed_dir` if codex requires it), and mounts the directory `:ro` at `/etc/codex`.
   - Gate it on `_sandy_agent_has codex` and the key.
   - Write it fresh per launch, never in place (#400).
   - Do NOT pin `[features].hooks = true`. That would override an operator who turned hooks off, so measure what happens instead (point 5 below) and warn if hooks are off.
4. **Stale image:** extend the stale-image warning to codex.
5. **Measure before you build.** Each of these is a guess until measured; record the results in the PR body, the way #487 did:
   - which events fire, in what order, for a normal turn, a tool call, Esc mid-turn (does `Interrupt` fire, and does `Stop` also fire?), and a subagent, including whether codex fires `SubagentStop` for internal agents with ids that never started, as Claude does;
   - whether hooks fire under `codex exec` (sandy's headless path);
   - whether a `requirements.toml` holding only `[hooks]` changes anything else codex enforces (sandbox mode, approval policy, models), and whether codex refuses or warns about it;
   - whether managed hooks still run when `~/.codex/config.toml` sets `[features].hooks = false`;
   - that no trust prompt appears for managed hooks on a fresh sandbox, in both the TUI and `--start`;
   - interaction with `agent_wrapper` (#484): a wrapper execs codex, so hooks should be unaffected, but check;
   - the codex version: sandy installs `@openai/codex@latest` at build. If hooks or `Interrupt` need a minimum version, gate on it (check `codex --version` in-container) and say so in a warning, rather than silently recording nothing.
6. **Tests**, mirroring #487:
   - a Python unit-test file, or an extension of `test_claude_activity.py`, run against the extracted heredoc;
   - a new run-tests section, §211, that runs the real requirements block under stubs and covers each gate, the `:ro` mount from the launch dir, only `[hooks]` written, the `exit 0` command, the stale warning, and the key tier;
   - mutation-test every guard on scratch copies, never in place;
   - an integration check in section 2 or 4 (codex headless) that `codex/activity/` recorded working then idle, if exec fires hooks; otherwise say why there is no integration proof.

## How #487 measured (reuse it)

A Python pty rig that runs the real TUI with a scratch config. It registers a logging hook for every event, sends a prompt and then keystrokes (`\x1b` for Esc), and diffs the event log. For codex, point `CODEX_HOME` at a scratch dir and put the hooks in its `config.toml` with `--dangerously-bypass-hook-trust`. That exercises the user layer only. `/etc/codex` cannot be written in a sandbox, so the **managed** layer can only be proven by the host integration run, as with Claude.

## Rules that apply (from CLAUDE.md)

- **Never run tmux, docker, or `sandy --start/--stop/--attach` inside a sandbox.** A pty rig around a bare `codex` is fine. Tests that need Docker run on the host: ask the maintainer to run them.
- **Name no consumer.** The record is sandy's own: no protocol or fleet names in code or docs.
- **Keep the helper safe.** It prints nothing and always exits 0, never writes through a planted link (`O_NOFOLLOW`, refuse a symlinked dir), and takes the lock for every read-modify-write.
- **Keep the docs in sync:** SPECIFICATION.md (a C-appendix section for codex settings, plus the A.1 listing if the base heredoc changes), `docs/guide/configuration.md`, and the regenerated tables.
- **Stage and push carefully.** Stage files by name, and push with `git push origin <branch>:<branch>` (no `-u`).
- **Report back** when the PR is ready: the maintainer, and through them the session that wrote this note, which coordinates with the downstream reader.
