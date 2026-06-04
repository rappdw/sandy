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

The proxy never terminates TLS, logs payload, caches, or retries. It matches a
hostname against the allowlist and splices bytes.

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

Single dependency: `github.com/miekg/dns`. ~620 code lines.
