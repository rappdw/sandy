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
