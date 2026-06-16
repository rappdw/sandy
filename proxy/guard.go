package main

import "runtime/debug"

// guard runs fn with panic recovery so a single malformed connection can never
// crash the whole proxy. An unrecovered panic in ANY goroutine terminates the
// entire Go process — and the proxy runs one goroutine per connection over
// untrusted, attacker-influenced bytes (TLS ClientHello / HTTP Host), so without
// this one bad connection would take down the agent's only route off the
// --internal sidecar (and with --restart on-failure, crash-loop it to death).
// The recovered value + stack is logged (and thus persisted to the host-side
// proxy log) so the cause stays diagnosable instead of vanishing with the
// process. This mirrors what net/http's Server does around every request.
func guard(what string, fn func()) {
	defer func() {
		if r := recover(); r != nil {
			logf("sandy-proxy: PANIC in %s: %v\n%s", what, r, debug.Stack())
		}
	}()
	fn()
}
