# Sandy — Manual Testing Plan

Tests that require interactive TUI sessions, human observation, or infrastructure not available to automated scripts. Run these after both test suites pass:

```sh
bash test/run-tests.sh              # pure-script, no Docker
bash test/run-integration-tests.sh  # headless end-to-end, needs Docker + API keys
```

> **Per-RC walkthrough.** Every checkbox below is reset to unchecked at each RC
> cut — tick items as you verify them *for this RC*. Currently tracking:
> **`v1.0.0-rc1`**. Skip a section only if you have no credential/platform for
> it (note it as skipped rather than ticking it).

---

## Prerequisites

- [x] Docker running
- [x] Both automated suites green (`run-tests.sh`, `run-integration-tests.sh`)
- [x] Fresh install-from-tag verified (`curl … install.sh` pinned at the RC tag builds + launches)
- [x] API keys available for the agents you intend to test (codex, gemini, claude, opencode)

---

## RC completion tracker

At-a-glance section status. Tick a section here once **all** its sub-checkboxes
above are done (or the section is consciously skipped for lack of a
credential/platform). Detail lives in each section below.

**Agents**
- [x] 1.1 Codex — OAuth `:ro` mount write-rejection
- [x] 1.2 Codex — synthkit skills in TUI
- [x] 2.1 Gemini — interactive session
- [x] 2.2 Gemini — extensions seeding
- [x] 2.3 Gemini — synthkit TOML commands
- [x] 2.4 Gemini — workspace `.gemini/commands/` overlay
- [s] 2.5 Gemini — `SANDY_GEMINI_AUTH` pinning — skipped (upstream OAuth deprecation, issue #21)
- [x] 3.1 Claude — interactive session
- [x] 3.2 Claude — layout migration (v1 → v1.5)
- [x] 3.3 Claude — `--remote`

**Multi-agent & OpenCode**
- [x] 4.1 Dual-pane (claude + gemini)
- [x] 4.2 Arbitrary combos / triple / 4-agent grid
- [x] 4b.1 OpenCode — provider via env var
- [s] 4b.2 OpenCode — local-LLM passthrough — skipped (no Linux+Ollama host; validation is unit-tested, live forward path unexercised for rc1)

**Channels & network**
- [s] 5 Telegram relay — skipped (optional; no bot token configured this RC)
- [x] 6.0 Egress — macOS topology spike (if Docker Desktop changed)
- [x] 6.1 Egress — permissive mode (`=1`)
- [x] 6.2 Egress — strict mode (`=2`)
- [x] 6.3 Egress — off (`=0`) warning
- [x] 6.4 Egress — SSH-agent interaction (if `SANDY_SSH=agent`)

> **rc1 note on §6:** `SANDY_PROXY_REF` is no longer needed — a published rc pins
> its own `v1.0.0-rc1` tag for the proxy build (the proxy-ref fix in this cut).
> Ignore the "set `SANDY_PROXY_REF` to the M2.7 branch" instruction in §6's
> preamble; it's stale for a tagged release.

---

# 1. Codex interactive (`SANDY_AGENT=codex`)

## 1.1 OAuth read-only mount (write rejection)

**Only if you have `~/.codex/auth.json` from `codex login`.**

```sh
mkdir -p ~/sandy-test-codex && cd ~/sandy-test-codex
mkdir -p .sandy && echo 'SANDY_AGENT=codex' > .sandy/config
unset CODEX_API_KEY OPENAI_API_KEY
sandy                                 # interactive launch
```

Inside the TUI, open a shell pane (Ctrl-b then ") and run:
```sh
echo foo > ~/.codex/auth.json         # MUST fail: "Read-only file system"
```

- [x] Write to auth.json fails inside container

> **Automated**: OAuth detection, tmpdir creation, and cleanup are tested in `run-integration-tests.sh` §9. This step verifies the `:ro` mount actually blocks writes from inside the TUI.

---

## 1.2 Synthkit skills in TUI

```sh
CODEX_API_KEY=sk-REDACTED sandy
```

Inside the codex TUI:
```
/skills
```

- [x] List includes `md2pdf`, `md2doc`, `md2html`, `md2email`

Test via natural language prompt (codex skills are context, not slash commands):
```
convert /tmp/hi.md to PDF
```

Or test directly in a shell pane (Ctrl-b then "):
```sh
echo -e "# Hello\n\nThis is a test." > /tmp/hi.md
md2pdf /tmp/hi.md
ls /tmp/hi.pdf
```

- [x] PDF is produced

> **Note**: Codex skills are NOT slash commands — they appear in `/skills` as context that codex uses when answering prompts. To trigger them, ask naturally (e.g. "convert file.md to PDF") rather than typing `/md2pdf`.
>
> **Automated**: synthkit binary availability and WeasyPrint functionality (via `md2html`) tested in `run-integration-tests.sh` §4. This step verifies codex's `/skills` TUI command discovers them and they produce actual output.

---

# 2. Gemini interactive (`SANDY_AGENT=gemini`)

## 2.1 Interactive session

```sh
mkdir -p ~/sandy-test-gemini && cd ~/sandy-test-gemini
git init && echo "test" > file.txt
mkdir -p .sandy
echo 'SANDY_AGENT=gemini' > .sandy/config
echo 'GEMINI_API_KEY=your_key_here' > .sandy/.secrets

sandy
```

- [x] Launches into tmux, `gemini` prompt appears
- [x] `what files are in this directory?` lists `file.txt`
- [x] Exit with Ctrl+D works cleanly

> **Automated**: headless response and sandbox layout tested in `run-integration-tests.sh` §5. This step verifies the interactive TUI experience.

---

## 2.2 Extensions seeding

```sh
cd ~/sandy-test-gemini
echo 'SANDY_GEMINI_EXTENSIONS=https://github.com/gemini-cli-extensions/security' >> .sandy/config
sandy -p "list your available extensions"
```

- [x] First run shows `[sandy] Installing Gemini extensions`
- [x] Second run is a no-op (idempotent)
- [x] `ls ~/.sandy/sandboxes/sandy-test-gemini-*/gemini/extensions/` shows `security/`

---

## 2.3 Synthkit TOML commands

```sh
sandy
# In the session:
/md2pdf --help
```

- [x] Gemini recognizes `/md2pdf` and runs the `md2pdf` binary

---

## 2.4 Workspace `.gemini/commands/` overlay

```sh
mkdir -p .gemini/commands
cat > .gemini/commands/hello.toml <<'EOF'
description = "say hi"
prompt = "Say hi"
EOF

sandy
# Inside gemini session, try: /hello
```

- [x] `/hello` IS visible inside the session (overlay is seeded from host on first creation)

Inside the session, create a new command file, then after exit:
- [x] New file is NOT in the host workspace dir
- [x] New file IS in the sandbox overlay dir (`workspace-gemini-commands/`)
- [x] Host's `hello.toml` is also in the sandbox overlay dir (seeded copy)

Delete the overlay dir and re-launch to verify re-seeding:
```sh
rm -rf ~/.sandy/sandboxes/sandy-test-gemini-*/workspace-gemini-commands
sandy
# /hello should be visible again (re-seeded from host)
```

---

## 2.5 `SANDY_GEMINI_AUTH` pinning

> **⊘ SKIPPED for v1.0.0-rc1 — upstream deprecation (not a sandy failure).**
> Google retired the free-tier `gemini-cli` OAuth login ("Gemini Code Assist for
> individuals" → `IneligibleTierError`, redirect to Antigravity), so the OAuth
> sub-path cannot succeed for a free-tier account regardless of sandy. Sandy
> loads and forwards the creds correctly; Google rejects them at the tier check.
> Gemini via `GEMINI_API_KEY` (§2.1–2.4) and via Vertex/ADC is unaffected and is
> the recommended path. Tracked: issue #21. Re-enable this section if a valid
> refreshing OAuth tier returns.

```sh
sed -i.bak '/GEMINI_API_KEY/d' .sandy/.secrets
echo 'SANDY_GEMINI_AUTH=oauth' >> .sandy/config
sandy -p "hi"
```

- [~] Uses only the OAuth path — **skipped (upstream: free-tier OAuth deprecated, issue #21)**
- [ ] If no `~/.gemini/oauth_creds.json` (or legacy `tokens.json`) exists, shows "No Gemini credentials found" warning *(still testable — this is sandy's absent-creds path, independent of Google's tier check)*

---

# 3. Claude interactive (`SANDY_AGENT=claude`)

## 3.1 Interactive session

```sh
mkdir -p ~/sandy-test-claude && cd ~/sandy-test-claude
git init && echo "hello" > README.md
sandy
```

- [x] Normal tmux session, `claude` prompt
- [x] `/help` works
- [x] Exit with Ctrl+D

> **Automated**: headless response and sandbox layout tested in `run-integration-tests.sh` §7.

---

## 3.2 Layout migration (v1 → v1.5)

```sh
SB=$(ls -d ~/.sandy/sandboxes/sandy-test-claude-*/ | head -1)
mv "$SB/claude/"* "$SB/" 2>/dev/null
rmdir "$SB/claude"

cd ~/sandy-test-claude && sandy -p "hi"
```

- [x] `[sandy] Migrating sandbox to v1.5 layout (claude/ subdir)...` appears once
- [x] Re-running sandy produces no second migration message (idempotent)

> **Automated**: migration logic tested in `run-tests.sh` §29 (4 scenarios). This verifies the live migration with a real sandbox.

---

## 3.3 `--remote`

```sh
sandy --remote
```

- [x] Launches `claude remote-control` (requires full OAuth; long-lived tokens are rejected by Claude Code with a clear error)

---

# 4. Multi-agent mode (comma-separated `SANDY_AGENT`)

## 4.0 Matrix coverage sign-off (M4 PR 4.3)

This matrix maps out **every** viable agent combination and where each is
covered. It's a *coverage map*, not a to-do list — most cells run unattended in
CI or are already covered by the single-agent sections you walk elsewhere. The
**"You run this RC"** column is the only thing that needs your hands; everything
else is informational.

| Combo | Automated coverage (no action) | Also covered by | **You run this RC** |
|---|---|---|---|
| `claude` | integ §7 (api_key/oauth) | §3 (you're walking it) | — |
| `gemini` | integ §5/§10 | §2 (you're walking it) | — |
| `codex` | integ §2/§9 | §1 (you're walking it) | — |
| `opencode` | integ §11 (provider key) | — | **§4b.1 / §4b.2** |
| `claude,gemini` | run-tests §54 routing | integ §16 if creds | **§4.1** (multi-pane) |
| `claude,codex` | run-tests §54 routing | integ §16 if creds | **§4.2** (multi-pane) |
| `gemini,codex` | run-tests §54 routing | integ §16 fallback | covered by §4.2 |
| `claude,gemini,codex` | run-tests §54 routing | — | **§4.2** (triple-pane) |
| `all` (4 agents) | run-tests §54 + alias-expand | — | **§4.2** (2×2 grid) |

**Bottom line — the manual multi-agent work for this RC is exactly:**
walk **§4.1**, **§4.2**, and **§4b** below. That's the whole "You run this RC"
column, collapsed (the single-agent rows are done in §1–§3, which you're already
doing). The three sign-off boxes track these.

Why the rest needs no action:
- **Headless** multi-agent routes the `-p` prompt to the **first** agent only
  (no panes); `run-tests.sh §54` pins image selection (`sandy-full`) and
  first-agent routing for every row above, unattended, no Docker.
- **integ §16** runs one *live* combo (first available of `claude,codex` →
  `claude,gemini` → `gemini,codex`) end-to-end and asserts the `sandy-full`
  image was used — so one live multi-pane combo is already exercised in CI. The
  reason §4.1/§4.2 still need you: **a multi-pane tmux layout can only be
  eyeballed in a real TTY** (do the panes actually split? does each respond?) —
  that's what CI can't see and you're signing off.
- A combo with no two-agent credential pair → integ §16 prints
  `skip "multi-agent combo (need 2 of claude/gemini/codex credentials)"` — so if
  you lack a pair, note §4.1/§4.2 skipped, same as any other credential gap.

Sign-off (tick when the manual rows have been walked this RC):

- [x] §4.1 dual-pane (claude + gemini)
- [x] §4.2 `claude,codex` / triple / 4-agent grid
- [x] §4b OpenCode single-agent

## 4.1 Dual-pane launch (claude + gemini)

```sh
mkdir -p ~/sandy-test-multi && cd ~/sandy-test-multi
git init && echo "multi test" > README.md
mkdir -p .sandy
echo 'SANDY_AGENT=claude,gemini' > .sandy/config
echo 'GEMINI_API_KEY=your_key_here' > .sandy/.secrets

sandy
```

- [x] Tmux opens with **two horizontal panes**: Claude (pane 0), Gemini (pane 1)
- [x] Each pane has its own prompt
- [x] Type a question in Claude pane — it responds
- [x] `Ctrl-B →` to Gemini pane — ask a question — it responds

## 4.2 Arbitrary combos and triple-pane

```sh
# Test claude,codex combo
echo 'SANDY_AGENT=claude,codex' > .sandy/config
sandy
```

- [x] Two horizontal panes: Claude (pane 0), Codex (pane 1)

```sh
# Test all three agents
echo 'SANDY_AGENT=claude,gemini,codex' > .sandy/config
sandy
```

- [x] Three panes: Claude (pane 0, left), Gemini (pane 1, top-right), Codex (pane 2, bottom-right)
- [x] Each pane has its own prompt and responds independently

```sh
# Test all four agents (claude + gemini + codex + opencode in 2x2 grid)
echo 'SANDY_AGENT=all' > .sandy/config
sandy
```

- [x] Four panes in a 2×2 grid: Claude (top-left, pane 0), Gemini (top-right, pane 1), Codex (bottom-right, pane 2), OpenCode (bottom-left, pane 3)
- [x] Each pane has its own prompt and responds independently

---

# 4b. OpenCode interactive (`SANDY_AGENT=opencode`)

## 4b.1 Provider via env var

```sh
mkdir -p ~/sandy-test-opencode && cd ~/sandy-test-opencode
git init -q
mkdir -p .sandy && echo 'SANDY_AGENT=opencode' > .sandy/config
# Use whichever provider key you have:
#   ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY
sandy
```

- [x] OpenCode TUI launches without an auth prompt
- [x] A simple "say hi" prompt returns a response
- [x] `~/.config/opencode/opencode.json` exists in the sandbox

## 4b.2 Local LLM passthrough (Linux + Ollama)

**Prereq**: Ollama running on host port 11434 with at least one model pulled (e.g. `ollama pull gemma2:2b`).

```sh
cd ~/sandy-test-opencode
cat > .sandy/config <<EOF
SANDY_AGENT=opencode
SANDY_LOCAL_LLM_HOST=127.0.0.1:11434
EOF
sandy
```

Inside the session, edit `~/.config/opencode/opencode.json` to add an Ollama provider with `baseURL: "http://host.docker.internal:11434/v1"`.

- [ ] `[sandy] Allowed local LLM: <gw>:11434 (host.docker.internal mapped)` appears at launch
- [ ] `curl http://host.docker.internal:11434/api/tags` succeeds inside the container
- [ ] `curl http://192.168.1.1` still fails (LAN block intact)
- [ ] OpenCode answers a prompt using the local model

---

# 5. Telegram relay (optional)

Prereqs: Telegram bot token + your user ID.

```sh
cd ~/sandy-test-both   # or any agent project
cat >> .sandy/.secrets <<EOF
TELEGRAM_BOT_TOKEN=123:ABC...
TELEGRAM_ALLOWED_SENDERS=your_user_id
EOF
echo 'SANDY_CHANNELS=telegram' >> .sandy/config

sandy
```

- [ ] `[sandy] Telegram channel relay started` appears
- [ ] DM the bot — message appears as keystrokes in the session
- [ ] Messages from unauthorized users are silently dropped
- [ ] After exit: `ps aux | grep channel-relay` finds nothing (cleanup worked)

---

# 6. Egress proxy (`SANDY_EGRESS_PROXY`) — macOS

The egress proxy is the one feature CI **cannot** cover: GitHub Actions is
Linux-only, and the whole point of M2.7 is to fix macOS network isolation
(finding F2), where iptables is unreachable. This section is the manual macOS
gate. Run it on real Docker Desktop whenever the proxy code, the launcher
network wiring, or Docker Desktop itself changes.

Prereqs: macOS + Docker Desktop, working Claude (OAuth or `ANTHROPIC_API_KEY`).
`SANDY_PROXY_REF` is **not** needed — M2.7 is on `main`, and a published release
(or rc) pins its own version tag for the proxy build. (Only set it if you're
testing an unmerged proxy branch from a local checkout.)

## 6.0 Re-run the topology spike (do this first when Docker Desktop updated)

```sh
bash test/spike/macos-internal-network-spike.sh
```

- [x] Ends with `GATE: PASSED on macOS.` (all assertions). If it fails, the
      `--internal` two-network assumptions no longer hold on this Docker Desktop
      version — stop and investigate before trusting the proxy.

## 6.1 Permissive mode (`=1`) — closes F2 with zero friction

```sh
cd ~/some-project
SANDY_EGRESS_PROXY=1 SANDY_DEBUG_PROXY=1 \
  sandy -p "run: curl -sS -m 8 https://api.github.com/zen; echo ---; curl -sS -m 5 http://192.168.1.1 || echo LAN-blocked"
```

- [x] `Creating egress-proxy networks (mode=permissive)` then `Starting egress
      proxy sidecar (… @ <ip>)`
- [x] Launch summary: `Network: Egress proxy (permissive): public internet
      allowed; LAN/host/metadata blocked`
- [x] The `[debug] probing the agent resolver view` block shows
      `getent … api.anthropic.com → <proxy-ip>` and `curl … http_code=404
      remote_ip=<proxy-ip>` (a real 404 from the API **through** the proxy)
- [x] The agent runs: the `zen` quote prints (HTTPS through the proxy works
      end-to-end — no `ECONNRESET`)
- [x] `http://192.168.1.1` fails fast → `LAN-blocked` (**F2 closed**)
- [x] On exit, no leaked networks: `docker network ls | grep sandy_` is empty

## 6.2 Strict mode (`=2`) — allowlist only

```sh
SANDY_EGRESS_PROXY=2 \
  sandy -p "run: curl -sS -m 8 https://api.github.com/zen; echo ---; curl -sS -m 6 https://example.com || echo example-blocked"
```

- [x] Launch summary: `Network: Egress proxy (strict): allowlist + …`
- [x] `api.github.com` (in the default allowlist) reachable → `zen` quote prints
- [x] `example.com` (not allowlisted) blocked → `example-blocked`
- [x] Add it back: `SANDY_ALLOW_HOSTS=example.com SANDY_EGRESS_PROXY=2 …` →
      `example.com` now reachable (approve the passive-privileged prompt if run
      from a workspace `.sandy/config`)

## 6.3 Off (`=0`) — explicit opt-out; honest warning still fires

Egress now **defaults to `1` (permissive)**, so `=0` is an explicit opt-out, not
the default. A bare `sandy` uses the proxy — you must set `SANDY_EGRESS_PROXY=0`
to get the legacy behavior (no isolation on macOS / iptables-only on Linux).

```sh
SANDY_EGRESS_PROXY=0 sandy -p "echo hi"
```

- [x] The macOS no-isolation warning banner prints (`Network isolation is NOT
      active on Darwin … set SANDY_EGRESS_PROXY=1`)
- [x] Launch summary: `Network: Internet + LAN reachable — NO isolation on
      Darwin …`

## 6.4 SSH-agent interaction (if you use `SANDY_SSH=agent`)

```sh
SANDY_SSH=agent SANDY_EGRESS_PROXY=1 \
  sandy -p "run: ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | head -1"
```

- [x] A warning notes host-agent signing is unavailable on macOS under the proxy
- [x] git-over-SSH still tunnels: the `git@github.com` line returns GitHub's
      `Hi <user>! You've successfully authenticated…` **or** a permission line
      (proves the CONNECT tunnel reached github.com:22), not a connection error

---

# Cleanup

```sh
rm -rf ~/sandy-test-claude ~/sandy-test-gemini ~/sandy-test-both ~/sandy-test-codex ~/sandy-test-opencode
rm -rf ~/.sandy/sandboxes/sandy-test-*
docker rmi sandy-gemini-cli sandy-both sandy-codex sandy-opencode 2>/dev/null || true
```

---

# Known failure signatures

| Section | Failure signature | Root cause |
|---|---|---|
| 1.1 | Write to auth.json succeeds | Mount is not `:ro` |
| 1.2 | `/skills` empty | YAML frontmatter missing or `_sandy_has_codex` block didn't fire |
| 2.1 | `unknown flag --sandbox=none` | Gemini sandbox env var not set correctly |
| 2.4 | Host file visible in overlay | Overlay mount not applied |
| 3.2 | Migration runs every launch | Migration guard broken |
| 4.1 | Single tmux pane | `build_both` launch block structural bug |
| 6.1 | `ECONNRESET` / `tlsv1 alert protocol version` | Transparent path double-sends the ClientHello (`up.Write(prefix)` not removed) |
| 6.1 | probe `remote_ip` is a public IP, not the proxy | DNS redirect not taking effect (agent not on sidecar, or `--dns` not applied) |
| 6.1 | upstream dials time out (slow fail) | Proxy booted on the `--internal` sidecar instead of egress (no default route) |
| 6.1 | leaked `sandy_*` networks after exit | `ensure_network` runs before the cleanup trap is armed |
| 6.3 | no warning banner with proxy off on macOS | `apply_network_isolation` wrongly skipped, or banner removed unconditionally |
| 5 | Relay PID left behind after exit | `cleanup()` trap missing `CHANNEL_RELAY_PID` |
