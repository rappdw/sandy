# Handoff: suggestions to incorporate into alice (from sandy)

Source: `sandy` (https://github.com/rappdw/sandy).

These are patterns sandy solves that alice could adopt. Each has a
concrete file:line reference and a sketch of where it would land in
alice. Both projects share an author-mind ("Claude Code in a box"), so
the cross-pollination is mostly about lifting sandy's defensive
posture into alice's daemon model.

---

## 1. Network egress isolation (HIGH priority)

**Why it matters.** Alice receives messages from the open internet
(Signal, Discord) and runs Claude with whatever skills the mind repo
ships. The worker container can reach anything the host network can
reach: LAN devices (router admin pages, NAS, printers), RFC1918 ranges,
link-local metadata services, Tailscale CGNAT, the host's localhost
services. A prompt-injection in an inbound message + a permissive skill
= potential exfil to "any internal HTTP endpoint" with no boundary.

**How sandy handles it (Linux).** Per-instance Docker bridge keyed on
PID (`sandy:113-115`), plus iptables DROP rules on container start that
block:

- `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (RFC1918)
- `169.254.0.0/16` (link-local + cloud metadata)
- `100.64.0.0/10` (CGNAT / Tailscale)
- Allow only the container's own subnet for internal traffic.

Rules are torn down in the script's exit trap. Reference:
`sandy` (`apply_iptables_egress_rules` and `cleanup_iptables_egress_rules`
helpers — search for "iptables").

**Suggested fix for alice.** Alice has the advantage that her container
is long-running, so iptables rules don't need PID-keying — apply them
once at `alice-up` time, tear down at `alice-down`. The rule set
translates directly. Apply on the bridge for `alice-net` (defined at
`research/alice/sandbox/docker-compose.yml:154-157`).

A reasonable shape:

```bash
# In bin/alice-up, after `docker compose up -d`:
SUBNET="$(docker network inspect alice-net -f '{{ (index .IPAM.Config 0).Subnet }}')"
sudo iptables -I DOCKER-USER -s "$SUBNET" -d 10.0.0.0/8 -j DROP
sudo iptables -I DOCKER-USER -s "$SUBNET" -d 172.16.0.0/12 -j DROP
sudo iptables -I DOCKER-USER -s "$SUBNET" -d 192.168.0.0/16 -j DROP
sudo iptables -I DOCKER-USER -s "$SUBNET" -d 169.254.0.0/16 -j DROP
sudo iptables -I DOCKER-USER -s "$SUBNET" -d 100.64.0.0/10 -j DROP
# Allow the subnet to reach itself (worker ↔ daemon, viewer ↔ state)
sudo iptables -I DOCKER-USER -s "$SUBNET" -d "$SUBNET" -j ACCEPT
```

Bonus carve-outs alice will probably need (sandy doesn't because it's
a coding sandbox, not a chat agent): `host.docker.internal` for
signal-cli, GitHub's API ranges if `gh` traffic goes through a corp
proxy, etc.

**macOS caveat.** Same as sandy: Docker Desktop's VM doesn't apply
iptables rules from the host. Print a launch banner on macOS noting
that egress isolation is not active. See sandy's "macOS limitation"
section in CLAUDE.md for the language.

---

## 2. Protected-files / protected-dirs read-only mount (HIGH priority)

**Why it matters.** Alice mounts the runtime repo `rw`
(`research/alice/sandbox/docker-compose.yml:72`) "so subagents can
self-improve in place," and the mind repo `rw`
(`docker-compose.yml:63`). That means:

- A skill or prompt-injection can write `.git/hooks/post-checkout` in
  `~/.alice` or `data/alice-mind`. The hook runs on the host at the
  next `git pull` / `git checkout`.
- Same exposure for `.git/hooks/`, `.git/config`, `.envrc`,
  `.gitconfig`, `.bashrc`/etc., `.vscode/`, `.github/workflows/`.

The hemisphere policy line in `research/alice/CLAUDE.md` ("thinking
MUST NOT write here … enforcement is documentation") names the gap
exactly — there's no enforcement, just a comment.

**How sandy handles it.** Sandy mounts a curated list of paths read-only
overlaid on top of the rw workspace bind. List is in
`sandy --print-protected-paths` output and documented in sandy's
`CLAUDE.md` "Protected Files" section. Files: existence-gated. Directories:
always-mounted (empty stub if host doesn't have one), with cleanup
tracking for the bind-mount-target stubs Docker auto-creates.

**Suggested fix for alice.** Add explicit `:ro` mounts for the dangerous
paths in `docker-compose.yml`. Compose handles this cleanly because
later mounts override earlier ones — list the rw mind/runtime mount
first, then layer the `:ro` overrides:

```yaml
volumes:
  - ${ALICE_REPO:-${HOME}/alice}:/home/alice/alice:rw
  - ${ALICE_REPO:-${HOME}/alice}/.git/hooks:/home/alice/alice/.git/hooks:ro
  - ${ALICE_REPO:-${HOME}/alice}/.git/config:/home/alice/alice/.git/config:ro
  - ${ALICE_REPO:-${HOME}/alice}/.github/workflows:/home/alice/alice/.github/workflows:ro
  - ${ALICE_MIND:-${HOME}/alice-mind}:/home/alice/alice-mind:rw
  - ${ALICE_MIND:-${HOME}/alice-mind}/.git/hooks:/home/alice/alice-mind/.git/hooks:ro
  # ... etc.
```

For paths that don't exist on every host (e.g. `.envrc`), use the
sandy "empty stub" trick: maintain a known-empty file/dir under
`$ALICE_HOME` (`~/.config/alice/.empty-ro-file`,
`~/.config/alice/.empty-ro-dir`) and bind-mount it as the protection
target. That way the mount always exists and an in-container write
fails with EROFS regardless of host state.

The 1.0-rc1 lessons in sandy's CLAUDE.md ("Mount policy" section) are
worth reading verbatim — sandy went through a few iterations on
"file existence-gated vs always-mounted" before landing on a stable
answer. The short version: directories are always-mounted with stub
fallback (Docker's auto-create-and-rmdir-on-cleanup behavior is benign
for empty dirs); files are existence-gated (because Docker leaves
0-byte stubs that confuse direnv, git status, etc.).

---

## 3. Symlink-escape approval persistence (MEDIUM priority)

**Why it matters.** Mind repos are user-authored and can grow over time.
A symlink in the mind that points outside the mind (absolute path, or
relative `..`-escape) silently extends alice's filesystem reach beyond
what the mount declares. Today there's no surface for this.

**How sandy handles it.** At launch, sandy walks the workspace for
absolute symlinks and `..`-escapes, prints each one and its target,
and asks for y/N approval. On accept, the set is persisted to
`$SANDBOX_DIR/.sandy-approved-symlinks.list`. Subsequent launches:
identical or reduced set → silent. New escape → **hard error at
launch** (no re-prompt, forces deliberate action). Reference: sandy's
"Persistent symlink approval" section in CLAUDE.md.

**Suggested fix for alice.** Apply at `alice-up` time. Walk
`$ALICE_MIND` and `$ALICE_TOOLS`, persist approvals to
`~/.local/state/alice/.approved-symlinks.list`. Hard-error on
unfamiliar escape — tell the user the link path, the target, and how
to remediate (`rm` and re-up).

The "no re-prompt on second encounter" choice is deliberate: a y/N
that fires every session can be trained past, whereas a hard error
forces the user to look at what changed.

---

## 4. Stable introspection JSON contract (MEDIUM priority)

**Why it matters.** Alice's viewer
(`research/alice/sandbox/viewer/`) is a custom web UI that reads state
directly from `~/.local/state/alice/...` and the mind repo. Anyone
building an external tool (status bar widget, Slack bridge, monitor)
has to either reimplement that file-layout knowledge or scrape the
viewer. When the layout changes, every consumer breaks.

**How sandy handles it.** Three machine-readable JSON commands:

- `--print-schema` — config keys, agents, schema_version
- `--print-state` — runtime state (running containers, sandbox metadata,
  approval files, lock holders)
- `--validate-config PATH` — parse + classify config

Reference: sandy's `SPEC_INTROSPECTION.md` documents the stability
contract field-by-field. Internal layout can change; the JSON shape
is the contract.

**Suggested fix for alice.** Add `bin/alice state --json` and
`bin/alice schema --json`. Cover:

- Container state (which workers exist, which holds the lease)
- Mind repo state (path, last commit hash, autopush status)
- Transport state (signal account configured? discord enabled?
  allowed senders)
- Recent activity counters (turns processed today, last wake time)

Then refactor the viewer to consume the JSON instead of reading state
files directly. Anyone else who wants to integrate uses the same
surface.

---

## 5. Workspace mutex with PID liveness (LOW priority — alice-specific applicability)

**Why it matters.** Alice uses `flock` for the worker lease. flock
correctly auto-releases when the holding process dies — so this is
*already correct* for alice's blue/green pattern. The mention here is
only relevant if alice ever fans out to multiple subagent containers
that need to claim the same mind repo or tool sidecar concurrently.

**How sandy handles it.** `mkdir`-on-`.<name>.lock` (atomic on every
POSIX FS, no flock dependency in container interiors), with a
`pid` file inside the lock dir. Second launcher reads the PID, probes
liveness via `kill -0`. If alive: hard-error naming the holder. If
dead: auto-clear and proceed. Reference: sandy CLAUDE.md
"Concurrent launches" section.

**Suggested fix for alice.** Skip unless and until alice spawns
peer-claiming subagents. Alice's current architecture doesn't need it.

---

## What I'd not port

- **Per-invocation Docker network with PID-keyed names** — sandy needs
  this because every sandy invocation makes a new container. Alice's
  containers are persistent and singleton-ish; one stable network is
  fine.
- **Skill packs** — alice already has the better answer here (mind
  repo with `.claude/skills/`). The pack-as-image pattern is overkill
  for alice's use case.
- **Per-workspace sandboxes** — alice is one persona, one container
  layout. The sandy "hash-named per-project sandbox" model doesn't
  map.

---

## Priority ranking

1. **Network egress isolation** — biggest exposure, sandy's pattern
   ports cleanly, single change to `alice-up`.
2. **Protected-files / dirs read-only mount** — closes the
   "thinking MUST NOT write here" gap with actual enforcement.
3. **Symlink approval persistence** — cheap, prevents a class of
   silent reach extensions.
4. **Stable introspection JSON** — useful for tooling but not
   security-critical.
5. **Workspace mutex** — defer; current flock setup is fine for
   current architecture.
