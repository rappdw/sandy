# Agents and credentials

How each agent signs in, multi-agent sessions, claude.ai connectors, Console profiles, and headless servers. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

## Using claude.ai connectors (Microsoft 365, Gmail, …)

Connectors you've added on claude.ai are **off inside sandy by default**, because the login sandy mounts reaches every connector on your account. To use them in one workspace:

```sh
# <project>/.sandy/config  (one approval prompt for this workspace)
SANDY_CLAUDE_CONNECTORS=1
SANDY_CLAUDE_AUTH=oauth     # only needed if you also have CLAUDE_CODE_OAUTH_TOKEN set somewhere
```

Then `/mcp` inside the session lists them, for example `claude.ai Microsoft 365`.

- **Connectors need your account login.** Claude Code loads them only for a `/login` account login; it skips them when it is using a long-lived `CLAUDE_CODE_OAUTH_TOKEN`, an `ANTHROPIC_API_KEY` or a Console profile. `SANDY_CLAUDE_AUTH=oauth` makes sandy use the account login and leave the other two out. Run `claude` and `/login` on the host once first. If connectors are on but this launch's credential won't load them, sandy says so at launch.
- **No network allowlist changes.** The connector list comes from `api.anthropic.com` and connector calls go through `mcp-proxy.anthropic.com`; both are reachable in every egress mode, including strict. The service itself (Microsoft Graph, Gmail) is reached by Anthropic, not from your machine, and you authorize it in your browser on claude.ai.
- **`SANDY_SUSPICIOUS=1` keeps connectors off**, even with `SANDY_CLAUDE_CONNECTORS=1`.
- **What you're opening:** every connector on your account becomes reachable from that sandbox, not just the one you want; Claude Code's `deniedMcpServers` setting or the toggles in `/mcp` narrow it. Content that comes back (mail, documents) is untrusted input to the agent.

## Using a Console profile — Claude Mythos and workspace-scoped access

Some Claude entitlements are granted to a **Console workspace**, not to an API key or a claude.ai subscription — Claude Mythos 5.1 (`claude-mythos-5-1`, Project Glasswing) is one. You reach them with an *Anthropic profile* written by the Claude Platform CLI, `ant`. Sandy supports that as `SANDY_CLAUDE_AUTH=profile`:

```sh
# on the HOST (browser flow; use --no-browser on a remote box):
ant auth login --workspace-id wrkspc_<id>      # binds the profile to the workspace
ant auth status                                # want: "(active) * Profile (user_oauth)"

# ~/.sandy/config
SANDY_CLAUDE_AUTH=profile
SANDY_MODEL=claude-mythos-5-1                  # or set it per workspace in .sandy/config
```

What sandy does on each launch: copies **only the selected profile** (`ANTHROPIC_PROFILE`, else the host's `active_config`, else `default`) from `~/.config/anthropic` into an ephemeral read-write mount at the same path in the container, and **withholds** `~/.claude/.credentials.json`, `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`. That is not optional: Claude Code ranks a profile *below* a `/login` credential and below every environment credential, so any of those in the box would silently win and you would be running on the wrong account. Inside, `/status` shows a `Profile` row; the session marker records `cred_mode: "profile"`.

Two things to know. The mount is a copy, so an in-session token refresh never rewrites the host's file (same rule as `.credentials.json`) — the host copy refreshes when you use `ant` or Claude Code there. And a profile directory can hold several profiles; sandy copies one, never the directory, so an `admin` profile on your host does not ride along.

Run `ant auth login` on the host, not in the container — the browser callback cannot reach a port bound inside the sandbox.

## Running Gemini CLI (`SANDY_AGENT=gemini`)

Sandy supports four Gemini auth paths, probed automatically unless `SANDY_GEMINI_AUTH` pins a specific one:

| Path | How to set up | When to use |
|---|---|---|
| **API key** (recommended) | `GEMINI_API_KEY=...` in `.sandy/.secrets` | Simplest; works on headless servers |
| ADC | `gcloud auth application-default login` on the host | Google Cloud / Vertex AI workflows |
| Vertex AI | ADC + `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_CLOUD_PROJECT=...`, `GOOGLE_CLOUD_LOCATION=...` | Enterprise / Vertex billing |
| OAuth (browser login) | Run `gemini auth` **on the host** once — sandy copies `~/.gemini/oauth_creds.json` (Gemini CLI ≥0.30; falls back to legacy `tokens.json`) into the container ephemerally on each launch | Subject to Google's client/account eligibility check; see below |

> **OAuth eligibility can fail independently of credential refresh.** Some
> launches receive `IneligibleTierError` with `UNSUPPORTED_CLIENT` from Google
> (tracked in issue #21). That response is an account/client rejection, not proof
> that all Google OAuth accounts are unsupported. Google's [authentication
> guide](https://geminicli.com/docs/get-started/authentication/) still documents
> Google sign-in and the cases requiring a Cloud project. A writable credential
> copy cannot grant eligibility. Use an eligible account/project or explicitly
> choose API-key or Vertex/ADC authentication; sandy does not switch billing
> modes automatically after a failed OAuth launch.

`gemini auth` must be run on the host because the container is headless and cannot open a browser. `--remote` is not supported in any multi-agent combo — only `SANDY_AGENT=claude` (single) works with `--remote`.

Sandy gives Gemini a writable private copy of the OAuth credential file so it can cache refreshed tokens during the session. The copy is discarded on exit; your host credential file and other launches' copies are untouched. This fixes the read-only refresh error, but cannot change a provider-side account or client rejection. ADC credentials remain read-only.

## Running Codex CLI (`SANDY_AGENT=codex`)

Sandy supports two Codex auth paths, probed automatically unless `SANDY_CODEX_AUTH` pins a specific one:

| Path | How to set up | When to use |
|---|---|---|
| API key | `OPENAI_API_KEY=sk-...` in `.sandy/.secrets` — sandy writes it into an ephemeral `auth.json` (what `codex login --with-api-key` would create) and mounts it **read-only**; codex 0.139+ ignores the bare env var for auth | Simplest; works on headless servers |
| OAuth (ChatGPT) | `sandy --login codex` in the workspace, or `codex login` **on the host** once — sandy seeds `~/.codex/auth.json` into this workspace's sandbox, where in-session refresh and later logins persist | ChatGPT Plus/Team/Enterprise accounts |

**`sandy --login codex`** logs codex in for this workspace's sandbox. It runs `codex login --device-auth` — the plain `codex login` waits on a `localhost:1455` callback that a browser on the host can never reach — and the credential lands in the sandbox's own `codex/auth.json`, which wins over the host's on every later launch. If a sandy session already runs for the workspace, the login runs inside it; otherwise sandy starts a one-shot launch whose only pane is the login. The session is OAuth by definition, so `OPENAI_API_KEY` is withheld from it. `--workspace PATH` and `--dry-run` (print the route, run nothing) are accepted; it needs a terminal. Other agents already have a route: claude is read from the host at every launch (log in there), `grok login` works inside the session, gemini and opencode authenticate on the host.

**`SANDY_CODEX_AUTH=oauth` withholds `OPENAI_API_KEY` from the container**, so the account credential is the only Codex credential in the box — except beside opencode (`SANDY_AGENT=codex,opencode`), which reads the key from the environment; there the key still reaches the container and the launch says so.

**Codex resumes where you left off.** An interactive launch runs `codex resume --last` when this sandbox already holds an interactive codex session for the workspace, and a plain `codex` otherwise. `sandy --new` starts fresh, and `sandy --resume` opens codex's own session picker (`codex resume`). Sessions started by `codex exec` (headless `-p`) do not count, and headless runs are never resumed.

Sandy forces `sandbox_mode = "danger-full-access"` in the container's `~/.codex/config.toml` and passes `--sandbox danger-full-access` on the CLI (belt-and-suspenders). Interactive codex also gets `--ask-for-approval never` while `SANDY_SKIP_PERMISSIONS=true` (the default), so it runs unprompted like claude and gemini; set `SANDY_SKIP_PERMISSIONS=false` to keep codex's approval prompts. Codex's Landlock sandbox does not nest cleanly inside Docker — sandy provides the outer isolation. Interactive codex also gets `--no-daemon` when the installed codex has that flag (codex-cli 0.163.0+): codex's background app-server daemon would otherwise copy itself (about 460 MB) into the sandbox's `~/.codex`, keep running after the pane, and update itself from the network, and it refuses to start when that copy is incomplete (`daemon executable not found … repair the existing installation`). `codex agents`, which needs that daemon, is therefore unavailable in sandy. A `codex/packages/app-server-daemon/` directory left in a sandbox by an earlier launch is safe to delete. On first launch sandy also seeds a full `[notice]` block in `config.toml` to suppress all first-run prompts and appends a trusted-project entry for your workspace.

Headless mode (`-p` / `--print` / `--prompt "..."`) translates to `codex exec --skip-git-repo-check` — the prompt is passed as a positional arg, not a flag, and the trust/git-repo gate is skipped (codex 0.139+ otherwise refuses to run headless outside a git repo; sandy already provides the isolation). `codex exec` only returns exit codes 0 (success) or 1 (failure), with no nuanced exit codes. `--continue` / `-c` is silently dropped (codex has `codex resume`, but no headless continuation flag).

Not supported with `codex`: `--remote`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS=discord`. Telegram channels work via the host-side tmux relay.

## Running OpenCode (`SANDY_AGENT=opencode`)

OpenCode (sst/opencode) is a provider-agnostic agent — sandy doesn't bind it to a specific LLM vendor. Set whichever provider key you have (in `.sandy/.secrets` or env), tweak `~/.config/opencode/opencode.json`, and OpenCode picks the matching provider:

| Provider | Key | Notes |
|---|---|---|
| Anthropic | `ANTHROPIC_API_KEY=sk-ant-...` | OpenCode reads natively |
| OpenAI | `OPENAI_API_KEY=sk-...` | Shared with Codex agent if both active |
| Google | `GEMINI_API_KEY=...` | Shared with Gemini agent if both active |
| OAuth | `opencode auth login` on host → `~/.local/share/opencode/auth.json` | Mounted read-only into the container |

Sandy seeds `~/.config/opencode/opencode.json` from the host's copy on first launch — point it at any provider OpenCode supports, including a local LLM.

**Local LLM passthrough.** Pair OpenCode with `SANDY_LOCAL_LLM_HOST=<ip>:<port>` (e.g. `127.0.0.1:11434` for Ollama, `localhost:8000` for vLLM, etc.) to allow the container to reach a local LLM running on the Docker host. With the egress proxy on (default), the proxy's dedicated forward listener relays `host.docker.internal:<port>` to the real host; with the proxy off (`SANDY_EGRESS=off`, Linux) sandy instead inserts a single narrow `iptables ACCEPT` for that exact `host:port` and maps `host.docker.internal` to the bridge gateway (Linux Docker doesn't auto-resolve it). Either way sandy rejects world-open IPs (`0.0.0.0`) and bare IPs without ports. Edit `~/.config/opencode/opencode.json` to set the provider's `baseURL` to `http://host.docker.internal:<port>/v1`. The rule is removed on session exit. The rest of LAN remains blocked.

Headless mode (`-p` / `--print` / `--prompt "..."`) translates to `opencode run` — the prompt is positional. `--continue` / `-c` is silently dropped (no headless resume flag yet).

Not supported with `opencode` in v0: `--remote`, `SANDY_SKILL_PACKS`, `SANDY_CHANNELS=discord`. Synthkit is installed in the image but skill auto-discovery for opencode is deferred until upstream support stabilizes.

## Running Grok Build (`SANDY_AGENT=grok`)

Grok Build is xAI's coding agent. Sandy installs it in the image from `https://x.ai/cli/install.sh` (a prebuilt binary, relocated onto `PATH` since the home dir is a tmpfs) and authenticates it **fully headless from an `XAI_API_KEY`** — no auth file to manage:

| Auth | How | Notes |
|---|---|---|
| API key | `XAI_API_KEY=xai-...` in `.sandy/.secrets` or env | Forwarded into the container; the primary path |
| OAuth | `grok login` inside the container | Session persists in the `~/.grok` sandbox mount across launches |

- Model: `GROK_MODEL=grok-4.5` (default; passed as `-m`). Probe override: `SANDY_GROK_AUTH=auto|api_key|oauth`.
- Headless mode (`-p` / `--print` / `--prompt "..."`) runs `grok --no-auto-update -p "<prompt>"` (grok can't self-update against the read-only rootfs). `--continue` / `-c` is dropped.
- Not supported with `grok` in v0: `--remote`, `SANDY_SKILL_PACKS`, synthkit slash-commands, channels beyond the host-side Telegram relay. Auto-update detection isn't wired (no version API) — `sandy --rebuild` re-fetches the latest grok.

## Running Mirror (`SANDY_AGENT=mirror`, 2.9.0, experimental)

[Mirror](https://github.com/reflection-oss/mirror) is Reflection AI's coding agent. Sandy installs it from PyPI (`reflection-mirror`) with `uv` and runs it **on its own**: Mirror is still beta, so it is not part of the multi-agent image, and a combo such as `claude,mirror` is refused ([#464](https://github.com/rappdw/sandy/issues/464) tracks lifting that). The design decisions are in `decisions/2026-10-20-mirror-agent.md`.

| Auth | How | Notes |
|---|---|---|
| API key | `REFLECTION_API_KEY=...` in `~/.sandy/.secrets` or env | Forwarded through the private env-file; Mirror keeps it out of the commands it runs |
| Saved key | Paste it at Mirror's prompt on an interactive launch | Saved in this sandbox (`~/.mirror/reflection_api_key`) and used on later launches |
| Host key | `~/.mirror/reflection_api_key` on the host | Copied into the sandbox (mode `0600`) when neither of the above exists |

No other provider key reaches a Mirror sandbox. To use Mirror's web search or OpenRouter, forward those keys yourself with `SANDY_EXTRA_ENV=FIRECRAWL_API_KEY,OPENROUTER_API_KEY`. A `--start` or headless launch with no Reflection key is refused, because Mirror would otherwise sit on its key prompt with nobody there to answer it.

- **Permissions:** `SANDY_SKIP_PERMISSIONS` (default `true`) passes `--approval-mode auto` on every launch, and `false` passes `--approval-mode approve`. Mirror remembers the mode between launches, so sandy always sets it explicitly. Mirror's approval prompts are not a sandbox, by Mirror's own docs; sandy is the boundary.
- **First run:** sandy accepts Mirror's usage notice and trusts the workspace for you, inside the container, so `--start` and headless runs never stop on Mirror's `[y/N]` prompt. It also turns Mirror's anonymous usage analytics off when you haven't chosen; `/settings` turns them back on, and that choice is kept.
- **Model and effort:** `MIRROR_MODEL` passes `--model` for one launch (Mirror's saved `/model` choice applies otherwise; its default is `Beam-1.0-501B-A23B`). `SANDY_EFFORT` passes `--reasoning-effort` with the same level name. With `SANDY_EFFORT` unset sandy passes nothing, and **Mirror's own default is `max`**, the most expensive level; use `/effort` in Mirror or set `SANDY_EFFORT` to change it.
- **Sessions:** an interactive launch reopens the workspace's last conversation (`--continue`); `sandy --new` starts fresh, and `sandy --resume` opens a fresh session where `/resume` picks an older one. Headless (`-p`) runs `mirror exec`, which always starts fresh and exits `0` on success, `1` otherwise.
- **Updates:** Mirror's own updater is off (`MIRROR_SKIP_UPDATE=1`); sandy checks PyPI at launch and rebuilds `sandy-mirror` when a newer release exists.
- **Workspace files:** `.mirror/` in a project holds Mirror extensions, which are Python that Mirror runs, so sandy mounts it read-only like `.claude/hooks/`.
- **A local model:** `SANDY_LOCAL_LLM_HOST` opens the network path; point Mirror at it from `$SANDBOX_DIR/agent-args.mirror`: `--api openai-chat-completions --base-url http://host.docker.internal:<port>/v1 --model <name>`.
- **Never use `--log-level debug`:** Mirror's debug logs include request headers, with the API key, and they persist in the sandbox.
- Not supported with `mirror` yet: multi-agent combos, `--remote`, `SANDY_SKILL_PACKS`, synthkit commands, Mirror's `/sandbox` (it needs `/dev/kvm`, which sandy containers do not have). Strict egress allows `api.reflection.ai` only.

## Multi-agent mode

Sandy runs any combination of Claude, Gemini, Codex, OpenCode, and Grok (not Mirror, which runs alone) side-by-side in a single tmux session — **up to 4 at once** (the layout is a 2×2 grid) — selected via comma-separated values in `SANDY_AGENT`:

```bash
SANDY_AGENT=claude,gemini              # two panes
SANDY_AGENT=claude,codex               # two panes
SANDY_AGENT=claude,opencode            # two panes
SANDY_AGENT=claude,gemini,codex,opencode  # four panes
SANDY_AGENT=all                        # alias for claude,gemini,codex,opencode
```

Panes appear in the order listed. Each agent has its own config dir(s): `~/.claude`, `~/.gemini`, `~/.codex`, and `~/.config/opencode` + `~/.local/share/opencode`. All panes share the same workspace mount. Exiting one pane leaves the others running. Single-agent modes use their own Docker images (`sandy-claude-code`, `sandy-gemini-cli`, `sandy-codex`, `sandy-opencode`, `sandy-grok`); any multi-agent combo uses the `sandy-full` image, which bundles all five CLIs. **Note:** in the 4-agent 2×2 grid, tmux's pane-index numbering does not match the order panes were spawned in — sandy publishes a stable pane-identity contract for anything that needs to tell agents apart in-container (session name, pane option, spawn order); see "Pane-identity contract" in `SPECIFICATION.md`.

**Resizing panes**: `prefix` + `H` / `J` / `K` / `L` (the prefix is tmux's default, `Ctrl-b`) resizes the active pane by 5 cells, moving its border left / down / up / right, and repeats — press the prefix once, then tap the letter as many times as you need. Sandy adds these because tmux's own resize keys do not work on macOS out of the box: `prefix` + Ctrl-Arrow is captured by Mission Control, and `prefix` + Option-Arrow needs the terminal's "Option as Meta" setting. Dragging a pane border with the mouse also works.

**Feature support in multi-agent mode**: skill packs apply to the Claude pane only. Telegram channels use the host-side relay and are routed to the first agent in `SANDY_AGENT` by default — override with `SANDY_CHANNEL_TARGET_PANE=0|1|2|3` (the Nth agent, 0-based; sandy finds that agent's pane by name, so the 2×2 grid routes correctly). `--remote` is not supported in any multi-agent combo. `SANDY_LOCAL_LLM_HOST` works in any combo that includes opencode (or any agent that wants to reach a host-side service over the gateway).


## Named Claude sessions (`.sandy/sessions/`)

Some workspaces run long-lived Claude Code agents rather than one conversation: a release captain and a reviewer, say, each with its own thread and memory. Declare each one as a file under `.sandy/sessions/`, and every launch brings them up as **named background sessions** (Claude Code's `claude --bg`), with **Claude Code's agent view** (`claude agents`) in the claude pane. Press Right to open a session, Left on an empty prompt to go back.

```markdown
<!-- .sandy/sessions/release-captain.md -->
---
name: Release Captain
receives: [cross_session]
---
## On create
You coordinate releases for this repository. Read docs/releasing.md, then …

## On resume
Re-read your startup files, re-create your crons and watchers, run one cycle, then report.
```

At each launch, for each file:

- **Found** (a background session with that `name` exists in this sandbox): sandy resumes it, sending the `## On resume` text once. A session's background jobs, crons and watchers don't survive a relaunch, so this is where it re-creates them.
- **Not found**: sandy creates it with that name and sends the `## On create` text as its first prompt.
- **Adopting a session you already have**: add `session: <full session id>` to the front matter. Sandy then resumes exactly that session, whatever it is called. Find the id with `claude agents --json --all` inside the container.

**The format is strict.** The front matter allows `name` (required: letters, digits, spaces, `.`, `_`, `-`), `session` and `receives`. The body allows exactly the two headings above; use `###` or deeper inside a section for your own structure. Anything else (an unknown key, another `#`/`##` heading, text outside a section, a symlink, a non-`.md` file) refuses the launch and names the file and line. A typo that silently did nothing would leave an agent un-started while every check looked fine. `## On create` is required unless `session:` is set.

**Flags are fixed when a session is created.** Claude Code saves a background session's options and reuses them every time it wakes the session. Passing any flag on a resume makes Claude Code start a *copy* under a new id (measured on Claude Code 2.1.296), so sandy resumes with no flags at all. A new session is created with sandy's own flags (model, effort, permission mode, teammate mode), your `agent-args.claude` / `SANDY_AGENT_ARGS`, and that session's own args from `~/.sandy/sandboxes/<sandbox>/agent-args.claude.<slug>` (privileged by where it lives, like `agent-args.claude`). If what sandy would pass changes later, the launch warns and names the session; recreate it to apply the change.

**`receives` names the one session that gets each single-receiver thing.** At most one session may claim each value:

| value | what that session gets |
|---|---|
| `cross_session` | Cross-session (peer) messages: sandy sets `crossSessionInbound` to `accept`, and every *other* session is created with an inline `refuse`. A feature that declares `receives: ["cross_session"]` sends its `agent_args` (an MCP config, say) to this session only. A selected feature like that with no claiming session refuses the launch. |
| `channels` | The `SANDY_CHANNELS` plugin (`--channels`). With named sessions, `SANDY_CHANNELS` set and no claiming session refuses the launch, and the host-side Telegram relay stands down (agent view can't take relayed keystrokes). |

A session you **adopt** was created without sandy's inbound `refuse` pin. If it doesn't claim `cross_session`, it can still receive peer messages while another session claims them; the launch warns about it every time, and `--print-state` reports `inbound_pinned: "no"`. Recreate it when its thread is expendable to close that.

**When they apply.** Interactive launches and `--start`, with claude selected. Headless (`-p`), `--remote` and `--provision` ignore the files with one notice. `sandy --new` never touches a named session. `SANDY_CLAUDE_SESSIONS=0` in the environment gives an ordinary claude pane for one launch; it's env-only, so a committed config can't switch your agents off.

**Readiness.** `--start` reports ready (exit `0`) only once every declared session is running. Otherwise it exits **`9`**, names each one and why (ambiguous name, unknown `session:` id, a copy instead of a resume, not running after 60s), and **leaves the container running**, so the sessions that did come up keep working. `--print-state` reports each session's status under `claude_sessions`.

Files under `.sandy/sessions/` are not part of the `.sandy/Dockerfile` build context: editing one never re-prompts the Dockerfile approval or rebuilds the project image. `.sandy/` is read-only inside the container, so an agent can't rewrite its own instructions.

## Headless / remote servers

**Recommended**: Use a long-lived token (valid 1 year) to avoid OAuth expiry entirely:

1. On a machine with a browser, run: `claude setup-token`
2. Copy the token and add to `~/.sandy/.secrets` on the headless server (applies to all projects):
   ```
   CLAUDE_CODE_OAUTH_TOKEN=your_token_here
   ```
3. Run `sandy` — no browser needed, no `/login` needed

**Fallback** (without a long-lived token): Sandy skips the browser-based OAuth flow on Linux and directs you to use `/login` inside the session.

The `/login` URL is long and Claude Code wraps it with indentation, which breaks copy-paste. To work around this on macOS:

1. Select the wrapped URL text in your terminal and copy it (Cmd+C)
2. Clean and open it with: `pbpaste | tr -d ' \n\t' | xargs open`

To automate this as a global keyboard shortcut (e.g., Ctrl+Cmd+U):

1. Open **Automator** > File > New > **Quick Action**
2. Set "Workflow receives" to **no input** in **any application**
3. Add a **Run Shell Script** action with: `pbpaste | tr -d ' \n\t' | xargs open`
4. Save as "Open Cleaned URL"
5. Assign a shortcut in **System Settings > Keyboard > Keyboard Shortcuts > Services**
