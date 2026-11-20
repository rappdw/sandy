# Decisions: announcing a deprecation in a minor, and deprecating the Gemini CLI agent (2026-11-20)

Decided by the maintainer on 2026-11-20, for 2.10.0 (plan row 33).

Google announced on 2026-05-19 that Gemini CLI is being replaced by Antigravity CLI ("An important update: transitioning Gemini CLI to Antigravity CLI", https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/). From 2026-06-18 Gemini CLI no longer serves personal Google accounts: free accounts and Google AI Pro/Ultra subscriptions. Paid API keys, Vertex AI and Gemini Code Assist Standard/Enterprise are still served. Sandy's Gemini support therefore has a dated end. Before this decision the deprecation rule did not allow it to be announced until 3.0.0.

| # | Decision | Choice | Deciding reason |
|---|----------|--------|-----------------|
| 1 | Deprecation rule | Keep the old rule: an entry may be added to README's `## Deprecated` table in an `X.0.0`, and removed in a later `X.Y.0`. Add: an entry may also be added in a minor when its removal is scheduled no earlier than the next `X.0.0`. Such a row's *since* cell names that release: `2.10.0 (removal: 3.0.0)`. | Nothing vanishes during the current major, because removal still lands only in a major. Users are warned earlier than an announcement held back for the `X.0.0` would warn them. The old rule protected against surprise. Announcing early adds notice and takes nothing away. |
| 2 | Enforcement | `run-tests.sh` §138(5)–(5d). A *since* cell must be one of `X.0.0`, `X.Y.Z (exception)` or `X.Y.Z (removal: N.0.0)` with `N` greater than `X`. It may be no later than the tree's own `SANDY_VERSION`. A minor-announced row marked `REMOVED in A.B.C` must have `A` at least `N`. | A convention kept by memory rots. The cell format keeps every existing row valid and needs no new column. |
| 3 | What is deprecated | The `gemini` agent: `SANDY_AGENT=gemini`, `--agent gemini`, `gemini` inside a combo, and as a member of `all`. Also `GEMINI_MODEL`, `SANDY_GEMINI_AUTH` and `SANDY_GEMINI_EXTENSIONS`. All are `2.10.0 (removal: 3.0.0)`. The replacement is Antigravity CLI (`agy`), planned for sandy 3.0.0. | These are the surfaces that exist only for Gemini CLI. |
| 4 | What is not deprecated | `GEMINI_API_KEY`, and the `.gemini/` workspace protections. | Antigravity uses `GEMINI_API_KEY`. The protections guard against a host-side gemini or agy reading files an agent wrote, and that threat outlives the agent. |
| 5 | Launch warning | One `warn` line on every launch whose resolved agent set includes gemini, once per launch. It never appears in `--print-schema`, `--print-state` or `--validate-config` output. There is no suppression key. | Under the 2.5.0 exception's precedent, the README list reaches only people who read it, so a deprecation sandy can detect in use is announced where it is used. |
| 6 | Personal-account warning | When the credential sandy selects is the host Google-account OAuth file, warn, conditionally, that a personal account is no longer served. Suggest `GEMINI_API_KEY` or Vertex AI (gcloud ADC). Never refuse the launch. | Sandy cannot tell a personal account from a Code Assist Standard/Enterprise one, and the latter still works through the same file. The warning does not name `SANDY_GEMINI_AUTH`, which is itself deprecated. |
| 7 | Introspection | `--print-schema` `agents[]` gains `stability` (additive, `schema_version` stays `4`): `deprecated` for gemini, `experimental` for mirror, `stable` for the rest. The three keys report `stability: deprecated`. | A consumer reading the schema learns of the deprecation without parsing README. |

Options considered and not taken:

- **1:** wait for 3.0.0 to announce (the old rule); treat it as a second written exception (the exception is for consumer-shaped surfaces, which this is not).
- **2:** a fourth table column for the removal release (every existing row would change).
- **6:** refuse a launch on the OAuth file (it would break Code Assist Standard/Enterprise users).
