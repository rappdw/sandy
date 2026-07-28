package main

import "testing"

// The proxy hand-parses attacker-influenced wire bytes (TLS ClientHello,
// server_name lists, HTTP Host) from the very agent it contains — exactly the
// position the Hugging Face incident's proxy was in when a zero-day in it broke
// containment (HF-incident analysis Issue 1). Go's memory safety removes the
// class that most likely was, and every wire accessor returns ok=false rather
// than panicking, but "returns an error, never panics, under ANY input" is a
// property worth proving rather than assuming. These fuzz targets do that; CI
// runs a short -fuzztime pass over them, and any crasher is a hard failure.
//
// The invariant is simply: the parser must not panic. A parse failure is a
// correct, expected outcome (return "", err) — only a panic (which would crash
// the whole proxy process, taking down the agent's only egress route) is a bug.

func FuzzExtractSNI(f *testing.F) {
	f.Add([]byte{})
	f.Add([]byte{22})                                  // handshake record type, then truncated
	f.Add([]byte{22, 3, 1, 0, 0})                      // zero-length record
	f.Add([]byte{22, 3, 1, 0xff, 0xff})                // record claims 65535 bytes, no body
	f.Add([]byte{22, 3, 1, 0, 4, 1, 0, 0, 0})          // ClientHello header, truncated
	f.Add([]byte{22, 3, 1, 0, 4, 1, 0xff, 0xff, 0xff}) // oversized handshake length
	f.Add(make([]byte, 70000))                         // over the 16 KiB peek window
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = extractSNI(data) // must never panic
	})
}

func FuzzParseServerName(f *testing.F) {
	f.Add([]byte{})
	f.Add([]byte{0})
	f.Add([]byte{0, 0, 5, 0, 0, 2, 0x61, 0x62}) // partial server_name entry
	f.Add([]byte{0, 0xff, 0xff, 0, 0, 0})       // list length overruns the buffer
	f.Add(make([]byte, 70000))
	f.Fuzz(func(t *testing.T, body []byte) {
		_, _ = parseServerName(body) // must never panic
	})
}

func FuzzExtractHTTPHost(f *testing.F) {
	f.Add([]byte(""))
	f.Add([]byte("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))
	f.Add([]byte("GET /"))                            // truncated request line
	f.Add([]byte("Host:"))                            // header key, no value, no CRLF
	f.Add([]byte("\r\n\r\n"))                         // empty request
	f.Add([]byte("GET / HTTP/1.1\r\nHost: \r\n\r\n")) // empty Host value
	f.Add(make([]byte, 70000))
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = extractHTTPHost(data) // must never panic
	})
}
