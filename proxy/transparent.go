package main

import (
	"bufio"
	"errors"
	"log"
	"net"
)

// transparentListener handles the redirected traffic for one HTTP(S) port. The
// DNS responder has pointed allowlisted names at the proxy's own IP, so the
// agent's TLS/HTTP connections arrive here. We read just enough to learn the
// intended hostname (SNI for :443, Host header for :80), allowlist-check it,
// dial the real host, replay the bytes we peeked, and splice.
//
// extract returns the hostname from a buffered prefix, or errShortRead to ask
// for more bytes. upstreamPort is the port we dial on the real host (same as
// the listen port: 443 or 80).
type transparentListener struct {
	port    int
	policy  *Policy
	extract func([]byte) (string, error)
}

func newTransparentTLS(p *Policy) *transparentListener {
	return &transparentListener{port: 443, policy: p, extract: extractSNI}
}

func newTransparentHTTP(p *Policy) *transparentListener {
	return &transparentListener{port: 80, policy: p, extract: extractHTTPHost}
}

func (l *transparentListener) addr() string { return ":" + itoa(l.port) }

func (l *transparentListener) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go l.handle(c)
	}
}

func (l *transparentListener) handle(client net.Conn) {
	// Peek (not read) into a buffered reader to find the hostname. Peeking does
	// NOT consume, so the ClientHello / HTTP request stays in br and is replayed
	// to the upstream naturally by the splice below — we must NOT also write it
	// out explicitly, or the upstream would receive the handshake twice and
	// reject it (a TLS "protocol version" alert).
	br := bufio.NewReaderSize(client, peekLimit)
	host, err := peekHost(br, l.extract)
	if err != nil {
		client.Close()
		return
	}
	up, deny := l.policy.Egress(host, l.port)
	if deny != "" {
		// Denied: drop. (No error body possible — this is a raw TLS/HTTP byte
		// stream, not a place we can return a 403; the client just sees a
		// closed conn, same as an unreachable host. Failing closed is the
		// point.) Log so the user/launcher can see what the agent tried to
		// reach and offer a "to allow, add SANDY_ALLOW_HOSTS=..." hint at exit.
		logf("sandy-proxy: deny :%d %s (%s)", l.port, host, deny)
		client.Close()
		return
	}
	// Splice through prefixConn so the splicer reads the still-buffered peeked
	// bytes (the ClientHello / request line) first, then the live connection —
	// the full client stream reaches the upstream exactly once.
	splice(&prefixConn{Conn: client, r: br}, up)
}

// peekHost grows a peek window over br until extract yields a hostname (or a
// hard error). It only peeks — br is never advanced — so the caller's splice
// replays the bytes to the upstream untouched.
func peekHost(br *bufio.Reader, extract func([]byte) (string, error)) (host string, err error) {
	for n := 1; n <= peekLimit; n++ {
		buf, perr := br.Peek(n)
		if len(buf) < n {
			// Couldn't get n bytes: try to extract from whatever we have; if
			// that still wants more, we're out of input.
			if h, e := extract(buf); e == nil {
				return h, nil
			}
			if perr != nil {
				return "", perr
			}
			return "", errShortRead
		}
		if h, e := extract(buf); e == nil {
			return h, nil
		} else if !errors.Is(e, errShortRead) {
			return "", e // a real parse error: not TLS/HTTP, no Host, etc.
		}
		// errShortRead -> grow and retry.
	}
	return "", errors.New("hostname not found within peek limit")
}

// prefixConn lets the splicer read through the bufio.Reader (which holds the
// already-buffered prefix) and then the live connection, while writes/closes go
// straight to the underlying conn.
type prefixConn struct {
	net.Conn
	r *bufio.Reader
}

func (p *prefixConn) Read(b []byte) (int, error) { return p.r.Read(b) }

// logf is the proxy's single logging seam. Intentionally minimal — no payload,
// no per-connection spam; just startup and hard failures.
func logf(format string, args ...any) { log.Printf(format, args...) }
