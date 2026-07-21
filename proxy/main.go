package main

import (
	"flag"
	"net"
	"os"

	"github.com/miekg/dns"
)

// configPath is where the sandy launcher writes the proxy config and mounts it
// into the proxy container.
const defaultConfigPath = "/etc/sandy-proxy.json"

func main() {
	cfgPath := flag.String("config", defaultConfigPath, "path to sandy-proxy.json")
	healthcheck := flag.Bool("healthcheck", false, "probe own listeners and exit 0 if healthy (for Docker HEALTHCHECK)")
	flag.Parse()

	// Docker HEALTHCHECK mode (#37): probe the listeners and exit, so readiness
	// reflects an actual bind, not just process start. Runs before LoadConfig —
	// the probe is self-contained and must stay fast. scratch has no shell, so
	// the healthcheck IS this binary re-invoked with -healthcheck.
	if *healthcheck {
		if err := runHealthcheck(); err != nil {
			logf("sandy-proxy: healthcheck failed: %v", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	cfg, err := LoadConfig(*cfgPath)
	if err != nil {
		logf("sandy-proxy: fatal: %v", err)
		// Exit non-zero so the container is visibly unhealthy rather than
		// silently allowing nothing.
		panicExit(err)
	}

	policy := newPolicy(cfg)

	// DNS (UDP 53): the redirect + denial brain.
	dnsSrv := &dns.Server{
		Addr:    ":53",
		Net:     "udp",
		Handler: newDNSHandler(policy),
	}
	go func() {
		logf("sandy-proxy: DNS listening on :53")
		if err := dnsSrv.ListenAndServe(); err != nil {
			logf("sandy-proxy: DNS server error: %v", err)
		}
	}()

	// Transparent HTTPS (:443) and HTTP (:80).
	tls := newTransparentTLS(policy)
	startTCP(tls.addr(), tls.serve)
	http := newTransparentHTTP(policy)
	startTCP(http.addr(), http.serve)

	// CONNECT (:3128) for git-over-SSH via ssh ProxyCommand.
	cl := newConnectListener(policy)
	startTCP(cl.addr(), cl.serve)

	// Optional local-LLM forward (mode-independent fixed forward).
	fl, err := newForwardListener(cfg)
	if err != nil {
		logf("sandy-proxy: invalid local_llm config: %v", err)
	} else if fl != nil {
		startTCP(fl.addr(), fl.serve)
	}

	logf("sandy-proxy: ready (mode=%s, proxy_ip=%s, %d allow entries)", cfg.Mode, cfg.ProxyIP, len(cfg.Allow))
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
