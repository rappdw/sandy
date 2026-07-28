package main

import "net"

// maxConns bounds the number of connections handled concurrently across ALL
// listeners. HF-incident Issue 2: the agent can open unbounded concurrent
// connections to the proxy, and each holds a peek buffer plus a goroutine — a
// self-inflicted or injected connection storm could otherwise grow memory and
// goroutines without limit until the container --memory cap OOM-kills the proxy
// (which --restart on-failure then revives, up to 5 times, before stranding the
// session). The semaphore makes the proxy apply backpressure itself, so the
// --memory limit is a backstop rather than the thing that enforces the bound.
const maxConns = 512

// connLimiter is a counting semaphore over concurrent connection handlers.
type connLimiter struct{ sem chan struct{} }

func newConnLimiter(n int) *connLimiter { return &connLimiter{sem: make(chan struct{}, n)} }

// acquire blocks until a slot is free.
func (c *connLimiter) acquire() { c.sem <- struct{}{} }

// release returns a slot.
func (c *connLimiter) release() { <-c.sem }

// inUse reports how many slots are currently held (test/diagnostic aid).
func (c *connLimiter) inUse() int { return len(c.sem) }

// globalConnLimiter bounds every listener's accept loop.
var globalConnLimiter = newConnLimiter(maxConns)

// acceptLoop accepts connections on ln and dispatches each to handle in a
// panic-guarded goroutine, bounding concurrency via the global limiter. The
// slot is acquired BEFORE Accept, so the proxy never accepts more than maxConns
// at once — excess connections wait in the kernel backlog (backpressure)
// instead of being accepted into unbounded goroutines. This is the single
// dispatch point for the transparent (:80/:443), CONNECT (:3128), and forward
// listeners, which were previously three identical `for { Accept(); go guard }`
// loops.
func acceptLoop(ln net.Listener, name string, handle func(net.Conn)) {
	acceptLoopLimited(ln, name, handle, globalConnLimiter)
}

// acceptLoopLimited is acceptLoop with an explicit limiter, for testing.
func acceptLoopLimited(ln net.Listener, name string, handle func(net.Conn), lim *connLimiter) {
	for {
		lim.acquire()
		c, err := ln.Accept()
		if err != nil {
			lim.release()
			return
		}
		go guard(name, func() {
			defer lim.release()
			handle(c)
		})
	}
}
