# Sandy v1.5 Manual Testing Plan (Gemini Support)

Manual validation steps for the Gemini CLI and dual-agent support added in v1.5. Run blocks in order. Each block is independent — skip any you don't care about.

## 0. Prerequisites

```sh
cd ~/dev/sandy
bash -n sandy && echo "syntax OK"
./sandy --version   # should print 0.8.2-dev-<hash>
```

Have ready (pick at least one Gemini auth path):
- `GEMINI_API_KEY=...` from https://aistudio.google.com/apikey, OR
- Ran `gemini auth` on host once (produces `~/.gemini/tokens.json`), OR
- Ran `gcloud auth application-default login`

### Where to put `GEMINI_API_KEY`

- **Per-project** (recommended for testing): `.sandy/.secrets` in the project dir (gitignore it)
- **User-level**: `~/.sandy/.secrets` (applies to all projects)
- **Ephemeral**: `export GEMINI_API_KEY=...` in the shell before running `sandy`

Load order: user-config → user-secrets → project-config → project-secrets (later wins). **Do NOT** put secrets in `.sandy/config` — that file is commonly committed.

---

## 1. Regression: Claude still works (`SANDY_AGENT=claude`)

```sh
cd ~ && mkdir sandy-test-claude && cd sandy-test-claude
git init && echo "hello" > README.md
sandy -p "what files are in this directory?"
```

**Expect:** Claude Code runs, lists `README.md`, exits cleanly. No errors about `.claude/settings.json` paths or layout migration.

```sh
sandy   # interactive
```

**Expect:** Normal tmux session, `claude` prompt. `/help` works. Exit with Ctrl+D.

**Check sandbox layout:**
```sh
ls ~/.sandy/sandboxes/sandy-test-claude-*/
```

**Expect:** You see `claude/`, `pip/`, `uv/`, `npm-global/`, `go/`, `cargo/` — NO `settings.json` at the top level (v1.5 layout).

---

## 2. Layout migration (v1 → v1.5)

Simulate a v1-era sandbox and confirm auto-migration:

```sh
# Find your test sandbox dir
SB=$(ls -d ~/.sandy/sandboxes/sandy-test-claude-*/ | head -1)
# Move contents back to v1 layout
mv "$SB/claude/"* "$SB/" 2>/dev/null
rmdir "$SB/claude"
ls "$SB"   # should show settings.json etc. at top level (v1 state)

# Re-launch
cd ~/sandy-test-claude && sandy -p "hi"
```

**Expect:** You see `[sandy] Migrating sandbox to v1.5 layout (claude/ subdir)...` once. Session still works.

```sh
ls "$SB"          # claude/ subdir back
ls "$SB/claude"   # settings.json, projects/, etc.
```

**Expect:** Claude-owned files moved into `claude/`; `pip/`, `uv/`, etc. untouched. Re-run sandy — no second migration message (idempotent).

---

## 3. Gemini-only mode (`SANDY_AGENT=gemini`)

```sh
cd ~ && mkdir sandy-test-gemini && cd sandy-test-gemini
git init && echo "test" > file.txt
mkdir -p .sandy
cat > .sandy/config <<EOF
SANDY_AGENT=gemini
EOF
cat > .sandy/.secrets <<EOF
GEMINI_API_KEY=your_key_here
EOF

sandy
```

**Expect:**
- On first run: builds `sandy-gemini-cli` image (takes a few min — downloads Node + Gemini CLI)
- Sandbox is created at `~/.sandy/sandboxes/sandy-test-gemini-<hash>/`
- You see `[sandy] Using GEMINI_API_KEY` (or OAuth/ADC message if you went that route)
- Launches into tmux, `gemini` prompt appears
- **No error about `--sandbox=none`** (this was the v1 bug — if you see it, Step 0 didn't land)

Ask Gemini: `what files are in this directory?`

**Expect:** Lists `file.txt`. Exit Ctrl+D.

**Check:**
```sh
ls ~/.sandy/sandboxes/sandy-test-gemini-*/
# Should show: gemini/, pip/, uv/, npm-global/, go/, cargo/ — NO claude/ dir
```

**Test `-p` flag translation** (the bug fixed during v1.5):
```sh
sandy -p "say hello in one word"
```

**Expect:** Gemini runs headless, prints one word, exits. If you see `unknown flag -p` or similar, the translation is broken.

---

## 4. OAuth path (only if you have host `~/.gemini/tokens.json`)

```sh
# Unset API key first
cd ~/sandy-test-gemini
sed -i.bak '/GEMINI_API_KEY/d' .sandy/.secrets
ls ~/.gemini/tokens.json && sandy -p "hi"
```

**Expect:** `[sandy] Loaded Gemini OAuth tokens from host`, Gemini runs without needing API key.

**Check ephemerality:**
```sh
# After sandy exits
ls ~/.sandy/sandboxes/sandy-test-gemini-*/gemini/tokens.json 2>&1
# Should NOT exist — tokens are copied to a tmpdir and cleaned up on exit
```

---

## 5. Gemini extensions seeding

```sh
cd ~/sandy-test-gemini
cat >> .sandy/config <<EOF
SANDY_GEMINI_EXTENSIONS=https://github.com/gemini-cli-extensions/security
EOF
sandy -p "list your available extensions"
```

**Expect:** First run shows `[sandy] Installing Gemini extensions` and the extension installs. Second run should be a no-op (idempotent — extension dir already exists).

**Check:**
```sh
ls ~/.sandy/sandboxes/sandy-test-gemini-*/gemini/extensions/
# Should show: security/
```

---

## 6. Dual-agent mode (`SANDY_AGENT=both`)

```sh
cd ~ && mkdir sandy-test-both && cd sandy-test-both
git init && echo "dual test" > README.md
mkdir -p .sandy
cat > .sandy/config <<EOF
SANDY_AGENT=both
EOF
cat > .sandy/.secrets <<EOF
GEMINI_API_KEY=your_key_here
EOF

sandy
```

**Expect:**
- First run builds `sandy-both` image (slowest — has both Claude Code and Gemini CLI)
- Tmux opens with **two horizontal panes**: Claude on the left (pane 0), Gemini on the right (pane 1)
- Each pane has its own prompt
- Status line shows "sandy: sandy-test-both"

**Interact:**
- Type a question in the Claude pane — it responds
- Tmux hotkey `Ctrl-B →` to switch to the Gemini pane — ask it a question — it responds
- `Ctrl-B d` to detach, or exit both for clean shutdown

**Check sandbox layout:**
```sh
ls ~/.sandy/sandboxes/sandy-test-both-*/
# Should show BOTH: claude/  gemini/  (plus pip/, uv/, etc.)
```

**Check `.claude.json` seeding for `both`:**
```sh
cat ~/.sandy/sandboxes/sandy-test-both-*.claude.json
# Should contain {"tipsDisabled":true,"installMethod":"native"} at minimum
```

---

## 7. Workspace `.gemini/commands/` overlay

In the gemini test project:
```sh
cd ~/sandy-test-gemini
mkdir -p .gemini/commands
cat > .gemini/commands/hello.toml <<'EOF'
description = "say hi"
prompt = "Say hi"
EOF

sandy
# Inside gemini session, try: /hello
```

**Expect:** `/hello` is NOT visible inside the session — the overlay hides host workspace content (same contract as Claude's `.claude/commands/`). If you want it visible, you'd add it through `~/.gemini/commands/` inside the container.

Then inside the session, create a new command:
```
(from inside gemini) create a file at .gemini/commands/test.toml with description "test" and prompt "test prompt"
```

After exit:
```sh
ls ~/sandy-test-gemini/.gemini/commands/
# test.toml should NOT be here (host untouched)
ls ~/.sandy/sandboxes/sandy-test-gemini-*/workspace-gemini-commands/
# test.toml should be here (sandbox overlay)
```

---

## 8. Synthkit TOML commands for Gemini

```sh
cd ~/sandy-test-gemini
sandy
# In the session:
/md2pdf --help
```

**Expect:** Gemini recognizes `/md2pdf` (the TOML file was seeded into `~/.gemini/commands/`) and runs the `md2pdf` binary.

**Check the generated file:**
```sh
docker exec $(docker ps --filter "name=sandy-" -q) cat /home/claude/.gemini/commands/md2pdf.toml
# Should show: description = "Convert markdown file(s) to PDF using md2pdf"
#              prompt = """..."""
```

---

## 9. `--remote` guard

```sh
cd ~/sandy-test-gemini
sandy --remote
```

**Expect:** Exits immediately with `[sandy] ERROR: --remote is only supported with SANDY_AGENT=claude (Gemini CLI has no remote-control mode)`.

Same test with `SANDY_AGENT=both`:
```sh
cd ~/sandy-test-both
sandy --remote
```

**Expect:** Same error.

Sanity check it still works for Claude:
```sh
cd ~/sandy-test-claude
sandy --remote
```

**Expect:** Launches `claude remote-control` (you can Ctrl+C out).

---

## 10. Telegram host-side relay (optional, needs bot)

Prereqs: You have a Telegram bot token + your user ID.

```sh
cd ~/sandy-test-both   # or sandy-test-gemini
cat >> .sandy/.secrets <<EOF
TELEGRAM_BOT_TOKEN=123:ABC...
TELEGRAM_ALLOWED_SENDERS=your_user_id
EOF
cat >> .sandy/config <<EOF
SANDY_CHANNELS=telegram
SANDY_CHANNEL_TARGET_PANE=0
EOF

sandy
```

**Expect:**
- `[sandy] Telegram channel relay started (PID ... → sandy-... pane 0)`
- Tmux opens normally

**From your phone:** DM the bot with `hello there, what is 2+2?`

**Expect:** The message appears as literal keystrokes in pane 0 (Claude side if `both`). The agent responds in the pane (not in Telegram — the relay is write-only by design).

**Test allowlist:** Ask someone *not* in `TELEGRAM_ALLOWED_SENDERS` to message the bot — their messages should be silently dropped.

**After exit:**
```sh
ps aux | grep channel-relay
# Should NOT find the process — it's killed by the cleanup trap
```

---

## 11. `SANDY_GEMINI_AUTH` pinning

```sh
cd ~/sandy-test-gemini
# Force OAuth only, unset API key
sed -i.bak '/GEMINI_API_KEY/d' .sandy/.secrets
cat >> .sandy/config <<EOF
SANDY_GEMINI_AUTH=oauth
EOF

sandy -p "hi"
```

**Expect:** Uses only the OAuth path. If no `~/.gemini/tokens.json` exists, you get the "No Gemini credentials found" warning.

---

## 12. Codex-only mode (`SANDY_AGENT=codex`)

**Prerequisites**: A real `CODEX_API_KEY` (OpenAI API key) OR a host `~/.codex/auth.json` from `codex login`.

```sh
mkdir -p ~/sandy-test-codex && cd ~/sandy-test-codex
mkdir -p .sandy
cat > .sandy/config <<'EOF'
SANDY_AGENT=codex
EOF

# Smoke test 1: image builds, codex is on PATH
CODEX_API_KEY=sk-real sandy --rebuild -p "say hello in one word"
# Expected: exits 0, prints a single word. No Landlock errors in stderr.

# Smoke test 2: config.toml seeding (inspect after first launch)
cat ~/.sandy/sandboxes/sandy-test-codex-*/codex/config.toml
# Expected: contains `sandbox_mode = "danger-full-access"`, all 5 hide_ keys,
# AND a [projects."/home/claude/sandy-test-codex"] trust_level entry.

# Smoke test 3: idempotency — relaunching does not duplicate the trust entry
CODEX_API_KEY=sk-real sandy -p "exit"
grep -c '^\[projects\.' ~/.sandy/sandboxes/sandy-test-codex-*/codex/config.toml
# Expected: 1

# Smoke test 4: OPENAI_API_KEY alias
unset CODEX_API_KEY
OPENAI_API_KEY=sk-real sandy -p "say hi"
# Expected: warn line "OPENAI_API_KEY detected; forwarding as CODEX_API_KEY",
# then succeeds.

# Smoke test 5: OAuth read-only mount (only if ~/.codex/auth.json exists)
unset CODEX_API_KEY OPENAI_API_KEY
sandy -p "say hi"
# Inside session (interactive):
#   ls -la ~/.codex/auth.json            # should show the file
#   echo foo > ~/.codex/auth.json        # should fail: read-only file system

# Smoke test 6: headless translation
CODEX_API_KEY=sk-real sandy -p "echo test" 2>&1 | head -20
# Expected: `codex exec` is invoked (check with ps during a longer run),
# not interactive `codex`.
```

**Feature guards** (must all fail with clear errors):

```sh
SANDY_AGENT=codex SANDY_SKILL_PACKS=gstack sandy --help    # → error: skill packs not supported with codex
SANDY_AGENT=codex SANDY_CHANNELS=plugin:discord@claude-plugins-official sandy --help  # → error: discord not supported
SANDY_AGENT=codex sandy --remote                            # → error: --remote only supported with claude
SANDY_AGENT=codex+claude sandy --help                       # → error: Invalid SANDY_AGENT
```

**Sandbox forcing** (belt-and-suspenders):

```sh
# Delete config.toml; relaunch — CLI flag should still force danger-full-access
rm ~/.sandy/sandboxes/sandy-test-codex-*/codex/config.toml
CODEX_API_KEY=sk-real sandy -p "hello"
# Expected: succeeds, no Landlock errors. On next run config.toml is reseeded.
```

**Update check**:

```sh
# Poison the version file inside the image to force a rebuild detection
docker run --rm sandy-codex cat /opt/codex/.version   # note current version
# Next `sandy` launch should detect the upstream /releases/latest tag and
# either agree (no rebuild) or rebuild. Check stderr for the "update available" line.
```

## 13. Cleanup

```sh
rm -rf ~/sandy-test-claude ~/sandy-test-gemini ~/sandy-test-both ~/sandy-test-codex
rm -rf ~/.sandy/sandboxes/sandy-test-*
docker rmi sandy-gemini-cli sandy-both sandy-codex 2>/dev/null
```

---

## What "passing" means

Each numbered block is a pass/fail gate. The **must-pass** set is 1, 2, 3, 6, 9, 12 (core behavior + the v1 bug fix + layout migration + dual-pane + guard + codex solo mode). Sections 4, 5, 7, 8, 10, 11 are feature validation — failures there indicate bugs in specific subsystems but don't block the release if you're not using that feature.

### Known failure signatures

| Block | Failure signature | Root cause |
|---|---|---|
| 3 | `gemini: unknown flag --sandbox=none` | Step 0 fix didn't reach generated user-setup.sh |
| 3 | `unknown flag -p` | `build_gemini_cmd` flag translation broken |
| 2 | Migration runs every launch | Migration guard (v1 marker check) broken |
| 6 | Single tmux pane, not split | `build_both` launch block structural bug |
| 6 | `.claude.json` missing for `both` | `.claude.json` seeding gate missing `both` case |
| 9 | `--remote` launches for gemini/both | Guard placement wrong or missing |
| 10 | Relay PID left behind after exit | `cleanup()` trap missing `CHANNEL_RELAY_PID` |
| 12 | `Landlock: operation not permitted` | `sandbox_mode = "danger-full-access"` missing from config.toml OR `--sandbox danger-full-access` missing from CLI |
| 12 | `Not inside a trusted directory` | Trust entry not appended — check `user-setup.sh` block runs and matches `$SANDY_WORKSPACE` |
| 12 | Codex prompts for "first-run notice" | `[notice]` block in seeded config.toml missing or misspelled key |
| 12 | `codex: unknown flag --print` | `build_codex_cmd` flag translation not dropping sandy's `-p`/`--print` |

Report which blocks fail and the specific error — that's enough to localize the bug.
