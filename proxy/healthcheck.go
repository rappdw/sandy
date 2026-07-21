package main

import (
	"fmt"
	"net"
	"strconv"
	"time"

	"github.com/miekg/dns"
)

// healthProbeTimeout bounds each individual listener probe. The healthy path is
// microseconds (loopback dials); a fully-down proxy fails all four in ~1s, well
// under the Docker HEALTHCHECK timeout.
const healthProbeTimeout = 250 * time.Millisecond

// The always-on listeners, probed on loopback. The binds are wildcard (":port"),
// so they accept on 127.0.0.1 too — which makes the probe valid even before the
// sidecar `--ip` is attached (loopback is up at process start regardless). The
// optional local-LLM forward is deliberately NOT probed: its port is variable
// and it is absent unless SANDY_LOCAL_LLM_HOST is set.
var (
	healthHost     = "127.0.0.1"
	healthTCPPorts = []int{443, 80, 3128}
	healthDNSAddr  = "127.0.0.1:53"
)

// runHealthcheck is the production entry point for `sandy-proxy -healthcheck`.
func runHealthcheck() error {
	return healthProbe(healthHost, healthTCPPorts, healthDNSAddr, healthProbeTimeout)
}

// healthProbe dials each TCP port and issues one DNS query, returning the first
// failure (nil = all listeners bound and serving). Ports/addr/timeout are
// parameters so tests can inject ephemeral listeners instead of the privileged
// 53/80/443.
func healthProbe(host string, tcpPorts []int, dnsAddr string, timeout time.Duration) error {
	for _, p := range tcpPorts {
		addr := net.JoinHostPort(host, strconv.Itoa(p))
		c, err := net.DialTimeout("tcp", addr, timeout)
		if err != nil {
			return fmt.Errorf("tcp %s: %w", addr, err)
		}
		_ = c.Close()
	}
	// UDP has no Accept, so probe DNS with a real query: ANY well-formed reply
	// proves the listener is bound and serving. NXDOMAIN is the expected answer
	// for an unknown name (the responder always replies) and is NOT an error —
	// only a network/timeout failure returns a non-nil err from Exchange.
	m := new(dns.Msg)
	m.SetQuestion("healthcheck.sandy.invalid.", dns.TypeA)
	cl := &dns.Client{Net: "udp", Timeout: timeout}
	if _, _, err := cl.Exchange(m, dnsAddr); err != nil {
		return fmt.Errorf("dns %s: %w", dnsAddr, err)
	}
	return nil
}
