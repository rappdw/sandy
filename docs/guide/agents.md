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
| OAuth (browser login) | Run `gemini auth` **on the host** once — sandy copies `~/.gemini/oauth_creds.json` (Gemini CLI ≥0.30; falls back to legacy `tokens.json`) into the container ephemerally on each launch | ⚠️ **See note below — free-tier OAuth is deprecated upstream** |

> ⚠️ **Gemini free-tier OAuth is deprecated by Google.** As of mid-2026, Google
> retired the free-tier `gemini-cli` OAuth login ("Gemini Code Assist for
> individuals") — a session using it fails with `IneligibleTierError` (redirect
> to the Antigravity product suite). This is **upstream**, not a sandy issue:
> sandy loads and forwards the credentials correctly; Google rejects them at the
> tier check, and the same happens running `gemini-cli` directly. **Use the API
> key or Vertex/ADC path instead.** (Tracked: issue #21.)

`gemini auth` must be run on the host because the container is headless and cannot open a browser. `--remote` is not supported in any multi-agent combo — only `SANDY_AGENT=claude` (single) works with `--remote`.

## Running Codex CLI (`SANDY_AGENT=codex`)

Sandy supports two Codex auth paths, probed automatically unless `SANDY_CODEX_AUTH` pins a specific one:

| Path | How to set up | When to use |
|---|---|---|
| API key | `OPENAI_API_KEY=sk-...` in `.sandy/.secrets` — sandy writes it into an ephemeral `auth.json` (what `codex login --with-api-key` would create) and mounts it **read-only**; codex 0.139+ ignores the bare env var for auth | Simplest; works on headless servers |
| OAuth (ChatGPT) | `sandy --login codex` in the workspace, or `codex login` **on the host** once — sandy seeds `~/.codex/auth.json` into this workspace's sandbox, where in-session refresh and later logins persist | ChatGPT Plus/Team/Enterprise accounts |

**`sandy --login codex`** logs codex in for this workspace's sandbox. It runs `codex login --device-auth` — the plain `codex login` waits on a `localhost:1455` callback that a browser on the host can never reach — and the credential lands in the sandbox's own `codex/auth.json`, which wins over the host's on every later launch. If a sandy session already runs for the workspace, the login runs inside it; otherwise sandy starts a one-shot launch whose only pane is the login. The session is OAuth by definition, so `OPENAI_API_KEY` is withheld from it. `--workspace PATH` and `--dry-run` (print the route, run nothing) are accepted; it needs a terminal. Other agents already have a route: claude is read from the host at every launch (log in there), `grok login` works inside the session, gemini and opencode authenticate on the host.

**`SANDY_CODEX_AUTH=oauth` withholds `OPENAI_API_KEY` from the container**, so the account credential is the only Codex credential in the box — except beside opencode (`SANDY_AGENT=codex,opencode`), which reads the key from the environment; there the key still reaches the container and the launch says so.

**Codex resumes where you left off.** An interactive launch runs `codex resume --last` when this sandbox already holds an interactive codex session for the workspace, and a plain `codex` otherwise. `sandy --new` starts fresh, and `sandy --resume` opens codex's own session picker (`codex resume`). Sessions started by `codex exec` (headless `-p`) do not count, and headless runs are never resumed.

Sandy forces `sandbox_mode = "danger-full-access"` in the container's `~/.codex/config.toml` and passes `--sandbox danger-full-access` on the CLI (belt-and-suspenders). Codex's Landlock sandbox does not nest cleanly inside Docker — sandy provides the outer isolation. On first launch sandy also seeds a full `[notice]` block in `config.toml` to suppress all first-run prompts and appends a trusted-project entry for your workspace.

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

## Multi-agent mode

Sandy runs any combination of Claude, Gemini, Codex, OpenCode, and Grok side-by-side in a single tmux session — **up to 4 at once** (the layout is a 2×2 grid) — selected via comma-separated values in `SANDY_AGENT`:

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
