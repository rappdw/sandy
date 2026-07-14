package main

import (
	"net"
	"testing"
)

// testPolicy builds a Policy for tests with a deterministic resolver: any name
// not overridden via withLookup resolves to a single public IP (8.8.8.8), so
// the permissive path's "allow public" branch is exercisable without real DNS.
func testPolicy(mode string, allow ...string) *Policy {
	p := newPolicy(&Config{Mode: mode, ProxyIP: "192.168.229.2", Allow: allow})
	p.lookupIP = func(host string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("8.8.8.8")}, nil
	}
	return p
}

func TestIsPrivateIP(t *testing.T) {
	private := []string{
		"10.0.0.5", "172.16.1.1", "192.168.1.1", // RFC1918
		"127.0.0.1", "::1", // loopback
		"169.254.0.1", "169.254.169.254", // link-local + cloud metadata
		"100.64.0.1", "100.127.255.255", // CGNAT
		"fe80::1",       // IPv6 link-local
		"fc00::1",       // IPv6 ULA
		"0.0.0.0", "::", // unspecified
	}
	public := []string{
		"8.8.8.8", "1.1.1.1", "140.82.112.3", // github
		"2606:4700:4700::1111", // cloudflare v6
		"100.63.255.255",       // just below CGNAT
		"100.128.0.0",          // just above CGNAT
	}
	for _, s := range private {
		if !isPrivateIP(net.ParseIP(s)) {
			t.Errorf("isPrivateIP(%s) = false, want true", s)
		}
	}
	for _, s := range public {
		if isPrivateIP(net.ParseIP(s)) {
			t.Errorf("isPrivateIP(%s) = true, want false", s)
		}
	}
	if !isPrivateIP(nil) {
		t.Error("isPrivateIP(nil) = false, want true (unparseable treated as unsafe)")
	}
}

func TestSelectEgressIP(t *testing.T) {
	ip := func(s string) net.IP { return net.ParseIP(s) }
	cases := []struct {
		name    string
		ips     []net.IP
		wantOK  bool
		wantStr string
	}{
		{"all private", []net.IP{ip("10.0.0.1"), ip("192.168.0.1")}, false, ""},
		{"all public", []net.IP{ip("8.8.8.8")}, true, "8.8.8.8"},
		{"rebinding mix picks public", []net.IP{ip("10.0.0.1"), ip("1.1.1.1")}, true, "1.1.1.1"},
		{"empty", nil, false, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := selectEgressIP(c.ips)
			if ok != c.wantOK {
				t.Fatalf("ok = %v, want %v", ok, c.wantOK)
			}
			if ok && got.String() != c.wantStr {
				t.Errorf("ip = %s, want %s", got, c.wantStr)
			}
		})
	}
}

func TestPermitDNS(t *testing.T) {
	strict := testPolicy(modeStrict, "api.anthropic.com", "*.example.com")
	if !strict.PermitDNS("api.anthropic.com") || !strict.PermitDNS("a.example.com") {
		t.Error("strict PermitDNS rejected an allowlisted name")
	}
	if strict.PermitDNS("evil.com") {
		t.Error("strict PermitDNS allowed a non-allowlisted name")
	}

	perm := testPolicy(modePermissive)
	if !perm.PermitDNS("evil.com") || !perm.PermitDNS("anything.example.org") {
		t.Error("permissive PermitDNS should answer any well-formed name")
	}
	if perm.PermitDNS("10.0.0.5") || perm.PermitDNS("167772165") {
		t.Error("permissive PermitDNS should reject raw/encoded IP names")
	}
}

func TestEgress_Strict(t *testing.T) {
	p := testPolicy(modeStrict, "api.anthropic.com")
	if _, deny := p.Egress("evil.com", 443); deny == "" {
		t.Error("strict Egress allowed a non-allowlisted host")
	}
	if _, deny := p.Egress("10.0.0.5", 443); deny == "" {
		t.Error("strict Egress allowed a raw IP")
	}
	if _, deny := p.Egress("ex ample.com", 443); deny != "malformed host" {
		t.Errorf("strict Egress malformed host deny = %q, want 'malformed host'", deny)
	}
}

func TestEgress_PermissiveBlocksPrivate(t *testing.T) {
	p := testPolicy(modePermissive) // no exceptions
	// A name that resolves only to a private address must be blocked.
	p.lookupIP = func(string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("192.168.1.50")}, nil
	}
	if _, deny := p.Egress("intranet.corp", 443); deny == "" {
		t.Error("permissive Egress allowed a name resolving to a private IP")
	}
	// A raw private IP literal (via CONNECT) must be blocked too.
	if _, deny := p.Egress("169.254.169.254", 80); deny == "" {
		t.Error("permissive Egress allowed the cloud-metadata address")
	}
}

func TestEgress_PermissiveExceptionAllowsPrivate(t *testing.T) {
	// A loopback echo server stands in for an opted-in LAN target. In permissive
	// mode an explicit host:port allowlist entry is a LAN-exception: allowed
	// even though the IP is private.
	upHost, upPort := echoServer(t, "EXC\n")
	p := testPolicy(modePermissive, upHost+":"+itoa(upPort))
	conn, deny := p.Egress(upHost, upPort)
	if deny != "" {
		t.Fatalf("permissive exception denied: %q", deny)
	}
	conn.Close()
}

// TestEgress_StrictResolvedIPRecheck covers #15.2: in strict mode, a bare-name/
// wildcard allowlist match must have its RESOLVED address re-screened against
// the private/metadata filter (so a poisoned allowlisted domain, or DNS
// rebinding, can't reach 169.254.169.254 / an RFC1918 host), while a raw-IP
// target or an explicit host:port entry is a deliberate LAN-exception and
// bypasses the re-check.
func TestEgress_StrictResolvedIPRecheck(t *testing.T) {
	t.Run("allowlisted name resolving to cloud metadata is refused", func(t *testing.T) {
		p := testPolicy(modeStrict, "internal.example.com")
		p.lookupIP = func(string) ([]net.IP, error) {
			return []net.IP{net.ParseIP("169.254.169.254")}, nil
		}
		if _, deny := p.Egress("internal.example.com", 443); deny == "" {
			t.Error("strict Egress allowed an allowlisted name resolving to the cloud-metadata address")
		}
	})

	t.Run("allowlisted name resolving to RFC1918 is refused", func(t *testing.T) {
		p := testPolicy(modeStrict, "internal.example.com")
		p.lookupIP = func(string) ([]net.IP, error) {
			return []net.IP{net.ParseIP("10.0.0.5")}, nil
		}
		if _, deny := p.Egress("internal.example.com", 443); deny == "" {
			t.Error("strict Egress allowed an allowlisted name resolving to a private RFC1918 address")
		}
	})

	t.Run("allowlisted name resolving to a public IP is allowed", func(t *testing.T) {
		p := testPolicy(modeStrict, "internal.example.com")
		p.lookupIP = func(string) ([]net.IP, error) {
			return []net.IP{net.ParseIP("8.8.8.8")}, nil
		}
		var dialedAddr string
		p.dial = func(network, address string) (net.Conn, error) {
			dialedAddr = address
			return nil, nil
		}
		_, deny := p.Egress("internal.example.com", 443)
		if deny != "" {
			t.Fatalf("strict Egress denied an allowlisted name resolving to a public IP: %q", deny)
		}
		if dialedAddr != "8.8.8.8:443" {
			t.Errorf("dialed %q, want 8.8.8.8:443", dialedAddr)
		}
	})

	t.Run("explicit host:port LAN-exception bypasses the re-check", func(t *testing.T) {
		_, upPort := echoServer(t, "EXC\n")
		p := testPolicy(modeStrict, "localhost:"+itoa(upPort))
		// If AllowedExactHostPort's bypass were missing, this lookupIP stub
		// would cause a wrongful "private/LAN" denial instead of reaching the
		// real echo server below — a red flag that the bypass regressed.
		p.lookupIP = func(string) ([]net.IP, error) {
			return []net.IP{net.ParseIP("169.254.169.254")}, nil
		}
		conn, deny := p.Egress("localhost", upPort)
		if deny != "" {
			t.Fatalf("strict Egress denied an explicit host:port LAN-exception: %q", deny)
		}
		conn.Close()
	})
}
