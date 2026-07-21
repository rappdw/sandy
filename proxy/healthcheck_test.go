package main

import (
	"net"
	"testing"
	"time"

	"github.com/miekg/dns"
)

// startTestTCP opens a loopback TCP listener on an ephemeral port (so the test
// needn't bind the privileged 53/80/443) and accepts+closes connections.
func startTestTCP(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

// startTestDNS runs a miekg/dns UDP server on an ephemeral port that answers
// NXDOMAIN to everything, mirroring the real responder's "always reply" shape.
func startTestDNS(t *testing.T) string {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("udp listen: %v", err)
	}
	srv := &dns.Server{PacketConn: pc, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		m := new(dns.Msg)
		m.SetRcode(r, dns.RcodeNameError) // NXDOMAIN — still a reply
		_ = w.WriteMsg(m)
	})}
	go func() { _ = srv.ActivateAndServe() }()
	t.Cleanup(func() { _ = srv.Shutdown() })
	return pc.LocalAddr().String()
}

func TestHealthProbe_AllUp(t *testing.T) {
	ports := []int{startTestTCP(t), startTestTCP(t), startTestTCP(t)}
	dnsAddr := startTestDNS(t)
	time.Sleep(30 * time.Millisecond) // let the DNS server spin up
	if err := healthProbe("127.0.0.1", ports, dnsAddr, 500*time.Millisecond); err != nil {
		t.Fatalf("expected healthy, got %v", err)
	}
}

func TestHealthProbe_TCPDown(t *testing.T) {
	ports := []int{startTestTCP(t), startTestTCP(t)}
	// A third port with nothing listening: reserve then release so the dial is refused.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	down := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	dnsAddr := startTestDNS(t)
	time.Sleep(30 * time.Millisecond)
	err = healthProbe("127.0.0.1", append(ports, down), dnsAddr, 250*time.Millisecond)
	if err == nil {
		t.Fatal("expected failure with a TCP port down")
	}
}

func TestHealthProbe_DNSDown(t *testing.T) {
	ports := []int{startTestTCP(t)}
	// A UDP addr with nothing listening.
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("udp listen: %v", err)
	}
	dnsAddr := pc.LocalAddr().String()
	_ = pc.Close()
	if err := healthProbe("127.0.0.1", ports, dnsAddr, 250*time.Millisecond); err == nil {
		t.Fatal("expected failure with DNS down")
	}
}
