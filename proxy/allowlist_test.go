package main

import "testing"

func TestAllowedName(t *testing.T) {
	a := NewAllowlist([]string{
		"api.anthropic.com",
		"*.githubusercontent.com",
		"github.com:22", // host:port — must NOT grant a bare-name match
		"  PyPI.org  ",  // whitespace + mixed case
		"",              // blank ignored
	})

	cases := []struct {
		host string
		want bool
	}{
		{"api.anthropic.com", true},
		{"API.Anthropic.Com", true}, // case-insensitive
		{"api.anthropic.com.evil.com", false},
		{"anthropic.com", false},
		{"raw.githubusercontent.com", true}, // wildcard subdomain
		{"a.b.githubusercontent.com", true}, // wildcard, multi-label
		{"githubusercontent.com", false},    // wildcard does not match apex
		{"notgithubusercontent.com", false}, // suffix must be on a dot boundary
		{"pypi.org", true},                  // trimmed + lowercased
		{"github.com", false},               // only present as host:port
		{"evil.com", false},
		{"", false},
	}
	for _, c := range cases {
		if got := a.AllowedName(c.host); got != c.want {
			t.Errorf("AllowedName(%q) = %v, want %v", c.host, got, c.want)
		}
	}
}

func TestAllowedHostPort(t *testing.T) {
	a := NewAllowlist([]string{
		"api.anthropic.com",  // name -> CONNECT ok on 443/80 only
		"*.example.com",      // wildcard -> CONNECT ok on 443/80 only
		"github.com:22",      // explicit odd port
		"ollama.local:11434", // explicit odd port
	})

	cases := []struct {
		host string
		port int
		want bool
	}{
		{"github.com", 22, true},         // explicit host:port
		{"github.com", 443, false},       // github.com is only allowed on :22
		{"api.anthropic.com", 443, true}, // name grants standard ports
		{"api.anthropic.com", 80, true},
		{"api.anthropic.com", 22, false}, // odd port needs explicit entry
		{"sub.example.com", 443, true},   // wildcard grants standard ports
		{"sub.example.com", 8443, false}, // odd port not granted by wildcard
		{"ollama.local", 11434, true},
		{"ollama.local", 11435, false},
		{"evil.com", 443, false},
		{"github.com", 0, false},     // invalid port
		{"github.com", 70000, false}, // out of range
		{"", 443, false},
	}
	for _, c := range cases {
		if got := a.AllowedHostPort(c.host, c.port); got != c.want {
			t.Errorf("AllowedHostPort(%q, %d) = %v, want %v", c.host, c.port, got, c.want)
		}
	}
}

func TestIsHostPort(t *testing.T) {
	cases := []struct {
		s    string
		want bool
	}{
		{"github.com:22", true},
		{"api.anthropic.com", false}, // no port
		{"*.example.com", false},     // wildcard
		{"host:0", false},            // invalid port
		{"host:99999", false},        // out of range
		{":22", false},               // empty host
		{"host:", false},             // empty port
		{"host:abc", false},          // non-numeric port
	}
	for _, c := range cases {
		if got := isHostPort(c.s); got != c.want {
			t.Errorf("isHostPort(%q) = %v, want %v", c.s, got, c.want)
		}
	}
}

func TestNormalizeHost_RejectsBypassVectors(t *testing.T) {
	// All of these must be rejected (ok=false) — they are malformed hosts or
	// alternate IP encodings that getaddrinfo would dial but which can't be a
	// legitimate allowlisted hostname.
	reject := []string{
		"167772165",                     // inet_aton decimal for 10.0.0.5
		"0x7f.0.0.1",                    // hex octet
		"0177.0.0.1",                    // octal-ish: last label "1" numeric -> rejected
		"127.1",                         // short form
		"example.com\x00.evil.com",      // embedded null
		"example.com\r\nHost: evil.com", // CRLF smuggling
		"exa mple.com",                  // space
		"example.com.",                  // trailing dot
		".example.com",                  // leading dot
		"under_score.com",               // underscore (stricter than DNS, intentional)
		"",                              // empty
		"999",                           // all-numeric label
	}
	for _, h := range reject {
		if _, _, ok := normalizeHost(h); ok {
			t.Errorf("normalizeHost(%q) ok=true, want rejected", h)
		}
	}
}

func TestNormalizeHost_CanonicalizesIP(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"127.0.0.1", "127.0.0.1"},
		{"10.0.0.5", "10.0.0.5"},
		{"[::1]", "::1"}, // bracketed IPv6 -> canonical
		{"::1", "::1"},
		{"2001:0db8:0000:0000:0000:0000:0000:0001", "2001:db8::1"}, // canonicalized
	}
	for _, c := range cases {
		h, isIP, ok := normalizeHost(c.in)
		if !ok || !isIP || h != c.want {
			t.Errorf("normalizeHost(%q) = (%q, ip=%v, ok=%v), want (%q, ip=true, ok=true)", c.in, h, isIP, ok, c.want)
		}
	}
}

func TestAllowedName_RejectsRawIPAndEncodings(t *testing.T) {
	// A name allowlist must never authorize a raw IP via SNI/Host, even if the
	// IP happens to be reachable, and must reject encoded forms.
	a := NewAllowlist([]string{"api.anthropic.com", "*.example.com"})
	for _, h := range []string{"127.0.0.1", "10.0.0.5", "167772165", "0x7f.0.0.1", "[::1]"} {
		if a.AllowedName(h) {
			t.Errorf("AllowedName(%q) = true, want false (raw/encoded IP on name path)", h)
		}
	}
}

func TestAllowedHostPort_IPLiteralOnlyViaExplicitEntry(t *testing.T) {
	// An IP CONNECT target is allowed ONLY if that exact IP:port was allowlisted,
	// and only in canonical form — encodings of the same IP must not match.
	a := NewAllowlist([]string{"10.0.0.5:8443"})
	if !a.AllowedHostPort("10.0.0.5", 8443) {
		t.Error("AllowedHostPort(10.0.0.5,8443) = false, want true (explicit entry)")
	}
	if a.AllowedHostPort("167772165", 8443) {
		t.Error("AllowedHostPort(167772165,8443) = true, want false (encoded form must not match)")
	}
	if a.AllowedHostPort("10.0.0.5", 22) {
		t.Error("AllowedHostPort(10.0.0.5,22) = true, want false (wrong port)")
	}
	if a.AllowedHostPort("10.0.0.6", 8443) {
		t.Error("AllowedHostPort(10.0.0.6,8443) = true, want false (different IP)")
	}
}
