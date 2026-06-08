# sandy-proxy

The egress proxy sidecar for sandy's macOS network isolation (roadmap milestone
M2.7). This package is **PR 2.7.1** — the Go binary and its unit tests only. The
Docker image (PR 2.7.2) and launcher wiring (PR 2.7.3) come next.

## Why it exists

On macOS, Docker Desktop's VM NATs containers onto the host LAN, and the host
can't apply the Linux iptables rules sandy uses elsewhere — so a sandboxed agent
can reach `192.168.x.x`, `host.docker.internal`, the home router, etc. (finding
F2). The fix is a two-network topology:

- An **`--internal`** "sidecar" bridge shared by the agent container and this
  proxy. `--internal` removes the route off the bridge — that's what actually
  closes F2. (Proven on real Docker Desktop by
  `test/spike/macos-internal-network-spike.sh`.)
- A normal "egress" bridge that only the proxy joins, giving it internet access.

The agent points DNS + traffic at the proxy, which becomes the single egress
chokepoint and enforces an allowlist.

## Listeners

| Port | Role |
|------|------|
| UDP 53 | DNS. Allowlisted name → proxy IP (so traffic funnels here); AAAA → empty NOERROR (force v4); `HTTPS`/`SVCB` → REFUSED (defeats TLS ECH, keeps SNI readable); else NXDOMAIN. Closes F9 (DNS exfil). |
| 443 | Transparent: read SNI from the unencrypted ClientHello, allowlist-check, splice to the real host. TLS is never terminated — no MITM, no certs. |
| 80 | Transparent: same, demuxing on the HTTP `Host` header. |
| 3128 | HTTP CONNECT. Used by the agent's ssh `ProxyCommand` so git-over-SSH works under `--internal`; also a manual escape hatch. Allowlist is host:port (authorizes odd ports like `:22`). |
| (local-LLM port) | Optional fixed-port forward to `host.docker.internal:port` for `SANDY_LOCAL_LLM_HOST`. |

## Modes

The proxy runs in one of two policies (set by the launcher from
`SANDY_EGRESS_PROXY`):

- **permissive** (`SANDY_EGRESS_PROXY=1`) — block only private/LAN/link-local/
  CGNAT/metadata destinations; allow all internet. DNS answers any well-formed
  name with the proxy IP; the forward path resolves the real address and refuses
  it only if it's private (resolving-then-checking also defeats DNS rebinding).
  `allow` is a LAN-**exception** list (e.g. a local registry, or
  `host.docker.internal:port` for a local LLM). Closes F2 (macOS host/LAN reach)
  with ~zero tool friction. Does NOT stop exfil to an arbitrary internet host.
- **strict** (`SANDY_EGRESS_PROXY=2`) — deny everything except `allow`-listed
  hosts. Closes F2 AND exfil-to-internet, at the cost of failing closed on any
  un-listed host. `allow` is the full allowlist.

Mode defaults to strict if the config omits it (fail closed).

The proxy never terminates TLS, logs payload, caches, or retries. It applies the
mode policy to a hostname/destination and splices bytes.

## Config

`/etc/sandy-proxy.json` (written and mounted by the sandy launcher):

```json
{
  "proxy_ip": "192.168.229.2",
  "allow": ["api.anthropic.com", "*.githubusercontent.com", "github.com:22"],
  "local_llm": "127.0.0.1:11434"
}
```

- `proxy_ip` — the proxy's own address on the sidecar network (what allowlisted A
  queries resolve to).
- `allow` — exact names, `*.wildcard` suffixes (match any subdomain, not the
  apex), and `host:port` literals (required for CONNECT odd ports).
- `local_llm` — optional `host:port`; the proxy forwards that port to
  `host.docker.internal` on its egress leg.

## Build & test

```sh
cd proxy
go test ./...                      # unit + loopback integration tests
go test -race ./...
CGO_ENABLED=0 go build -ldflags='-s -w' .   # static binary (as the image builds it)
```

Single dependency: `github.com/miekg/dns`. ~700 code lines.

## Allowlist hardening

Every host is run through `normalizeHost` before matching (see `allowlist.go`),
informed by bugs `anthropic-experimental/sandbox-runtime` already paid for:

- Rejects control chars, whitespace, CRLF, null bytes, and overlong hosts (the
  classic smuggling vectors).
- Canonicalizes IP literals (`[::1]` → `::1`, etc.).
- Rejects alternate IP encodings — inet_aton decimal (`167772165`), hex
  (`0x7f.0.0.1`), and short (`127.1`) forms — which `getaddrinfo()` would dial
  but which cannot be legitimate hostnames.
- The name path (DNS / transparent SNI/Host) **never** authorizes a raw IP; IPs
  are reachable only via an explicit `host:port` allowlist entry, canonicalized
  on both sides. So an agent can't reach an arbitrary address by stuffing it
  into SNI.

Denied connections are logged (host + port + reason). CONNECT denials also
return a real `403` so the agent can tell a policy block from a network failure;
the transparent path can only close the connection (raw byte stream). The
launcher (PR 2.7.3) aggregates these logs into an exit-time "to allow, add
`SANDY_ALLOW_HOSTS=…`" hint.
