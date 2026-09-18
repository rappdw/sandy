# Feature manifest and feature-owned per-sandbox trees (2.0.0)

**Status:** decided, not implemented. This record is the contract three repositories will build against — sandy, the AMAP adapter, and the router — and it exists so the decisions are made once rather than re-derived per repo.

**Requested by** the AMAP sandy adapter (2026-09-18), amended after review. **Tier:** `2.0.0`.

---

## 1. The problem

A feature deployed into sandy sandboxes today uses **four** mechanisms:

| mechanism | shipped | what it does |
|---|---|---|
| `SANDY_FEATURES_DIR` + `features/<name>` markers | 1.15.0 | one shared payload, `:ro`, into marked sandboxes |
| `relay-bin/relay` slot | 1.11.0 | one executable per sandbox, supervised |
| `handoff/` tree + five `SANDY_HANDOFF_*` exports | 1.7.0 / 1.10.0 | four fixed directories, mounted, with a fixed vocabulary |
| `SANDY_HANDOFF_DIRS` / `SANDY_HANDOFF_RELAY` | 1.7.0 / 1.10.0 | the keys that gate the above |

Two things are wrong with that. It is four moving parts for one feature, each enrolled and verified separately. And the **handoff vocabulary is a consumer's concept living in sandy's code** — `inbox`, `outbox`, `peer`, `relay` are one messaging design's nouns, fixed in a launcher that should not know them.

## 2. The shape

One directory per feature under a fixed root, with a manifest that declares everything:

```
$SANDY_HOME/features/<feature>/
  feature.json                 the manifest; NEVER mounted
  payload/                     one per host; :ro into every selected sandbox
  instances/<slug>/            created by sandy at launch, selected sandboxes only
  selected.json                written by sandy; read-only to everyone else
```

`$SANDY_HOME` is already the privileged config root, so the whole tree is **privileged by construction of where it lives** — a repository cannot reach it. That is the same argument that carries `.handoff-enabled`, `agent-args.<agent>` and `relay-bin/`, and it is why no new config tier is needed.

## 3. The ten decisions

### D1 — Tier: `2.0.0`

Forced by D4. Retiring the `features/<name>` marker changes what `sandboxes[].features` **means** — marker-derived becomes selection-derived. Same field, different source, which is worse than removal: a consumer keeps parsing and silently gets different semantics.

`schema_version` therefore moves to **`2`** (see D11). Sandy's own rule already put this at 2.0: *"anything breaking the sandbox forward-compat promise, the introspection `schema_version: 1` contract, or config-key tier semantics."* This breaks the second and third.

### D2 — Format: JSON, with a hard preflight

The manifest is JSON. Sandy cannot parse JSON without `node` or `jq`, and the existing helper is worse than absent — `json_merge` opens `command -v node &>/dev/null || return 0`, so it **silently does nothing**.

Therefore: **a launch that must read a manifest and finds neither `node` nor `jq` REFUSES.** It drops the `.fatal` marker so a `--start` client fails in ~1s with exit `6`, matching every other pre-launch refusal. The parse is strict — no literal-match fallback, no partial mounts, no "best effort". A manifest that cannot be read **in full** mounts nothing and fails the launch.

This keeps sandy a single file with **no global dependency**: only launches that read a manifest pay. The manifest path must not reuse `json_merge` or inherit its shape. `doctor.sh` upgrades node/jq from a warning to **required when any manifest is present**.

### D3 — `SANDY_FEATURES_DIR` is removed

The features root is fixed at `$SANDY_HOME/features/`. The key is **removed with a hard error naming the replacement**, not silently ignored — it shipped in 1.15.0 and anyone who set it must be told rather than left wondering why their payload stopped mounting.

### D4 — Selection replaces the marker

`features/<name>` markers are retired. Selection is evaluated **at every launch** from the manifest, and a sandbox that is not selected gets nothing from the feature.

Two blocks, `sandboxes` and `agents`, each with `include` and `exclude` lists of globs. Selected iff an include matches in **both** blocks and no exclude matches in **either** — **exclude wins**. An exact name is a pattern without a wildcard and `"*"` is "all", so there is no keyword and no special case.

`sandboxes` patterns match the slug and the workspace host path, case-folded. `agents` patterns match **the agent this launch runs**, which is the point: today a consumer gates on `--print-state`'s `agents` field *after the fact*, from last-launch data. Applying it at the launch makes a Claude-only feature structurally Claude-only.

### D5 — Mounts declare a `name`, never a destination

A mount has a `name`. **Sandy computes the destination**, under two roots it owns:

| mount name | container destination |
|---|---|
| `payload` | `/opt/sandy/features/<feature>` |
| `.` | `${HOME}/.<feature>/` |
| anything else | `${HOME}/.<feature>/<name>` |

There is no `to` field, so there is nothing to police and nothing to allowlist. This is deliberate: an earlier draft let the manifest choose the container path, which would have permitted a mount over `/etc/sandy-session.json` — the `:ro` attestation trust root — or over `~/.claude`. **Removing the capability beats constraining it.**

`name` is validated with the **published feature-marker predicate**, verbatim: `[A-Za-z0-9._-]+`, no leading dot, no `..` substring, with `.` as the single special value. One predicate, already documented in `SPEC_INTROSPECTION.md` and guarded by `run-tests.sh` §134. Without it, `name: "../../.ssh"` escapes the computed root.

`from` is a path under the feature directory and is validated the same way, per segment.

### D6 — `selected.json`, and its inherent staleness

Sandy writes `selected.json` beside the manifest at every launch and every removal: the slugs currently selected, and for a candidate that was not, which pattern excluded it.

It exists because the router **executes nothing** — no subprocess, no dependencies, which is the basis of its claim to be a trusted runtime. Running `sandy --print-state` to learn membership would invert the trust direction between the repositories. A file it reads does not.

**It is last-launch data for the agent dimension, necessarily.** Selection depends on the agent *this launch runs*, so for a sandbox that is not running the answer is unknowable rather than merely stale. That caveat has been misread here three times (`agents`, `handoff_enabled`, `handoff.state`), so it is **stated in the file itself** — a `note` field plus the launch timestamp — not left to the reader. `--print-state` reports the same data with the same caveat.

### D7 — Mounts are read-only by default

`mode` defaults to `ro`. A mount is writable only by declaring `rw`. The router refuses to publish into an agent-writable tree, so it needs this as a property the manifest **guarantees**, not one an example happens to show. Defaulting closed gives it by construction.

### D8 — `--remove-sandbox` destroys `instances/<slug>/`

It is per-sandbox state and the command already enumerates what it will destroy. It is **named in the plan**, like `relay-bin/relay` and each `agent-args.<agent>`.

`--reset-sandbox` leaves it alone: the instance tree is feature state under `$SANDY_HOME`, in the same class as `relay-bin/` and `.handoff-enabled`, which a reset preserves.

### D9 — `entry` coexists with `relay-bin` for one release

`entry` names a path under the feature directory that sandy supervises, replacing the relay slot for a feature that declares one. Both mechanisms work during the window.

**If both are present, `relay-bin/relay` wins, with a notice naming it.** Per-sandbox operator state beats a fleet manifest, so an operator can override for one sandbox during migration. Never merged; the winner is named — the `agent-args` rule.

A flag day on the mechanism that starts a delivery daemon is how a fleet goes silently dark.

### D10 — A feature directory with no manifest

- **flat directory, no manifest** → 1.15.0 behaviour, mounted whole `:ro` at `/opt/sandy/features/<name>`.
- **nested directory, no manifest** → **hard error** naming the fix.

The second is a safety property, not tidiness: per-slug instance trees live under the feature directory, and a whole-directory mount would give every sandbox every other sandbox's inbox.

### D11 — `schema_version: 2`

The first bump. It is the honest signal for D4's semantic change, and it gives consumers the capability gate they need — better than probing for a key's presence and immune to `1.15.0-dev == 1.15.0` (#310).

Consumers affected: the AMAP adapter, the router, and **lore**, which reads `--print-state`. Lore gets a heads-up before the tag.

## 4. What else rides this 2.0

**#248 — rename the container user and home, `claude` → `sandy`.** Already queued for 2.0 and included here: two 2.0 releases in short order is worse than one, and the manifest computes `${HOME}/.<feature>/<name>`, so the home is in the new contract from day one.

Consumers are protected **only if they read the exported paths**. A manifest mount may declare an `export` name, and sandy exports the resolved container path under it. Anything that hardcodes `/home/claude/...` breaks at the rename; anything that reads `$AMAP_INBOX_DIR` does not. That is stated here so three repositories build the right way the first time.

## 5. Deprecation windows

| mechanism | 2.0.0 | removed |
|---|---|---|
| `features/<name>` marker | **removed** | 2.0.0 |
| `SANDY_FEATURES_DIR` | **removed**, hard error naming the replacement | 2.0.0 |
| `relay-bin/` + `SANDY_HANDOFF_RELAY` | kept, deprecated; `relay-bin` wins over `entry` | next release |
| `handoff/` tree, `SANDY_HANDOFF_*`, `SANDY_HANDOFF_DIRS` | kept, deprecated | next release |
| `handoff_relay`, `relay{}` in the marker and `--print-state` | kept, deprecated | next release |

The windows exist for migration cost across sibling repositories, not for tier reasons — 2.0 could remove them all. Keeping them means one repository can move at a time.

## 6. Reserved namespace

Exactly **one** top-level key is reserved and never interpreted by sandy: `feature`. Everything else unknown is **refused**.

Blanket tolerance was asked for and declined: for a document that decides what gets bind-mounted, a typo'd `mounts` key that mounts nothing silently is the failure class this project spent three releases removing. A reserved key gives a consumer its opaque policy block without buying that back.

## 7. Acceptance

Assert the property, never the presence of a mechanism; mutation-test every guard.

- A sandbox **not** selected has **no** mount from the feature. Mutation: drop the selection test and this goes red while a selected sandbox still passes. This is the security check.
- `exclude` beats `include`, in either block.
- A manifest naming `name: "../../x"`, or a `from` that escapes the feature directory, is **refused** — the launch fails, nothing is mounted.
- A mount with no `mode` is mounted `:ro`, asserted by attempting a write and getting `EROFS`, never by grepping the argv.
- A manifest present with neither `node` nor `jq` on PATH **fails the launch** and drops the `.fatal` marker; `--start` returns `6` in ~1s.
- A truncated or malformed manifest mounts **nothing** — not a subset.
- An unknown top-level key is refused; `feature` is not.
- A nested feature directory with no manifest is a hard error; a flat one still mounts whole, preserving 1.15.0.
- `--remove-sandbox` names `instances/<slug>/` in its plan and destroys it; `--reset-sandbox` preserves it.
- With both `entry` and `relay-bin/relay`, the slot runs and the notice names it.
- `selected.json` carries its `note` and timestamp; a hand-edited copy is overwritten at the next launch.

## 8. Out of scope

- Moving sandy's own built-ins (screenshots, skill packs) onto the manifest. The schema must not **preclude** it — a feature with one mount, no entry, no instance tree and `include: ["*"]` is valid, which is the shape a screenshots directory would take — but nothing is migrated here.
- Any change to `_ver_lt`, the config tiers, or the passive/privileged split.
