# Sandy as a fleet of node agents — capability handoff

> **Historical handoff record, written for the 1.8.0 release.** It says
> "requires sandy 1.8.0 (unreleased)"; 1.8.0 shipped long ago and the current
> release is well past it. The fleet surface it describes (`--provision`,
> `--print-state`, `--remove-sandbox`, `--update-sessions`) is live and is
> documented in `CLAUDE.md` and `SPEC_INTROSPECTION.md`, which are authoritative.
> Kept because it explains WHY that surface exists and what a fleet consumer can
> do with it — context CLAUDE.md compresses away. Do not read the version
> statements as current.

**For:** `inbox_lab`, the workspace that spawned this work
**Milestone:** "Node agent" (#175) — six code issues, all merged
**Requires:** sandy **1.8.0** (unreleased; currently `main` @ `1.7.1-dev`). `schema_version` stays `1` — every change below is additive.

---

## What you could not do before

A sandbox was **only a launch artifact**. It came into existence as a side effect of `mkdir -p "$SANDBOX_DIR"` partway through an interactive launch. So an external orchestrator that wanted N ready sandboxes had exactly one option: start N interactive agent sessions and abandon them, harvesting a side effect. There was no way to ask how big a sandbox was, whether its workspace still existed, which host it belonged to, or whether the host was healthy — and no way to delete one whose workspace had been moved away.

That bring-up step read, in full: *"launch each sandbox once."*

## What you can do now

Drive the entire sandbox lifecycle non-interactively, with machine-readable state and a defined exit-code contract at every stage.

| Stage | Command | Notes |
|---|---|---|
| **Create** | `sandy --provision [--workspace PATH] [--yes]` | Runs the **real launch path** once, then stops it |
| **Inspect** | `sandy --print-state [light]` | Runtime state as one JSON document |
| **Describe** | `sandy --print-schema` | Static: keys, flags, tiers, protected paths |
| **Version** | `sandy --print-version` | Cheap probe; `full_version` is the cache key |
| **Health** | `sandy --doctor [--fix] [--yes]` | Host + runtime readiness |
| **Run** | `sandy --start` / `--attach` / `--stop` | Daemon session lifecycle |
| **Refresh** | `sandy --update-sessions [--idle-for N] [--yes]` | Fleet image refresh + rolling restart |
| **Panic** | `sandy --stop-all [--yes]` | Stop every daemon session on the host |
| **Reclaim** | `sandy --gc [--yes]` | Docker resources only |
| **Reset** | `sandy --reset-sandbox [--yes]` | Wipe sandbox state, **keep** `WORKSPACE.json` |
| **Delete** | `sandy --remove-sandbox [--sandbox NAME\|--orphans] [--yes]` | Preserves **nothing** |

Every one of these accepts `--dry-run` where it mutates, and refuses to mutate from a non-TTY without `--yes`.

---

## `--provision` — the one that unblocks bring-up

```sh
sandy --provision --workspace /path/to/repo --yes
```

**It does not fabricate sandbox state.** That was the tempting shortcut and it is the wrong one: hand-created state that no container ever mounted *looks wired and is not*. Instead it composes the hardened primitives verbatim — `--start` the real daemon session, confirm the inner tmux session is attachable, then `--stop` it. What you get is a sandbox produced by the same code path a normal launch uses, so the handoff pair, the settings seed, and `WORKSPACE.json` all come from the paths that normally produce them.

- **Always re-runnable.** Directory presence is never treated as proof of provisioning.
- **Safe no-op against a live session → exit `0`.** Two guards: the workspace mutex, *and* a running daemon container (a rebooted host can resurrect a container on a dead supervisor pid, which the lock alone would miss).
- **Needs a reachable Docker daemon**, unlike the filesystem-only members of this family.

**Ownership token.** Each run mints a random `SANDY_PROVISION_ID`, stamped on the container as `sandy.provision_id`. Both TOCTOU checks require *that exact token*, so `--provision` can never stop a session it did not create. This replaced a timestamp check: `provisioned_at` is second-granularity, so a bring-up loop provisioning two sandboxes in the same second produced byte-identical stamps. Sub-second precision is **not** the fix — `date %N` is GNU-only and this runs in the host-side supervisor, so on macOS it would emit a literal `N` and make collisions *more* likely, invisibly to a Linux CI.

---

## `--print-state` — what to poll

Two modes. **Light mode has a two-process-spawn budget** and is what a frequent poller should use; full mode is for when you actually need the expensive figures.

New in 1.8.0:

| Field | Where | Mode | Meaning |
|---|---|---|---|
| `host_id`, `host_id_source` | top level | both | Advisory host identity (`uname -n`, or `SANDY_HOST_ID`) |
| `size_bytes` | `sandboxes[]` | **full only** | Allocated disk (`du -skx` × 1024). `null` in light mode |
| `workspace_exists` | `sandboxes[]` | both | Tri-state; costs no extra spawn |
| `handoff_enabled` | `sandboxes[]` | both | The `.handoff-enabled` **marker only** |

**`host_id` exists because sandbox names hash only the workspace path.** Two hosts with the same repo checked out at the same path produce the *same sandbox name*. If you merge `--print-state` across a fleet without attributing rows by host, they silently collide. It is an operator-facing label, not a security identity.

**`handoff_enabled` reports the marker, not the effective state.** A workspace `SANDY_HANDOFF_DIRS=1` also enables the directories, but `--print-state` does not read workspace configs. `false` means *"not enrolled via the marker"*, not *"off next launch"*.

---

## Exit codes — the C1 rule

One rule across the whole maintenance family, worth internalizing before you write retry logic:

> **Refusal is exit `1` when the goal state is UNMET. Skip is exit `0` when it is ALREADY MET.**

So `--provision` against a live session is `0` (already provisioned, nothing to do), while `--reset-sandbox` blocked by a live lock is `1` (the reset did not happen). The distinction is whether the *stated goal* was achieved, not whether work was performed.

`--doctor` is the health probe: **exit `0` iff every required HOST check passes.** Every RUNTIME finding — stale images, orphaned resources, orphaned sandboxes — is a **warning that never affects the exit code**. `--yes` without `--fix` is a hard error, so a CI job that dropped the `--fix` token fails loudly instead of silently running read-only and reporting success.

### The `--attach` trap

`--attach` returns `0` (session ended), `3` (clean detach), `4` (no such session), `5` (failed to establish).

**A missing exit code is not a verdict.** Sandy discards `tmux attach`'s own return and re-derives the answer by probing live state. If the process is killed by a signal — commonly `SIGHUP` when an editor closes a terminal — that probe never runs and a supervising parent sees `code === null`. That means *the decision procedure did not execute*. It does **not** mean the session failed, and it must not be mapped onto `5` (which `--attach` never emits anyway — both `exit 5` sites live in `--stop`). Reconcile against `--print-state`, or just re-run `--attach`, which returns `4` if the session is genuinely gone.

---

## Feature-detect, don't version-compare

Pre-1.7.0 sandy forwards unrecognized flags **to the wrapped agent** rather than erroring, so probing `--print-version` on an old build does something surprising. The safe order:

```sh
sandy --version                      # safe on every version; format: "sandy <full_version>"
sandy --print-version | jq -r .full_version
sandy --print-schema | jq -e '.cli_flags[] | select(.name=="--provision")' >/dev/null
```

Cache on **`full_version`**, not `version`: on a dev channel `version` stays `1.8.0-dev` across every commit, so a cache keyed on it never invalidates across exactly the upgrades that matter.

All four introspection flags guarantee **exactly one JSON document on stdout and zero bytes of stderr**, even on JSON-shaped failures.

---

## Recipes

```sh
# Bring up a fleet
for ws in "${WORKSPACES[@]}"; do sandy --provision --workspace "$ws" --yes || echo "FAILED $ws"; done

# Health probe (exit code is the whole answer)
sandy --doctor >/dev/null 2>&1 && echo healthy || echo unhealthy

# Cheap poll — light mode, two spawns
sandy --print-state light | jq -c '{host: .host_id, n: (.sandboxes|length),
  live: [.running_containers[] | select(.daemon)] | length}'

# Disk pressure (full mode; du walk)
sandy --print-state | jq -r '.sandboxes | sort_by(-(.size_bytes//0))[:5][]
  | "\(.size_bytes/1048576|floor)MB \(.name)"'

# Find sandboxes whose workspace is gone
sandy --remove-sandbox --orphans --dry-run
```

There is no `--list-orphans`; `--dry-run` **is** the listing, mirroring `--gc --dry-run`.

---

## Residuals — read these before automating

1. **Do not cron `--remove-sandbox --orphans --yes`** on a host where workspaces live on removable or network media. A merely *unmounted* volume is indistinguishable from a deleted one, and a slow network mount can make the `[ -d ]` check block. The plan is always printed and confirmation always required — keep it that way.
2. **`--reset-sandbox` cannot target a workspace that is gone.** Its `pwd -P` step has nothing to canonicalize. That is what `--remove-sandbox --sandbox NAME` is for.
3. **Handoff directories are substrate only.** `SANDY_HANDOFF_DIRS` / `.handoff-enabled` create `~/.handoff/{inbox,outbox}` (inbox `:ro`). **Nothing moves files** — no relay, no peer list, no manifest format. If `inbox_lab` wants actual transfer, that is #132 and it is unbuilt. Note the residual: `outbox` persists across sessions, so a future relay must quarantine content predating the first peer approval.
4. **`SANDY_CHANNEL_TARGET_PANE` is unreliable for 4-agent combos.** tmux `pane_index` stops tracking spawn order once a later split re-splits an earlier pane. The on-screen layout is correct; the index is not.
5. **One sandy per workspace.** The workspace mutex is a `mkdir` lock holding a pid. PID reuse can produce a false "alive" (you clear it manually) — chosen over a false negative that would clobber a live session.

---

## Not done

**#106 — nightly integration CI — is not green.** The workflow, the gate job, the credential plumbing, and the suite hardening all exist and are merged. Keyless auth (GitHub OIDC → Anthropic workload identity federation) is **not yet working**: the token exchange is refused, and the last audit entry read `jwt_audience_mismatch`. That is provider-side rule configuration, not repo code.

Two things worth carrying over from that work regardless:

- A federation rule's **Expected audience must be set explicitly**. A blank field is an *empty list* that matches nothing — not a default. The audit entry shows `actor.audience: []`.
- The integration suite now **refuses to report a green run that tested nothing** (`SANDY_INTEG_REQUIRE_CLAUDE=1`). A run once announced *"auth: workload identity federation"*, ended up with Claude `none configured`, skipped ~22 sections, and passed. If `inbox_lab` builds anything with a skip-on-missing-credential design, it needs the same guard: **skipping is correct when nothing was intended, and a false green when something was** — only the operator can say which.
