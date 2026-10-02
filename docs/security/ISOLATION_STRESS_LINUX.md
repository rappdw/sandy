# Sandy 2.7.1-dev Isolation Stress Test — Linux

**Date:** 2026-10-01
**Environment:** Debian GNU/Linux 13 (trixie) container on Ubuntu host, kernel 6.8.0-142-generic, docker (Docker Engine, embedded resolver 127.0.0.11), sandy 2.7.1-dev/b8f6d1b, cgroup **v2** (`cgroup2fs`), host architecture **x86_64**, host VM = QEMU/KVM.
**Posture at run time:** `egress_mode: strict` (proxy on, agent on `--internal` sidecar `10.200.0.3`, proxy `10.200.0.2`). Per-marker: `permission_mode: bypassPermissions`, `cred_mode: api-key`, `cross_session_inbound: refuse`.
**Methodology:** Run from **inside** the sandy container on a disposable VM, uid 1000 (= host uid, no userns remap). Kernel/runtime probes P1–P11 and B1–B8 were executed empirically. The sandy-mechanism S-probes that require a host-side `$SANDY_HOME` write or a second launch (S1, S3–S9, S11) were done as **source analysis** — Claude Code inside sandy cannot reach Docker or `$SANDY_HOME`, so a live relaunch is impossible from here; those are marked analysis-only. S2 and S10 were verifiable from source. All mutations confined to `/tmp` in the VM; no external service contacted.

## Executive summary

| # | Finding | Severity | Type |
|---|---|---|---|
| L1 | Unstaged host-side seed writers (`opencode/config/opencode.json`, `codex/auth.json`) follow a dangling symlink planted in the rw sandbox dir → create-through-link to an arbitrary host path outside the workspace | High | Host FS write outside workspace (create-only, fixed content) |
| L2 | No `ip6tables` backstop: `off`-posture LAN isolation is IPv4-only, relying solely on per-network `--ipv6=false` | Low (hardening) | Isolation defense-in-depth gap |
| L3 | Host identity/network info disclosure: `boot_id`, DNS search domain, host home path + `$SANDY_HOME` layout + username, DMI vendor | Low | Information disclosure |

No Critical finding. L1 is the only functional break and is gated behind agent selection + a relaunch; L2/L3 are hardening/info-disclosure. **Nothing here blocks the release;** L1 should be fixed in a patch (it is the exact "not all audited" class #400 flagged), L2 belongs with the Linux-hardening track (#370).

## Attack surface map (Linux-specific)

What sandy actually gives the agent on this Linux host, that the macOS run could not touch:

- **Rootfs** `--read-only` (`touch /etc/canary`, `/usr/bin/canary` → EROFS).
- **cgroup v2, mounted read-only.** `/sys/fs/cgroup/{cgroup.procs,memory.max}` → EROFS; `mkdir /sys/fs/cgroup/child` → EROFS. `pids.max=512`. No pids-limit escape, no sub-cgroup delegation.
- **Caps:** `CapEff=CapPrm=CapInh=CapAmb=0` (gosu drop complete); `CapBnd=0x00000000000000cb` = exactly {CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID} — the five retained caps, held by **no** agent-visible process. `no-new-privileges` on.
- **Seccomp:** mode 2, 1 filter (Docker default, sandy adds none). Blocks `io_uring_setup` (EPERM even though `/proc/sys/kernel/io_uring_disabled=0`), `userfaultfd`, `bpf`, `perf_event_open`, `kcmp`. `process_vm_readv` is *allowed* by the profile but inert without CAP_SYS_PTRACE against root-owned pids.
- **AppArmor:** `docker-default (enforce)`.
- **pid 1 = `/sbin/docker-init -- /usr/local/bin/entrypoint.sh`** (`--init` present, #392). `/proc/1/root`, `/proc/1/environ` → EPERM from agent uid (pid 1 root-owned).
- **Network:** proxy posture, `--internal` sidecar (no route off it), DNS = Docker embedded resolver forwarding to proxy `10.200.0.2`. Off-posture iptables (`apply_network_isolation()`, `sandy:15427`) DROPs v4 `10/8,172.16/12,192.168/16,169.254/16,100.64/10` in `DOCKER-USER`, each now `-C`-verified (`sandy:15489`). **Zero `ip6tables` anywhere; all nets `--ipv6=false`** (`sandy:13199,13244,13277`).
- **Mounts:** protected paths `:ro` (`.git/config`, `.git/hooks`, `.git/info`, `.git/packed-refs`, `.github/workflows`, `.gitmodules`, `.sandy`, `.claude/settings.local.json`); `.git/HEAD` writable by design (1.5.0); marker `/etc/sandy-session.json` `:ro`; rw = `~/.claude`, workspace.

## Finding L1 — Unstaged seed writers follow a planted symlink to a host path

*Status (2.7.1, #418): fixed. The opencode and codex-auth seeds now remove a planted symlink before deciding whether to write (the §169 guard gemini already used), and the redundant first-run `statsig` copy is gone; §192 guards all three. Severity revised down at triage: GNU `cp` refuses to write through a dangling link, so on Linux hosts the two `cp` writers did not fire; the live vectors were the opencode local-LLM `cat >` branch and BSD `cp`.*

### Premise
#400 (2.7.0) made host-side launch writers into the rw agent homes stage to a fresh `<target>.sandy-launch.<id>` path that the container renames in, so the host never writes *through* a path (or link) the agent planted. The staged set is exactly `claude/settings.json`, `claude/.claude.json`, `claude/statsig`, `claude/hooks/cmux-notify.sh`, `codex/config.toml`, `gemini/settings.json` (`_sandy_stage_commit` call sites, `sandy:14037,15273,15297,15330,16061,16375`). CLAUDE.md states plainly: *"Other host-side writes into the rw sandbox dirs are the same class and have not all been audited."* Two seed writers were **not** converted and remain raw `cp`/`cat >`:

- **opencode** (`sandy:14094–14128`): `if [ ! -f "$SANDBOX_DIR/opencode/config/opencode.json" ]; then cp "$HOME/.config/opencode/opencode.json" …` / `cat > "$SANDBOX_DIR/opencode/config/opencode.json"`.
- **codex auth** (`sandy:16326–16335`): guard `[ -s "$SANDBOX_DIR/codex/auth.json" ]` then `cp "$HOME/.codex/auth.json" "$SANDBOX_DIR/codex/auth.json"`.

`$SANDBOX_DIR/opencode/config` and `$SANDBOX_DIR/codex` are mounted **rw** in-container (`~/.config/opencode`, `~/.codex`), so an agent can plant a symlink there between sessions. The existence guards `-f`/`-s` **follow symlinks**, and `cp`/`cat >` to a symlink **whose target does not yet exist** creates the target *through the link*. The agent learns the host home from `/proc/self/mountinfo` (leaks `/home/ubuntu/.sandy/sandboxes/…`, see L3). Neither path is under the workspace, so the dangerous-symlink approval (which scans only `$WORK_DIR`) never sees it.

### Repro
Analysis-only (no relaunch available from inside the container). The planting step is live; the host-side write is shown from the source.

```
# Session N, inside the container (opencode or codex selected so the dir is mounted rw):
$ grep -o '/home/[^/]*/\.sandy' /proc/self/mountinfo | head -1
/home/ubuntu/.sandy                 # host home learned from the mount source

$ ln -s /home/ubuntu/.config/systemd/user/evil.service \
        ~/.config/opencode/opencode.json      # dangling: target does not exist
#   (for codex:  ln -s /home/ubuntu/<nonexistent> ~/.codex/auth.json )

# Session N+1, host-side seed (sandy:14096 / 16334), target still absent:
#   [ ! -f "$SANDBOX_DIR/opencode/config/opencode.json" ]  -> true (dangling link)
#   cp "$HOME/.config/opencode/opencode.json" "$SANDBOX_DIR/opencode/config/opencode.json"
#   -> cp follows the link and CREATES /home/ubuntu/.config/systemd/user/evil.service
#      on the HOST, outside the workspace, with the host's own opencode.json bytes.
```

Contrast the correct shape already in the tree — `_sandy_stage_begin` (`sandy:531`) refuses a symlinked source (`[ ! -L "$_t" ]`), writers use `_sandy_write_atomic` (exclusive `set -C` temp + `mv`), and the container-side apply `mv -f`s onto the target, *replacing* a planted link instead of following it. Gemini got exactly this treatment (`_gemini_write_auth_type`, `sandy:16254`, with its own `[ ! -L ]` check); opencode and codex-auth did not.

### Impact
An agent with filesystem access in an opencode- or codex-enabled sandbox can, across one relaunch, **create a file at an arbitrary host path outside the workspace** — a systemd user unit, a `~/.config/autostart/*.desktop`, a `.git/hooks/*` in another repo, a `~/.bashrc` where none exists. Two real limits keep this off "Critical": the write is **create-only** (both guards skip when the link target already exists, so no overwrite of live host files), and the **content is not attacker-controlled** (the host's own `opencode.json` / `codex auth.json`, or the generated local-LLM stub). JSON-as-bashrc mostly errors, so turning create-only + fixed-content into direct code execution needs a path whose mere *existence* with arbitrary content matters (an autostart entry, a marker file a host cron reads). Credential angle for codex: the created file holds the host's codex OAuth `auth.json`; dropping it inside the workspace (`/home/ubuntu/dev/sandy/…`) makes it readable by the next session, though a codex-enabled sandbox already mounts those creds, weakening the exfil value.

### Suggested fix
Route both writers through the #400 staging pipeline, identical to `codex/config.toml` and `gemini/settings.json`: `W="$(_sandy_stage_begin "$dest")"`, write the seed to `$W` (via `_sandy_write_atomic` for the `cat >` heredoc, or `cp "$src" "$W"` for the host copy), then `_sandy_stage_commit "$dest"` and let `user-setup.sh` move it in. `_sandy_stage_begin` already refuses a symlinked target and the exclusive temp + rename closes the through-link write. Minimal alternative (no staging): add the §169 remove-and-name guard before each write — `[ -L "$dest" ] && { warn "removed planted link at $dest"; rm -f "$dest"; }` — and never rely on `-f`/`-s` to decide whether to write through a path the agent can replace. Neither change affects legitimate seeding: a fresh sandbox has no link there, and a real prior config is a regular file the guard leaves alone. Add a §169-style test asserting the opencode/codex-auth targets are refused when symlinked (the gemini/codex-config cases already have coverage).

## Finding L2 — No `ip6tables` backstop; off-posture isolation is IPv4-only

*Status (2.7.1): accepted as a hardening item on the #370 Linux-hardening track (#419); not reachable today.*

### Premise
Every network sandy creates is `--ipv6=false` (`sandy:13199,13244,13277`) and `grep -c ip6tables sandy` = **0**. In the `off` posture, `apply_network_isolation()` (`sandy:15427`) installs v4 DROP rules for `10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10` in `DOCKER-USER` and `-C`-verifies each. There is **no v6 mirror** of those rules. The sole IPv6 defense is the per-network `--ipv6=false` toggle, which prevents the bridge from assigning the container a v6 address — a docker-daemon-level knob, not a kernel/iptables enforcement.

### Repro
```
# Inside the container:
$ cat /proc/net/if_inet6
00000000000000000000000000000001 01 80 10 80  lo     # only loopback has a v6 addr
$ sysctl net.ipv6.conf.all.disable_ipv6
net.ipv6.conf.all.disable_ipv6 = 0                    # v6 not disabled in-kernel

# In the source:
$ grep -c ip6tables sandy
0
```

`eth0` has no v6 address today, so **no v6 egress path currently exists** — the probe found nothing reachable.

### Impact
Defense-in-depth gap, not currently exploitable. If a future change, a daemon with `ipv6:true`/v6 default-address-pools, or a per-network override ever gave the sidecar/bridge a v6 address, the `off`-posture LAN isolation would silently not cover it — `DOCKER-USER` holds only v4 DROPs, so RFC-4193/link-local v6 LAN destinations would be reachable with no rule in the way. The proxy posture is unaffected (`--internal` is an L3, protocol-agnostic FORWARD DROP that already fails v6 closed). The prompt pre-authorized a **High** rating here on the "purely `--ipv6=false` with no kernel backstop" criterion; I keep it **Low** because there is no reachable v6 path on a correctly-configured daemon and the gap is `off`-posture-only, but the reviewer may prefer High as a hardening priority.

### Suggested fix
In `apply_network_isolation()`, mirror each DROP with an `ip6tables -I DOCKER-USER … -j DROP` (and the same `-C` verify), guarded by `command -v ip6tables` and a graceful skip when the host lacks v6 — so that even if a container ever acquires a v6 address, the LAN ranges are denied in both families. Belongs with #370. Legitimate traffic is unaffected: the container has no v6 address to send from in the normal case, so the rules are inert until they are needed.

## Finding L3 — Host identity and network info disclosure

*Status (2.7.1): `boot_id` and the `mountinfo` source paths accepted as inherent to Docker; the inherited DNS `search` line is tracked as a cleanup (#420).*

### Premise
Several host-identifying values are readable from inside the container. Individually minor; together they fingerprint the host and allow cross-session correlation.

### Repro
```
$ cat /proc/sys/kernel/random/boot_id
300e9cae-680f-4e13-925c-bf7b03e2cc4d          # HOST boot id (not namespaced) — stable across every sandbox this boot

$ grep -o '/home/[^/]*/\.sandy/sandboxes/[^ ]*' /proc/self/mountinfo | head -1
/home/ubuntu/.sandy/sandboxes/sandy-a99f7aa5/launch/f2f20f7783840432/sandy-session.json
                                              # leaks host username (ubuntu), $SANDY_HOME layout, sandbox slug, launch id

$ grep search /etc/resolv.conf
search thatsarapp.org                         # host's DNS search domain inherited into the container

$ cat /sys/class/dmi/id/sys_vendor
QEMU                                          # host virtualization (product_uuid correctly masked: Permission denied)
```

### Impact
`boot_id` is a stable per-boot host identifier — any two sandy sessions on the same host boot share it, defeating the "sandboxes are isolated siblings" expectation for an agent trying to tell whether it has seen this host before. The `mountinfo` source leak hands the agent the host username and `$SANDY_HOME` path layout, which is the enabling primitive for L1 (knowing `/home/ubuntu` to aim a planted symlink). The DNS search domain leaks internal network naming. All are read-only info disclosure; none is an escape.

### Suggested fix
`boot_id` and the `mountinfo` source field are inherent to Docker (bind-mount source paths and the un-namespaced `boot_id`) and cannot be fully closed without userns remapping or a masked-paths overlay — note them as accepted, or mask `/proc/sys/kernel/random/boot_id` via `--security-opt` masked paths if the hardening is judged worth it. The DNS search domain is avoidable: in proxy posture sandy already supplies a generated resolver config; dropping the inherited `search` line (the proxy resolves absolute names) removes that leak at no cost. The L1 fix is the real mitigation for the `mountinfo`-enabled attack, not hiding the path.

## Negative results

Correctly defended / not reproducible:

- **P1 IPv6 egress (proxy posture):** no v6 address on `eth0` (`if_inet6` = loopback only); `--internal` drops all non-TCP incl. v6. (Backstop gap recorded as L2.)
- **P2 cgroup v2:** `/sys/fs/cgroup` mounted read-only — `cgroup.procs`, `memory.max` EROFS, `mkdir child` EROFS. No pids-limit escape, no release_agent (v2, no such file), no delegation.
- **P3 abstract UNIX sockets:** could not bind a host-side `\0` canary from inside the container, so not empirically confirmed; netns scopes abstract sockets per container by design and `/proc/net/unix` showed no cross-container names. Treat as defended-by-design, unverified end-to-end.
- **P4 kernel keyring:** `keyctl` not installed; `/proc/keys` empty (Docker masks it). No host keyring visibility.
- **P5 io_uring:** `io_uring_setup(425)` → EPERM despite `io_uring_disabled=0` — blocked by Docker's seccomp, not the kernel. No seccomp bypass surface.
- **P6 /proc masking:** `/proc/1/root`, `/proc/1/environ` EPERM; `/proc/kcore`/`keys`/`sched_debug` not readable; `binfmt_misc` is an empty non-mounted stub dir, read-only. `/proc/1/cmdline` = `docker-init` (#392 intact).
- **P7 seccomp syscalls:** `userfaultfd`, `bpf`, `perf_event_open`, `kcmp` all EPERM. `process_vm_readv` allowed but inert (no CAP_SYS_PTRACE; only root-owned pid 1 to target).
- **P7b root phase / caps:** agent `CapEff/Prm/Inh/Amb=0`; `CapBnd=0xcb` = exactly the five retained caps and nothing wider; no agent-visible process holds a non-zero `CapEff`. gosu drop complete, `no-new-privileges` blocks regain.
- **P8 AppArmor:** `docker-default (enforce)`, not unconfined.
- **P9 /dev /sys:** only `eth0`/`lo` in `/sys/class/net` (no other bridges/sessions); DMI `product_uuid` masked (`Permission denied`), only `sys_vendor=QEMU` leaks (recorded in L3).
- **P10 DNS:** resolver is Docker embedded (127.0.0.11) forwarding to the proxy; `.local`/magic names do not resolve to LAN.
- **P11 `--add-host`:** `host.docker.internal`, `gateway.docker.internal`, `metadata.google.internal` all NXDOMAIN on Linux (no `SANDY_LOCAL_LLM_HOST` set). Correct.
- **B1 docker.sock:** ENOENT (not mounted).
- **B2 userns:** identity map `0 0 4294967295` — no remap; container uid 1000 == host uid 1000 (expected; not an escape on its own).
- **B3 rootfs:** EROFS on `/etc` and `/usr/bin`.
- **B5 mount leaks:** no unexpected host paths in `mountinfo` beyond the documented bind sources.
- **B6 cgroup delegation:** `mkdir /sys/fs/cgroup/child` EROFS.
- **S2 manifest charset escape (analysis):** `_sandy_fm_valid_segment` (`sandy:1159`) case `""|.*|*..*|*[!A-Za-z0-9._-]*` rejects empty, leading-dot, any `..`, and any non-`[A-Za-z0-9._-]` byte (so `/`, absolute paths, unicode). `${slug}` substituted before the check. No escape of the computed root — airtight.
- **S10 off-posture iptables verify (analysis):** `-C` verify present per-range (`sandy:15489`); a missing DROP `error`s and refuses the launch (EXIT-trap cleanup removes partial rules), downgraded to an INCOMPLETE warning only under `SANDY_ALLOW_NO_ISOLATION=1`. #299 correctly implemented.
- **S7 staged writers (analysis):** the six staged targets are symlink-safe by construction (`_sandy_stage_begin` refuses a symlinked source; apply `mv -f` replaces a planted link). Only the two *unstaged* writers (L1) are exposed.

## Conclusion

The kernel/runtime boundary on this Linux host is in good shape: read-only rootfs and read-only cgroup v2, a complete capability drop, Docker's seccomp blocking the usual escape syscalls (`io_uring`, `userfaultfd`, `bpf`, `perf_event_open`, `kcmp`), `docker-default` AppArmor enforcing, `--init` intact, no docker.sock, and all protected paths `:ro`. Nothing here is a release blocker. The one functional finding, **L1**, is precisely the "host-side writes … not all audited" class #400 called out: two seed writers (`opencode/config/opencode.json`, `codex/auth.json`) were left on the pre-#400 raw-`cp`/`cat` pattern and follow a dangling symlink to create a file outside the workspace — fix by converting them to the existing staging pipeline (a patch-sized change) and add the §169-style symlink test. **L2** (no `ip6tables` backstop) is a `off`-posture hardening gap with no reachable v6 path today — route it to the Linux-hardening track (#370). **L3** is accepted-class info disclosure except for the inherited DNS search domain, which is a free cleanup. S-probes requiring a relaunch (S1, S3–S9, S11) could not be exercised live from inside the container and warrant a host-driven run to close empirically.
