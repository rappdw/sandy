# Daemon mode and maintenance

Sessions that outlive the terminal, remote access, fleet updates, and a shell inside a running sandbox. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

## Daemon mode

By default a sandy session lives and dies with the terminal that launched it.
**Daemon mode decouples the two** — start a session detached, attach and detach
interactive clients whenever you like, and stop it explicitly when you're done:

```bash
sandy --start      # launch a detached session for this workspace; returns once attachable
sandy --attach     # attach an interactive client (last-attach-wins; a second attach
                   # cleanly displaces the first — no screen mirroring)
sandy --stop       # tear the session down completely (container, networks, lock)
```

The container runs with `--restart unless-stopped`, so a daemon session
**survives a host reboot or Docker restart** — close your laptop, come back
tomorrow, and `sandy --attach` picks up where you left off. `--start` is
idempotent (a second `--start` is a no-op), and running bare `sandy` in a
workspace that already has a daemon session errors with a hint to `--attach` or
`--stop` rather than clobbering it. `--start` is interactive-only (it rejects
`-p`/`--print`).

**First-run dialogs.** Nobody is attached to a daemon session to answer a
dialog, so sandy answers Claude Code's first-run ones before it starts: the
theme picker, the folder-trust prompt for your workspace, the auto-mode offer
and the bypass-permissions warning. The trust and first-run answers are also
written inside the container, so the host does not need `node` (before #505 a
host without `node` skipped the trust step silently).

One limit: `--start` reports ready as soon as the session exists and every
feature entry has passed its 5s startup window. It does not yet check that the
agent got past every dialog, so after changing credentials or Claude Code
versions, `sandy --attach` once to look.

**Feature entries and readiness (2.9.0).** A feature's supervised entry gets a
5s startup window, which now runs alongside the agent: the agent is already
booting while the entries settle, so the session is usable when `--start`
returns `0`. If an entry starts and then exits inside the window, the session
is torn down and `--start` exits `6` (it was `7`, "crash-looping", before
2.9.0); nothing is left running. An entry that cannot start at all (missing,
not executable) still exits `7`. A second `--start` during the first one's
window waits for the same verdict rather than reporting "already running" at
once. A daemon container that comes back on its own (after a reboot or a
Docker restart, with no `sandy --start` watching it) and whose entry fails
idles for 60s, then exits so Docker's restart policy tries again; the next
`sandy --start` for that workspace sees no supervisor behind it, removes it and
starts a fresh session (with a supervisor still alive, it exits `6` instead).
A container that comes back this way and keeps running has no supervisor, so
sandy's end-of-session checks never run for it, and on macOS its file locks may
have lapsed. Since 2.9.0 the next `sandy --attach` or `sandy --start` of that
workspace says so, re-applies the macOS locks and records the protected files'
contents (if no record exists); `sandy --stop` says so too and runs the
session-end checks the supervisor would have run (below). For a fully
protected session, `--stop` it and `--start` again.

### The session-end report of a daemon session

When a session ends, sandy reports protected paths that appeared, changed or
were replaced in the workspace during it (a new `.git/hooks/` hook,
`.github/workflows/` file, `.vscode/` task, `.claude/commands/` command, and so
on; see [Security](security.md)). A terminal session prints that report as it
exits. The report runs once the agent's container has been removed (2.11.1), so
it also covers anything the agent wrote in its last moments. If sandy cannot
confirm the container is gone (Docker unreachable during the teardown), the
report says it is provisional and what to do (for a terminal session:
`docker rm -f <container>`, then launch again). The next launch, or
`sandy --stop` of a daemon session, checks the workspace again once the
container is gone, and records that report until `sandy --ack-report`. A daemon session has no terminal: its supervisor's output goes to a log
file under `~/.sandy/sandboxes/` that nobody reads. So a daemon
session also **records** the report in its sandbox
(`~/.sandy/sandboxes/<name>/.session-end-report`, outside the workspace and
never visible to a container), one block per session headed by the UTC time it
ended. `--stop` of a session with no live supervisor runs the same checks once the
container is gone and records them too (only the changed-file check when the
session's own launch record is missing).

The next `sandy --start`, `--attach`, `--stop` (at its end, so it includes the
report of the session it just stopped) and terminal launch of that workspace
prints the record, and keeps printing it until you acknowledge it:

```sh
sandy --ack-report --workspace /path/to/project   # prints it, then removes it
```

Acknowledging is explicit rather than automatic because a reported path may be
yours and kept on purpose (a `.vscode/` you asked the agent to set up); sandy
cannot tell. A terminal session records nothing, so its report is printed
once, as before.
See
[Installing a relay](features.md#installing-a-relay) for the two failure shapes.

**Exit codes** — `--start`: `0` = ready, `1` = a usage error (`-p` with
`--start`) or a failure not covered below, `6` = the launch was refused before
the container was ready, and the error names the cause: most often an approval
to answer, a missing or expired credential the agent would prompt for, or a
sandbox below the compatibility floor, but also a config, feature,
named-session or network-isolation error, or (2.9.0; `7` before) a feature
entry that started and then exited inside its startup window, `7` = the
container is crash-looping
(including a feature entry that cannot start at all), `8` = timed out (600s, wall clock) waiting
for the session, `9` = a named Claude session (`.sandy/sessions/`) did not come
up (the container is left running; see
[Named Claude sessions](agents.md#named-claude-sessions-sandysessions)).
`--attach`: `0` = the session ended while you were attached,
`3` = you detached cleanly and the session is still running, `4` = no such
session (`5` is a `--stop` code, unreachable on `--attach`). `--stop`: `0` = stopped, `4` = no such session,
`5` = teardown failed. `--stop` waits up to 15s for the session's supervisor to finish its teardown (proxy, networks, lock). If the container is gone but the supervisor is still finishing, `--stop` warns and exits `0`, and a `--start` issued before it finishes finds the workspace locked; wait for the supervisor and retry. Starting several workspaces at once is safe: a launch never removes another launch's proxy while that launch is still starting (#498).

**An unresponsive session** (2.10.1, #548). Sandy checks a session by asking
its tmux server, and the agent can stop that server (it runs as the same
user). Every such check now gives up after a few seconds, and the answer is
"unknown", never "ready" and never "gone". So `--start` exits `8` after three
unanswered checks in a row (seconds, not the full 600s budget), saying why,
and leaves the session running for you to `--attach` or `--stop`;
`--attach` exits `3` after a warning; a bare `sandy` refuses rather than
reaping the container; `--gc` keeps the container and says why; and
`--update-sessions` skips it as active, giving the cause. The supervisor never tears down a
session because it does not answer: after about two minutes it logs one
warning, and `sandy --stop` ends the session.

This is what [`sandy-ui`](https://github.com/rappdw/sandy-ui) uses to keep a
session alive across a VSCode quit/relaunch.

### Remote access: what sandy covers, and what sits below it

Three things get conflated when sandy runs on a remote machine (an always-on
workstation or GPU box you reach from a laptop). Sandy owns exactly one of them.

- **Session persistence — sandy's layer.** A daemon session lives on the host
  that ran `sandy --start`, independent of any client. When your SSH or VS Code
  Remote connection drops, only the *client* is gone: the container and its tmux
  session keep running. Reconnect however you like, then `sandy --attach` (from
  the workspace, or with `--workspace PATH`) and carry on. If your client was
  killed mid-attach (a `SIGHUP` from a closed terminal), just run `--attach`
  again; it exits `4` if the session is genuinely gone. A foreground `sandy`
  (no `--start`) is the exception: it is tied to the terminal that launched it
  and cannot be reattached.
- **Connection resilience — below sandy.** Keeping the client link itself alive
  across laptop sleep or a flaky network is a transport problem: Remote-SSH, VS
  Code Remote Tunnels, mosh, Eternal Terminal, autossh and the like. Sandy needs,
  and takes, **zero changes** for any of them — it neither bundles nor checks
  for one, and there is no `sandy --tunnel`. Pick whichever you already trust.
- **Session mobility — not a sandy feature.** Reaching a session *from* another
  device is just the two above: get a shell on the host (SSH, over Tailscale or
  any VPN) and `sandy --attach`. Moving a running session *to* a different
  machine is something sandy does not do; the session stays on the host that
  started it. `sandy --rsync <host>` copies a sandbox's state to another host so
  a new session can start there (and the workspace too, when that host has
  none), and `sandy --rsync-from <host>` pulls one from
  another host to this one. Both refuse while a session is live.

These transports run on the **host**, outside sandy's containers, so they are
orthogonal to its isolation: sandy's network blocking applies to what the
*agent* can reach from inside the container (the `--internal` sidecar and egress
proxy), and a host-side `sshd`, `etserver` or tunnel is neither weakened by it
nor governed by it. Securing the path to your host is the host's business.

## Fleet updates (`--update-sessions`)

Daemon sessions can sit up for days, running an ever-staler image. `sandy --update-sessions` is a **global** maintenance command (ignores cwd — it operates on every daemon session on the host) that refreshes each session's images and rolling-restarts the ones that came out stale:

```bash
sandy --update-sessions --dry-run           # show the plan, refresh images, restart nothing
sandy --update-sessions --yes               # restart every stale session, no confirmation prompt
sandy --update-sessions --idle-for 30 --yes # only restart sessions idle 30+ minutes (cron-friendly)
sandy --update-sessions --rebuild --yes     # force a rebuild before checking staleness (each image once, however many sessions share it)
sandy --update-sessions --yes --workspace ~/dev/myproj   # scope to ONE session (per-session update)
```

For each session it runs that workspace's own `sandy --build-only` (so image selection, skills, and any per-project Dockerfile are resolved the same way a normal launch would resolve them), compares the running container's image ID against the freshly-built one — for the agent container **and** its egress-proxy sidecar, so a proxy image refresh (the monthly base/stdlib refresh, or a proxy fix) reaches live sessions even when the agent image did not change; the plan says `restart (proxy stale)` for those — and, for anything stale, does `sandy --stop` followed by `sandy --start` for you. `--dry-run` still refreshes images (so the printed plan reflects reality) but never stops or starts anything. Without `--idle-for`, every stale session is a restart candidate; a TTY without `--yes` gets a y/N confirmation, and a non-interactive run without `--yes` refuses with exit `1` — pass `--yes` explicitly for cron/launchd. Exit `0` unless a restart (`--stop` + `--start`) failed or there was something to restart and the run was non-interactive without `--yes` (both exit `1`; with nothing to restart, or under `--dry-run`, it exits `0`). A session whose image build fails is reported (`Build failed for <session>` with the tail of its build log) and skipped; it does not change the exit code, and the run goes on to the other sessions.

A cron/launchd recipe for a nightly quiet-hours refresh:

```cron
0 3 * * * /path/to/sandy --update-sessions --idle-for 30 --yes >> ~/.sandy/update-sessions.log 2>&1
```

Restarted sessions carry a `sandy.updated_at` container label so tooling (e.g. `sandy-ui`) can distinguish "restarted for an image update" from a session you stopped and started yourself.


## Getting a shell inside a running sandbox (`sandy --exec`)

```sh
sandy --exec                  # interactive shell in this workspace's container
sandy --exec -- codex login --device-auth   # or simply: sandy --login codex
sandy --exec --workspace ~/other-project -- git status
sandy --exec --dry-run        # print the docker exec command, run nothing
```

**Do not hand-roll this.** The obvious form is wrong in a way that does not announce itself:

```sh
docker exec -it -u sandy <container> /bin/bash      # -> "I have no name!"
```

The image creates the user with `useradd -u 1001 sandy`, but sandy bind-mounts a generated `/etc/passwd` carrying **your** uid so bind-mount ownership works. Docker resolves `-u <name>` against the container's *image* filesystem, not the runtime mount — so `-u sandy` runs as **uid 1001**. The prompt reading `I have no name!` is the harmless symptom; the real one is that every write lands as the wrong owner on a workspace mount owned by you.

`--exec` uses the numeric `-u $(id -u):$(id -g)`, sets `-w` to the container-side workspace path, and sets `HOME` explicitly (as root, `HOME=/root` sits on the read-only rootfs — which is why an in-container `codex logout` fails with `Read-only file system`). It finds a daemon container by label and a foreground one by exact name, exits `4` when the workspace has no running container, and otherwise passes the command's own exit status through.

For an interactive *agent* session, attach to the tmux session instead: `sandy --attach`.
