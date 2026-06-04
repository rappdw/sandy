package main

import (
	"net"
	"testing"

	"github.com/miekg/dns"
)

// fakeRW captures the DNS reply the handler writes, so we can assert on it
// without a real socket.
type fakeRW struct{ msg *dns.Msg }

func (f *fakeRW) WriteMsg(m *dns.Msg) error { f.msg = m; return nil }
func (f *fakeRW) Write([]byte) (int, error) { return 0, nil }
func (f *fakeRW) Close() error              { return nil }
func (f *fakeRW) TsigStatus() error         { return nil }
func (f *fakeRW) TsigTimersOnly(bool)       {}
func (f *fakeRW) Hijack()                   {}
func (f *fakeRW) LocalAddr() net.Addr       { return &net.UDPAddr{} }
func (f *fakeRW) RemoteAddr() net.Addr      { return &net.UDPAddr{} }
func (f *fakeRW) Network() string           { return "udp" }

func ask(h *dnsHandler, name string, qtype uint16) *dns.Msg {
	req := new(dns.Msg)
	req.SetQuestion(dns.Fqdn(name), qtype)
	rw := &fakeRW{}
	h.ServeDNS(rw, req)
	return rw.msg
}

func newTestHandler() *dnsHandler {
	a := NewAllowlist([]string{"api.anthropic.com", "*.githubusercontent.com"})
	return newDNSHandler(a, "192.168.229.2")
}

func TestDNS_AllowedA(t *testing.T) {
	h := newTestHandler()
	m := ask(h, "api.anthropic.com", dns.TypeA)
	if m.Rcode != dns.RcodeSuccess {
		t.Fatalf("rcode = %v, want success", dns.RcodeToString[m.Rcode])
	}
	if len(m.Answer) != 1 {
		t.Fatalf("got %d answers, want 1", len(m.Answer))
	}
	a, ok := m.Answer[0].(*dns.A)
	if !ok {
		t.Fatalf("answer is %T, want *dns.A", m.Answer[0])
	}
	if a.A.String() != "192.168.229.2" {
		t.Errorf("A = %s, want proxy IP 192.168.229.2", a.A)
	}
}

func TestDNS_WildcardA(t *testing.T) {
	h := newTestHandler()
	m := ask(h, "raw.githubusercontent.com", dns.TypeA)
	if m.Rcode != dns.RcodeSuccess || len(m.Answer) != 1 {
		t.Fatalf("wildcard A not answered: rcode=%v answers=%d", dns.RcodeToString[m.Rcode], len(m.Answer))
	}
}

func TestDNS_DeniedA_NXDOMAIN(t *testing.T) {
	h := newTestHandler()
	m := ask(h, "evil.com", dns.TypeA)
	if m.Rcode != dns.RcodeNameError {
		t.Errorf("rcode = %v, want NXDOMAIN", dns.RcodeToString[m.Rcode])
	}
	if len(m.Answer) != 0 {
		t.Errorf("got %d answers for denied name, want 0", len(m.Answer))
	}
}

func TestDNS_AllowedAAAA_EmptyNoError(t *testing.T) {
	h := newTestHandler()
	m := ask(h, "api.anthropic.com", dns.TypeAAAA)
	if m.Rcode != dns.RcodeSuccess {
		t.Errorf("AAAA rcode = %v, want NOERROR", dns.RcodeToString[m.Rcode])
	}
	if len(m.Answer) != 0 {
		t.Errorf("AAAA returned %d answers, want 0 (force v4 fallback)", len(m.Answer))
	}
}

func TestDNS_DeniedAAAA_NXDOMAIN(t *testing.T) {
	h := newTestHandler()
	m := ask(h, "evil.com", dns.TypeAAAA)
	if m.Rcode != dns.RcodeNameError {
		t.Errorf("denied AAAA rcode = %v, want NXDOMAIN", dns.RcodeToString[m.Rcode])
	}
}

func TestDNS_HTTPS_SVCB_Refused(t *testing.T) {
	h := newTestHandler()
	// Even an allowlisted name must have HTTPS/SVCB refused (ECH defeat).
	for _, qt := range []uint16{dns.TypeHTTPS, dns.TypeSVCB} {
		m := ask(h, "api.anthropic.com", qt)
		if m.Rcode != dns.RcodeRefused {
			t.Errorf("%s rcode = %v, want REFUSED", dns.TypeToString[qt], dns.RcodeToString[m.Rcode])
		}
	}
}

func TestDNS_OtherType_NXDOMAIN(t *testing.T) {
	h := newTestHandler()
	m := ask(h, "api.anthropic.com", dns.TypeMX)
	if m.Rcode != dns.RcodeNameError {
		t.Errorf("MX rcode = %v, want NXDOMAIN", dns.RcodeToString[m.Rcode])
	}
}
