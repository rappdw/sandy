# Spec: per-sandbox, per-agent agent-args files

> **Historical design record.** This is the pre-implementation spec. The feature
> shipped and its current behaviour is documented in `CLAUDE.md` ("Per-agent
> override: `$SANDBOX_DIR/agent-args.<agent>`") and `SPECIFICATION.md`, which are
> authoritative. Kept for the reasoning, not as reference — where this document
> and CLAUDE.md disagree, CLAUDE.md is right.

**To:** `inbox-lab` / `amp-sandy-adapter`
**From:** sandy
**Status:** contract agreed; sandy-side implementation **in progress** at time of writing.
**Ships in:** sandy `1.8.0` (unreleased). Nothing below exists in `1.7.x`.

Proposal accepted as **option A** (per-agent values applied per pane), with one
correction to its premise — see *Placement*, which changed the file location.

Each section is marked **LOCKED** (decided; will not move) or **PROVISIONAL**
(could still shift). Build against LOCKED freely. For PROVISIONAL, isolate it
behind one function so a rename is a one-line change on your side.

---

## 1. Placement — LOCKED, and different from the proposal

```
$SANDBOX_DIR/agent-args.<agent>
```

Sandbox **top level**, **non-hidden**, one file per agent.

`<agent>` is one of: `claude`, `gemini`, `codex`, `opencode`, `grok`.

**The proposal's `<SANDBOX_DIR>/<agent>/agent-args` is not usable, and your hedge
was right.** Your reading — *"only `.claude/{commands,agents,plugins}` are
writable overlays rather than the whole tree"* — describes a design that was
**reverted before 0.11.3**: the stricter `:ro` sidecar broke `/plugin install`
with `EROFS`. The current mount is:

```
sandy:9747   -v "$SANDBOX_DIR/claude:/home/claude/.claude"
```

The **whole** `claude/` directory is read-write. Sandy's own comment at
`sandy:8295` states it: *"rw via the parent `$SANDBOX_DIR/claude` mount — no
`:ro` overlay."* So `claude/agent-args` would be **agent-writable**, failing your
acceptance criterion 4 outright.

Your stated fallback — a top-level per-agent file — is what ships. Sandy's own
schema already documents the reasoning, in the `SANDY_HANDOFF_DIRS` metadata row:
the marker *"lives at the sandbox TOP level (never under `claude/`, which is
mounted and agent-writable)."*

Nothing bind-mounts the sandbox top level. `run-tests.sh §97(8)` asserts that
**negatively** — it fails if a mount covering `$SANDBOX_DIR` is ever added — and
the new file gets its own sibling assertion.

### Resolving `$SANDBOX_DIR` — LOCKED

Unchanged from what you already do for `.handoff-enabled`:

```
$SANDY_HOME/sandboxes/<basename>-<hash>
```

where `<hash>` is the **first 8 hex chars** of the sha256 of the workspace path
canonicalized with `pwd -P`, and `<basename>` is the workspace basename filtered
to `[A-Za-z0-9._-]` (empty → `project`).

> Note this is an **8**-char hash. The per-workspace *approval* files use a
> **16**-char hash of the same path. Two different lengths, two different
> purposes — do not share a helper between them.

---

## 2. File contents — LOCKED

The file's contents are the extra CLI arguments for that agent.

- **Whitespace-split into argv** via `read -ra`. Never `eval`.
- **No quoting scheme.** `--msg "hello world"` becomes **three** tokens, not two.
  This is the same v1 limitation `SANDY_AGENT_ARGS` already has. If you need an
  argument containing a space, you cannot express it yet — tell us and it gets
  its own issue rather than a silent workaround.
- **Empty or whitespace-only ⇒ treated as ABSENT**, not as an empty argument.
  Writing an empty file is a safe no-op, not a way to inject `''` into argv.
- Trailing newline is fine and is not an argument.
- **Headless mode flags are dropped with a warning.** `-p`, `--print`, `--prompt`
  are stripped, because host-side headless detection runs before injection — a
  `-p` here would make the host launch interactive while the container went
  headless. Put those on the command line. (Inherited from `SANDY_AGENT_ARGS`;
  same behavior, same warning.)
- Avoid `--continue` / `--new` for the same reason: they influence launch mode.

### Writing it — recommended

```sh
sbx="$SANDY_HOME/sandboxes/$slug"
printf '%s\n' "$args" > "$sbx/.agent-args.claude.tmp"
mv -f "$sbx/.agent-args.claude.tmp" "$sbx/agent-args.claude"   # atomic within one fs
```

Write-then-rename so a launch racing your provisioner never reads a half-written
file. `touch`-and-append is not safe here the way it was for the marker, because
this file has content.

---

## 3. Precedence — LOCKED

**The sandbox file wins over a workspace `.sandy/config` `SANDY_AGENT_ARGS`.**

When both are present sandy emits a one-line notice naming which one won. Per
your ask, the ambiguity is refused rather than resolved silently.

**They are not concatenated.** Deliberately: the value is whitespace-split with
no quoting scheme, so merging two sources multiplies the ways a stray token
lands in the wrong place.

Full ordering of what reaches the agent, unchanged apart from the new source:

```
sandy's own flags  →  [sandbox file | workspace SANDY_AGENT_ARGS]  →  CLI pass-through
```

A command-line argument still wins over both.

---

## 4. Trust tier — LOCKED

**No new tier, no approval prompt, no new trust.**

`$SANDBOX_DIR` lives under `$SANDY_HOME`, which is already sandy's **privileged
source root** — the same root as `~/.sandy/config`. The file is therefore
privileged *by construction of where it lives*. That is precisely why it needs no
prompt while a workspace config setting the same key does: a repository can carry
a workspace config into a clone, and it cannot reach `$SANDY_HOME`.

This is the same argument that carried `.handoff-enabled`, and it is unchanged.

---

## 5. Per-agent isolation — LOCKED

Args written for one agent **never** reach another, including when several run at
once in a multi-agent tmux combo. `agent-args.claude` has no effect on a `codex`
pane in a `claude,codex` session.

A file for an agent **not** in `SANDY_AGENT` is inert — not an error.

> Implementation note you do not need but may care about: args are keyed by
> **agent name**, never by pane index. tmux `pane_index` does not track spawn
> order in the 4-agent grid (a later split re-splits pane 0), so an
> index-keyed mapping would be wrong for exactly the 4-agent case.

---

## 6. `--print-state` — PROVISIONAL (shape), LOCKED (semantics)

**Semantics are locked:** sandy reports **file presence**, explicitly as *the
file*, **not** as effective state. A workspace `.sandy/config` can also supply
args, and `--print-state` does not read workspace configs. So this answers *"does
this sandbox carry agent-args files, and for which agents"* — never *"will the
agent get args next launch."*

This is the same call as `handoff_enabled`, for the same reason, and you were
right to ask that it hold here.

**Shape is provisional.** Current intent, per sandbox:

```json
{ "name": "...", "handoff_enabled": true, "agent_args_files": ["claude"] }
```

`agent_args_files` — array of agent names having a non-empty file, sorted, `[]`
when none. Emitted in **both** light and full mode (it costs no extra process
spawn, same reasoning as `workspace_exists`).

Additive; `schema_version` stays `1`.

**Isolate this behind one accessor on your side.** If review pushes it to an
object (`{"claude": true}`) or renames it, that is where you would feel it.

---

## 7. Lifecycle — LOCKED

| Command | Behavior |
|---|---|
| `--reset-sandbox` | **Preserves** the file, like `WORKSPACE.json` and `.handoff-enabled`. Destroying it would silently un-configure a sandbox — the mounts still appear and the agent quietly launches without its args. |
| `--remove-sandbox` | **Destroys** it with everything else, and **names it in the printed plan**, the way the plan already names `.handoff-enabled`. |
| `--provision` | Does not create, read, or care about it. Provisioning and configuring stay separate concerns. |

---

## 8. Feature detection — LOCKED

Do **not** probe by running the feature. Order:

```sh
sandy --version                                  # safe on every version
sandy --print-version | jq -r .full_version      # 1.7.0+ only
```

Gate on `1.8.0`. Cache on **`full_version`**, never `version` — on a dev channel
`version` stays `"1.8.0-dev"` across every commit, so a cache keyed on it never
invalidates across exactly the upgrades that matter.

A missing `agent_args_files` key means **sandy is too old**, not "no files".
Treat absent and `[]` as different.

---

## 9. What sandy still does not know

Unchanged, and worth restating since this feature could look like a step toward
it: sandy knows nothing about channels, about MCP server names, about AMP, or
about what any argument means. It reads a string from a file the operator wrote
and passes the tokens through.

`--dangerously-load-development-channels server:inbox-channel` is a string from
your connector. Sandy will never derive it, special-case it, or validate it.
That is the same line residual 3 draws around the handoff substrate.

---

## 10. Open, and not part of this contract

**The silent-subset problem you raised is real and is not solved here.** A
sandbox carrying the enrolment marker but no agent-args file is exactly the
"meant 15, reached 14" case, and it stays invisible. We agreed this belongs in
`--doctor` as a consistency check — detectable without sandy knowing what the
args mean — and it is not in this change. If you want it, it wants its own issue.

**Arguments containing spaces** are not expressible (§2). Same for
`SANDY_AGENT_ARGS` today. Tell us if you hit it.

---

## Acceptance mapping

Your eight criteria, and where each is answered:

| # | Criterion | Where |
|---|---|---|
| 1 | file alone supplies args | §2, §3 |
| 2 | workspace config unchanged | §3 |
| 3 | both present → documented precedence | §3 |
| 4 | container cannot write it | §1 |
| 5 | empty ⇒ absent | §2 |
| 6 | never crosses agents | §5 |
| 7 | `--print-state` reports the file, labelled as such | §6 |
| 8 | `--reset-sandbox` preserves | §7 |
