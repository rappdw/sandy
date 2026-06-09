package main

import (
	"io"
	"net"
	"time"
)

// dialTimeout is how long the proxy waits to establish an upstream connection
// before giving up. Kept short — these are well-known reachable hosts on the
// egress network; a long hang usually means a misconfigured allowlist target.
const dialTimeout = 10 * time.Second

// peekLimit bounds how many bytes the transparent listeners buffer while
// waiting for the SNI / Host header. A ClientHello or HTTP header block is far
// smaller than this; the cap stops a malicious client from making the proxy
// buffer unboundedly before it has a hostname to allowlist-check.
const peekLimit = 16 * 1024

// splice copies bytes in both directions between two connections until either
// side closes, then closes both. This is the whole data path: the proxy never
// inspects or rewrites payload after the initial hostname read.
func splice(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		// Half-close the write side so the peer sees EOF; fall back to full
		// close if half-close isn't supported.
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = dst.Close()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	<-done
	_ = a.Close()
	_ = b.Close()
}

// dialUpstream opens a TCP connection to host:port on the egress network.
func dialUpstream(host string, port int) (net.Conn, error) {
	return net.DialTimeout("tcp", net.JoinHostPort(host, itoa(port)), dialTimeout)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [6]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
