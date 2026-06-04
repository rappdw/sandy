package main

import (
	"crypto/tls"
	"errors"
	"net"
	"testing"
	"time"
)

// captureClientHello produces a real TLS ClientHello for the given serverName
// by starting a handshake against a pipe and grabbing the first flight of bytes
// the client writes. This yields authentic wire bytes (correct extension
// ordering, lengths, cipher list) rather than a hand-built fixture.
func captureClientHello(t *testing.T, serverName string) []byte {
	t.Helper()
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()

	got := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 4096)
		_ = serverConn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _ := serverConn.Read(buf)
		got <- append([]byte(nil), buf[:n]...)
	}()

	cfg := &tls.Config{ServerName: serverName, InsecureSkipVerify: true}
	client := tls.Client(clientConn, cfg)
	// Handshake will block (no server completing it); we only need the first
	// flight. Run it in a goroutine and let it die with the closed pipe.
	go func() { _ = client.Handshake(); clientConn.Close() }()

	select {
	case b := <-got:
		if len(b) == 0 {
			t.Fatal("captured empty ClientHello")
		}
		return b
	case <-time.After(2 * time.Second):
		t.Fatal("timed out capturing ClientHello")
		return nil
	}
}

func TestExtractSNI_Valid(t *testing.T) {
	for _, name := range []string{"api.anthropic.com", "raw.githubusercontent.com", "a.b.c.example.com"} {
		hello := captureClientHello(t, name)
		got, err := extractSNI(hello)
		if err != nil {
			t.Fatalf("extractSNI(%q) error: %v", name, err)
		}
		if got != name {
			t.Errorf("extractSNI = %q, want %q", got, name)
		}
	}
}

func TestExtractSNI_NoSNI(t *testing.T) {
	// A ClientHello with an empty ServerName carries no server_name extension.
	hello := captureClientHello(t, "")
	_, err := extractSNI(hello)
	if !errors.Is(err, errNoSNI) {
		t.Errorf("extractSNI(no-SNI) error = %v, want errNoSNI", err)
	}
}

func TestExtractSNI_Truncated(t *testing.T) {
	hello := captureClientHello(t, "api.anthropic.com")
	// Feed progressively longer prefixes; every prefix shorter than the full
	// hello must yield errShortRead (need more bytes), never a wrong host and
	// never a panic.
	for n := 0; n < len(hello)-1; n++ {
		_, err := extractSNI(hello[:n])
		if err == nil {
			t.Fatalf("extractSNI(prefix len %d) unexpectedly succeeded", n)
		}
	}
}

func TestExtractSNI_NotHandshake(t *testing.T) {
	// Record type 23 (application_data) is not a handshake.
	_, err := extractSNI([]byte{23, 3, 3, 0, 1, 0})
	if err == nil || errors.Is(err, errShortRead) {
		t.Errorf("extractSNI(non-handshake) error = %v, want a parse error", err)
	}
}

func TestExtractHTTPHost(t *testing.T) {
	cases := []struct {
		name string
		req  string
		want string
		err  bool
	}{
		{"simple", "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", "example.com", false},
		{"with port", "GET / HTTP/1.1\r\nHost: example.com:8080\r\n\r\n", "example.com", false},
		{"case", "GET / HTTP/1.1\r\nhOsT:   API.Example.Com  \r\n\r\n", "api.example.com", false},
		{"other headers first", "POST /x HTTP/1.1\r\nUser-Agent: z\r\nHost: a.b.com\r\nAccept: */*\r\n\r\n", "a.b.com", false},
		{"no host", "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := extractHTTPHost([]byte(c.req))
			if c.err {
				if err == nil {
					t.Fatalf("extractHTTPHost(%q) = %q, want error", c.req, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("extractHTTPHost(%q) error: %v", c.req, err)
			}
			if got != c.want {
				t.Errorf("extractHTTPHost = %q, want %q", got, c.want)
			}
		})
	}
}

func TestExtractHTTPHost_Incomplete(t *testing.T) {
	// Header block not terminated yet -> errShortRead so the caller reads more.
	_, err := extractHTTPHost([]byte("GET / HTTP/1.1\r\nHo"))
	if !errors.Is(err, errShortRead) {
		t.Errorf("extractHTTPHost(incomplete) error = %v, want errShortRead", err)
	}
}
