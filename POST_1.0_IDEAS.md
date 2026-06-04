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
