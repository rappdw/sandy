# Does sandy's restart-time cleanup mitigate the `crossSessionInbound: accept` persistence threat?

**Short answer:** It depends entirely on lifecycle, and for the mode AMP will use
(daemon / `--start`) the answer is **no**. Sandy has **no in-container process
cleanup at all** — the mitigation you were hoping exists does not exist as a
process reaper. What exists instead is a *namespace* mitigation that only fires
in foreground mode, achieved by destroying the whole container.

Grounded in a read of the `sandy` script (not aspirational behavior). The one
caveat: this is from the code, not from running the setsid+double-fork test in a
live daemon container — but the code path is unambiguous, because there is simply
no process-killing code to find. Empirical belt-and-suspenders check is at the end.

---

## Correcting the premise

The hoped-for mitigation — "enumerate uid processes, kill the ones not in the
known-good set, before the next session" — **does not exist.** Searching the whole
script: the only `pkill`/`killall` matches are the literal string `ripgrep`. There
is no `ps -u`, no `/proc` walk, no kill-by-uid, no process enumeration of any kind,
at any point. What sandy calls "cleanup" is **host-side `cleanup()`**, operating on
Docker objects and host files: `docker rm -f` the container, `docker network rm`,
wipe the credential tmpdir, release the lock, reap orphan networks. It never reaches
inside a running container to kill a process.

---

## 1. Lifecycle — it varies, and the variance *is* the answer

| Mode | Container | Lifetime |
|---|---|---|
| **Foreground** (bare `sandy`, `-p`) | `--rm -it`, one per invocation | **Ephemeral** — destroyed on exit |
| **Daemon** (`--start`) | `-d --restart unless-stopped`, no `--rm` | **Long-lived** — survives client exit, host reboot; days-to-weeks |

Driver: **which command launched it.** Daemon mode exists specifically to persist
across a closed terminal / VSCode quit, and it is what **sandy-ui uses**. An "AMP
delivery daemon delivering to sessions it did not spawn" is describing a persistent,
attach-later container — i.e. **daemon mode**, the long-lived case.

## 2. Existing cleanup — files/Docker only, never processes

`cleanup()` (`sandy:~217–260`): `docker rm -f "$CONTAINER_NAME"` → `docker rm -f
"$PROXY_CONTAINER"` → `docker network rm` (×2) → `rm -rf` the credential tmpdirs →
release the lock. Pre-launch it also reaps stale containers, orphan networks,
stranded proxies, dead locks. **All host-side Docker/filesystem. It enumerates and
kills zero processes.**

## 3. Timing — one hook, per container, kills nothing

The only container-start hook is the **entrypoint**, which runs **once at
`docker run`**: root setup (chown home, ssh, mkdir the persistent mounts), drop to
`claude` via gosu, then `tmux new-session -- claude`. It runs *before* the first
session binds its socket — but it **does not run again** for a second Claude Code
session started later inside a persistent daemon container, and it kills nothing
regardless. There is **no per-session-start hook.** Re-running `claude` inside a
daemon container's tmux is a plain exec with no sandy involvement.

## 4. Coverage — no, and it never walks a process tree

For **foreground**, the reparented pid-1 daemon *is* caught — but not by a rule.
It is caught because the container is destroyed (`--rm`), and **a setsid+double-fork
escapes the process *tree*, not the PID *namespace*.** When pid 1 exits, Docker
SIGKILLs the whole namespace, so ancestry is irrelevant — every process at the uid
dies, plus the tmpfs home wipes the binary. That is effectively "kill everything
except the known-good set," achieved by nuking the namespace — **but only because
each foreground container is single-session-and-gone.**

For **daemon**, nothing catches it. The container idles on `exec tail -f /dev/null`
(`sandy:5783`), independent of the Claude Code process. Claude Code can exit and
restart — new socket, same container, same PID namespace — while a reparented daemon
planted in an earlier session keeps running as pid 1's child. Sandy walks **neither**
its own tree **nor** the uid's process set inside the container. Persistence is
bounded only by **container lifetime**, which in daemon mode is unbounded by design.

## 5. Extending it — feasible, but no hook to hang it on, and a cheaper real answer

- **Container recreation (cheap, exists today, partial).** A reparented daemon dies
  when the container is destroyed. `sandy --stop`, and critically
  **`sandy --update-sessions`** (which does `--stop`+`--start` = a *new* container),
  both clear it. If AMP's hosts already run a nightly `--update-sessions` cron,
  persistence is bounded to that cadence *for free*. That is the one existing lever.
- **A real per-session reaper (new work).** You would need a hook that runs **before
  each Claude Code (re)start inside the container** — which doesn't exist; the
  entrypoint is per-container — that kills every uid process outside a known-good set.
  Two costs: (a) inventing that per-session hook (wrapping the `claude` invocation
  inside the container), and (b) defining "known-good" robustly. The second part is
  genuinely hard: the user legitimately backgrounds processes (`npm run dev`, a build,
  a watch) that are *also* reparented uid processes, indistinguishable from the
  malicious daemon by uid+ancestry alone. A too-broad reaper kills legitimate work; a
  too-narrow one misses the threat.

---

## The residual, written plainly

- **Foreground sandy: the threat is fully mitigated** — by per-session container
  destruction + tmpfs, not by any cleanup rule. A reparented daemon cannot outlive
  the container, and the container is one session.
- **Daemon sandy (what AMP will use): the threat is real and unbounded by container
  life.** Sandy runs no in-container process reaper and no per-session hook, so a
  setsid+double-forked daemon planted in session N under `accept` silently injects
  into every later session in that container until the container is recreated. The
  only thing that clears it today is destroying/recreating the container (`--stop`,
  `--update-sessions`, reboot-of-a-foreground).

**Recommendation:** do not document sandy's cleanup as the mitigation for the daemon
case — it isn't one. Either **bound the daemon container's life** (per-task
recreation, or a scheduled `--update-sessions`) and document *that* as the
mitigation with its cadence as the residual window, or add the per-session reaper and
pay the "known-good set" complexity. Preference: start with container-recreation
cadence, because it composes with sandy's existing "the container is cattle" model
instead of adding process-management sandy deliberately does not do today.

## Empirical confirmation (5-minute host test, if you want it before writing it down)

The code path is unambiguous (there is no process-killing code), but to
belt-and-suspenders the daemon claim: in a `--start` session, plant the daemon
(`setsid` + double fork, confirm `ppid 1`); then `sandy --stop` + `sandy --start`
and confirm it is **gone** after recreation; and separately confirm it is **present**
across a plain re-`claude` in the *same* container. That distinguishes
"container recreation clears it" (expected) from "session restart clears it" (it
does not).
