# Upgrading to 2.0

Migrating sandboxes created by sandy 1.x. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

**Read this before upgrading. 2.0 renames the container user and home from `claude` to `sandy`, and every sandbox created by 1.x must be migrated.**

Your **workspaces are never touched** — the change is entirely inside sandy's own state under `~/.sandy/`.

## Why a migration is needed at all

`/home/claude` is baked into files sandy does not own: virtualenv shebangs and `pyvenv.cfg`, `.pth` files, editable installs, `GOPATH` and `PYTHONUSERBASE` metadata, npm and cargo state. Moving the home leaves those pointing at a directory that no longer exists, and they fail in ways that look like broken packages rather than a moved home. Sandy refuses to launch against such a sandbox rather than limping into it.

## The migration

One command, once, for every sandbox on the host:

```sh
sandy --reset-sandbox --all --dry-run                  # see what it will do
sandy --reset-sandbox --all --keep-history --yes       # migrate
```

`--keep-history` preserves `claude/projects/` — every Claude session transcript and all auto-memory — **and nothing else**. Other agents' own history (`codex/`, `gemini/`, …), anything else under `claude/`, and any directory a host-side tool keeps in the sandbox are destroyed even with it; the reset plan **names each of them** under *NOT kept by --keep-history* (derived from what is actually in the sandbox), so stash anything you need first. **It is not the default and `--yes` does not choose it**, because the same command is also how you remediate a sandbox you distrust, and there memory is the thing you most want gone: it reaches the agent's context every session, so a compromised session writing to it is persistent injection with no expiry. Run interactively and sandy asks; run non-interactively and it requires `--keep-history` or `--purge-history` rather than guessing.

| destroyed (rebuilt on next launch) | preserved |
|---|---|
| `pip/`, `uv/`, `npm-global/`, `go/`, `cargo/` package caches | `WORKSPACE.json` (lineage) |
| the `venv/` overlay | — |
| per-agent state: `claude/`, `gemini/`, `codex/`, `opencode/`, `grok/` | `agent-args.<agent>` (per-agent launch args) |
| `.claude.json`, installed plugins, approvals | — |
| `claude/projects/` — transcripts and auto-memory, **unless `--keep-history`** | `claude/projects/` **with `--keep-history`** |

## Back up anyway

`--keep-history` preserves the corpus, but a backup costs little against 149 MB of irreplaceable transcripts per sandbox:

```sh
tar czf sandy-history-$(date +%F).tar.gz ~/.sandy/sandboxes/*/claude/projects
```

If you use [lore](https://github.com/rappdw/lore), also export the memory corpus — **its JSON export covers memories only and does not include transcripts**, so you want both:

```sh
lore export --json > lore-memories-$(date +%F).json
```

**Do not use `rm -rf` on the sandbox directory.** It takes the preserved column with it, and nothing recreates those — `agent-args.*` is operator state a repository cannot carry. (`relay-bin/` is **not** preserved since 2.2.0: the slot was removed, and a leftover entry would block the next launch.)

The cost is time and bandwidth: the next launch in each workspace re-downloads packages and rebuilds the venv. Nothing is lost that a `uv sync` or `npm install` will not restore.

A sandbox whose workspace no longer exists cannot be migrated — it is named and counted, and `sandy --remove-sandbox --orphans` is the command for it.

## If you have scripts, MCP configs or agent args that hardcode `/home/claude`

They break. Container paths are available from the environment and from the read-only attestation marker rather than by assumption:

```sh
sandy --exec -- printenv HOME                 # the container home
sandy --exec -- cat /etc/sandy-session.json   # workspace, sandbox_name, posture
```

## Also in 2.0

- `--print-state`'s `schema_version` was **`2`** in the 2.0 line, moved to **`3`** in 2.2.0, and is **`4`** as of 2.6.0 (see **Deprecated**). Gate on that number, not on sandy's version string — `2.0.0-dev` compares equal to `2.0.0`. Treat it as an **opaque token**: compare against a reviewed set, not with `>=`, so a future bump is something you read rather than something you silently accept.
- `sandboxes[].features` now reports **manifest selection** rather than per-sandbox markers; `SANDY_FEATURES_DIR` is removed with an error naming its replacement.
- `SANDY_EGRESS=off|permissive|strict` replaces two booleans. The old keys still work — see **Deprecated** below.
