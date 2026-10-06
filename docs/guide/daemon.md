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

**Exit codes** — `--attach`: `0` = the session ended while you were attached,
`3` = you detached cleanly and the session is still running, `4` = no such
session (`5` is a `--stop` code, unreachable on `--attach`). `--stop`: `0` = stopped, `4` = no such session,
`5` = teardown failed.

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
  a new session can start there, and `sandy --rsync-from <host>` pulls one from
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
sandy --update-sessions --rebuild --yes     # force a rebuild before checking staleness
sandy --update-sessions --yes --workspace ~/dev/myproj   # scope to ONE session (per-session update)
```

For each session it runs that workspace's own `sandy --build-only` (so image selection, skills, and any per-project Dockerfile are resolved the same way a normal launch would resolve them), compares the running container's image ID against the freshly-built one — for the agent container **and** its egress-proxy sidecar, so a proxy image refresh (the monthly base/stdlib refresh, or a proxy fix) reaches live sessions even when the agent image did not change; the plan says `restart (proxy stale)` for those — and, for anything stale, does `sandy --stop` followed by `sandy --start` for you. `--dry-run` still refreshes images (so the printed plan reflects reality) but never stops or starts anything. Without `--idle-for`, every stale session is a restart candidate; a TTY without `--yes` gets a y/N confirmation, and a non-interactive run without `--yes` refuses with exit `1` — pass `--yes` explicitly for cron/launchd. Exit `0` means everything is clean (including "nothing to do"); exit `1` means something failed or the non-interactive prompt was refused.

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
docker exec -it -u claude <container> /bin/bash     # -> "I have no name!"
```

The image creates the user with `useradd -u 1001 claude`, but sandy bind-mounts a generated `/etc/passwd` carrying **your** uid so bind-mount ownership works. Docker resolves `-u <name>` against the container's *image* filesystem, not the runtime mount — so `-u sandy` runs as **uid 1001**. The prompt reading `I have no name!` is the harmless symptom; the real one is that every write lands as the wrong owner on a workspace mount owned by you.

`--exec` uses the numeric `-u $(id -u):$(id -g)`, sets `-w` to the container-side workspace path, and sets `HOME` explicitly (as root, `HOME=/root` sits on the read-only rootfs — which is why an in-container `codex logout` fails with `Read-only file system`). It finds a daemon container by label and a foreground one by exact name, exits `4` when the workspace has no running container, and otherwise passes the command's own exit status through.

For an interactive *agent* session, attach to the tmux session instead: `sandy --attach`.
