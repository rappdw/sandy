package main

import (
	"context"
	"net"
)

const (
	// modePermissive blocks only private/LAN/link-local/CGNAT/metadata
	// destinations and allows all internet. Closes F2 (macOS host/LAN reach)
	// with ~zero tool friction; the allowlist is a LAN-exception list.
	modePermissive = "permissive"
	// modeStrict denies everything except allowlisted hosts — closes F2 AND
	// exfil-to-internet, failing closed on any un-listed host.
	modeStrict = "strict"
)

// Policy is the egress decision engine shared by the DNS responder and the
// transparent/CONNECT listeners. It is built once at startup and read-only
// thereafter, so it needs no locking.
type Policy struct {
	mode    string
	allow   *Allowlist // strict: the allowlist; permissive: the LAN-exception list
	proxyIP net.IP
	// lookupIP resolves a hostname to IPs on the egress network. A field (not a
	// hard call to net.DefaultResolver) so tests can inject a fake resolver to
	// exercise the permissive private-IP / rebinding logic deterministically.
	lookupIP func(host string) ([]net.IP, error)
}

func newPolicy(cfg *Config) *Policy {
	return &Policy{
		mode:    cfg.Mode,
		allow:   NewAllowlist(cfg.Allow),
		proxyIP: net.ParseIP(cfg.ProxyIP).To4(),
		lookupIP: func(host string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(context.Background(), "ip", host)
		},
	}
}

// PermitDNS decides whether the DNS responder should answer a name with the
// proxy IP (so the agent's traffic funnels through the proxy) or NXDOMAIN it.
//   - strict:     only allowlisted names.
//   - permissive: any well-formed hostname (not a raw IP / encoded-IP). The
//     LAN block happens later, at forward time, once we know the
//     real address — so a name that resolves only to a private IP
//     still funnels here and is then refused on egress.
func (p *Policy) PermitDNS(name string) bool {
	if p.mode == modeStrict {
		return p.allow.AllowedName(name)
	}
	_, isIP, ok := normalizeHost(name)
	return ok && !isIP
}

// Egress makes the full allow-or-deny decision for a forward connection and, if
// allowed, dials the upstream. It returns (conn, "") on allow and (nil, reason)
// on deny — the caller logs `reason` and responds (close, or 403 for CONNECT).
// `port` is the listener's port for the transparent paths (443/80) or the
// CONNECT-requested port.
func (p *Policy) Egress(host string, port int) (net.Conn, string) {
	h, isIP, ok := normalizeHost(host)
	if !ok {
		return nil, "malformed host"
	}

	if p.mode == modeStrict {
		if !p.allow.AllowedHostPort(h, port) {
			return nil, "not in allowlist"
		}
		return dialOrDeny(h, port)
	}

	// Permissive: an explicit allowlist entry is a LAN-exception — allow it
	// even if it points at a private address (e.g. a local registry the user
	// opted into, or host.docker.internal:port for a local LLM).
	if p.allow.AllowedHostPort(h, port) {
		return dialOrDeny(h, port)
	}

	// Otherwise: resolve and refuse private/LAN/metadata destinations. Doing
	// the check on the *resolved* address (not the name) also defeats DNS
	// rebinding — a domain that resolves public-then-private can't slip a
	// private target past us, because we re-resolve here and dial only a
	// public IP.
	var ips []net.IP
	if isIP {
		ips = []net.IP{net.ParseIP(h)}
	} else {
		r, err := p.lookupIP(h)
		if err != nil {
			return nil, "resolve failed: " + err.Error()
		}
		ips = r
	}
	chosen, ok := selectEgressIP(ips)
	if !ok {
		return nil, "private/LAN address blocked (add to SANDY_ALLOW_HOSTS to allow)"
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort(chosen.String(), itoa(port)), dialTimeout)
	if err != nil {
		return nil, "dial failed: " + err.Error()
	}
	return c, ""
}

// selectEgressIP picks the first public IP from a resolution result, or
// (nil,false) if every result is private/LAN. Choosing among the resolved set
// (rather than trusting the name) is the DNS-rebinding defense: a domain that
// resolves to both a public and a private address yields the public one, and a
// domain that resolves only to private addresses is refused.
func selectEgressIP(ips []net.IP) (net.IP, bool) {
	for _, ip := range ips {
		if !isPrivateIP(ip) {
			return ip, true
		}
	}
	return nil, false
}

func dialOrDeny(host string, port int) (net.Conn, string) {
	c, err := dialUpstream(host, port)
	if err != nil {
		return nil, "dial failed: " + err.Error()
	}
	return c, ""
}

// isPrivateIP reports whether ip is one we refuse in permissive mode: RFC1918,
// IPv6 ULA, loopback, link-local (incl. 169.254.169.254 cloud metadata),
// unspecified, or CGNAT (100.64.0.0/10). A nil/unparseable IP is treated as
// unsafe.
func isPrivateIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsPrivate() {
		return true
	}
	// CGNAT 100.64.0.0/10 (RFC 6598) — not covered by net.IP.IsPrivate.
	if v4 := ip.To4(); v4 != nil && v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127 {
		return true
	}
	return false
}
