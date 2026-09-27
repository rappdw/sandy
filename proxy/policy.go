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
	// dial opens every upstream TCP connection Egress makes: an already-
	// screened resolved IP (both modes) or an allowlisted host:port as-is
	// (dialOrDeny). A field (mirrors lookupIP) so tests can substitute a local
	// listener, or a recorder, instead of exercising a live socket.
	dial func(network, address string) (net.Conn, error)
}

func newPolicy(cfg *Config) *Policy {
	return &Policy{
		mode:    cfg.Mode,
		allow:   NewAllowlist(cfg.Allow),
		proxyIP: net.ParseIP(cfg.ProxyIP).To4(),
		lookupIP: func(host string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(context.Background(), "ip", host)
		},
		dial: func(network, address string) (net.Conn, error) {
			return net.DialTimeout(network, address, dialTimeout)
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
//
// A well-known DoH resolver name (#154) is deliberately ANSWERED here in
// permissive mode and refused later, in Egress. NXDOMAIN-ing it would give the
// agent a slightly cleaner failure, but the DNS responder logs nothing, so the
// attempt would never reach proxy.log — and the egress log's completeness is
// the whole reason the block exists. Deciding in one place also covers a
// client that reaches the proxy without asking this responder (a hardcoded
// /etc/hosts line, curl --resolve, an explicit CONNECT).
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
		// A raw-IP target or an explicit host:port entry is a deliberate
		// LAN-exception — dial as-is. But a bare-name/wildcard match must still
		// have its RESOLVED address screened, so a poisoned allowlisted domain
		// (or DNS rebinding) can't reach 169.254.169.254 / an RFC1918 host.
		if isIP || p.allow.AllowedExactHostPort(h, port) {
			return p.dialOrDeny(h, port)
		}
		r, err := p.lookupIP(h)
		if err != nil {
			return nil, "resolve failed: " + err.Error()
		}
		chosen, ok := selectEgressIP(r)
		if !ok {
			return nil, "allowlisted name resolved to private/LAN address; refused"
		}
		c, err := p.dial("tcp", net.JoinHostPort(chosen.String(), itoa(port)))
		if err != nil {
			return nil, "dial failed: " + err.Error()
		}
		return c, ""
	}

	// Permissive: an explicit allowlist entry is a LAN-exception — allow it
	// even if it points at a private address (e.g. a local registry the user
	// opted into, or host.docker.internal:port for a local LLM).
	if p.allow.AllowedHostPort(h, port) {
		return p.dialOrDeny(h, port)
	}

	// A well-known DNS-over-HTTPS resolver is refused (#154): it would move
	// name resolution off the path sandy observes (see doh.go). Checked AFTER
	// the allowlist on purpose, so SANDY_ALLOW_HOSTS re-allows a listed
	// provider, and on every port, so CONNECT to the same name (including DoT
	// on :853) is refused too. Strict mode needs no such check: a resolver
	// that is not allowlisted is already denied above.
	if !isIP && isDoHProvider(h) {
		return nil, "known DNS-over-HTTPS resolver blocked in permissive mode (add to SANDY_ALLOW_HOSTS to allow)"
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
	c, err := p.dial("tcp", net.JoinHostPort(chosen.String(), itoa(port)))
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

// dialOrDeny dials an allowlisted host:port as-is. It goes through p.dial
// (whose default is exactly dialUpstream's net.DialTimeout) rather than
// dialUpstream directly, so a test can prove WHICH path an allowlisted name
// took -- e.g. that SANDY_ALLOW_HOSTS re-allows a listed DoH provider (#154) --
// without a live socket.
func (p *Policy) dialOrDeny(host string, port int) (net.Conn, string) {
	c, err := p.dial("tcp", net.JoinHostPort(host, itoa(port)))
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
