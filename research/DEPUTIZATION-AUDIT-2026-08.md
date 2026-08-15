# The Deputization Audit — what it implies for sandy (August 2026)

**Source.** *"How to Decide What Work AI Should Do for You: The AI Deputization Audit"*, AI Daily Brief, 2026-08-14 (Nathaniel Whittemore) — https://aidailybrief.ai/e/2026-08-14. The framework is the episode's own; the mapping onto sandy below is ours. **Observation / inference / recommendation kept distinct; confidence H/M/L.**

**Why this is in sandy's research dir at all.** Sandy has a positioning problem it has never named crisply: *why* would someone run an agent in a box rather than just running it? The usual answer — "security" — is weak, because most users do not feel like a target. This framework supplies a sharper one. It scores a task on five dimensions to decide whether to hand it to an AI, and **sandy moves exactly two of those five**. That is a testable, falsifiable claim about what sandy is for, and it is more useful than "isolation good."

---

## 1. The framework, compressed

Inventory your **recurring** processes (email triage, status reports, meeting prep, CRM hygiene, content repurposing, vendor-portal chores, metrics pulls). Score each 0–2 on five dimensions:

| # | Dimension | 0 | 1 | 2 |
|---|---|---|---|---|
| 1 | **Worth it** (frequency × duration) | rare + quick | most weeks, <1h | weekly+, hours |
| 2 | **Teachable** (10-min screen share?) | impossible | demo with caveats | one demo covers it |
| 3 | **Checkable** (verify vs. redo) | checking = redoing | careful read | quick glance |
| 4 | **Stakes** (if it is wrong and nobody catches it) | serious / irreversible | embarrassing, fixable | low, easy redo |
| 5 | **You-integral** (must it be you?) | yes | helps, not essential | nobody would notice |

Total 0–10 → **Deputize** (8–10), **Duet** (4–7), **Defend** (0–3). The episode's own estimate, which matches ours: *most knowledge work sits in Duet.*

Step 4 is the part that matters most here: for anything in Duet/Defend, **name the specific blocker**, because tooling changes move specific blockers rather than raising scores in general.

---

## 2. The load-bearing claim: sandy is a stakes-and-checkability instrument

**Observation.** Of the five dimensions, three are properties of the *task and the person* — frequency, teachability, whether it must be you. No sandbox touches them. Two are properties of the *execution environment*:

- **Dimension 4 (stakes)** is a blast-radius question. Sandy's containment is a blast-radius intervention: read-only rootfs, per-project credential sandboxes, protected `:ro` mounts, egress modes, `--reset-sandbox` as destroy-and-redeploy.
- **Dimension 3 (checkable)** is an evidence question. Sandy already emits artifacts an unsandboxed run does not have: the session-end protected-path sweep, the HEAD-branch notice, `SANDY_EGRESS_LOG`'s "N distinct hosts reached", `SANDY_TOOL_AUDIT`'s per-call JSONL, `--print-state`, and the `:ro` `sandy-session.json` attestation marker.

**Inference (confidence: M-H).** Sandy's real function in this framework is to **raise the score of tasks that would otherwise be Defend or low Duet**, by lowering stakes and supplying verification evidence. That reframes the pitch from *"isolate your agent"* to *"isolation is what makes a task safe enough to hand over at all."* The second is a reason to adopt; the first is a feature.

**The honest bound — and it is a real one.** Sandy does **not** take dimension 4 to zero, and claiming so would be false:

- The **workspace is bind-mounted read-write**. An agent can rewrite any source file, and those writes land on the host filesystem immediately. Nothing about the container prevents that; it is the point of the tool.
- Protected-path coverage is **existence-gated**, and `CLAUDE.md` states plainly that the replacement is session-end *detection*, which is "weaker than prevention," with a threat window running until the user's next `git pull` / `push` / IDE open.
- Egress defaults to **permissive** (`SANDY_EGRESS_STRICT` default `0`): LAN is blocked, arbitrary internet is not. Exfiltration is not closed by default.
- Dimension 4's wording is *"if it is wrong and nobody catches it."* Sandy's detection means someone **can** catch it — but only if they read the exit notices. Detection that is not read is not detection.

**Recommendation.** If this framing is ever used in sandy's own docs or positioning, state the bound in the same breath as the claim. The failure mode is a user who reasons *"it is in a container, so stakes are 0"* and deputizes irreversible work. That is a **worse** outcome than not adopting the framework, and it is the specific way this idea could hurt.

---

## 3. Blocker-by-blocker

The episode's insight is that tooling shifts *named blockers*. Sorting its blocker list by whether sandy moves it:

| Blocker | Does sandy move it? | Mechanism / note |
|---|---|---|
| Privacy or security makes it inappropriate | **Yes** (H) | Per-project credential sandbox, `SANDY_EGRESS_STRICT`, protected `:ro` mounts, `--reset-sandbox`. This is sandy's core competence. |
| Mistakes costly / irreversible | **Partly** (M) | Bounded for host config, toolchains, git hooks, CI. **Not** bounded for workspace source (rw) or for exfil under the permissive default. |
| AI lacks context (accounts, history, formats) | **Slightly** (M) | Per-project sandbox persistence (`pip/`, `npm-global/`, agent state) accretes context per workspace; `SANDY_HANDOFF_DIRS` (#132) is substrate for moving it between workspaces. Not an ambient-observation story. |
| Needs taste / judgment | **No** (H) | Out of scope; no sandbox affects this. |
| Depends on human relationships | **No** (H) | Same. |
| Work spans websites / legacy software with no API | **No** (H) | Computer-use territory (the GrokBot / Computer History features that prompted the episode). Sandy runs coding agents in a container; it has no browser-driving surface and should not grow one for this. |
| **Recording your screen creates a new thing to secure** | **Yes, and this one is ours** (M-H) | The episode names this as a blocker the *new* tools **add**. See §4. |

---

## 4. The one place sandy has something specific to say

**Observation.** The episode notes that ambient-observation tooling (ChatGPT Computer History, Windows Recall's lineage) *creates* a security blocker where none existed: a persistent record of everything you do becomes a new asset to protect. It also notes the striking attitude shift — Recall was panned in 2024; the 2026 equivalents are welcomed — and attributes it to the value proposition changing from *"find something you saw"* to *"do your work."*

**Inference (confidence: M).** This is the same trade sandy already takes a position on, one layer down. Sandy's answer to "the agent needs broad access to be useful" is **scoped, disposable, per-project context** rather than **broad, persistent, cross-everything context**. The `#129` finding is the crisp example: claude.ai account connectors (Gmail, Drive) leak into *every* sandbox by default, which is precisely the ambient-context-becomes-an-asset problem arriving inside sandy uninvited. `#130` (`SANDY_SUSPICIOUS`) is the other half — shrinking token blast radius for workspaces you distrust.

**Recommendation (REC: use as framing, do not build).** No new sandy feature falls out of this document. Its value is:

1. **A sharper adoption argument** for the README / positioning docs, with the bound from §2 attached.
2. **Independent motivation for `#129` and `#130`**, which are currently justified on security grounds alone. Under this framework they are *deputization-score* features: they are what let a user move a task from Defend to Duet without lying to themselves about stakes.
3. **A prompt for a gap we have not examined**: the framework assumes *recurring* work, and sandy's daemon mode (`--start`, `--update-sessions`) is the recurring-work substrate. We have never asked which recurring processes sandy sessions are actually used for. Worth asking before designing anything for them.

**Explicitly rejected**: building a task-scoring feature into sandy (`sandy --audit` or similar). The audit is a human planning exercise about a person's own job; sandy has no visibility into a user's task inventory, and a CLI that asks five questions and sums them adds a surface with no information sandy possesses.

---

## 5. Open questions

- **Does the mapping survive contact with a real inventory?** Untested. The claim "sandy moves dimensions 3 and 4 only" is an armchair analysis; running the audit against a real week of recurring work and marking which rows sandy changes would confirm or kill it. Confidence stays M until then.
- **Is "checkable" actually improved, or only *auditable after the fact*?** Dimension 3 is about verification cost *before you accept the output*. Sandy's artifacts are mostly **post-hoc** (session-end sweeps, egress rollup). A post-hoc trail lowers the cost of *catching* a bad result; it does not obviously lower the cost of *verifying a good one*. This distinction may weaken the §2 claim on dimension 3, leaving stakes as sandy's only clean lever. Unresolved — and the most likely error in this document.
- **Does isolation raise the *teachability* score indirectly** by making it cheap to let an agent fail repeatedly while you refine the task? Plausible, unexamined.

---

## Provenance

Written from the 2026-08-14 episode transcript (auto-transcribed; speaker attribution in the source is imperfect, and the surrounding headline segments — Gemini 3.7 Flash, the AlphaSense cost study, OpenAI personnel — are unrelated to this analysis and deliberately not summarized here). The five dimensions, the 0/1/2 rubric, the 8–10 / 4–7 / 0–3 tiers, and the Deputize / Duet / Defend naming are the episode's. The episode said a companion artifact would be published at aidailybrief.ai; if it materializes, prefer it over this transcript-derived reconstruction of the rubric.
