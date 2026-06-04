package main

import (
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
//	                                       (used for CONNECT targets like SSH)
//
// A plain name entry (exact or wildcard) authorizes the name on ANY port for
// the transparent/HTTP paths, where the port is implied by the listener (443 or
// 80). A host:port entry additionally authorizes that exact name+port for
// CONNECT, where the client names an arbitrary port.
type Allowlist struct {
	exact     map[string]struct{} // "api.anthropic.com"
	wildcards []string            // suffixes incl. leading dot: ".example.com"
	hostPort  map[string]struct{} // "github.com:22"
}

// NewAllowlist compiles raw config entries into an Allowlist. Blank entries and
// surrounding whitespace are ignored; hostnames are lower-cased so matching is
// case-insensitive (DNS names are case-insensitive).
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
			a.hostPort[e] = struct{}{}
		default:
			a.exact[e] = struct{}{}
		}
	}
	return a
}

// AllowedName reports whether the bare hostname is permitted on the implied
// HTTP(S) port (used by the DNS responder and the transparent SNI/Host paths).
// It matches exact and wildcard entries. host:port entries do NOT grant a
// bare-name match — they're CONNECT-specific.
func (a *Allowlist) AllowedName(host string) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	if h == "" {
		return false
	}
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
// It is satisfied by an explicit host:port entry, OR by a name entry (exact or
// wildcard) — a name allowlisted for HTTPS is also reachable via CONNECT on the
// standard ports. The explicit host:port form is what authorizes non-standard
// ports such as 22 (git-over-SSH).
func (a *Allowlist) AllowedHostPort(host string, port int) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	if h == "" || port <= 0 || port > 65535 {
		return false
	}
	if _, ok := a.hostPort[h+":"+strconv.Itoa(port)]; ok {
		return true
	}
	// A name allowlist grants CONNECT on the conventional web ports only; odd
	// ports must be named explicitly.
	if port == 443 || port == 80 {
		return a.AllowedName(h)
	}
	return false
}

// isHostPort reports whether s looks like "host:port" with a numeric port. A
// bare "host" (no colon) or a wildcard is not a host:port literal.
func isHostPort(s string) bool {
	i := strings.LastIndexByte(s, ':')
	if i <= 0 || i == len(s)-1 {
		return false
	}
	port, err := strconv.Atoi(s[i+1:])
	if err != nil || port <= 0 || port > 65535 {
		return false
	}
	// Reject things that are clearly not a hostname:port (e.g. a bare wildcard).
	host := s[:i]
	return host != "" && !strings.HasPrefix(host, "*")
}
