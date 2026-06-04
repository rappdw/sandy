package main

import (
	"net"

	"github.com/miekg/dns"
)

// dnsHandler answers the agent container's DNS queries. It is deliberately not a
// recursive resolver: it exists to (1) redirect allowlisted names to the proxy
// so traffic is funneled through the transparent listeners, and (2) deny
// everything else, which closes the DNS-exfil vector (F9).
//
// Policy by query type:
//
//	A      allowlisted -> proxy_ip ; else NXDOMAIN
//	AAAA   allowlisted -> empty NOERROR (no AAAA) so the client falls back to
//	       A ; else NXDOMAIN. The proxy speaks IPv4 on the sidecar net, so we
//	       never hand out a v6 address.
//	HTTPS  refused (RcodeRefused), regardless of allowlist. These SVCB-family
//	SVCB   records can carry ECH configs; refusing them forces TLS clients to
//	       fall back to plaintext SNI, keeping the transparent listener able to
//	       read the hostname. (Closes the one real SNI blind spot.)
//	other  NXDOMAIN.
type dnsHandler struct {
	allow   *Allowlist
	proxyIP net.IP
}

func newDNSHandler(allow *Allowlist, proxyIP string) *dnsHandler {
	return &dnsHandler{allow: allow, proxyIP: net.ParseIP(proxyIP).To4()}
}

func (h *dnsHandler) ServeDNS(w dns.ResponseWriter, req *dns.Msg) {
	m := new(dns.Msg)
	m.SetReply(req)
	m.Authoritative = true

	// Single-question is the universal real-world case; if a query somehow
	// carries none, reply NXDOMAIN.
	if len(req.Question) == 0 {
		m.Rcode = dns.RcodeNameError
		_ = w.WriteMsg(m)
		return
	}
	q := req.Question[0]
	name := trimDot(q.Name)

	switch q.Qtype {
	case dns.TypeA:
		if h.proxyIP != nil && h.allow.AllowedName(name) {
			m.Answer = append(m.Answer, &dns.A{
				Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30},
				A:   h.proxyIP,
			})
		} else {
			m.Rcode = dns.RcodeNameError // NXDOMAIN
		}

	case dns.TypeAAAA:
		// Allowlisted: NOERROR with no answer -> client retries over A.
		// Not allowlisted: NXDOMAIN, same as A.
		if !h.allow.AllowedName(name) {
			m.Rcode = dns.RcodeNameError
		}

	case dns.TypeHTTPS, dns.TypeSVCB:
		// Refuse outright — defeats Encrypted ClientHello advertisement.
		m.Rcode = dns.RcodeRefused

	default:
		m.Rcode = dns.RcodeNameError
	}

	_ = w.WriteMsg(m)
}

func trimDot(s string) string {
	if n := len(s); n > 0 && s[n-1] == '.' {
		return s[:n-1]
	}
	return s
}
