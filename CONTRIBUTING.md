# Contributing to sandy

Thanks for wanting to help. Sandy is a small, deliberately opinionated tool, so a
few constraints matter more here than in a typical repo. Please read this before
opening a PR.

## The one hard constraint: sandy stays a single file

`sandy` is a **single self-contained bash script**. It installs to
`~/.local/bin/` and updates in place with `sandy --upgrade`, which downloads and
replaces that one file. **Do not split it into multiple files, add a runtime
dependency on a helper library, or otherwise break the single-file /
`--upgrade`-compatible property.** Everything the launcher needs at runtime lives
in that one script (it *generates* the Dockerfiles, entrypoint, tmux config,
etc. on first run).

Derived files exist for review and linting only (e.g.
`templates/user-setup.sh.tmpl`), and are regenerated from the script — see
"Keeping docs and templates in sync" below. They are not shipped to users.

## Development setup

Clone the repo and install the local copy:

```sh
LOCAL_INSTALL=./sandy ./install.sh
```

Not sure your host has what sandy needs? Run `./doctor.sh` — it checks the
Docker daemon, git, curl, `gh`, credentials, and PATH, and only *reports*; it
never installs anything.

## Running the tests

**Tests must run on the host, not inside sandy.** Sandy running inside sandy
can't reach Docker, and the suites build and inspect Docker images directly. So
if you're developing with sandy, run the tests in a plain host shell.

```sh
bash test/run-tests.sh              # pure-script tests — needs Docker + built images
bash test/run-integration-tests.sh  # headless end-to-end — needs Docker + API keys
```

`test/run-tests.sh` also enforces the doc/template regen `--check` modes and
`shellcheck`, so it catches drift as well as behavior regressions. Manual /
interactive-TUI validation steps that can't be scripted live in
`TESTING_PLAN.md`.

Please **run both suites and share the results in your PR.** Because they require
the maintainer's Docker + API keys in some cases, the maintainer may re-run them,
but a PR that says "ran `run-tests.sh` clean on Linux/OrbstackDocker" moves much
faster.

## Keeping docs and templates in sync

Sandy's documentation is treated as part of the product. When you change
behavior, update:

- **`SPECIFICATION.md`** — the implementation-level reference, including
  appendices **A–E** (generated file templates, runtime parameters, JSON schemas,
  platform-specific behavior, container launch assembly). Keep these accurate.
- **`README.md`** — user-facing behavior, flags, config table.
- **`CLAUDE.md`** — design rationale and the guidance the coding agent follows.

Two regeneration scripts keep machine-derived content honest; both have a
`--check` mode that the test suite runs (a PR that leaves them stale will fail):

```sh
test/regen-config-docs.sh          # rewrite the autogen config tables in CLAUDE.md / SPECIFICATION.md
test/regen-config-docs.sh --check  # verify no drift

test/regen-template.sh             # rewrite templates/user-setup.sh.tmpl from the heredoc
test/regen-template.sh --check     # verify no drift
```

### Adding or changing a config key

The privileged/passive key lists and the config tables are **generated** from the
script's `_sandy_key_metadata` heredoc — don't hand-edit the autogen blocks. When
you add, remove, or re-tier a key:

1. Add/adjust the key in the appropriate tier array in `sandy`
   (`SANDY_PRIVILEGED_KEYS`, `SANDY_PASSIVE_KEYS`, or `SANDY_ENV_ONLY_KEYS`).
2. Add/adjust its row in the `_sandy_key_metadata` heredoc
   (pipe-separated `key|type|default|pattern|description`).
3. Run `test/regen-config-docs.sh` to propagate it into the docs.
4. Verify it surfaces correctly in `sandy --print-schema`.

The introspection surface (`--print-schema`, `--print-state`, `--validate-config`)
has its own stability contract in `SPEC_INTROSPECTION.md` — respect
`schema_version: 1`.

## Versioning and compatibility

`SANDY_VERSION` follows semver with the discipline documented in `CLAUDE.md`:

- `X.Y.(Z+1)` — **fixes only**.
- `X.(Y+1).0` — **additive** (new config keys/flags allowed; no re-tiering or
  renames of existing keys).
- `2.0.0` — anything that **breaks** the sandbox forward-compat promise, the
  introspection `schema_version: 1` contract, or config-key tier semantics.

Within `1.x` sandy makes a **forward-compatibility promise**: a sandbox created by
any `1.x` sandy works with any later `1.x` sandy. Concretely,
`SANDY_SANDBOX_MIN_COMPAT` must never advance above `1.0.0` within `1.x`
(guarded by `run-tests.sh §60`). A layout change that would break `1.x`
sandboxes is a `2.0` change. Please don't propose one lightly.

## Pull request conventions

- **Branch from `main`.** Keep the branch focused on one change.
- **Keep commits focused** and their messages meaningful.
- **Run both test suites on the host** and note the result in the PR.
- **Update `SPECIFICATION.md` / `README.md` / `CLAUDE.md`** whenever behavior
  changes, and run the regen `--check` scripts.
- Fill out the PR template checklist.
- Link the issue your PR addresses, if there is one.

There is **no CLA** — contributions are under the repository's MIT license.

## Reporting bugs and requesting features

Use the GitHub issue templates. For **security vulnerabilities do not open a
public issue** — follow [`SECURITY.md`](SECURITY.md) (email rappdw@gmail.com or a
private GitHub advisory).
