package main

import (
	"net"
	"strconv"
	"strings"
)

// Allowlist decides whether egress to a given host (and, for CONNECT, port) is
// permitted. It is built once from Config.Allow and is read-only thereafter, so
// it needs no locking across the listener goroutines.
//
// Entry forms:
//
//	exact      "api.anthropic.com"        matches that name only
//	wildcard   "*.githubusercontent.com"  matches any subdomain (any depth);
//	                                       does NOT match the bare apex
//	host:port  "github.com:22"            matches that name only on that port
//	                                       (used for CONNECT targets like SSH);
//	                                       an IP literal here is canonicalized
//
// A plain name entry (exact or wildcard) authorizes the name on ANY port for
// the transparent/HTTP paths, where the port is implied by the listener (443 or
// 80). A host:port entry additionally authorizes that exact name+port for
// CONNECT, where the client names an arbitrary port.
//
// Hardening (M2.7, after cross-referencing anthropic-experimental/sandbox-runtime,
// which paid the bug tax): every host is run through normalizeHost before
// matching. That rejects control/whitespace/CRLF/null/overlong garbage,
// canonicalizes IP literals, and rejects alternate IP encodings
// (inet_aton-style "167772165", hex "0x7f.0.0.1", short "127.1"). The name path
// never authorizes a raw IP at all — IPs are reachable only via an explicit
// host:port entry — so an agent can't reach an arbitrary address by stuffing it
// into SNI/Host. Sandy's allowlist-only + `--internal` model already resists the
// classic denylist-bypass, but this closes the residual edges by construction.
type Allowlist struct {
	exact     map[string]struct{} // "api.anthropic.com"
	wildcards []string            // suffixes incl. leading dot: ".example.com"
	hostPort  map[string]struct{} // "github.com:22" (IP hosts canonicalized)
}

// NewAllowlist compiles raw config entries into an Allowlist. Blank entries and
// surrounding whitespace are ignored; names are lower-cased (DNS is
// case-insensitive); IP literals in host:port entries are canonicalized so a
// query in any equivalent encoding still matches the same stored form.
func NewAllowlist(entries []string) *Allowlist {
	a := &Allowlist{
		exact:    make(map[string]struct{}),
		hostPort: make(map[string]struct{}),
	}
	for _, raw := range entries {
		e := strings.ToLower(strings.TrimSpace(raw))
		if e == "" {
			continue
		}
		switch {
		case strings.HasPrefix(e, "*."):
			// "*.example.com" -> suffix ".example.com"
			a.wildcards = append(a.wildcards, e[1:])
		case isHostPort(e):
			host, port := splitHostPortRaw(e)
			if h, _, ok := normalizeHost(host); ok {
				a.hostPort[h+":"+strconv.Itoa(port)] = struct{}{}
			}
		default:
			a.exact[e] = struct{}{}
		}
	}
	return a
}

// AllowedName reports whether the bare hostname is permitted on the implied
// HTTP(S) port (used by the DNS responder and the transparent SNI/Host paths).
// It matches exact and wildcard entries. A raw IP literal is NEVER allowed here
// (those go through explicit host:port CONNECT entries), and malformed or
// encoded-IP hosts are rejected outright.
func (a *Allowlist) AllowedName(host string) bool {
	h, isIP, ok := normalizeHost(host)
	if !ok || isIP {
		return false
	}
	return a.allowedNameNorm(h)
}

// allowedNameNorm matches an already-normalized, non-IP hostname against the
// exact and wildcard sets.
func (a *Allowlist) allowedNameNorm(h string) bool {
	if _, ok := a.exact[h]; ok {
		return true
	}
	for _, suf := range a.wildcards {
		// ".example.com" matches "a.example.com", "a.b.example.com" — any
		// subdomain — but not the apex "example.com".
		if strings.HasSuffix(h, suf) && len(h) > len(suf) {
			return true
		}
	}
	return false
}

// AllowedHostPort reports whether host:port is permitted for a CONNECT tunnel.
// It is satisfied by an explicit host:port entry (IPs canonicalized on both
// sides), OR — for a name on the conventional web ports — by a name entry. Odd
// ports (e.g. 22 for git-over-SSH) must be named explicitly. Malformed and
// encoded-IP hosts are rejected.
func (a *Allowlist) AllowedHostPort(host string, port int) bool {
	if port <= 0 || port > 65535 {
		return false
	}
	h, isIP, ok := normalizeHost(host)
	if !ok {
		return false
	}
	if _, ok := a.hostPort[h+":"+strconv.Itoa(port)]; ok {
		return true
	}
	if isIP {
		// A raw IP is reachable only via an explicit host:port entry, checked
		// above. Name-allowlist entries never grant raw-IP CONNECT.
		return false
	}
	// A name allowlist grants CONNECT on the conventional web ports only.
	if port == 443 || port == 80 {
		return a.allowedNameNorm(h)
	}
	return false
}

// AllowedExactHostPort reports whether host:port matched an explicit host:port
// allowlist entry (a deliberate LAN-exception), as opposed to a bare-name/
// wildcard entry. Used by strict-mode egress to decide whether to re-check the
// resolved IP against the private/metadata filter.
func (a *Allowlist) AllowedExactHostPort(host string, port int) bool {
	h, _, ok := normalizeHost(host)
	if !ok {
		return false
	}
	_, ok = a.hostPort[h+":"+strconv.Itoa(port)]
	return ok
}

// normalizeHost validates and canonicalizes a host string before matching.
// Returns (canonicalHost, isIP, ok). ok=false means the host is rejected
// (malformed, encoded-IP attempt, or not a plausible hostname). For a valid IP
// literal it returns the canonical net.IP string form and isIP=true.
func normalizeHost(raw string) (host string, isIP bool, ok bool) {
	h := strings.ToLower(strings.TrimSpace(raw))
	if h == "" || len(h) > 253 {
		return "", false, false
	}
	// Reject any control char, space, or DEL — these have no place in a host
	// and are the classic CRLF / null-byte / whitespace smuggling vectors.
	for i := 0; i < len(h); i++ {
		if c := h[i]; c <= 0x20 || c == 0x7f {
			return "", false, false
		}
	}
	// Bracketed IPv6 literal: [::1] -> ::1
	if strings.HasPrefix(h, "[") && strings.HasSuffix(h, "]") {
		h = h[1 : len(h)-1]
	}
	// Canonical IP literal (standard dotted-quad IPv4 or RFC IPv6). net.ParseIP
	// deliberately does NOT accept inet_aton forms, which is what we want.
	if ip := net.ParseIP(h); ip != nil {
		return ip.String(), true, true
	}
	// Not a canonical IP. Reject encoded-IP attempts: a real hostname's last
	// label is alphabetic — never all-numeric and never 0x-prefixed. This
	// catches "167772165" (== 10.0.0.5), "0x7f.0.0.1", "127.1", etc., which
	// getaddrinfo() WOULD dial but which can't be legitimate hostnames.
	last := h
	if i := strings.LastIndexByte(h, '.'); i >= 0 {
		last = h[i+1:]
	}
	if last == "" || strings.HasPrefix(last, "0x") || isAllDigits(last) {
		return "", false, false
	}
	// Plausible hostname: labels of [a-z0-9-] separated by dots, no leading or
	// trailing dot. (Underscores etc. are rejected — stricter than DNS, fine
	// for an egress allowlist.)
	if strings.HasPrefix(h, ".") || strings.HasSuffix(h, ".") {
		return "", false, false
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.') {
			return "", false, false
		}
	}
	return h, false, true
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// isHostPort reports whether s looks like "host:port" with a numeric port. A
// bare "host" (no colon) or a wildcard is not a host:port literal. IPv6 host:port
// must be bracketed ("[::1]:443") to be recognized here.
func isHostPort(s string) bool {
	host, port := splitHostPortRaw(s)
	return host != "" && port > 0 && port <= 65535 && !strings.HasPrefix(host, "*")
}

// splitHostPortRaw splits "host:port" (or "[ipv6]:port") into host and numeric
// port. Returns ("", 0) if it doesn't parse as host:port.
func splitHostPortRaw(s string) (string, int) {
	// Bracketed IPv6 form.
	if strings.HasPrefix(s, "[") {
		host, portStr, err := net.SplitHostPort(s)
		if err != nil {
			return "", 0
		}
		p, err := strconv.Atoi(portStr)
		if err != nil {
			return "", 0
		}
		return host, p
	}
	i := strings.LastIndexByte(s, ':')
	if i <= 0 || i == len(s)-1 {
		return "", 0
	}
	// More than one colon and not bracketed -> ambiguous (bare IPv6) -> not a
	// host:port literal for our purposes.
	if strings.IndexByte(s, ':') != i {
		return "", 0
	}
	p, err := strconv.Atoi(s[i+1:])
	if err != nil || p <= 0 || p > 65535 {
		return "", 0
	}
	return s[:i], p
}
