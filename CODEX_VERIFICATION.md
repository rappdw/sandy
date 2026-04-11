# Codex v0.10.0 — End-to-End Verification

A hands-on walkthrough to confirm `SANDY_AGENT=codex` works end-to-end on a real machine. Run through these in order. Each step has an **Expected** and a **Red flag** line — if the red flag fires, stop and file a bug before continuing.

**Prerequisites**:
- Sandy installed from the `main` branch at v0.10.0-dev or later (`sandy --version` shows `0.10.0`)
- Docker running
- A real `CODEX_API_KEY` (OpenAI API key) **or** a host `~/.codex/auth.json` from `codex login` on the host
- `~/sandy-verify-codex` does not yet exist (fresh workspace)

---

## 1. Static checks (no Docker required)

```sh
cd /path/to/sandy-repo
bash -n sandy && echo "syntax OK"
grep -c '^SANDY_VERSION=' sandy       # → 1
grep SANDY_VERSION= sandy             # → SANDY_VERSION="0.10.0-dev"
```

**Expected**: `syntax OK`, version string matches.
**Red flag**: bash parse error, or version still shows `0.9.x`.

---

## 2. Image build

```sh
mkdir -p ~/sandy-verify-codex && cd ~/sandy-verify-codex
mkdir -p .sandy
cat > .sandy/config <<'EOF'
SANDY_AGENT=codex
EOF

CODEX_API_KEY=sk-REDACTED sandy --rebuild -p "reply with exactly one word: ready"
```

**Expected**:
- Sandy builds `sandy-base` (if not cached), then `sandy-codex` (new image).
- Build log contains `npm install -g @openai/codex` and `codex --version`.
- Container launches, codex responds with a single word, process exits 0.
- `docker images sandy-codex` shows the image.

**Red flag**:
- `ERROR: Invalid SANDY_AGENT 'codex'` → Step 1 of v0.10 plan didn't land.
- `npm install` fails inside the build → network or node version issue in the base image.
- `Landlock: operation not permitted` in the exec output → **critical**, see §6.

---

## 3. Config.toml seeding

```sh
SANDBOX=$(ls -d ~/.sandy/sandboxes/sandy-verify-codex-* | head -1)
cat "$SANDBOX/codex/config.toml"
```

**Expected** the file exists and contains:
- `sandbox_mode = "danger-full-access"`
- A `[notice]` block with **all five** hide keys:
  - `hide_full_access_warning`
  - `hide_gpt5_1_migration_prompt`
  - `"hide_gpt-5.1-codex-max_migration_prompt"` (quoted)
  - `hide_rate_limit_model_nudge`
  - `hide_world_writable_warning`
- A `[projects."/home/claude/sandy-verify-codex"]` block with `trust_level = "trusted"` (appended by `user-setup.sh` on first session start).

Quick check:
```sh
grep -cE '^(hide_|"hide)' "$SANDBOX/codex/config.toml"   # → 5
grep -c '^\[projects\.' "$SANDBOX/codex/config.toml"     # → 1
```

**Red flag**: fewer than 5 hide keys (seeding block got truncated), or missing `[projects]` (user-setup.sh trust-entry block didn't run — check that `$SANDY_WORKSPACE` is exported in the container).

---

## 4. Idempotency

```sh
CODEX_API_KEY=sk-REDACTED sandy -p "reply one word: again"
grep -c '^\[projects\.' "$SANDBOX/codex/config.toml"     # → still 1
```

**Expected**: the trust entry is not duplicated on second launch. If you edit the config.toml manually (say, add a comment), re-launching should preserve the edit — sandy only creates the file on first run.

**Red flag**: count goes to 2+ (grep guard in user-setup.sh is broken), or your edit is overwritten (seeding gate missing the `if [ ! -f … ]` check).

---

## 5. OPENAI_API_KEY aliasing

```sh
unset CODEX_API_KEY
OPENAI_API_KEY=sk-REDACTED sandy -p "one word reply"
```

**Expected**: stderr contains `OPENAI_API_KEY detected; forwarding as CODEX_API_KEY`, then codex runs and prints a word.

**Red flag**: `No Codex credentials found` — the alias block at `sandy:~1403` didn't fire. Confirm `OPENAI_API_KEY` is in the allowlist and the alias runs before `load_codex_credentials`.

---

## 6. Sandbox forcing (belt-and-suspenders)

Delete the seeded config.toml and relaunch — the CLI flag should still force `danger-full-access`:

```sh
rm "$SANDBOX/codex/config.toml"
CODEX_API_KEY=sk-REDACTED sandy -p "one word reply"
ls "$SANDBOX/codex/config.toml"    # file is reseeded
```

**Expected**: codex runs successfully without Landlock errors. The config.toml is recreated on launch by the seeding block.

**Red flag**: `Landlock: operation not permitted`, `failed to create ruleset`, or similar — this means the CLI flag `--sandbox danger-full-access` is not being passed in `build_codex_cmd`. Verify with:
```sh
docker exec -it <container> ps -ef | grep codex
```
The running `codex exec` process should include `--sandbox danger-full-access` in its argv.

---

## 7. OAuth path (read-only mount)

**Only if you have a host `~/.codex/auth.json` from `codex login` on the host.**

```sh
unset CODEX_API_KEY OPENAI_API_KEY
sandy                                 # interactive launch
```

Inside the TUI, open a shell pane (Ctrl-b then ") and run:
```sh
ls -la ~/.codex/auth.json             # shows the file with 600 perms
echo foo > ~/.codex/auth.json         # MUST fail: "Read-only file system"
stat -c %a ~/.codex/auth.json         # → 600
```

Then verify sandy copied it to a tmpdir (host-side, in another terminal):
```sh
ls /tmp/tmp.*/auth.json 2>/dev/null   # at least one exists during the session
```

Exit the session; the tmpdir should be cleaned up:
```sh
ls /tmp/tmp.*/auth.json 2>/dev/null   # gone
```

**Expected**: write fails inside container, file visible with correct perms, tmpdir cleaned on exit.

**Red flag**: write succeeds (mount is not `:ro` — check `RUN_FLAGS` in §5 of the plan), or tmpdir persists (cleanup trap missing `CODEX_CRED_TMPDIR`).

---

## 8. Headless mode uses `codex exec`

```sh
CODEX_API_KEY=sk-REDACTED sandy -p "count to five slowly, one per line" &
SANDY_PID=$!
sleep 3
docker ps --format '{{.Names}}' | grep sandy
CONTAINER=$(docker ps --format '{{.Names}}' | grep sandy | head -1)
docker exec "$CONTAINER" ps -ef | grep -E 'codex( |$)'
wait $SANDY_PID
```

**Expected**: the running codex process includes `codex exec --sandbox danger-full-access` (NOT plain `codex` — that's interactive).

**Red flag**: `codex` without `exec` — `build_codex_cmd` didn't detect `-p` as the headless marker. Check the `for arg in "$@"` headless-detection loop.

---

## 9. Feature guards (must all fail fast with clear errors)

```sh
SANDY_AGENT=codex SANDY_SKILL_PACKS=gstack sandy --help 2>&1 | tail -5
# Expected: error about skill packs not supported with codex

SANDY_AGENT=codex SANDY_CHANNELS=plugin:discord@claude-plugins-official sandy --help 2>&1 | tail -5
# Expected: error about discord not supported with codex

SANDY_AGENT=codex sandy --remote 2>&1 | tail -5
# Expected: error about --remote only supported with claude

SANDY_AGENT=codex+claude sandy --help 2>&1 | tail -5
# Expected: "Invalid SANDY_AGENT 'codex+claude' (must be 'claude', 'gemini', 'codex', or 'both')"

SANDY_AGENT=all sandy --help 2>&1 | tail -5
# Expected: same Invalid SANDY_AGENT error
```

**Expected**: each command exits non-zero with a human-readable error. No command falls through silently.

**Red flag**: any of the above launches a container — the guard is missing or placed after the launch dispatch.

---

## 10. Synthkit skills visible to codex

Launch interactively:
```sh
CODEX_API_KEY=sk-REDACTED sandy
```

Inside the codex TUI:
```
/skills
```

**Expected**: the list includes `md2pdf`, `md2doc`, `md2html`, `md2email`. Each skill was written by `user-setup.sh` to `~/.codex/skills/<name>/SKILL.md` with YAML frontmatter.

Verify the file format:
```sh
# In a split shell pane inside the container:
cat ~/.codex/skills/md2pdf/SKILL.md
```

**Expected**:
```
---
name: md2pdf
description: Convert markdown file(s) to PDF using the md2pdf command on PATH.
---
Run: `md2pdf <file.md> [file2.md ...]`
```

**Red flag**: `/skills` doesn't list them → check that synthkit is installed in the image (`command -v synthkit` inside container) and the `_sandy_has_codex` block fired. Missing YAML frontmatter → codex silently ignores the skill (Spike 1 learning).

Then test it runs end-to-end:
```sh
echo "# Hello\n\nThis is a test." > /tmp/hi.md
md2pdf /tmp/hi.md
ls /tmp/hi.pdf
```

**Expected**: a PDF is produced (synthkit's WeasyPrint pipeline works — libpango/cairo/gdk-pixbuf are installed in Dockerfile.codex).

---

## 11. Update check

```sh
docker run --rm --entrypoint cat sandy-codex /opt/codex/.version
# Note the version, e.g. "0.119.0"

# Simulate a new release by overwriting to an older version:
docker run --name sandy-codex-poison sandy-codex true
docker commit -c 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]' sandy-codex-poison sandy-codex:poison
echo "0.0.1" | docker run -i --rm --entrypoint sh sandy-codex:poison -c 'cat > /opt/codex/.version' 2>/dev/null || true
# Easier: just trust the curl-based check and observe its output
```

Alternative — just observe the check output:
```sh
CODEX_API_KEY=sk-REDACTED SANDY_VERBOSE=2 sandy -p "hi" 2>&1 | grep -iE 'codex|update'
```

**Expected**: log line `Codex CLI update available: X → Y` or silence if you're up-to-date. If `curl` fails or the GitHub API is rate-limited, fail-soft: no update detected, no rebuild.

**Red flag**: spurious update loops (rebuilds every launch), or parse failure that crashes the launch. The sed regex `sed -E 's/.*"rust-v?([0-9][^"]*)"$/\1/'` should survive tag format drift.

---

## 12. Regression — other agents still work

```sh
# Claude-only
cd ~/sandy-verify-codex
sed -i 's/SANDY_AGENT=codex/SANDY_AGENT=claude/' .sandy/config
sandy -p "one word" && echo CLAUDE_OK

# Gemini-only
sed -i 's/SANDY_AGENT=claude/SANDY_AGENT=gemini/' .sandy/config
GEMINI_API_KEY=... sandy -p "one word" && echo GEMINI_OK

# Both
sed -i 's/SANDY_AGENT=gemini/SANDY_AGENT=both/' .sandy/config
GEMINI_API_KEY=... sandy 2>&1 | head -20   # verify tmux split panes
```

**Expected**: all three existing modes still launch cleanly. v0.10.0 must not regress v0.9.0 behavior.

**Red flag**: any mode now errors or builds a codex image when it shouldn't.

---

## 13. Cleanup

```sh
rm -rf ~/sandy-verify-codex
rm -rf ~/.sandy/sandboxes/sandy-verify-codex-*
docker rmi sandy-codex 2>/dev/null || true
```

---

## Verification checklist summary

| # | Check | Pass? |
|---|---|---|
| 1 | Syntax + version string | |
| 2 | Image builds, codex responds to `-p` | |
| 3 | config.toml seeded with 5 hide keys + trust entry | |
| 4 | Trust entry idempotent on relaunch | |
| 5 | OPENAI_API_KEY aliases to CODEX_API_KEY | |
| 6 | CLI `--sandbox danger-full-access` forces mode even with no config.toml | |
| 7 | auth.json mounted read-only, tmpdir cleaned on exit | |
| 8 | `-p` invokes `codex exec`, not plain `codex` | |
| 9 | All feature guards reject cleanly (skill-packs / discord / --remote / combos) | |
| 10 | Synthkit skills appear in `/skills` and run | |
| 11 | Update check runs and fail-softs | |
| 12 | Claude / Gemini / Both regression-clean | |

If all 12 rows pass, v0.10.0 is ready to tag and release.
