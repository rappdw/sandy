# Handoff: suggestions to incorporate into sandy (from alice)

Source: `research/alice` (https://github.com/jcronq/alice).

These are patterns alice solves that sandy could adopt. Each has a concrete
file:line reference and a sketch of where it would land in sandy.

---

## 1. Torn-read protection on `.claude.json` host seed

**Why it matters.** Claude Code rewrites `~/.claude.json` constantly on the
host (per-project session state, last cost, OAuth refresh). Sandy seeds
`$SANDY_HOME/sandboxes/<name>.claude.json` from the host once at sandbox
creation. If the host's claude is mid-rewrite at that exact moment, the
read sees a partial file, JSON.parse throws, and sandy falls back to a raw
`cp` — which copies the same garbage bytes. Result: the brand-new sandbox
has a corrupt `.claude.json` until the user manually deletes it.

**Where it bites in sandy.** `sandy:3793-3802` — the seed-from-host block.

**How alice handles it.** `research/alice/sandbox/entrypoint.sh:24-46`:
5 attempts × 200 ms backoff, validate JSON parse on each try, fall back
to writing `{}` if all attempts fail.

**Suggested fix.** Replace the current seed block with something like:

```bash
if _sandy_agent_has claude && [ ! -f "$CLAUDE_JSON" ]; then
    if [ -f "$HOME/.claude.json" ]; then
        # Retry: host claude may be mid-rewrite. Validate JSON parses.
        node -e '
            const fs = require("fs");
            const [src, dst] = process.argv.slice(1);
            for (let i = 0; i < 5; i++) {
                try {
                    const d = JSON.parse(fs.readFileSync(src, "utf8"));
                    delete d.projects;
                    const tmp = dst + ".tmp";
                    fs.writeFileSync(tmp, JSON.stringify(d, null, 2) + "\n");
                    fs.renameSync(tmp, dst);
                    process.exit(0);
                } catch(e) {}
                require("child_process").execSync("sleep 0.2");
            }
            // All attempts failed: write a minimal valid file
            fs.writeFileSync(dst, JSON.stringify({tipsDisabled:true,installMethod:"native"}, null, 2) + "\n");
        ' "$HOME/.claude.json" "$CLAUDE_JSON" 2>/dev/null
        info "Seeded .claude.json from host"
    else
        printf '{"tipsDisabled":true,"installMethod":"native"}\n' > "$CLAUDE_JSON"
    fi
fi
```

This is a one-time race (only fires when `! -f "$CLAUDE_JSON"`), so the
cost is negligible and the failure mode goes from "silently corrupt" to
"valid empty seed."

---

## 2. Directory-mount-with-symlink for credential refresh

**Why it matters.** Single-file bind mounts (`docker run -v
/host/file:/container/file`) pin the *inode* of the host file at
container-create time. When Claude Code on the host does `/login`, it
writes a new `.credentials.json` via atomic rename — which produces a
new inode. The container's bind mount keeps pointing at the old inode
(no longer linked to any path), so the running session has stale creds
until restart.

**Where it bites in sandy.** Sandy's pattern is to read creds fresh per
launch and mount ephemerally — so this only matters for *long* sessions
that span a host token refresh. If you've never seen a sandy session
silently lose auth halfway through, this can be deferred.

**How alice handles it.** `research/alice/sandbox/docker-compose.yml:77-83`
mounts `~/.claude` as a *directory* (`:ro`), and the entrypoint creates
symlinks (`research/alice/sandbox/entrypoint.sh:11-14`):

```bash
ln -sf /host-claude/.credentials.json "$HOME/.claude/.credentials.json"
```

Symlink resolution happens at every `open()`, so atomic-replace on the
host becomes visible inside the container immediately.

**Suggested fix for sandy.** Only worth doing if (a) we expect long-running
sessions and (b) we want host `/login` refresh to propagate. For the
common case (one session, refresh happens at next sandy launch anyway),
skip. If we do adopt it, the change is in the credential mount block
around `sandy:4543-4552` — mount `$HOME/.claude` as a `:ro` directory
sidecar and have user-setup.sh symlink the live files.

---

## 3. "Talk to the running sandy" CLI

**Why it matters.** Today, if a sandy session is live in tmux on your
host and you want to send a one-shot prompt from a script (CI status
update, notification, "ask sandy about X"), you have to either:
attach to tmux yourself, or `docker exec` and `tmux send-keys` manually.

**How alice handles it.** `research/alice/bin/alice` docker-execs into
the live worker container, locates the message-processing socket, and
speaks the inbound CLI transport. `alice -p "..."` lands in the *running*
agent (with session continuity, MCP state) instead of spawning a new
process. Reference: `research/alice/CLAUDE.md` lines 21-58.

**Suggested fix.** A `sandy send "prompt"` host command that:

1. Finds the running sandy container for the current workspace
   (sandy already filters `--print-state` by image name prefix — same
   approach: `docker ps --filter` on the sandy image labels).
2. Runs `docker exec ... tmux send-keys -t <pane> "prompt" Enter`.
3. Optionally `--json` to capture the next reply via the same pattern
   sandy already uses for the channel relay.

This is a small wrapper. The Telegram/Discord channel relay
(`channel-relay.sh`) already proves the plumbing works — `sandy send`
would just be a host-side CLI front for the same inject path. Could be
useful for `gh pr comment | sandy send` and similar pipelines.

---

## 4. Structured event log

**Why it matters.** Sandy's session history is mostly recoverable from
`$SANDBOX_DIR/WORKSPACE.json` + Claude Code's own session jsonls, but
there's no single place to ask "when did this sandbox launch, with what
sandy version, against what model, did it finish cleanly?"

**How alice handles it.** `research/alice/memory/events.jsonl` —
append-only structured event stream queryable via `bin/event-log`.
Records meals, workouts, errors, but the pattern generalizes.

**Suggested fix for sandy.** A per-sandbox `$SANDBOX_DIR/events.jsonl`
appended by sandy at launch start, launch end, rebuild, and
auto-update events. One JSON line per event with `ts`,
`event`, `sandy_version`, `claude_version`, `model`, `agent`,
`workspace_path`. Surface it via `sandy --print-state` (already returns
sandbox metadata) and a `sandy log [--sandbox NAME]` host CLI for tail
queries.

This is a logical extension of the work already done in
`WORKSPACE.json` (first/last launch timestamps, first/last sandy
versions). Lower priority — only worth it if we have a debugging or
analytics use case in mind.

---

## What we already have (no action needed)

- **Per-instance Docker network with PID-keyed names** — sandy already
  does this (`sandy_net_$$`). Alice doesn't need to because it's a
  singleton.
- **Workspace mutex** — sandy's `mkdir`-on-`.<name>.lock` + PID liveness
  is already richer than alice's flock pattern.
- **Skill packs** — sandy's pack registry + dynamic version resolution
  covers the same ground as alice's mind repo for "shared agent code."

---

## Priority ranking

1. **Torn-read fix** — small, contained, fixes a real failure mode.
2. **Event log** — useful for support/debugging if anyone ever asks
   "what happened in sandbox X."
3. **`sandy send` CLI** — useful for pipelines but no urgency.
4. **Credential dir-mount** — defer until we see the actual bug.
