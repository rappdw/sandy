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

A manifest declares `schema`, `sandboxes`, `agents`, `create`, `mounts`, `entry`, `expose`, (2.1.0) `agent_args` and (2.4.0) `receives`. `--print-schema` publishes that list as `manifest.top_level_keys` so a consumer can gate on **membership** rather than on a sandy version — see §9.

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

*2.4.0 (#381):* with `relay-bin` gone (#354), the remaining precedence question was between two **features** that both declare `entry` — and there is none any more: every selected feature's entry runs, each independently supervised (§10). Order survives in one place only: the first selected feature in feature-directory name order is the **relay-designated** entry that `relay{}` describes. (An interim patch on the same dev line ran only that first entry and named each later one in a launch warning; §10 supersedes it. Before either, the later entries were skipped silently while the `features:` line claimed `entry` for both.)

### D10 — A feature directory with no manifest

- **flat directory, no manifest** → 1.15.0 behaviour, mounted whole `:ro` at `/opt/sandy/features/<name>`.
- **nested directory, no manifest** → **hard error** naming the fix.

The second is a safety property, not tidiness: per-slug instance trees live under the feature directory, and a whole-directory mount would give every sandbox every other sandbox's inbox.

### D11 — `schema_version: 2`

The first bump. It is the honest signal for D4's semantic change, and it gives consumers the capability gate they need — better than probing for a key's presence and immune to `1.15.0-dev == 1.15.0` (#310).

Consumers affected: the AMAP adapter, the router, and **lore**, which reads `--print-state`. Lore gets a heads-up before the tag.

## 4. What else rides this 2.0

**#248 — rename the container user and home, `claude` → `sandy`. DONE, in this release.** Queued for 2.0 and included here: two 2.0 releases in short order is worse than one, and the manifest computes `${HOME}/.<feature>/<name>`, so the home is in the new contract from day one.

Consumers are protected **only if they read the exported paths**. A manifest mount may declare an `export` name, and sandy exports the resolved container path under it. Anything that hardcodes the old `/home/claude` breaks at the tag; anything that reads `$NOTIFY_INBOX_DIR` does not. That is stated here so three repos build the right way the first time. **`SANDY_SANDBOX_MIN_COMPAT` advances to `2.0.0` with the rename**, so every existing sandbox is refused with a message naming the rename — its venv shebangs, `.pth` files, `GOPATH` and npm/cargo metadata all still say `/home/claude`, and they would fail in ways that look like broken packages rather than a moved home.

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

## 9. `agent_args` — wiring the agent, not just the files (2.1.0, #348)

A manifest could mount files and export variables but had no way to make the agent **read** them, so anything agent-facing still needed a per-sandbox write *after* selection — and selection only happens at launch, so a new sandbox cost three steps (launch, sync, relaunch). `agent_args` closes that gap:

```json
"agent_args": {
  "claude": ["--mcp-config", "/opt/sandy/features/notify/mcp-servers.json",
             "--append-system-prompt-file", "/opt/sandy/features/notify/policy.md"]
}
```

Stateless by construction: nothing is written into the sandbox, so removing the feature leaves nothing to reap. Every file named lives on the same `:ro` payload the manifest already mounts, so the agent cannot edit its own registration.

**The name is not `args`.** The manifest already has `entry`; `args` beside it reads as *the entry's* arguments, which is exactly what it is not. `agent_args` also matches the two existing spellings of this concept — `SANDY_AGENT_ARGS` and `agent-args.<agent>` — rather than inventing a third.

**Refusals are whole-manifest, and that is the operationally important part.** An unknown top-level key, an unknown agent name, an empty token, or a token containing a space, tab, newline or CR refuses the manifest — which takes that feature's **mounts and exports down with it**, not just its arguments. On a mixed-version fleet an older sandy therefore loses the feature entirely rather than degrading. That is why `manifest.top_level_keys` exists and why a consumer must gate on it before emitting the key.

**A token containing whitespace is refused, never split.** The channel is whitespace-separated and has no quoting scheme, so the choice was refuse-loudly or split-silently; splitting is how `--append-system-prompt "two words"` becomes two arguments nobody wrote. Use a flag that takes a file. This may be widened later — refusing now and permitting later breaks nothing, the reverse would.

**No flag denylist.** The same manifest can already declare `entry` (a binary sandy supervises as a daemon) and `rw` mounts of any host path, so filtering flags beside those would protect nothing. Only the mode flags `-p`/`--print`/`--prompt` are dropped, and that is a correctness rule, not a security one: host-side headless detection runs before injection, so a `-p` here would make the host launch interactive while the container went headless. The warning names the feature — an unnamed misconfiguration is indistinguishable from a working one.

**Precedence.** Feature args are additive, ordered first, and never suppressible; several features compose in sorted slug order. Sandy defines the ORDER — PRECEDENCE belongs to the agent's parser, and `claude --mcp-config` is variadic, so a second occurrence may accumulate rather than replace.

**Reporting.** The launch records what it applied in `sandy-session.json` (§C.9), attributed per feature and post-filter, and `--print-state` reads it back. Deliberately *not* re-derived from the manifest at query time: that would report a prediction, and would disagree with the running container for any sandbox whose manifest changed since — the same last-launch-vs-next-launch confusion `agents`, `handoff_enabled` and `handoff.state` each carry a caveat about.

**It narrows §8.** A Claude Code plugin directory carries `commands/`, `agents/` and `skills/`, and `claude --plugin-dir <path>` is repeatable — so a feature can now contribute slash commands off its `:ro` payload with no new manifest concept and no write into the sandbox. That answers the claude half of #317; the open question shrinks to the other four agents, which have three different command formats between them.

## 10. One supervised entry per feature (2.4.0, #381)

**Why not exactly one.** `entry` was built assuming a single fleet connector per container, and the adoption loop enforced that assumption by accident: the first `entry` in sorted feature-directory order won, and every later one was silently dropped, with nothing anywhere saying so — the same silent-inert shape #363 fixed for `agent_args`. The rationale for "exactly one" in the code was a *consumer's* constraint ("a second consumer on one notice directory is refused by a connector's claim lock"), not a property of sandy's own supervision — a mistake `CLAUDE.md`'s "Consumer boundary" section now names explicitly: sandy code and docs name no consumer's protocol. A second, unrelated feature wanting its own supervised daemon (a sync tool, a local indexer, a watcher) had no way to get one without silently starving the first.

**What changed.** Every selected feature's `entry` now runs, each independently supervised: its own `flock` lock, its own exponential backoff, its own state directory. Exclusivity between consumers — if a connector needs it — is the consumer's own business, enforced where it already is (its own claim lock on its own resource), not sandy's.

**The relay-designated entry.** Exactly one entry is *also* the one `relay{}`, `SANDY_HANDOFF_RELAY`, `SANDY_RELAY_STATE` and `/opt/sandy/relay-state` describe: the first entry adopted, in the same sorted feature-directory order the pre-#381 loop always used. This is deliberate, not incidental — it means every existing consumer of those relay-named surfaces sees **byte-identical behaviour** when a sandbox has exactly one feature entry, which is every sandbox today. A second entry is purely additive: it gets its own state directory and its own report under `feature_entries`, and never touches the first entry's.

**State directories.** The designated entry keeps using `$SANDBOX_DIR/relay-state`, mounted rw at `/opt/sandy/relay-state` (unchanged since #353). Every other entry gets `$SANDBOX_DIR/feature-state/<feature>`, mounted rw at `/opt/sandy/feature-state/<feature>`. The designated entry's directory is *additionally* mounted at `/opt/sandy/feature-state/<feature>` for its own feature name, so the env contract below is uniform regardless of which entry happens to be designated.

**Env contract, per entry's own process:**

| var | who sees it | value |
|---|---|---|
| `SANDY_FEATURE_STATE` | that entry's own child process only (never the parent shell, never another entry, never an agent pane) | `/opt/sandy/feature-state/<feature>` — uniformly, **including the designated entry**, whose `<feature>` mount is the same host `relay-state` directory at a second path. The one exception is the pre-#381 legacy fallback (an older, cached image that only ever forwarded a lone `SANDY_HANDOFF_RELAY`, no `SANDY_FEATURE_ENTRIES`): no `feature-state/<name>` mount was ever requested for that launch, so the designated entry falls back to `/opt/sandy/relay-state` there instead of naming a mount that does not exist |
| `SANDY_RELAY_STATE` | the designated entry's process, and (for back-compat) the container's shell / every agent pane | `/opt/sandy/relay-state` — unchanged |
| `SANDY_AGENT` / `SANDY_WORKSPACE` | every entry | ambient, unchanged |

**`relay_alias`.** Each entry's report — in both the session marker (launch intent) and `--print-state` (live) — carries `relay_alias: true|false`: whether this is the entry also described by `relay{}`. Named `relay_alias`, not `relay`, so it cannot collide with an existing `"relay":` reader that greps rather than parses.

**Fail-the-launch per entry.** The guarantee #258 built — a configured entry that cannot start fails the whole session, rather than crash-looping unnoticed — now applies to every entry independently. All entries are started first, then **one shared 5-second startup window** (not one window per entry) polls every entry's own outcome; N sequential windows would add 5s of launch time per already-healthy long-running entry, which does not scale with the number of installed features. The first entry to report a nonzero exit inside its window fails the session, naming that entry.

**`SANDY_RELAY=0` stops all of them, loudly**, exactly as it stops the single relay today — see the metadata description in CLAUDE.md / SPECIFICATION.md Appendix B. There is no per-feature opt-out; a feature that needs to be selectively disabled is a selection-time question (`feature.json`'s `sandboxes`/`agents` blocks), not a runtime one.

**Documented exception to "an entry that cannot start fails the launch": a stale image whose build was deferred (#218).** Because the container-side supervisor lives in the image (`user-setup.sh`, baked in at build time) while the entries list is a launch-time host decision, a launcher that resolved multiple entries but is running against an **older, cached image** — one built before #381, whose `user-setup.sh` only knows how to start a single designated relay — starts only the designated entry. That is not a broken entry, so it does not fail the launch the way a genuinely missing/non-executable entry does.

Sandy detects this at the host, rather than leaving it to `--print-state` alone: every generated agent Dockerfile carries `LABEL sandy.feature_entries=1` (inherited through `FROM` into per-project and skill-pack images), so a cached image that predates it can be told apart from a current one with one `docker image inspect -f '{{index .Config.Labels "sandy.feature_entries"}}'` (empty or `<no value>` both count as lacking the label). When more than one entry is adopted and the resolved image lacks the label, sandy **warns at launch**, naming every entry that will not start (every adopted entry except the designated one) and pointing at `sandy --rebuild`. With zero or one entry there is nothing a stale image would drop, so nothing is printed. `--print-state`'s `feature_entries.<name>.state` for the un-started ones still reports `absent`, for as long as that image is in use — the launch-time warning and the live `--print-state` reporting are two views of the same fact, not two different ones. The fix is the existing one: `sandy --rebuild` (or the next launch that triggers a rebuild) picks up the new `user-setup.sh`, and the label with it.

## 11. `receives` — declaring a need, not a mechanism (2.4.0, #380)

**The problem it replaces.** `SANDY_CROSS_SESSION_INBOUND`'s unset default used to resolve `accept` iff a feature manifest `entry` would actually start this launch — tying sandy's receive posture to one mechanism (the supervised entry) that exists because of #383's decoupling umbrella. A feature that needs to receive cross-session messages but ships no entry — or whose entry `SANDY_RELAY=0` has stopped — had no way to say so, and the coupling meant "is an entry running" was standing in for a question it does not actually answer ("does anything need delivery").

**The shape: `"receives": ["cross_session"]`, a closed set of enums, not a string and not a boolean.**

- **An array**, because a feature declares a *set* of needs, and a second kind of inbound need (not designed yet) is a new enum value added to the set — never a schema change, never a new top-level key.
- **Enums from a closed, published list** (`cross_session` today; `--print-schema`'s `manifest.receives_values`), not a free-form string — an unknown value **refuses the whole manifest**, naming the offending value, exactly like every other manifest key. This is the load-bearing part: a typo (`"corss_session"`) must not silently resolve to "declares nothing" (which reads as safe and is actually a missed need) any more than it should silently resolve to "declares the need" (which reads as safe and is actually an unreviewed grant). Refusing is the only answer that cannot be misread either way.
- **`[]` is valid** and declares nothing — a feature naming the key with no values is not an error, just a no-op.
- **Names the need, never a consumer, never a mechanism.** `receives` says nothing about entries, relays, or any particular feature's business — a feature declaring `"receives": ["cross_session"]` is stating "sessions launched from this sandbox need to be reachable by another local process," full stop, without saying by whom or how. Whatever mechanism eventually satisfies that (a supervised entry, a future one, none at all) is orthogonal, which is why declaring the need is **not gated by `SANDY_RELAY`** — that key gates whether entry *processes* run, and `receives` is a separate, privileged *statement*. A manifest can declare the need with no `entry` at all.

**Resolution.** `SANDY_CROSS_SESSION_INBOUND`'s unset default now resolves `accept` iff a **selected** feature (D4 — an excluded feature's declaration does not count, evaluated fresh every launch against the agents this launch actually resolved to) declares `receives: ["cross_session"]`, subject to the same non-start cases (criterion 8: headless, `--remote`, `--provision`) the old rule always was. **The old rule survives, additive-only, as a deprecated legacy path**: if no selected feature declares the need, `accept` iff a feature `entry` will start this launch — so an existing manifest that ships only an `entry` keeps delivering until it adds `receives` directly. `#382` will list the legacy rule in README's `## Deprecated` table at the next `X.0.0`; nothing is removed by `#380` itself. Full precedence, residuals and the live-probe evidence: `docs/security/CROSS_SESSION_INBOUND.md` §2.

**Recorded, not just resolved.** `/etc/sandy-session.json`'s `cross_session_inbound_source` names *why* the resolved value is what it is — `explicit`, `feature:<name>` (the first declaring feature in sorted order), `relay-legacy`, or `default` (JSON `null` when claude was not selected, mirroring `cross_session_inbound`'s own null convention) — so a run's receive posture is provable after the fact without re-deriving it from the manifest tree.

**Projector and schema surface, same as every other key.** Both projectors (node `RECEIVES`, jq `receives_known`) and the shell copy (`_sandy_fm_receives_known`, published as `--print-schema`'s `manifest.receives_values`) are held to byte-identical output — the same discipline `§135(20)` polices for the rest of the manifest, one clause later (`test/run-tests.sh §173`).
