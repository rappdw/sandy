# Decisions: distribution channel and the consumer contract (2026-10-05)

Decided with the maintainer, one at a time. Context: the sandy-ui 1.0 planning exchange found that `install.sh` and `sandy --upgrade` install `main`, not a release, and left three "maintainer's call" items about how sandy treats consumers of its machine output.

| # | Decision | Choice | Deciding reason |
|---|----------|--------|-----------------|
| 1 | Install and upgrade source | Releases by default. `SANDY_CHANNEL=dev` installs `main` and records the commit. A failed release lookup fails loudly, naming `SANDY_URL` as the manual override, and never falls back to `main`. | The update check already treats `releases/latest` as the truth. Install and `--upgrade` now agree with it, which fixes two bugs: `--upgrade` moved stable users onto the dev line, and never updated a dev install (it compared only the version string). |
| 2 | Known consumers, and notice before a schema change | A "Known consumers" section in SPEC_INTROSPECTION (sandy-ui, lore, amap-deploy-sandy), saying what each reads and how it compares `schema_version`. Any `schema_version` change, at a major included, ships in an rc first, with an issue opened in each listed consumer's repo when that rc is tagged. A consumer joins the list by opening an issue. | Makes the written exception's "every known consumer" condition checkable, and gives notice at a major through the rc process that already exists, without a calendar. The list is a courtesy, not a guarantee to every user: sandy is public. |
| 3 | Config field types | Every config key in `--print-schema` gains `base_type` (`string`, `bool` or `int`), derived from `type`. SPEC_INTROSPECTION documents the closed set of types, with the rule that an unknown `type` renders as its `base_type`. | The fallback for an unknown type lives in the data, so a new type cannot take down a consumer's renderer (sandy-ui's settings form broke on `path`). |
| 4 | Consumer test in CI | Consumer-owned. sandy-ui runs its parser and gate nightly against sandy's `main` and any rc tag, and files an issue in rappdw/sandy on a break. Sandy's CI does not change. | Catches accidental breaks before a release, without making one consumer's code a gate on sandy's merges. Decision 2 covers the deliberate changes. |

Options considered and not taken:
- **1:** releases only, with no dev channel; staying on `main` and only recording commits; leaving it as is.
- **2:** leaving it as is; adding a fixed 14-day notice period.
- **3:** documenting the types only; also listing them in `--print-schema`; doing nothing.
- **4:** a blocking job in sandy's CI; a job required only on release-cut PRs; doing nothing.
