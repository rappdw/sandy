package main

import (
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// TestAcceptLoopBoundsConcurrency verifies that acceptLoopLimited never runs
// more than the limiter's capacity of connection handlers at once (HF-incident
// Issue 2 — a connection storm must be bounded by the proxy itself, not by the
// container OOM-killer).
func TestAcceptLoopBoundsConcurrency(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	const limit = 2
	lim := newConnLimiter(limit)
	release := make(chan struct{})
	var entered int32

	handle := func(c net.Conn) {
		atomic.AddInt32(&entered, 1)
		<-release
		c.Close()
	}
	go acceptLoopLimited(ln, "test", handle, lim)

	// Dial more than the limit; the excess must not be accepted while the first
	// `limit` handlers are still blocked.
	var conns []net.Conn
	for i := 0; i < limit+3; i++ {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		conns = append(conns, c)
	}
	defer func() {
		for _, c := range conns {
			c.Close()
		}
	}()

	// Wait until the limiter saturates.
	deadline := time.Now().Add(2 * time.Second)
	for atomic.LoadInt32(&entered) < limit {
		if time.Now().After(deadline) {
			t.Fatalf("only %d handlers entered, want %d", atomic.LoadInt32(&entered), limit)
		}
		time.Sleep(5 * time.Millisecond)
	}
	// It must NOT dispatch beyond the limit while the handlers are blocked.
	time.Sleep(150 * time.Millisecond)
	if got := atomic.LoadInt32(&entered); got != limit {
		t.Fatalf("entered=%d exceeded limit=%d (semaphore did not bound concurrency)", got, limit)
	}
	if got := lim.inUse(); got != limit {
		t.Fatalf("limiter inUse=%d, want %d", got, limit)
	}

	// After releasing, the loop must drain the remaining connections.
	close(release)
	deadline = time.Now().Add(2 * time.Second)
	for atomic.LoadInt32(&entered) < int32(limit+3) {
		if time.Now().After(deadline) {
			t.Fatalf("after release, only %d handlers entered, want %d", atomic.LoadInt32(&entered), limit+3)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
