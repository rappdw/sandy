# Network isolation

The egress proxy, its three postures, platform specifics, and how to check it. Part of the [sandy guides](README.md); back to the [project README](../../README.md).

> Network egress is one of sandy's isolation layers. For the full picture —
> the assumed adversary, every layer, and the honest residual risks — see
> [`THREAT_MODEL.md`](../security/THREAT_MODEL.md). Empirical bypass attempts are in
> [`ISOLATION_STRESS.md`](../security/ISOLATION_STRESS.md).

## Egress proxy — cross-platform isolation

The egress proxy is the recommended isolation mechanism and the **only** one that works on macOS. It routes the agent through a small proxy sidecar on a Docker `--internal` network (no route off the bridge except through the proxy), so it behaves identically on macOS and Linux. The posture is one key, `SANDY_EGRESS` (default **permissive**):

| Setting | Mode | Behavior |
|---|---|---|
| `SANDY_EGRESS=permissive` *(or unset)* | permissive (default) | Blocks private/LAN/host/cloud-metadata destinations and well-known DNS-over-HTTPS resolvers, allows all other internet. Closes the macOS LAN gap with ~zero friction. |
| `SANDY_EGRESS=strict` | strict | Allows only a built-in default allowlist (model providers, GitHub incl. SSH, npm/PyPI/crates/Go/Debian) plus `SANDY_ALLOW_HOSTS`. Fails closed on everything else. **Strengthens isolation — safe to commit in a workspace config.** |
| `SANDY_EGRESS=off` | off | Linux iptables only; macOS has no network isolation (see below). **Weakens isolation — a workspace `.sandy/config` setting it triggers an approval prompt** so a cloned repo can't silently disable your sandbox. |

```sh
SANDY_EGRESS=strict   # in ~/.sandy/config or a workspace .sandy/config
```

**A workspace `SANDY_EGRESS=permissive` also triggers the approval prompt.** A workspace `.sandy/config` outranks `~/.sandy/config` for the same key, so on a host that chose `strict`, a cloned repository's one-line `SANDY_EGRESS=permissive` would otherwise re-open the whole internet with no prompt (#371; sandy 2.0.0–2.3.x gated only `off`). Only `strict` — the tightening value — is free from a workspace. The prompt appears even when your host is already permissive, because the gate judges the value, not what your host resolved; approving it once for that workspace silences it.

**Permissive mode refuses well-known DNS-over-HTTPS resolvers** (`dns.google`, `cloudflare-dns.com`, `dns.quad9.net`, `doh.opendns.com`, `dns.nextdns.io`, … — the list is in `proxy/doh.go`). A tool that resolves names over HTTPS instead of DNS would otherwise take resolution off the path sandy observes, so `SANDY_EGRESS_LOG`'s "what did this session reach" summary would be incomplete. The refusal is logged in `proxy.log` like any other denial. If you genuinely route DNS that way, add the resolver to `SANDY_ALLOW_HOSTS` — an allowlisted provider is reachable again. The list is **best-effort and enumerable, not complete**: an unlisted or self-hosted resolver, or one addressed by raw IP through the proxy, is not caught. For a real guarantee use `SANDY_EGRESS=strict`, which already denies every resolver you have not allowlisted.

> The pre-2.0 keys still work and are listed under **Deprecated**: `SANDY_EGRESS_STRICT=1`/`=0` (strict/permissive), `SANDY_EGRESS_NO_ISOLATION=1` (off), and the older `SANDY_EGRESS_PROXY=0|1|2` alias (`0`→off, `1`→permissive, `2`→strict). If `SANDY_EGRESS` is set it wins and the old values are ignored with a notice. Their weakening values are approval-gated from a workspace the same way: `SANDY_EGRESS_STRICT=0`, `SANDY_EGRESS_NO_ISOLATION=1`, `SANDY_EGRESS_PROXY=0` and `=1`.

Add extra reachable hosts with `SANDY_ALLOW_HOSTS` (privileged; comma-separated `host`, `*.suffix`, or `host:port`). git-over-SSH (`SANDY_SSH=agent`) is tunneled through the proxy automatically on both platforms; on macOS, host-agent *key signing* is unavailable under the proxy (use `SANDY_SSH=token` for a fully-supported HTTPS path). A local LLM (`SANDY_LOCAL_LLM_HOST`) is forwarded through the proxy rather than an iptables hole. See `CLAUDE.md` → "Egress Proxy" for the full topology.

**`SANDY_SSH=agent` no longer hands the container your whole `~/.ssh`.** Before 1.14.0 it mounted `~/.ssh` in full and copied every file into the container, agent-readable — in one measured case 35 private keys, including the operator's employer credentials and six AWS `.pem` files, in a container working on an unrelated repo. Now nothing private is staged unless you name it:

```sh
# in <project>/.sandy/config — one approval prompt, scoped to this workspace
SANDY_SSH_KEYS=id_rsa_homelab,id_rsa_deploy
```

This works in **any** `SANDY_SSH` mode. If your workspace reaches other machines with `ssh -i` and doesn't need agent forwarding, `SANDY_SSH=token` plus an allowlist is the right combination — git over HTTPS, the specific keys you named, and no agent relay at all.

`config`, `known_hosts` and `*.pub` are always staged. A name that matches no file warns rather than silently doing nothing. A named key with no `.pub` sibling gets one derived. `SANDY_SUSPICIOUS=1` forces the list empty.

**macOS SSH-agent relay exposure.** Outside proxy mode, `SANDY_SSH=agent` on macOS bridges the host SSH agent into the container via a host-side TCP relay (`socat TCP-LISTEN:<port>,bind=127.0.0.1`) — Linux doesn't need this since the agent socket is bind-mounted directly. The relay is bound to `127.0.0.1` and lives only for the session, but on a multi-user Mac any local process that can reach `127.0.0.1` can connect to it and sign with your keys for as long as the session is open (the ephemeral port number is weak obscurity, not an authentication boundary). If that matters for your threat model, prefer `SANDY_SSH=token` (HTTPS via `gh auth token`), which never exposes the agent.

## macOS (Docker Desktop) — not isolated when the proxy is off

**Warning:** if you turn the proxy off with `SANDY_EGRESS=off` (the proxy is on by default), Docker Desktop does *not* provide LAN isolation. The container *can* reach `host.docker.internal` (→ your Mac's gateway), your host's `localhost` services, and any device on your physical LAN — your home router at `192.168.1.1`, a NAS, a printer, an internal dashboard, your SSH daemon. A stress test in April 2026 opened a live TCP connection from inside the container to the host's SSHD and read its banner (see `ISOLATION_STRESS.md`, finding F2).

As defense-in-depth, sandy nullifies the Docker Desktop magic hostnames (`gateway.docker.internal`, `metadata.google.internal`, and — when `SANDY_SSH != agent` — `host.docker.internal`) via `--add-host`, and prints a launch-time warning banner on macOS. But **raw-IP access is unaffected**, and the banner is a warning, not a fix.

**Fix:** leave the proxy on (the default) or set `SANDY_EGRESS=strict` — both apply real isolation on macOS. Otherwise treat proxy-off macOS sandy as "process and filesystem isolation only; no network isolation."

## Linux
Sandy automatically inserts `iptables` rules into the `DOCKER-USER` chain that block all RFC 1918 traffic from the container's bridge interface:

| Range | What it blocks |
|---|---|
| `10.0.0.0/8` | Home/office LAN, VPNs |
| `172.16.0.0/12` | Docker internals, some LANs |
| `192.168.0.0/16` | Home/office LAN |
| `169.254.0.0/16` | Link-local |
| `100.64.0.0/10` | CGNAT, Tailscale |

Rules are automatically cleaned up when sandy exits. Stale rules from a previous unclean exit are cleaned up on startup. If `iptables` is not accessible, sandy **refuses to launch**. Each DROP rule is then re-checked with `iptables -C` after insertion, and if any is missing — a readable chain can still refuse an insert — sandy refuses too, naming the range, rather than reporting isolation it does not have. `SANDY_ALLOW_NO_ISOLATION=1` overrides both refusals with a warning instead.

## Verifying Isolation

From inside the container, you can verify:

```bash
# Should FAIL — LAN is blocked
curl -m 5 http://192.168.1.1

# Should SUCCEED — public internet works
curl -m 5 https://api.anthropic.com
```
