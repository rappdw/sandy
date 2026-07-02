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

## Retire the Linux iptables isolation path — single-mechanism egress proxy

**Target: 1.1 (data-gated on the M2.7 soak).** Filed 2026-06-09.

### What

Once `SANDY_EGRESS_PROXY=1` is the soaked default on both platforms, remove the
legacy Linux-only iptables isolation (`apply_network_isolation`'s DROP rules,
`cleanup_network_isolation`, `PRIVATE_RANGES`, the `SANDY_ALLOW_LAN_HOSTS` /
`SANDY_LOCAL_LLM_HOST` iptables holes) and make the proxy the *sole* isolation
mechanism. Collapses two code paths to one: identical behavior on macOS and
Linux, one posture to document and audit, no `sudo`/host-iptables dependency.

### Why it's deferred (not done in M2.7)

The proxy is brand new — its live bring-up (2026-06-09) surfaced four bugs
(OS-ordering, sidecar-boot routing, network-leak/trap ordering, transparent
double-send) that no static test or the topology spike caught. Making it the
*only* mechanism before its own 7-day soak inverts the risk: if the soak finds
a proxy issue, there'd be no soaked fallback. iptables is proven, zero-overhead,
and costs ~nothing to keep as the `=0` escape hatch. So: default to the proxy
now (parity + a security upgrade for Linux), but keep iptables until the soak
proves the proxy can stand alone.

### The gate (preserve this — it's the real blocker)

The permissive proxy is *stricter* than iptables in a way that can regress some
Linux workflows: iptables allows **any protocol/port to a public IP**, but the
proxy only carries what its listeners handle — HTTP `:80`, HTTPS `:443`,
git-over-SSH via CONNECT `:3128`, DNS, and the local-LLM forward. A tool hitting
a public host on a non-standard port (`:5432`, `:8443`, raw TCP/UDP) works under
iptables and **fails through the proxy** (nothing listening on that port at the
proxy IP; the agent has no route off `--internal`).

Retiring iptables is therefore gated on the soak answering: *does the non-web-
port gap bite in practice?* If it never does → retire iptables, single mechanism.
If it does → first close the gap (a catch-all CONNECT for arbitrary ports, or a
generic raw-TCP forward keyed on an allowlist), then retire. Either way it's a
data-informed 1.1 decision, not a pre-soak bet.

### Effort

Small once gated: delete the iptables functions + the `_SANDY_PROXY_ON != true`
branches that call them, make `_SANDY_PROXY_ON` always-true (or drop the
tri-state's `0`), update `--print-schema`/docs/tests. The closing-the-gap option
(if needed) is the larger piece and would be its own entry.

---

## Codex CLI v0.138+ auth — env-var path no longer works in the sandbox

**Target: TBD (codex-version-driven).** Filed 2026-06-09.

### What / the symptom

On codex v0.138 inside sandy, neither auth path produces a working session:

- **OAuth** (read-only `~/.codex/auth.json` mount): ChatGPT uses single-use,
  rotating refresh tokens. The first in-container refresh consumes the host's
  refresh token but can't persist the new one (read-only mount) → every later
  session gets `refresh_token_reused` (401) and codex **retries in a tight loop**
  (looks like a 99%-CPU spin).
- **API key** (`OPENAI_API_KEY`): sandy forwards it correctly
  (`-e OPENAI_API_KEY=…`, confirmed), and codex's env shows it — but codex v0.138
  sends **no Authorization header** to the Responses API (`wss://api.openai.com/
  v1/responses` → 401 "Missing bearer or basic authentication"). So v0.138 seems
  to no longer read `OPENAI_API_KEY` from the env for the Responses path.

CLAUDE.md still says "`OPENAI_API_KEY` env var (what codex CLI reads natively)" —
that's stale for v0.138.

### Likely fix (needs verification against the installed codex version)

Stop relying on the env var. At entrypoint, write the key into codex's expected
location — either run `codex login --api-key "$OPENAI_API_KEY"` (writes
`auth.json`) or seed the key into `~/.codex/config.toml` under the openai
provider — whichever v0.138 actually honors. For OAuth, consider a writable
*ephemeral* `auth.json` copy (tmpfs, not bind-mounted back to host) so in-session
refresh persists for that session — but note this does NOT fix the host's
consumed refresh token across sessions, so re-login on the host is still needed
once. Investigate codex's current auth precedence (env vs auth.json vs config)
before choosing.

### Why deferred

Codex-CLI-version churn, not a sandy architecture issue, and codex is the
least-critical agent. It blocked nothing in M2.7 (the integration suite §1-12 is
pinned to no-proxy and codex sections are creds-dependent). Worth its own small
PR once the right v0.138 mechanism is confirmed. Workaround today: use a current
codex version whose env-var auth works, or pin codex auth via whatever method
the installed version documents.

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

### Approval design notes (added 2026-06-29, from Mitko Vasilev's YubiKey/broker post)

Two upgrades to the per-action confirm, both cheap once the broker exists:

- **Content-bind the approval, don't just display argv.** "Approve pushing
  `main`?" bound only to the action *description* is a TOCTOU hole: user
  approves, agent amends the commit underneath, approval still "matches." Bind
  each approval to a hash over the exact action content — argv + repo + branch +
  commit hash + **diff hash** — plus a short **TTL**, so what was approved is
  pinned to what ships and expires if unused. Sandy already uses exactly this
  pattern at the config tier: the passive-privileged approval file is a sha256
  over the sorted `KEY=VALUE` set, and any change re-prompts. Same mechanism,
  per-action.
- **Optional hardware user-presence, with tooling users already have.** No
  WebAuthn stack needed: `ssh-keygen -Y sign` with a FIDO2 `-sk` key is a
  touch-gated approval primitive. The confirm step becomes: helper displays the
  action summary → user touches the key → the signature over the action-hash
  *is* the approval, and doubles as a signed, auditable approval log. Upgrades
  the confirm from "anything that can write to the TTY can approve" to "only a
  physically present human can." Strictly opt-in, and reserved for the dangerous
  verbs (push, PR-write, deploy) — prompt-per-command trains reflexive approval
  (the "airport security" trap); sandy's existing tiering philosophy applies.

Related observation (no broker needed): `SANDY_SSH=agent` is *already* a
capability-based signing oracle — see the doc-note entry below about
documenting the touch-gated-push story.

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

## Sandbox migration utility (`sandy --migrate-sandbox`)

**Target: 1.0.x / 1.1 (M-effort).** Filed 2026-06-11, out of M4 PR 4.2.

PR 4.2 made `SANDY_SANDBOX_MIN_COMPAT` a **hard floor**: a sandbox created below it
is *refused* at launch (the 1.x forward-compat promise — see `SPECIFICATION.md`
"Sandbox version tracking"). Today the only remedy is destructive: `rm -rf
~/.sandy/sandboxes/<name> && sandy --rebuild`, which discards the sandbox's
installed packages (pip/npm/go/cargo), `uv`-managed Pythons, `.claude` plugins/
commands, and the workspace `.venv` overlay — the user re-installs everything.

A **non-destructive migration** would rewrite the stale cached absolute paths in
place instead of nuking the sandbox. The known break is the `/workspace` →
`/home/claude/<rel>` mount move (`SANDY_SANDBOX_MIN_COMPAT=0.7.10`): the fix is a
targeted rewrite of `/workspace/...` references in the overlay venv's
`pyvenv.cfg`, `.pth` files, editable-install `*.egg-link`/`direct_url.json`, and
console-script shebangs, then stamp `.sandy_created_version` to the current
version. Sketch:

```
sandy --migrate-sandbox            # migrate the current workspace's sandbox
sandy --migrate-sandbox --all      # sweep every sandbox under ~/.sandy/sandboxes
```

Scope/cautions:
- **Back up first** (`cp -a` the sandbox to `<name>.premigrate` so a failed
  rewrite is recoverable) — migration touches package metadata.
- **Path-rewrite only, not a rebuild.** If a future floor bump is about toolchain
  ABI rather than paths, migration may not be expressible as a sed — detect and
  fall back to "recreate" with a clear message.
- Pairs naturally with a `sandy --doctor` that reports each sandbox's
  classification (`_sandbox_compat_classify`) and offers migrate-or-recreate.

Until this lands, the hard floor's UX is "refuse + recreate," which is correct
but lossy; the migration utility turns it into "refuse + one-command fix."

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

---

## Optional gVisor runtime — `SANDY_RUNTIME` (strong-isolation tier)

**Target: 1.1+ (defense-in-depth; opt-in).** Filed 2026-06-11. Closes/strongly
mitigates residual **R1** (shared host kernel) in `THREAT_MODEL.md` — the one
boundary that matters against a *determined/jailbroken* agent rather than a
wrong-but-not-evil one.

### What

Let the maintainer run the container under a stronger runtime — primarily
**gVisor** (`runsc`), a user-space kernel that intercepts the container's syscalls
and services them itself, so the container never touches the host kernel directly.
A container escape then has to break *gVisor's* sandbox, not just Linux
namespaces. Exposed as a passive-looking but **privileged-tier** config key:

```sh
SANDY_RUNTIME=runc    # default — standard runtime (today's behavior)
SANDY_RUNTIME=runsc   # gVisor — user-space kernel, strong isolation
# (kata-runtime / a VM runtime could be a third value later)
```

### Why privileged-tier

A *committed workspace* `.sandy/config` must not be able to **downgrade** the
runtime (e.g. force `runc` when the maintainer wanted `runsc`, or point at an
attacker-named runtime). So `SANDY_RUNTIME` goes in `SANDY_PRIVILEGED_KEYS` and
needs the per-workspace approval prompt, like the other isolation toggles.
Validate the value against an allowlist (`runc`/`runsc`/`kata-runtime`) — never
pass an arbitrary string to `docker run --runtime`.

### Launcher sketch

```sh
# after config load, near the other RUN_FLAGS:
_runtime="${SANDY_RUNTIME:-runc}"
case "$_runtime" in runc|runsc|kata-runtime) : ;; *) error "invalid SANDY_RUNTIME"; exit 1 ;; esac
if [ "$_runtime" != runc ]; then
    # fail closed if the runtime the maintainer asked for isn't installed —
    # silently falling back to runc would defeat the security intent.
    if ! docker info 2>/dev/null | grep -qiE "Runtimes:.*\b$_runtime\b"; then
        error "SANDY_RUNTIME=$_runtime but Docker has no '$_runtime' runtime registered."
        error "Install gVisor (https://gvisor.dev) and 'runsc install', or set SANDY_RUNTIME=runc."
        exit 1
    fi
    RUN_FLAGS+=(--runtime "$_runtime")
fi
```
Everything else — the egress proxy, mounts, `--cap-drop`, `no-new-privileges`,
read-only root — stays exactly the same and composes *on top of* the stronger
runtime. gVisor is orthogonal to all of it.

### Platform reality (the catch)

- **Linux native: the real use case.** Install gVisor in the host's Docker
  (`runsc install`), then `SANDY_RUNTIME=runsc`. This is where R1 (escape =
  host root) is sharpest, so this is where gVisor earns its keep.
- **macOS Docker Desktop: largely N/A.** Docker Desktop doesn't ship `runsc`, and
  there's no supported way to register it inside its VM. macOS already has the VM
  boundary between the container and the Mac, so the marginal value is lower.
  Behavior: the install check above just hard-errors, which is correct — don't
  pretend.

### Compatibility caveats (the real cost — must be soak-tested)

gVisor re-implements the kernel surface; not every syscall/feature is supported,
and there's overhead. Things to verify with the `sandy-isolation-test` kit *and*
normal agent work under `runsc` before recommending it:
- **Networking** — gVisor has its own netstack; confirm the `--internal` bridge +
  the proxy DNS/transparent/CONNECT path all still work (this is the load-bearing
  check — if the proxy breaks under runsc, the feature is moot).
- **Toolchains** — heavy builds, `node`/`go`/`rust`, FUSE, `ptrace`-based tools,
  and anything doing exotic syscalls can break or slow down. Playwright/Chromium
  (gstack) is a known stress case.
- **Bind mounts / overlay** behavior under gofer.
- **Performance** — measurable syscall overhead; fine for agent work, painful for
  IO-heavy builds.

### Test plan

1. `sandy --runtime`-style smoke: launch under `runsc`, run the network/fs/priv
   probes — isolation should still HELD, and gVisor should *narrow* the escape
   surface (R1) without breaking R-anything.
2. Run the existing integration suite with `SANDY_RUNTIME=runsc` on a gVisor host
   and diff failures vs `runc` — that delta is the compatibility cost.
3. Document the supported/unsupported matrix in `SPECIFICATION.md` Appendix D.

### Effort

Small *launcher* change (validate + detect + one `--runtime` flag) + the
privileged-key metadata + docs. The real work is **compatibility soak**, not code
— hence opt-in, Linux-first, and clearly labeled "strong-isolation tier, expect
some workloads to need `runc`."

---

## Doc note: `SANDY_SSH=agent` + FIDO2 key = touch-gated push, today

**Target: 1.0.1 (doc-only).** Filed 2026-06-29, from the same exchange as the
broker approval-design notes above.

### What

A short README addition (SSH agent relay section) making an existing property
visible: SSH agent forwarding is **capability-based by construction** — the
container gets *signatures* from the host agent, never the key material. If the
user's SSH key is hardware-backed (`ed25519-sk` / FIDO2 resident key), every
git-over-SSH operation out of the sandbox therefore requires a **physical touch
on the host** — a hardware root of trust for agent pushes with zero sandy
changes and no broker. Nobody discovers this on their own because it's emergent
from the agent protocol, not a sandy feature flag; one paragraph makes it a
selling point.

Caveat to include: in egress-proxy mode on macOS, agent *signing* is unavailable
(the sidecar blocks the host TCP relay — see the SSH-agent interaction note in
CLAUDE.md), so the touch-gated story currently holds on Linux, and on macOS only
with `SANDY_EGRESS_PROXY=0`. Worth stating precisely rather than overclaiming.

### Why deferred

Doc-only; parked mid-M5-soak alongside the cmux caveat below. Apply post-rc1.

---

## Doc note: cmux notification hook doesn't protect against orphan-on-close

**Target: 1.0.1 (doc-only).** Filed 2026-06-29.

### What

A one-paragraph caveat to add to the cmux notification docs (`README.md` §terminal
notifications, `SPECIFICATION.md` §C.6). The cmux auto-setup (`sandy:4566–4607`,
gated on `CMUX_WORKSPACE_ID`) installs `cmux-notify.sh` so Claude Code events render
as cmux notification rings/badges. That integration is *correct and worth keeping* —
but it should note what it does **not** cover: cmux has no live detach/reattach
(closing the cmux app ends sessions; its "session restore" replays layout/scrollback,
not live processes). So closing a cmux window **kills the foreground `docker run`
client and orphans the sandy session** — the exact `FailedToOpenSocket` failure the
0.15.1 stranded-agent work addressed from the proxy side. The notification hook is
orthogonal to that and provides no protection against it.

### Why it's deferred (not done now)

Surfaced 2026-06-29 from a terminal-options research pass while sandy was ~10 days
into the M5 14-day pre-rc1 soak (06-19 → ~07-03). Editing prose mid-soak is harmless
to the *binary* but the discipline is "no changes until rc1 is cut," so it's parked.
Pure doc tweak, no code, no soak impact when applied post-rc1.

### Note worth preserving

The research compared tmux / cmux / Ghostty / Supacode / VS Code+sandy-ui as outer
hosts for sandy. Key finding: because sandy multiplexes agents via its *inner* tmux,
the outer host's only load-bearing job is **keeping the `docker run` client alive
across a closed window**. On that axis: tmux ✅, Supacode (bundles `zmx` for real PTY
persistence) ✅, **cmux ❌**, bare terminal ❌. So the doc caveat isn't cmux-bashing —
it's the single property that distinguishes the safe outer hosts. Adjacent idea, also
post-1.0: if the orphan-on-close case proves common, a host-side wrapper could trap
the terminal-close signal and run sandy's teardown explicitly (sandy-ui already does
this via `SIGINT→SIGTERM→SIGKILL` on tab close — a CLI equivalent for non-persistent
terminals would generalize it).

---

## Lessons from Anthropic's sandbox-runtime (srt) — carried over from TODO.md

**Target: assorted (1.1+).** Consolidated 2026-06-11 from the old root `TODO.md`
(an analysis of [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)).
One item already **shipped**, the rest are parked here; the deeper analysis lives
under `research/`.

- **Domain-based network filtering — ✅ SHIPPED** as the M2.7 egress proxy
  (`SANDY_EGRESS_PROXY` permissive/strict + `SANDY_ALLOW_HOSTS`). This was the
  headline srt lesson; it's done.
- **`.env` / secret-file protection (highest-value remaining).** `.env`,
  `.env.*`, `.env.local` are **not** in the protected-paths list, so a
  prompt-injected agent can `cat` a project's secrets and (in permissive mode)
  exfiltrate them. srt and Gemini CLI both address this — Gemini bind-mounts
  zero-permission files over them (masking). Fix: scan the workspace ≤3 levels
  (excluding `node_modules/`, `.venv*/`, `.git/`) for `.env*` and add them to the
  protected list — read-only at minimum, **masked** ideally (reading is the real
  risk, and RO only stops writes). See also `docs/security/THREAT_MODEL.md` R2.
- **Violation logging.** sandy blocks silently; srt logs blocked connections /
  write attempts in real time. At minimum, log denied egress (the proxy already
  has a deny log behind `SANDY_DEBUG_PROXY`) and protected-path write attempts to
  `~/.sandy/sandboxes/<project>/violations.log` for debuggability + trust.
- **macOS native sandbox fallback.** For users without Docker, `sandbox-exec`
  (Seatbelt) as a lighter-weight alternative — broadens reach, large effort.
- **Per-command sandboxing.** srt can sandbox individual commands, not just whole
  sessions. A significant architectural change; finer-grained but heavy.
- **Dynamic config reload** (srt's `--control-fd`) and **MITM/inspection-proxy
  support** (corporate CA, traffic visibility — composes with strict mode and the
  POST_1.0 host-relay broker) — both lower priority.

(Dropped from the old TODO as not-isolation/marketing: awesome-claude-code
listing, community plugin marketplaces, a web-UI dashboard.)
