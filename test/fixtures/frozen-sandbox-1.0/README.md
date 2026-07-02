# Frozen sandbox snapshot — 1.0 forward-compat fixture

A minimal sandbox directory **as created at the `1.0.0-rc1` cut** (2026-07-02).

**Do not update these files when sandy's version changes — staleness is the
point.** This fixture stands in for every real user sandbox created by a `1.x`
sandy. `run-tests.sh §60` asserts, on every future release, that:

1. `_sandbox_compat_classify` still classifies this sandbox `ok` against the
   *live* `SANDY_SANDBOX_MIN_COMPAT` floor, and
2. the floor itself has not moved above `1.0.0`.

If §60 fails, you have broken the 1.x forward-compat promise ("a sandbox
created by any 1.x sandy works with every later 1.x sandy" — see CLAUDE.md
§Sandbox compatibility). That change is `2.0.0` territory, not a `1.x` release.

Only the compat-relevant files are frozen here (`.sandy_created_version`,
`.sandy_last_version`, `WORKSPACE.json`, plus a placeholder
`claude/settings.json`). The runtime subdirectories (`pip/`, `uv/`,
`npm-global/`, `go/`, `cargo/`, …) are excluded deliberately: sandy `mkdir -p`s
them on launch, so their absence exercises the same path as a real old sandbox
whose dirs already exist — and git can't track empty dirs anyway.
