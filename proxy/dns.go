package main

import (
	"github.com/miekg/dns"
)

// dnsHandler answers the agent container's DNS queries. It is deliberately not a
// recursive resolver: it exists to (1) redirect *permitted* names to the proxy
// so traffic is funneled through the transparent listeners, and (2) deny
// everything else, which closes the DNS-exfil vector (F9). What "permitted"
// means depends on the policy mode (strict allowlist vs permissive any-name);
// in permissive mode the actual LAN block happens later at forward time.
//
// Policy by query type:
//
//	A      permitted -> proxy_ip ; else NXDOMAIN
//	AAAA   permitted -> empty NOERROR (no AAAA) so the client falls back to
//	       A ; else NXDOMAIN. The proxy speaks IPv4 on the sidecar net, so we
//	       never hand out a v6 address.
//	HTTPS  refused (RcodeRefused), in BOTH modes. These SVCB-family records can
//	SVCB   carry ECH configs; refusing them forces TLS clients to fall back to
//	       plaintext SNI, keeping the transparent listener able to read the
//	       hostname. (Closes the one real SNI blind spot.)
//	other  NXDOMAIN.
type dnsHandler struct {
	p *Policy
}

func newDNSHandler(p *Policy) *dnsHandler {
	return &dnsHandler{p: p}
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
		if h.p.proxyIP != nil && h.p.PermitDNS(name) {
			m.Answer = append(m.Answer, &dns.A{
				Hdr: dns.RR_Header{Name: q.Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 30},
				A:   h.p.proxyIP,
			})
		} else {
			m.Rcode = dns.RcodeNameError // NXDOMAIN
		}

	case dns.TypeAAAA:
		// Permitted: NOERROR with no answer -> client retries over A.
		// Not permitted: NXDOMAIN, same as A.
		if !h.p.PermitDNS(name) {
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
