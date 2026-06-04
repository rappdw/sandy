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
