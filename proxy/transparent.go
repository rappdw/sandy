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
	allow   *Allowlist
	extract func([]byte) (string, error)
}

func newTransparentTLS(allow *Allowlist) *transparentListener {
	return &transparentListener{port: 443, allow: allow, extract: extractSNI}
}

func newTransparentHTTP(allow *Allowlist) *transparentListener {
	return &transparentListener{port: 80, allow: allow, extract: extractHTTPHost}
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
	// Peek into a buffered reader so the bytes we consume to find the hostname
	// can be replayed to the upstream untouched.
	br := bufio.NewReaderSize(client, peekLimit)
	host, prefix, err := peekHost(br, l.extract)
	if err != nil {
		client.Close()
		return
	}
	if !l.allow.AllowedName(host) {
		// Denied: drop. (No error body — the client just sees a closed conn,
		// same as an unreachable host. Failing closed is the point.)
		client.Close()
		return
	}
	up, err := dialUpstream(host, l.port)
	if err != nil {
		client.Close()
		return
	}
	// Replay the peeked bytes to the upstream, then hand off to the splicer.
	if _, err := up.Write(prefix); err != nil {
		client.Close()
		up.Close()
		return
	}
	// Wrap the client so the splicer reads any bytes still buffered in br plus
	// the live connection.
	splice(&prefixConn{Conn: client, r: br}, up)
}

// peekHost grows a buffer from br until extract yields a hostname (or a hard
// error). It returns the host and the exact bytes consumed so far, so they can
// be replayed upstream.
func peekHost(br *bufio.Reader, extract func([]byte) (string, error)) (host string, prefix []byte, err error) {
	for n := 1; n <= peekLimit; n++ {
		buf, perr := br.Peek(n)
		if len(buf) < n {
			// Couldn't get n bytes: try to extract from whatever we have; if
			// that still wants more, we're out of input.
			host, e := extract(buf)
			if e == nil {
				return host, append([]byte(nil), buf...), nil
			}
			if perr != nil {
				return "", nil, perr
			}
			return "", nil, errShortRead
		}
		host, e := extract(buf)
		if e == nil {
			return host, append([]byte(nil), buf...), nil
		}
		if !errors.Is(e, errShortRead) {
			return "", nil, e // a real parse error: not TLS/HTTP, no Host, etc.
		}
		// errShortRead -> grow and retry.
	}
	return "", nil, errors.New("hostname not found within peek limit")
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
