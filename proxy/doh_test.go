package main

import (
	"bufio"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// dohDenyReason is the substring every DoH denial carries, so a test can tell
// the #154 block apart from any other deny (malformed host, private IP, ...).
const dohDenyReason = "DNS-over-HTTPS"

// recordDial replaces p.dial with a recorder that never opens a socket, so a
// test can assert whether Egress would have dialed and to what address. If the
// DoH block regressed, the permissive path would otherwise make a REAL dial to
// the stub resolver's 8.8.8.8 — a test that hangs on the network rather than
// failing on the assertion.
func recordDial(p *Policy) *[]string {
	var dialed []string
	p.dial = func(network, address string) (net.Conn, error) {
		dialed = append(dialed, address)
		return nil, errors.New("test: dial recorded, not performed")
	}
	return &dialed
}

func TestIsDoHProvider(t *testing.T) {
	yes := []string{
		"dns.google", "dns.google.com", "cloudflare-dns.com",
		"mozilla.cloudflare-dns.com", "1dot1dot1dot1.cloudflare-dns.com", // subdomain match
		"one.one.one.one", "dns.quad9.net", "dns11.quad9.net",
		"doh.opendns.com", "dns.nextdns.io", "doh.cleanbrowsing.org",
		"dns.adguard.com", "dns.adguard-dns.com", "doh.dns.sb",
		"adblock.dns.mullvad.net", "zero.dns0.eu",
	}
	no := []string{
		// the dot boundary: a suffix without it is a different domain
		"evilcloudflare-dns.com", "notdns.google",
		// parents that also host ordinary sites are NOT listed
		"google.com", "www.google.com", "cloudflare.com", "quad9.net",
		"mullvad.net", "opendns.com", "adguard.com",
		// the model providers and registries sandy's own agents need
		"api.anthropic.com", "registry.npmjs.org", "github.com",
	}
	for _, h := range yes {
		if !isDoHProvider(h) {
			t.Errorf("isDoHProvider(%q) = false, want true", h)
		}
	}
	for _, h := range no {
		if isDoHProvider(h) {
			t.Errorf("isDoHProvider(%q) = true, want false", h)
		}
	}
}

// Every listed entry must be a plausible hostname by the proxy's own rules —
// an entry normalizeHost would reject could never match anything, silently.
func TestDoHProviders_WellFormed(t *testing.T) {
	for _, d := range dohProviders {
		h, isIP, ok := normalizeHost(d)
		if !ok || isIP || h != d {
			t.Errorf("dohProviders entry %q is not a normalized hostname (got %q ip=%v ok=%v)", d, h, isIP, ok)
		}
	}
}

// The property #154 asks for: in permissive mode a DoH provider is refused on
// the transparent :443/:80 paths AND via CONNECT, before anything is dialed,
// with a reason that says why and names the escape hatch.
func TestEgress_PermissiveDeniesDoH(t *testing.T) {
	for _, host := range []string{"dns.google", "cloudflare-dns.com", "mozilla.cloudflare-dns.com", "DNS.Quad9.NET"} {
		for _, port := range []int{443, 80, 853} {
			p := testPolicy(modePermissive)
			dialed := recordDial(p)
			conn, deny := p.Egress(host, port)
			if conn != nil || !strings.Contains(deny, dohDenyReason) {
				t.Errorf("permissive Egress(%s:%d) = (%v, %q), want a %s denial", host, port, conn, deny, dohDenyReason)
			}
			if !strings.Contains(deny, "SANDY_ALLOW_HOSTS") {
				t.Errorf("permissive Egress(%s:%d) deny %q does not name the SANDY_ALLOW_HOSTS escape hatch", host, port, deny)
			}
			if len(*dialed) != 0 {
				t.Errorf("permissive Egress(%s:%d) dialed %v before denying", host, port, *dialed)
			}
		}
	}
}

// Non-vacuity control: an ordinary public name still goes through (reaches the
// dial), so the test above measures the DoH block and not a policy that has
// started denying everything.
func TestEgress_PermissiveAllowsOrdinaryPublicName(t *testing.T) {
	p := testPolicy(modePermissive)
	dialed := recordDial(p)
	_, deny := p.Egress("example.com", 443)
	if strings.Contains(deny, dohDenyReason) {
		t.Fatalf("permissive Egress denied an ordinary name as DoH: %q", deny)
	}
	if len(*dialed) != 1 || (*dialed)[0] != "8.8.8.8:443" {
		t.Errorf("permissive Egress(example.com) dialed %v, want [8.8.8.8:443]", *dialed)
	}
}

// SANDY_ALLOW_HOSTS wins: an operator who allowlists a DoH provider has said
// what they want, so the name is dialed as-is — exact and wildcard entries both.
func TestEgress_PermissiveAllowlistReallowsDoH(t *testing.T) {
	for _, tc := range []struct{ entry, host string }{
		{"dns.google", "dns.google"},
		{"*.cloudflare-dns.com", "mozilla.cloudflare-dns.com"},
		{"dns.quad9.net:853", "dns.quad9.net"}, // host:port form, for DoT via CONNECT
	} {
		p := testPolicy(modePermissive, tc.entry)
		dialed := recordDial(p)
		port := 443
		if strings.HasSuffix(tc.entry, ":853") {
			port = 853
		}
		_, deny := p.Egress(tc.host, port)
		if strings.Contains(deny, dohDenyReason) {
			t.Errorf("allowlisted %q: Egress(%s:%d) still denied as DoH: %q", tc.entry, tc.host, port, deny)
		}
		want := net.JoinHostPort(tc.host, itoa(port))
		if len(*dialed) != 1 || (*dialed)[0] != want {
			t.Errorf("allowlisted %q: dialed %v, want [%s]", tc.entry, *dialed, want)
		}
	}
	// ...and the re-allow is scoped to what was listed: allowlisting one
	// provider does not open another.
	p := testPolicy(modePermissive, "dns.google")
	recordDial(p)
	if _, deny := p.Egress("cloudflare-dns.com", 443); !strings.Contains(deny, dohDenyReason) {
		t.Errorf("allowlisting dns.google re-allowed cloudflare-dns.com too: deny=%q", deny)
	}
}

// Strict mode is unchanged: a DoH provider is denied because it is not
// allowlisted (the pre-#154 reason, not the new one), and an allowlisted one
// is reachable exactly as before.
func TestEgress_StrictDoHUnchanged(t *testing.T) {
	p := testPolicy(modeStrict, "api.anthropic.com")
	recordDial(p)
	if _, deny := p.Egress("dns.google", 443); deny != "not in allowlist" {
		t.Errorf("strict Egress(dns.google) deny = %q, want %q", deny, "not in allowlist")
	}
	p = testPolicy(modeStrict, "dns.google")
	dialed := recordDial(p)
	if _, deny := p.Egress("dns.google", 443); strings.Contains(deny, dohDenyReason) {
		t.Errorf("strict Egress denied an ALLOWLISTED DoH provider as DoH: %q", deny)
	}
	if len(*dialed) != 1 || (*dialed)[0] != "8.8.8.8:443" {
		t.Errorf("strict allowlisted dns.google dialed %v, want [8.8.8.8:443]", *dialed)
	}
}

// PermitDNS deliberately still ANSWERS a DoH name in permissive mode (see its
// doc comment): the refusal happens in Egress, where it is logged. If this
// flips, the attempt silently disappears from proxy.log.
func TestPermitDNS_PermissiveStillAnswersDoH(t *testing.T) {
	if !testPolicy(modePermissive).PermitDNS("dns.google") {
		t.Error("permissive PermitDNS refused a DoH name; the deny must happen in Egress so it reaches proxy.log")
	}
	if testPolicy(modeStrict, "api.anthropic.com").PermitDNS("dns.google") {
		t.Error("strict PermitDNS answered a non-allowlisted DoH name")
	}
}

// syncBuf is a goroutine-safe log sink: the listener logs from its own
// goroutine while the test reads.
type syncBuf struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func captureLog(t *testing.T) *syncBuf {
	t.Helper()
	buf := &syncBuf{}
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(prevOut); log.SetFlags(prevFlags) })
	return buf
}

// waitFor polls the captured log for want; the listener logs just before it
// closes the client, so the line lands within a moment of the client seeing
// the close.
func waitFor(buf *syncBuf, want string) bool {
	for i := 0; i < 100; i++ {
		if strings.Contains(buf.String(), want) {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

// End to end through the real :443 listener: a TLS ClientHello whose SNI names
// a DoH provider is dropped AND recorded in the log exactly as any other
// denial is -- the "sandy-proxy: deny " prefix is what sandy's session-end
// egress summary counts, so a DoH block that did not log would vanish from it.
func TestTransparentTLS_DoHDeniedAndLogged(t *testing.T) {
	buf := captureLog(t)
	p := testPolicy(modePermissive)
	recordDial(p)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	l := &transparentListener{port: 443, policy: p, extract: extractSNI}
	go l.serve(ln)

	raw, err := net.DialTimeout("tcp", ln.Addr().String(), 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	_ = raw.SetDeadline(time.Now().Add(3 * time.Second))
	client := tls.Client(raw, &tls.Config{ServerName: "cloudflare-dns.com", InsecureSkipVerify: true})
	if err := client.Handshake(); err == nil {
		t.Error("TLS handshake to a DoH provider's SNI succeeded in permissive mode, want the proxy to drop it")
	}
	if !waitFor(buf, "sandy-proxy: deny :443 cloudflare-dns.com (known DNS-over-HTTPS") {
		t.Errorf("DoH denial not logged like other denials; log = %q", buf.String())
	}
}

// The CONNECT path returns a real 403 for a DoH provider and logs it.
func TestConnect_DoHDeniedAndLogged(t *testing.T) {
	buf := captureLog(t)
	p := testPolicy(modePermissive)
	recordDial(p)
	proxyAddr := startConnect(t, p)
	c, err := net.DialTimeout("tcp", proxyAddr, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(c, "CONNECT dns.google:443 HTTP/1.1\r\nHost: dns.google:443\r\n\r\n")
	status, _ := bufio.NewReader(c).ReadString('\n')
	if !strings.Contains(status, "403") {
		t.Errorf("CONNECT to a DoH provider status = %q, want 403", strings.TrimSpace(status))
	}
	if !waitFor(buf, "sandy-proxy: deny CONNECT dns.google:443 (known DNS-over-HTTPS") {
		t.Errorf("DoH CONNECT denial not logged; log = %q", buf.String())
	}
}
