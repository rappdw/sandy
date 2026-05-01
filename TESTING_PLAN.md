# Sandy — Manual Testing Plan

Tests that require interactive TUI sessions, human observation, or infrastructure not available to automated scripts. Run these after both test suites pass:

```sh
bash test/run-tests.sh              # pure-script, no Docker
bash test/run-integration-tests.sh  # headless end-to-end, needs Docker + API keys
```

---

## Prerequisites

- Docker running
- All automated tests passing
- API keys for agents you want to test (codex, gemini, claude, opencode)

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

```sh
sed -i.bak '/GEMINI_API_KEY/d' .sandy/.secrets
echo 'SANDY_GEMINI_AUTH=oauth' >> .sandy/config
sandy -p "hi"
```

- [x] Uses only the OAuth path
- [x] If no `~/.gemini/oauth_creds.json` (or legacy `tokens.json`) exists, shows "No Gemini credentials found" warning

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

- [ ] Four panes in a 2×2 grid: Claude (top-left, pane 0), Gemini (top-right, pane 1), Codex (bottom-right, pane 2), OpenCode (bottom-left, pane 3)
- [ ] Each pane has its own prompt and responds independently

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

- [ ] OpenCode TUI launches without an auth prompt
- [ ] A simple "say hi" prompt returns a response
- [ ] `~/.config/opencode/opencode.json` exists in the sandbox

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
| 5 | Relay PID left behind after exit | `cleanup()` trap missing `CHANNEL_RELAY_PID` |
