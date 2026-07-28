package main

import "sync"

// egressLogger logs each DISTINCT allowed (host,port) egress decision once, when
// enabled. HF-incident Issue 4: the proxy is a perfect chokepoint — every host
// the agent reaches passes through Policy.Egress with the SNI/Host already
// extracted — but it logged only DENIALS, so `proxy.log` could answer "what was
// blocked" and never "what did the agent actually reach this session," which is
// the first question after a suspected prompt injection or a leaked-token scare.
// This adds the allow side. It dedupes by (host,port) so a chatty agent can't
// turn the log into a gigabyte — the goal is the SET of destinations, not a
// per-connection firehose. Hostnames are metadata the proxy already sees; TLS is
// never terminated and no payload is touched, so this is not a privacy regression.
type egressLogger struct {
	enabled bool
	mu      sync.Mutex
	seen    map[string]struct{}
}

func newEgressLogger(enabled bool) *egressLogger {
	return &egressLogger{enabled: enabled, seen: make(map[string]struct{})}
}

// note logs "allow :port host" once per distinct (host,port). No-op when the
// logger is nil or disabled. Safe for concurrent use across all listeners.
func (e *egressLogger) note(port int, host string) {
	if e == nil || !e.enabled || host == "" {
		return
	}
	key := host + ":" + itoa(port)
	e.mu.Lock()
	_, dup := e.seen[key]
	if !dup {
		e.seen[key] = struct{}{}
	}
	e.mu.Unlock()
	if !dup {
		logf("sandy-proxy: allow :%d %s", port, host)
	}
}

// egressLog is the process-wide logger, wired from Config.EgressLog in main.
// Defaults to disabled so tests that never set it are safe no-ops.
var egressLog = newEgressLogger(false)
