// Command sandy-proxy is the egress proxy sidecar for sandy's macOS network
// isolation (milestone M2.7). It runs in a dual-homed container: one leg on an
// `--internal` "sidecar" network shared with the agent container (no route off
// that bridge — this is what closes finding F2), and one leg on a normal
// "egress" network that can reach the internet.
//
// The agent container points its DNS and traffic at this proxy. The proxy is
// the ONLY way off the sidecar bridge, so it is also the single allowlist
// chokepoint. It runs four listeners:
//
//   - DNS (UDP 53):    allowlisted name -> the proxy's own sidecar IP, so the
//     agent's connections land here; AAAA -> empty; HTTPS/SVCB
//     -> refused (defeats TLS ECH, keeping SNI readable);
//     everything else -> NXDOMAIN. Also closes F9 (DNS exfil).
//   - Transparent 443: read the SNI from the (unencrypted) TLS ClientHello,
//     allowlist-check, splice bytes to the real host. TLS is
//     never terminated — no MITM, no cert surgery.
//   - Transparent 80:  same idea, demuxing on the HTTP Host header.
//   - CONNECT 3128:    classic forward-proxy CONNECT, used by the agent's ssh
//     ProxyCommand so git-over-SSH works under `--internal`.
//
// Optionally a fifth listener forwards a fixed local-LLM port to
// host.docker.internal (so SANDY_LOCAL_LLM_HOST keeps working with the proxy).
//
// The proxy never terminates TLS, never logs payload, never caches. It matches
// a hostname against the allowlist and splices bytes. That's it.
package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// Config is the on-disk proxy configuration, written by the sandy launcher to
// /etc/sandy-proxy.json and mounted into the proxy container.
type Config struct {
	// Mode is the egress policy (maps to SANDY_EGRESS_PROXY=1/2):
	//   "permissive" — block only private/LAN/link-local/CGNAT/metadata
	//                  destinations; allow all internet. Closes F2 (macOS host/
	//                  LAN reach) with ~zero tool friction. `allow` is the
	//                  LAN-exception list here.
	//   "strict"     — deny everything except `allow`-listed hosts. Closes F2
	//                  AND exfil-to-internet, at the cost of failing closed on
	//                  any un-listed host.
	// Defaults to "strict" if absent — fail closed, never silently permissive.
	Mode string `json:"mode"`

	// ProxyIP is the proxy's own address on the sidecar (internal) network.
	// The DNS responder answers permitted A queries with this address so the
	// agent's traffic is redirected to the proxy for SNI/Host demux.
	ProxyIP string `json:"proxy_ip"`

	// Allow is the egress allowlist. Each entry is one of:
	//   - an exact hostname        ("api.anthropic.com")
	//   - a wildcard suffix        ("*.githubusercontent.com")
	//   - a host:port literal      ("github.com:22")  — required for CONNECT
	//     targets such as git-over-SSH, where the port matters.
	Allow []string `json:"allow"`

	// LocalLLM, when non-empty, is the "host:port" the user set via
	// SANDY_LOCAL_LLM_HOST. The proxy listens on that port and forwards to
	// host.docker.internal:port on its egress leg. Empty disables the feature.
	LocalLLM string `json:"local_llm,omitempty"`

	// LocalLLMTarget is the host the local-LLM forward dials on the egress
	// network. Defaults to "host.docker.internal" when empty; overridable for
	// tests.
	LocalLLMTarget string `json:"local_llm_target,omitempty"`
}

// LoadConfig reads and validates the proxy config from path.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", path, err)
	}
	if c.ProxyIP == "" {
		return nil, fmt.Errorf("config %s: proxy_ip is required", path)
	}
	switch c.Mode {
	case "", modeStrict:
		c.Mode = modeStrict // fail closed if unspecified
	case modePermissive:
		// ok
	default:
		return nil, fmt.Errorf("config %s: invalid mode %q (want %q or %q)", path, c.Mode, modePermissive, modeStrict)
	}
	if c.LocalLLMTarget == "" {
		c.LocalLLMTarget = "host.docker.internal"
	}
	return &c, nil
}
