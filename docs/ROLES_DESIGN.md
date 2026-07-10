# Design: Role-Based Multi-Session Orchestration (`SANDY_ROLE`)

**Status: PARKED — design settled, implementation not started.**
Target: prototype on a separate branch post-rc; ship as a **1.1** additive
feature (new passive keys, no retiering, no breaking changes — fits the 1.x
semver discipline). Designed 2026-07-06/07 in conversation; this doc preserves
the decisions and their rationale so the implementer (probably us, in a few
weeks) doesn't re-derive them.

---

## 1. What this is

Run a **plan → implement → verify** loop where each role is an *independent
long-lived interactive sandy session* in its own tmux pane, with a
role-appropriate personality, model, and even agent product (planner on codex,
implementer on claude, …). Roles hand work to each other through markdown files
at well-known workspace paths; a dumb host-side orchestrator script passes
turns. No shared context between roles, by construction.

```
┌──────────────┬──────────────┐
│ orchestrator │   planner    │   pane 0: sandy-roles.sh — state machine + status
│ (dumb bash)  │  (fable 5)   │   panes 1–3: interactive sandy sessions,
├──────────────┼──────────────┤   each launched with SANDY_ROLE=<x>
│ implementer  │   verifier   │   (+ per-role SANDY_MODEL / SANDY_AGENT)
│ (sonnet 5)   │  (opus 4.8)  │
└──────────────┴──────────────┘
        outer (host) tmux — NOT sandy's inner tmux
```

## 2. Constraints that shaped the design (why it looks like this)

These were each decisive; future changes must re-check them:

1. **Subscription economics rule out headless loops.** An earlier draft used
   `sandy -p` one-shots per phase (fresh context per invocation, mutex-friendly
   because sequential). Rejected: Anthropic's commercial model makes repeated
   headless invocations disadvantageous vs long-lived interactive sessions
   covered by a Max subscription. Roles must be **interactive sessions that
   stay up**. (Bonus recovered: persistent roles *remember their own history* —
   the verifier can say "you claimed this was fixed last round," which one-shot
   roles cannot.)
2. **The workspace mutex forbids concurrent same-workspace sessions** — and
   it's not just the lock: the sandbox dir is keyed on the workspace path
   alone, so concurrent sessions would share one sandbox dir rw (settings.json
   regen races, shared session history). This is the thing `SANDY_ROLE` must
   fix (§4).
3. **Worktrees are not a dodge.** A worktree's `.git` file points into the main
   repo's `.git/worktrees/<n>` with a `commondir` indirection back to the
   shared object store; sandy's gitdir mounting was built for *submodules*
   (self-contained gitdirs). Untested at best, likely broken. Don't assume it.
4. **Personality is a suggestion; permissions are a boundary.** An
   "adversarial" verifier prompt is vibes — the structural rule (verifier
   cannot edit) is what keeps it honest. Enforce roles with tool restrictions
   where the agent supports them, prompts everywhere.

## 3. Core execution model: concurrent-alive, serialized-active

All three sessions stay up all day (subscription-covered). **Only one role is
ever prompted at a time** — the orchestrator enforces turn-taking. Write
safety is provided by *protocol*, not by lock: acceptable for a
self-driven v0; hardening ideas (implementer-only rw workspace, advisory turn
tokens) are deliberately deferred until dogfooding shows they're needed.

## 4. The enabling sandy change: `SANDY_ROLE=<name>`

New passive-safe key (and/or `--role` flag). Effect: suffix **both** the
sandbox identity and the workspace lock:

- sandbox: `myproject-<hash>` → `myproject-<hash>-planner`
- lock: `.<name>.lock` → `.<name>-planner.lock`

~20–30 lines. Three sessions, same workspace, no mutex collision. Per-role
sandboxes then buy, for free:

- **Zero memory bleed** — each role's `~/.claude` (history, user-level memory)
  is its own sandbox dir. Solved structurally, not mitigated.
- **A durable personality home** — the role's sandbox-mounted user-level
  `CLAUDE.md` (claude) / `~/.codex/AGENTS.md` (codex) *is* the personality.
  Not re-injected per prompt; survives relaunches.
- **Per-role session continuity** — tomorrow's planner pane `--continue`s the
  *planner's* history, nobody else's.
- **Per-role model/agent env** already works today (env > config precedence):
  `SANDY_ROLE=planner SANDY_AGENT=codex sandy`.

Validation: role name should match something like `^[a-z][a-z0-9-]{0,31}$`
(it lands in sandbox dir names, lock names, container names).

## 5. Handoff protocol (files in the shared workspace)

All roles mount the same workspace, so handoff is just files:

```
handoff/
  00-request.md      # the human's intent (orchestrator seeds this)
  10-plan.md         # planner: spec, acceptance criteria, explicit non-goals
  15-questions.md    # implementer → planner Q&A (orchestrator re-runs planner if present)
  20-report.md       # implementer: what changed, deviations from spec
  30-verdict.md      # verifier: PASS/FAIL + findings, judged against 10-plan.md criteria
  state.json         # orchestrator bookkeeping (phase, iteration)
  .done-<role>       # turn-completion markers (see §6)
```

Numbered for ordering; iteration-suffixed on loops (`30-verdict.2.md`).
Properties that made us pick files over anything cleverer: **auditable**
(the whole inter-role "conversation" is a directory you can read/diff/commit),
**resumable**, and **agent-agnostic** (codex/gemini/opencode read and write
files like anyone — this is the differentiator over Claude-native agent teams,
which lock every role into claude).

`handoff/` should be gitignored by the target project (same posture as
`.gstack/` — warn-at-launch if not ignored is a nice-to-have).

## 6. Orchestrator: dumb code, smart models

**The orchestrator is NOT an LLM.** The loop (whose turn, did verify fail,
iteration count, give up at N) is deterministic bookkeeping; putting the
deepest-thinking model on traffic control burns Fable tokens on if/else. A
~100–200 line host-side bash script (`sandy-roles.sh`), same philosophy as the
rest of sandy: deterministic, auditable, readable in one sitting.

Two primitives, both already proven in sandy:

1. **Turn injection** — `docker exec <container> tmux send-keys`, exactly the
   mechanism the Telegram channel relay uses today (documented agent-agnostic;
   it's how Telegram reaches gemini/codex panes).
2. **Turn-completion detection** — per agent:
   - *claude*: a **Stop hook** that touches `handoff/.done-<role>`
     (workspace-mounted → host-visible instantly).
   - *codex*: seed `notify = [...]` in `config.toml` to fire on
     agent-turn-complete → touch the marker. **Needs a spike** to confirm
     in-container behavior.
   - *any agent (fallback)*: protocol convention — role prompt ends with
     "when finished, run `touch handoff/.done-<role>`." Less bulletproof
     (model can forget); build the orchestrator against the convention with
     hooks as belt-and-suspenders where available.

Loop: seed `00-request.md` → prompt planner → wait for done → prompt
implementer → (if `15-questions.md` appears, bounce to planner) → prompt
verifier → on FAIL, loop implementer with findings (max N iterations, default
3) → on PASS or exhaustion, report to the human.

## 7. Default roles (the shipped presets)

| Role | Personality (prompt core) | Default model | Tool boundary |
|---|---|---|---|
| **planner** | Architect. "What breaks later?" Produces spec with acceptance criteria + non-goals. Forbidden from writing code. | Fable 5 (thinking-per-token pays most at plan time) | Read-only |
| **implementer** | Pragmatic executor. Follows the spec; must *report* deviations, never silently improvise. | Sonnet 5 (most tokens burned here; speed/cost matter) | Full edit + Bash |
| **verifier** | Adversarial skeptic. Success = the failure it finds. "Assume the diff is broken until proven otherwise." Judges against 10-plan.md's criteria, not its own taste. | Opus 4.8 (strong judgment; cross-model diversity vs the implementer) | Read + run tests; **never edit** |

Verifier notes (the two rules that make or break it):
- **Context independence** — it gets the spec + the diff + test execution.
  Never the implementer's reasoning (that's how rubber-stamping happens).
- **No-edit is load-bearing** — a verifier that can fix things stops hunting
  problems and starts finishing the job.

**Mixed-vendor roles are supported and encouraged**: planner-on-codex spreads
usage across two flat-rate subscriptions (same economics argument that killed
`-p`, one level up), and a cross-vendor verifier is the strongest adversarial
configuration — same-family verifiers inherit family-typical blind spots.

## 8. Known gotchas (accepted for v0)

- **Venv overlays diverge**: each role-sandbox has its own `.venv` overlay
  shadowing the same workspace path → implementer's installs aren't in the
  verifier's venv. Verifier prompt must include "run `uv sync` before
  testing." (Arguably a feature: verification in an
  implementer-uncontaminated env.)
- **Write collisions prevented by protocol, not lock** — an orchestrator bug
  that prompts two roles at once can interleave writes. Accepted for v0.
- **Shared rate limits**: three claude sessions share one Max subscription's
  caps. Turn-based mostly serializes usage, but a deep verify loop is real
  load. (Mixed-vendor spreads this.)
- **Three proxies/sidecar networks per workspace**: fine — the /24 pool holds
  hundreds; the orphan reaper handles crashes.
- **Duplicate-sandbox warning**: role sandboxes for the same workspace will
  trip the sibling-sandbox `workspace_path` duplicate scan — the scan needs to
  learn that `-<role>` suffixed siblings are expected, not duplicates.

## 9. Open questions (decide at implementation time)

1. **Orchestrator location**: in-repo (`contrib/` or `tools/`) vs standalone
   repo until proven (lore-style). Was explicitly left undecided.
2. **Roles as generated presets** (`SANDY_ROLES=planner,implementer,verifier`
   generating personality files into role sandboxes at setup, like the `/ss`
   skill generation pattern) vs documented recipe first. Lean: recipe first,
   promote when the prompts stop changing.
3. **Codex `notify` seeding** — spike required (§6).
4. **`--resume <session-id>` plumbing** for precise per-role continuation
   (v0 relies on `--continue` within a role sandbox, which is already
   correctly scoped).
5. Does `--print-state` need to surface role sandboxes distinctly
   (`role: planner` field)? Probably yes — lore/sandy-ui will want it.

## 10. Implementation plan (the branch)

1. **`SANDY_ROLE` plumbing** — sandbox + lock suffix, key metadata row
   (`_sandy_key_metadata`), validation, `regen-config-docs.sh`, tests
   (mutex non-collision, distinct sandboxes, duplicate-scan exemption).
2. **Role personality files** — three battle-testable persona `CLAUDE.md`s
   (+ codex `AGENTS.md` variant for planner).
3. **`sandy-roles.sh` v0** — outer-tmux layout, turn injection, done-marker
   watching, the §6 loop, max-iteration guard.
4. **Claude Stop-hook** for done-markers; codex notify spike.
5. **Dogfood on a real 1.0.1 issue** (#12 or #30 are the right size).
6. Reassess → promote to documented 1.1 feature; only then consider
   `SANDY_ROLES` preset generation.
