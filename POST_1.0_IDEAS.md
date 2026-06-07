# Post-1.0 Ideas

Parking lot for ideas that surface during the 1.0 push but don't belong in it.
`ROADMAP_1.0.md` is deliberately a stability-only path — "no new features until
1.0." When a feature idea comes up mid-push, it lands here instead of disrupting
the freeze, and gets reconsidered for 1.0.1+ once the RC is out.

Each entry: what it is, why it was deferred, rough effort, and any design notes
worth preserving so the eventual implementer doesn't re-derive them.

---

## `SANDY_AUTO_UPGRADE` — one-step sandy self-upgrade + re-exec

**Target: 1.0.1 (fast-follow).** Filed 2026-06-04.

### What

An opt-in that makes the sandy *script's* own upgrade as seamless as the agent
auto-rebuild already is. Today the flow is three steps: launch sandy → see the
`Update available: X → Y. Run 'sandy --upgrade'` nag → run `sandy --upgrade` →
re-run sandy (which rebuilds because the script changed). With `SANDY_AUTO_UPGRADE=1`,
a single `sandy` invocation would detect the new release, pull it, re-exec the
new script with the same args, and let the normal build-hash path rebuild the
image — detect→pull→rebuild→launch in one shot.

### Why it's deferred (not rejected)

It's a new feature + a new config key, which bumps into the re-baselined roadmap's
"no new features until 1.0" rule. It's tiny and opt-in, so it's a clean 1.0.1
fast-follow rather than something to sneak into the freeze.

### Why it must be opt-in (the real reason, preserve this)

There's a deliberate asymmetry in sandy's existing update design, and it's
correct:

- **Agent binaries (Claude/Gemini/Codex/OpenCode) auto-rebuild today** with zero
  opt-in (`_check_*_update` → `NEEDS_BUILD=true` → `docker build --no-cache`).
  Safe because the agent runs *inside* the sandbox — whatever it becomes, it's
  boxed.
- **The sandy script runs on the host** with `sudo iptables` + `docker` access.
  Auto-pulling-and-executing a newer version of *that* is a genuine supply-chain
  decision: a compromised repo/release would auto-execute on every machine with
  host privileges before the user could react. The current "warn + manual
  `--upgrade`" default exists precisely for this.

So: **never default-on.** Make it **privileged-tier** (host `~/.sandy/config` /
env only) so a committed workspace `.sandy/config` can't silently enable
host-script auto-replacement.

### Sketch (~20 lines; all machinery already exists)

Right after `sandy_check_update()` confirms a newer version, before the build
phase:

```sh
if [ "${SANDY_AUTO_UPGRADE:-0}" = "1" ] \
   && [ -z "${SANDY_UPGRADED_ONCE:-}" ] \
   && _sandy_newer_available; then          # reuse the cached check result
    info "Auto-upgrading sandy: $SANDY_VERSION → $new_ver"
    sandy_self_update                         # existing fn: downloads + replaces $0
    exec env SANDY_UPGRADED_ONCE=1 "$(readlink -f "$0")" "$@"
fi
```

After the `exec`, the new script runs from the top, sees the changed
Dockerfiles / build hash, rebuilds, and launches. Safety pieces:

- `SANDY_AUTO_UPGRADE` privileged-tier, default `0`.
- `SANDY_UPGRADED_ONCE` sentinel → at most one re-exec per launch; no loop if a
  version compare is ever flaky.
- Launch-time only (before the container starts; nothing mid-session).

### Effort / surface

~20 lines in `sandy` + one privileged key in the metadata heredoc + a test that
the sentinel prevents a re-exec loop + a CLAUDE.md/README note. `sandy_self_update`
and `sandy_check_update` already exist; this just wires them into an opt-in
re-exec.

### Note

If the user's actual itch is only "I want the latest Claude without thinking
about it," that already works today (agent auto-rebuild). This idea is strictly
about auto-upgrading the *sandy script itself*.

### Variant: agent-requested upgrade (from inside Claude Code)

Same feature family, same 1.0.1 target. Question that prompted it: "can the
upgrade be invoked from within Claude Code running in sandy?"

Answer: the in-box agent can **request** an upgrade but cannot **perform** one,
and that boundary is correct for two independent reasons:

1. **Isolation is inside→outside by design.** The container has no docker
   socket, no host shell, no access to the sandy script (host-side). Letting
   the agent *directly* drive the host upgrade is the exact capability sandy
   exists to deny — a prompt-injected agent would inherit it.
2. **You can't rebuild-and-restart the container you're living in, from inside
   it.** The upgrade destroys and recreates the very container the agent runs
   in; the agent can't survive its own substrate being rebuilt. So the action
   is inherently host-side and between-sessions, regardless of isolation.

Both point to the same shape: **the agent leaves a request; the host honors it
at the session boundary.**

Mechanism (no new isolation hole — piggybacks on the already-writable workspace
and the natural moment control returns to the host after `docker run` exits):

1. Agent (or user via the `!` escape) writes a marker, e.g.
   `<workspace>/.sandy/request-upgrade`.
2. When the container exits and the host sandy script regains control (around
   the `cleanup` trap), it checks for the marker.
3. If present **and** opted in, the host does the upgrade + relaunch — host
   side, user present, after the session.

Guardrails:
- **Opt-in, privileged-tier** (`SANDY_ALLOW_AGENT_UPGRADE_REQUEST=1`, host
  config / env only). A committed workspace `.sandy/config` must not be able to
  enable "honor the agent's upgrade requests."
- **Confirm on the host, don't silently act**: on finding the marker, prompt
  `"This session requested a sandy upgrade (X → Y). Proceed? [y/N]"`. A
  prompt-injected agent dropping the marker then costs only a y/N at exit, not a
  silent host-script swap.
- **Marker is advisory** — the host validates the real version delta itself; it
  trusts nothing in the marker beyond "an upgrade was requested."

Explicitly rejected alternatives:
- **Mounting the docker socket** (or any live host-command channel) into the
  container — gives the agent direct host control. Hard no; it's the precise
  thing sandy prevents.
- **A live RPC pipe** (agent writes "upgrade" to a mounted socket, host listener
  acts mid-session) — narrower than the docker socket but still a permanent
  inbound control channel from the sandbox, and it can't solve the
  can't-restart-your-own-container problem anyway. The sentinel-on-exit gets the
  same outcome with no runtime channel.

Effort on top of the host-side `SANDY_AUTO_UPGRADE`: the marker check in the
exit path (~10 lines), the second privileged key, the host confirm prompt, and
a docs note. Reuses the same `sandy_self_update` + re-exec plumbing.

---

## Host-side credential broker (agent never sees the token)

**Target: 1.0.1+ (highest-value strategic item).** Filed 2026-06-07 from the
`research/` cross-cutting review (see `research/CROSS-CUTTING-SYNTHESIS-2026-06.md`).

### What

Today sandy forwards `ANTHROPIC_API_KEY`, the `gh` token, and `SANDY_EXTRA_ENV`
values **into the container env**, where a prompt-injected or compromised agent
can read and exfiltrate them. The two most sandy-like research projects both
close this the same way: keep credentials strictly host-side and let the agent
make *unauthenticated* calls that a host-side broker authenticates.

- **agentbox** (`research/agentbox/packages/sandbox-docker/scripts/git-shim`,
  `docs/host-relay.md`): a PATH-shadowing `git` shim intercepts only the four
  network ops (push/pull/fetch/clone) with a strict per-op flag whitelist and
  RPCs a tiny host process that runs the real `git` with the user's creds in the
  host worktree. Non-network git falls straight through. Pairs with per-action
  host-side confirm prompts (push/PR-write show the exact argv before running) +
  an auditable auto-approve event log.
- **OpenShell** (`research/OpenShell/architecture/sandbox.md:48`): the egress
  proxy MITMs `api.github.com` with an ephemeral CA and injects the token into
  the request — the credential never enters the container at all.

### Why deferred

A host-side daemon/relay is a real architectural addition for a single-file bash
tool. It's the opposite of "no runtime host channel" (cf. the `SANDY_AUTO_UPGRADE`
agent-request analysis above). But it's the single highest-value non-trivial idea
from the whole review: it closes sandy's clearest remaining weakness and composes
with M2.7's egress allowlist into real defense-in-depth (allowlist limits where a
leaked cred can go; the broker stops the leak).

### Shape that fits sandy

Don't build OpenShell's MITM-CA path (heavy, CA-trust dance). The agentbox git-shim
model is closer to sandy's grain: a PATH-shadowing `git`/`gh` wrapper in the
container that pipes the four network ops over a **bind-mounted Unix socket** to a
small host-side helper sandy starts at launch and tears down in the cleanup trap
(sandy already manages per-launch helpers — the channel relay, the macOS SSH
relay). Start with `git push/pull/fetch/clone` + `gh` auth; the proxy's CONNECT
path (M2.7) already handles the transport, so this is "who holds the token,"
not "how does traffic egress." Per-action host confirm is the confused-deputy
guard. Keep it opt-in at first.

### Effort

L. New host-side socket helper + container-side shim + approval UX. Sequence it
*after* M2.7 (it builds on the proxy + the launcher's helper/cleanup machinery).

---

## Version / freshness hygiene cluster

**Target: 1.0.1 (cheap, S-effort, bundle).** Filed 2026-06-07 from the `research/`
review. Several projects independently address "which version is actually
running / is this download what I think it is," which sandy's self-mutating
single-file model makes genuinely confusing.

- **`script_sha` startup stamp** — alice logs `sha256sum "$0" | head -c12` in its
  banner (`research/alice/sandbox/host-claude-watcher/alice-host-claude-watcher.sh:59`).
  Sandy's `SANDY_COMMIT` is empty for curl-installed-then-hand-edited binaries,
  and users routinely have a second copy ahead on `PATH` or a clone checkout.
  Add the script's own sha to the `--version` line and `--print-state` so "which
  sandy is live" is answerable in one glance, independent of git.
- **Checksum-verify the downloaded script** in `install.sh` and on
  `sandy --upgrade` — supply-chain win (`research/OpenShell/install.sh:605`).
- **Breaking-upgrade ack gate** — OpenShell refuses to clobber incompatible prior
  state without an explicit ack env var (`install.sh:311`), a cleaner "hard stop
  + escape hatch" than a warning that can be ignored. Sandy already prefers this
  shape (symlink approval chose hard-error over trainable y/N); apply it to
  `SANDY_SANDBOX_MIN_COMPAT`.
- **Optional `SANDY_CLAUDE_VERSION` pin** — claude-code ships
  `requiredMinimumVersion`/`requiredMaximumVersion`
  (`research/claude-code/CHANGELOG.md:236`); sandy always rebuilds on a newer
  Claude release with no escape hatch when an upstream release regresses inside
  the sandbox. A pin gives users a way out.

All independent S-effort items; group them so they share one release + doc pass.

---

## Atomic tempfile+rename on state writes

**Target: 1.0.1 (S-effort; pairs with the .claude.json torn-read fix in
HANDOFF_TO_SANDY.md).** Filed 2026-06-07.

alice writes *every* state file as `tmp.write(); tmp.replace(dst)` (~30 sites;
`research/alice/sandbox/entrypoint.sh`). The handoff's torn-read idea covered the
**read** side of `.claude.json`; the **write** side is unprotected in sandy:
`WORKSPACE.json` is written via `} > "$SANDBOX_DIR/WORKSPACE.json"` (`sandy:~3565`)
and `settings.json` is regenerated each launch. A redirect-truncate is non-atomic —
a `kill -9` mid-write, or a concurrent `--print-state` read from a UI frontend
(no lock on that path), leaves a truncated/corrupt file the next launch silently
mis-parses. Fix: write to `.tmp` then `mv` (atomic on same filesystem). Same
`tmp+rename` primitive as the read-side fix; do them together.

---

## Pack-independent browser capability

**Target: 1.0.1+ (L-effort; flagship potential).** Filed 2026-06-07.

Today the headless Chromium engine is welded to the gstack skill pack. The
`browse` daemon design is independently excellent and already isolation-shaped
(`research/gstack/ARCHITECTURE.md`, `BROWSER.md`): compiled binary, localhost-only
bind, bearer-token auth, random per-workspace port, 30-min idle shutdown, zero
MCP token overhead (plain text in/out), state in `<workspace>/.gstack/` (sandy
already bind-mounts it). Promote it to a first-class, pack-independent sandy
capability so *any* agent gets a real browser via a CLI with no gstack skills.
Combine with agentbox's lazy-Chromium resolver
(`research/agentbox/scripts/chromium-resolver`): reuse the project's *pinned*
Playwright Chromium instead of baking one that goes stale when a project pins a
different Playwright. Adopt only the headless, lazy-resolved path — both projects
also have host-Chrome / cookie-import modes that are the opposite of sandy's
isolation.
