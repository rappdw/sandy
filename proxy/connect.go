package main

import (
	"bufio"
	"net"
	"net/http"
	"strconv"
)

// connectListener implements an HTTP CONNECT forward proxy on :3128. Its main
// job under sandy is git-over-SSH: the agent's ssh ProxyCommand issues
//
//	CONNECT github.com:22 HTTP/1.1
//
// which we allowlist-check (host:port) and then byte-splice. It also serves as
// a manual escape hatch for any proxy-aware tool. Only the CONNECT method is
// supported; anything else gets 405.
type connectListener struct {
	allow *Allowlist
}

func newConnectListener(allow *Allowlist) *connectListener { return &connectListener{allow: allow} }

func (l *connectListener) addr() string { return ":3128" }

func (l *connectListener) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go l.handle(c)
	}
}

func (l *connectListener) handle(client net.Conn) {
	br := bufio.NewReader(client)
	req, err := http.ReadRequest(br)
	if err != nil {
		client.Close()
		return
	}
	if req.Method != http.MethodConnect {
		writeStatus(client, http.StatusMethodNotAllowed)
		client.Close()
		return
	}
	host, port, err := splitHostPort(req.Host)
	if err != nil {
		writeStatus(client, http.StatusBadRequest)
		client.Close()
		return
	}
	if !l.allow.AllowedHostPort(host, port) {
		// CONNECT can return a real 403 (unlike the transparent path), so the
		// agent can distinguish a policy block from a network failure. Also log
		// it for the launcher's exit-time "to allow, add ..." aggregation.
		logf("sandy-proxy: deny CONNECT %s:%d (not in allowlist)", host, port)
		writeStatus(client, http.StatusForbidden)
		client.Close()
		return
	}
	up, err := dialUpstream(host, port)
	if err != nil {
		writeStatus(client, http.StatusBadGateway)
		client.Close()
		return
	}
	if _, err := client.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n")); err != nil {
		client.Close()
		up.Close()
		return
	}
	// Any bytes the client pipelined after the CONNECT line are buffered in br;
	// route reads through it.
	splice(&prefixConn{Conn: client, r: br}, up)
}

func writeStatus(c net.Conn, code int) {
	_, _ = c.Write([]byte("HTTP/1.1 " + strconv.Itoa(code) + " " + http.StatusText(code) + "\r\n\r\n"))
}

// splitHostPort parses "host:port" from a CONNECT target, returning a numeric
// port. Unlike net.SplitHostPort it rejects a missing/zero port.
func splitHostPort(s string) (string, int, error) {
	host, portStr, err := net.SplitHostPort(s)
	if err != nil {
		return "", 0, err
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		return "", 0, errShortRead // reuse a sentinel; caller only checks != nil
	}
	return host, port, nil
}
