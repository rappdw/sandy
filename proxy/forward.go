package main

import (
	"net"
)

// forwardListener is the local-LLM path. SANDY_LOCAL_LLM_HOST gives a "host:port"
// the user wants reachable (e.g. an Ollama server). Under `--internal` the agent
// can't reach host.docker.internal directly, so the proxy listens on that port
// and pipes every connection straight to <target>:<port> on its egress leg,
// where host.docker.internal IS reachable. No demux, no inspection — a fixed
// port→host:port byte pipe.
type forwardListener struct {
	listenPort int
	target     string // e.g. "host.docker.internal"
	targetPort int
}

// newForwardListener parses cfg.LocalLLM ("host:port"); the listen port and the
// upstream port are the same (the user configured a single port), and the
// upstream host is cfg.LocalLLMTarget (host.docker.internal by default). The
// host portion of LocalLLM is informational — what matters to the agent is the
// port; the proxy always forwards to the egress-reachable target.
func newForwardListener(cfg *Config) (*forwardListener, error) {
	if cfg.LocalLLM == "" {
		return nil, nil
	}
	_, port, err := splitHostPort(cfg.LocalLLM)
	if err != nil {
		return nil, err
	}
	return &forwardListener{
		listenPort: port,
		target:     cfg.LocalLLMTarget,
		targetPort: port,
	}, nil
}

func (l *forwardListener) addr() string { return ":" + itoa(l.listenPort) }

func (l *forwardListener) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go guard("forward", func() { l.handle(c) })
	}
}

func (l *forwardListener) handle(client net.Conn) {
	up, err := dialUpstream(l.target, l.targetPort)
	if err != nil {
		client.Close()
		return
	}
	splice(client, up)
}
