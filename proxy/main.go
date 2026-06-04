package main

import (
	"flag"
	"net"

	"github.com/miekg/dns"
)

// configPath is where the sandy launcher writes the proxy config and mounts it
// into the proxy container.
const defaultConfigPath = "/etc/sandy-proxy.json"

func main() {
	cfgPath := flag.String("config", defaultConfigPath, "path to sandy-proxy.json")
	flag.Parse()

	cfg, err := LoadConfig(*cfgPath)
	if err != nil {
		logf("sandy-proxy: fatal: %v", err)
		// Exit non-zero so the container is visibly unhealthy rather than
		// silently allowing nothing.
		panicExit(err)
	}

	allow := NewAllowlist(cfg.Allow)

	// DNS (UDP 53): the redirect + denial brain.
	dnsSrv := &dns.Server{
		Addr:    ":53",
		Net:     "udp",
		Handler: newDNSHandler(allow, cfg.ProxyIP),
	}
	go func() {
		logf("sandy-proxy: DNS listening on :53")
		if err := dnsSrv.ListenAndServe(); err != nil {
			logf("sandy-proxy: DNS server error: %v", err)
		}
	}()

	// Transparent HTTPS (:443) and HTTP (:80).
	startTCP(newTransparentTLS(allow).addr(), func(ln net.Listener) {
		newTransparentTLS(allow).serve(ln)
	})
	startTCP(newTransparentHTTP(allow).addr(), func(ln net.Listener) {
		newTransparentHTTP(allow).serve(ln)
	})

	// CONNECT (:3128) for git-over-SSH via ssh ProxyCommand.
	cl := newConnectListener(allow)
	startTCP(cl.addr(), cl.serve)

	// Optional local-LLM forward.
	fl, err := newForwardListener(cfg)
	if err != nil {
		logf("sandy-proxy: invalid local_llm config: %v", err)
	} else if fl != nil {
		startTCP(fl.addr(), fl.serve)
	}

	logf("sandy-proxy: ready (proxy_ip=%s, %d allowlist entries)", cfg.ProxyIP, len(cfg.Allow))
	select {} // block forever; listeners run in goroutines
}

// startTCP opens a TCP listener on addr and runs serve in a goroutine. A bind
// failure is logged but not fatal — losing one listener shouldn't take down the
// others (e.g. a port already in use shouldn't kill DNS).
func startTCP(addr string, serve func(net.Listener)) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		logf("sandy-proxy: listen %s failed: %v", addr, err)
		return
	}
	logf("sandy-proxy: TCP listening on %s", addr)
	go serve(ln)
}

// panicExit terminates the process with a non-zero status. Split out so tests
// never call it (they exercise LoadConfig directly).
func panicExit(err error) { panic(err) }
