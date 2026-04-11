# Codex v0.10.0 — Step 0 Pre-implementation Spikes

Four unknowns to resolve against a real `codex` binary before writing any sandy code. Each is ~15 minutes. Run them on your host (not inside sandy). Capture output and report back.

**Prereq**: install codex locally first.

```sh
npm install -g @openai/codex
codex --version
```

---

## Spike 1 — `~/.codex/skills/` as a drop-in directory

**Goal**: determine whether codex auto-discovers user skills from a directory (like Claude's `.claude/commands/`), or whether skills require a manifest / CLI registration / build step.

**Outcome drives**: Step 7 (synthkit slash commands for codex). If drop-in works, we seed `md2pdf`, `md2doc`, `md2html`, `md2email` skills into `~/.codex/skills/` at container launch. If not, we skip Step 7 entirely and document that synthkit commands must be invoked from PATH directly.

```sh
mkdir -p ~/.codex/skills/md2pdf
cat > ~/.codex/skills/md2pdf/SKILL.md <<'EOF'
# md2pdf
Convert markdown files to PDF using the `md2pdf` command available on PATH.
Run: `md2pdf <file.md>`
EOF

codex
# Inside the TUI:
#   /skills
# Does md2pdf appear? Can you invoke it?
```

**Report**:
- Does the skill appear in `/skills`?
- Any errors or manifest requirements?
- Paste the relevant TUI output.

---

## Spike 2 — `[notice]` + trust entry efficacy

**Goal**: verify that a seeded `~/.codex/config.toml` with the full `[notice]` block and a `[projects]` trust entry suppresses ALL first-run prompts.

**Outcome drives**: Step 3b (config.toml seeding). If additional prompts fire that aren't in the documented `[notice]` list, those become additional seeding targets.

```sh
# Back up any existing config
[ -f ~/.codex/config.toml ] && mv ~/.codex/config.toml ~/.codex/config.toml.bak

mkdir -p /tmp/codex-spike-test
cat > ~/.codex/config.toml <<'EOF'
sandbox_mode = "danger-full-access"

[notice]
hide_full_access_warning = true
hide_gpt5_1_migration_prompt = true
"hide_gpt-5.1-codex-max_migration_prompt" = true
hide_rate_limit_model_nudge = true
hide_world_writable_warning = true

[projects."/tmp/codex-spike-test"]
trust_level = "trusted"
EOF

cd /tmp/codex-spike-test
codex
# Note EVERY prompt that fires. Exit.

# Restore
[ -f ~/.codex/config.toml.bak ] && mv ~/.codex/config.toml.bak ~/.codex/config.toml
```

**Report**:
- Did any prompts fire? Which ones?
- Any warnings about unknown config keys?

---

## Spike 3 — `CODEX_API_KEY` env-var auth

**Goal**: confirm `CODEX_API_KEY` alone (no `~/.codex/auth.json`) drives a successful `codex exec` run. The codex source (`auth_manager.rs:605-644`) claims this works via an `enable_codex_api_key_env` flag on `codex exec`, but needs a real-world smoke test.

**Outcome drives**: Step 4 (credential loader). If `CODEX_API_KEY` does not work standalone, the loader must fall back to requiring `auth.json`, which changes the UX story.

```sh
# Back up auth.json if present
[ -f ~/.codex/auth.json ] && mv ~/.codex/auth.json ~/.codex/auth.json.bak

# Replace sk-REDACTED with a real key
CODEX_API_KEY=sk-REDACTED codex exec "say hello in one word"
echo "exit=$?"

# Restore
[ -f ~/.codex/auth.json.bak ] && mv ~/.codex/auth.json.bak ~/.codex/auth.json
```

**Report**:
- Exit code?
- Did codex print a response, or complain about missing auth?
- Paste the output.

---

## Spike 4 — Landlock-in-Docker under `danger-full-access`

**Goal**: verify that `codex exec --sandbox danger-full-access` runs cleanly inside a `--read-only` Docker container on a Linux kernel ≥5.13, without Landlock initialization errors. This is the highest-risk spike — if Landlock nests badly in Docker, the whole architecture needs a rethink.

**Outcome drives**: Steps 3b + 6b (belt-and-suspenders sandbox forcing). If Landlock attempts to initialize even in `danger-full-access` mode, we need to investigate codex issue tracker #10535 and possibly set `LANDLOCK_*` env vars.

Sandy bakes codex into the image at `docker build` time (writable layer), then runs `docker run --read-only`. So the install must happen during build, and only `codex exec` runs under read-only. Retry:

```sh
uname -r   # should be >= 5.13 on Linux; on macOS this runs in Docker Desktop's VM which is >= 5.15

mkdir -p /tmp/codex-spike4 && cd /tmp/codex-spike4
cat > Dockerfile <<'EOF'
FROM node:22-bookworm
RUN npm install -g @openai/codex && codex --version
EOF
docker build -t codex-spike .

docker run --rm \
    --read-only \
    --tmpfs /tmp \
    --tmpfs /home/node \
    -e CODEX_API_KEY=sk-REDACTED \
    -e HOME=/home/node \
    codex-spike bash -c '
        cd /tmp
        codex exec --sandbox danger-full-access --skip-git-repo-check "say hi in one word" </dev/null 2>&1
        echo "exit=$?"
    '
```

**Report**:
- Kernel version?
- Did `codex exec` succeed? Exit code?
- Any Landlock errors, seccomp errors, or "operation not permitted" messages?
- Paste the full output.

---

## After all four spikes

Paste results back here (one block per spike). I'll fold findings into the v0.10 PR description and start Step 1 on the `codex-support` branch. If any spike reveals a blocker, we reassess before touching code.
