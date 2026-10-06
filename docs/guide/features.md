# Features

Feature manifests: per-sandbox directories, mounts, supervised entries (relays), and re-provisioning. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

## Features (`$SANDY_HOME/features/<name>/feature.json`)

A **feature** is something you deploy into sandboxes that is not sandy's — a connector, a fleet agent, a shared toolchain. It lives in one directory with a manifest that says which sandboxes get it and what they get:

```json
{
  "sandboxes": { "include": ["*"], "exclude": ["scratch-*"] },
  "agents":    { "include": ["claude"] },
  "create":    ["instances/${slug}/inbox"],
  "mounts": [
    { "name": "payload", "from": "payload", "export": "MYTOOL_DIR" },
    { "name": "inbox",   "from": "instances/${slug}/inbox" }
  ],
  "entry": "payload/relay",
  "agent_args": {
    "claude": ["--mcp-config", "/opt/sandy/features/mytool/mcp-servers.json"]
  }
}
```

Sandy computes every container path — you name a mount, sandy decides where it lands (`payload` at `/opt/sandy/features/<name>`, anything else under `~/.<name>/`) and exports it if you ask. Mounts are **read-only unless you say `rw`**.

**`entry` names a supervised, container-level process** — sandy runs it as a sibling of the tmux server, restarted on death, held to one instance; see "Installing a relay" below. **One `entry` per feature** (2.4.0) — a feature declares at most one, but a sandbox can have several features each with their own, and every one of them runs independently, unconditionally, once its feature is adopted. There is no per-launch off switch for an individual entry: `SANDY_RELAY`, the toggle that used to stop all of them, is a **hard error** as of 2.6.0 (see the Deprecated table) — to keep a feature's entry out of a sandbox, exclude that sandbox in the feature manifest's own `"sandboxes"` block instead.

**Selection is enrolment.** A sandbox gets the feature only if an include matches in both blocks and no exclude matches in either. A sandbox that is not selected gets nothing at all — no mount, no export, no entry. Check what applied:

```sh
sandy --print-state | jq '.sandboxes[] | {name, features, feature_problems}'
```

and `$SANDY_HOME/features/<name>/selected.json` says the same thing for tools that cannot run sandy.

**`agent_args` wires the agent, not just the files** (2.1.0). Mounting a config does not make the agent read it; these are passed to the agent at launch, per agent, straight from the `:ro` payload — so a feature needs no write into the sandbox and leaves nothing behind when you remove it.

A manifest is **all-or-nothing**: an unknown key, an unknown agent name, or a token containing a space refuses the whole file, and that feature's mounts and exports do not happen either. So before a tool writes `agent_args` into a manifest, it should check that the host accepts it — by membership, never by version number:

```sh
sandy --print-schema | jq '.manifest.top_level_keys | index("agent_args")'
```

`null` (or no `.manifest` block at all) means this sandy predates the key: do not emit it. What a launch actually passed is recorded per sandbox:

```sh
sandy --print-state | jq '.sandboxes[] | {name, agent_args}'
```

`{}` means sandy looked and no feature contributed; `null` means the sandbox last launched under a sandy too old to say — not the same thing.

**Two features can contribute the same flag, and for some flags that discards one of them** (2.3.0). `agent_args` is additive in the command line sandy builds; whether it is additive in *effect* is up to the agent. Claude Code reads `--append-system-prompt-file` **once** — the last occurrence wins — so two features each supplying it meant one feature's prompt silently never arrived, with every other signal looking healthy.

Sandy now merges those contributions itself, into a file it owns and mounts `:ro`, and passes the flag once. Which flags it will do this for is published:

```sh
sandy --print-schema | jq '.manifest.agent_args_compose'
```

At one contributor nothing changes. At two or more, the result is recorded per sandbox:

```sh
sandy --print-state | jq '.sandboxes[] | {name, agent_args_composed}'
```

`{}` means no collision; an entry with `composed: false` means sandy **found** a collision and deliberately did not merge it — either the flag replaces rather than appends, or it named a file sandy cannot read — and `from` says which contributors were involved. The launch prints this too, alongside a line naming every feature that applied and what it contributed.

**`receives` declares a need, not a mechanism (2.4.0).** A feature that needs another local session to be able to inject a turn into a session running in its sandbox says so directly:

```json
{
  "sandboxes": { "include": ["*"] },
  "agents":    { "include": ["claude"] },
  "receives":  ["cross_session"]
}
```

`receives` is an array from a closed, published set (today just `cross_session`; `sandy --print-schema | jq '.manifest.receives_values'`) — an unknown value refuses the whole manifest, the same as an unknown top-level key. It names no consumer and no mechanism: a feature can declare this need with **no `entry` at all** — `receives` is a separate statement of what the feature needs to receive, independent of whether any entry runs. When a selected feature declares it, `SANDY_CROSS_SESSION_INBOUND`'s unset default resolves to `accept` (unless this is a headless, `--remote` or `--provision` run, which have no session to deliver into). See `SANDY_CROSS_SESSION_INBOUND` above and `docs/security/CROSS_SESSION_INBOUND.md` for the full precedence and residual risks.

Reading a manifest needs `node` or `jq` on the host. If neither is there, a launch that would use one **refuses** rather than mounting a guess — see `sandy --doctor`.

## Installing a relay

A *relay* is a program sandy runs as a container-level process — a sibling of the tmux server, never a pane — restarted on death with backoff and held to one instance by a lock.

**Installing one is a feature manifest `entry`:**

```json
{
  "sandboxes": { "include": ["*"] },
  "agents":    { "include": ["claude"] },
  "mounts":    [ { "name": "payload", "from": "payload" } ],
  "entry":     "payload/relay"
}
```

> **Removed in 2.2.0.** The two older routes are gone. `SANDY_HANDOFF_RELAY=<path>` as a configuration key, and installing an executable at `~/.sandy/sandboxes/<sandbox>/relay-bin/relay`, are both now **hard errors** naming the replacement — never silent skips, because ignoring either would start the wrong relay, or none, without saying so. `sandy --reset-sandbox` **destroys** a leftover `relay-bin/relay` for the same reason.

**`SANDY_RELAY` was the capability toggle through 2.5.0 and is a hard error as of 2.6.0.** Setting it from any source — environment, host config, or a workspace `.sandy/config` — to any value, refuses the launch and names the replacement. There is no per-feature off switch and no replacement key: to keep a feature's entry out of a sandbox, add that sandbox to the feature manifest's own `"sandboxes": {"exclude": [...]}`. The key stays recognizable to the config loader (it is not treated as unknown) specifically so it errors rather than being silently ignored. See the Deprecated table below.

**More than one feature, more than one entry (2.4.0, #381).** Each selected feature's `entry` runs, independently supervised — its own lock, its own backoff, its own state directory (`$SANDBOX_DIR/feature-state/<feature>`, mounted rw at `/opt/sandy/feature-state/<feature>` and exported to that entry's own process as `SANDY_FEATURE_STATE`). **Since 2.6.0 (#382) every entry is identical** — there is no longer a "first" or "designated" entry treated differently from the rest. Every entry is reported per feature:

```sh
sandy --print-state | jq '.sandboxes[] | .feature_entries'
```

Each value carries `state`, `restarts`, `executable_present`, `path` and `state_dir`. `{}` means no feature declared an entry; `null` means the sandbox last launched under a sandy too old to answer.

**Read-only by construction.** An `entry` lives on the feature payload, which the manifest mounts `:ro`. That matters because the container process runs as *your* uid and owns the file, so permission bits bind nothing — `chmod` would succeed against a normal mount and the agent could rewrite its own relay. Under `:ro` the write returns `EROFS`, because the mount flag is checked above the permission check. An adapter can write files; only sandy can create a mount.

**The honest limit**: sandy guarantees the *first* executable. It cannot guarantee the chain — a relay that execs a daemon out of a writable directory is replaceable at that second link.

Two failure shapes, handled differently:

- **Cannot start** (missing, not executable, its `feature-state/<feature>` dir not mounted, no `flock`): fails the launch, before or during container start. **One documented exception**: a stale image built before the `sandy.feature_entries=1` Dockerfile label existed (a build deferred by #218's reachability gate, or any other old cached image) only ever knew the removed `SANDY_HANDOFF_RELAY` internal channel, so with one or more entries adopted it starts **none** of them — that is not a broken entry, so it does not fail the launch. Sandy warns at launch instead, naming every entry that will not start and pointing at `sandy --rebuild`; `--print-state` reports those entries as `state: "absent"`.
- **Starts, then exits**: if the first run exits non-zero within ~5s the session fails with that exit code. Past that window it is a runtime loop, which cannot un-succeed a launch that already completed — it is reported instead:

```sh
sandy --print-state | jq '.sandboxes[] | .feature_entries'
# {"myfeature":{"state":"looping","restarts":417,"last_exit_code":3,"executable_present":true,"path":"/opt/sandy/features/myfeature/relay","state_dir":"/home/you/.sandy/sandboxes/myproj-1a2b3c4d/feature-state/myfeature"}}
```

`state` is one of `absent`, `started`, `looping`, `failed` — there is no `disabled` state, because there is no per-feature off switch to disable it with (`SANDY_RELAY` is a hard error, not a toggle). Each entry's `state_dir` is the **host** path `$SANDBOX_DIR/feature-state/<feature>`, mounted rw at `/opt/sandy/feature-state/<feature>` inside the container; that entry's own process finds it through `SANDY_FEATURE_STATE` rather than by building the path.

The session marker (`/etc/sandy-session.json`) carries `feature_entries.<name>: {"path": "..."}` — launch **intent**, because it is written **before** the container starts and cannot know whether the entry ran; live state comes from `--print-state`. Treat all of it as diagnostics: `feature-state/<feature>` is mounted read-write, so the entry's own process can write it.



## Per-sandbox directories for a feature

**The `~/.handoff` tree was removed in 2.2.0.** A feature manifest names its own directories instead — see "Features" above — which is more flexible and does not require every sandbox to carry four fixed directories it may not use.

If you were using it: `inbox`, `outbox` and `peer` become manifest `mounts` (`mode: ro` for host-written inbound lanes). Relay state moved to `$SANDBOX_DIR/relay-state`, mounted at `/opt/sandy/relay-state`, in 2.2.0 — that path was itself removed in 2.6.0 (#382): every entry now gets its own `$SANDBOX_DIR/feature-state/<feature>`, mounted at `/opt/sandy/feature-state/<feature>` and reported per entry as `feature_entries.<name>.state_dir` in `--print-state`, so nothing has to construct it. `SANDY_HANDOFF_DIRS` and the `.handoff-enabled` marker are gone; setting the key is a hard error naming the replacement.


## Re-provisioning sandboxes after a reset

Some per-sandbox state is created **by the launch**, deliberately: it exists only because the thing that mounts it made it, so hand-made state can never pass for working state. Today that is `pip/` — created unconditionally by every launch, used as the "did a launch ever complete here" test since 2.6.0 (`relay-state/` was the target from 2.2.0 through 2.5.x; a launch no longer creates it) — alongside `feature-state/<feature>` for every adopted feature entry (see "Installing a relay" above). The cost is that a sandbox can sit without it — most often after `sandy --reset-sandbox`, which keeps the sandbox but destroys everything a launch re-creates, and also after any launch that failed part-way.

To bring every sandbox back in one pass:

```sh
sandy --provision --all --dry-run   # what would be done
sandy --provision --all --yes
```

This provisions every sandbox sandy already **knows about** that is missing that state, serially, through the real launch path. It **cannot** reach a workspace that has never been launched — that has no sandbox directory, so sandy does not know it exists; enrolling one is a deliberate `sandy --provision --workspace PATH`. A sandbox whose workspace has been deleted cannot be provisioned at all: it is named, counted as unprepared, and makes the run exit non-zero rather than being skipped into a false success.

A sandbox with a **live session** is named and skipped the same way — it cannot be provisioned while it runs, so the run exits non-zero and tells you to stop it and re-run. Nothing running is ever touched. Because of that, **exit `1` here means "re-read the output and see which", not "something broke"**.
