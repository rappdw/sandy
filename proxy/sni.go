package main

import (
	"errors"
	"strings"
)

// errNoSNI means the ClientHello was parsed but carried no server_name
// extension. The proxy fails closed on this (rejects the connection) — a
// nameless TLS connection can't be allowlist-checked, and every modern client
// sends SNI.
var errNoSNI = errors.New("no SNI in ClientHello")

// extractSNI parses the leading bytes of a TLS stream and returns the SNI
// hostname from the ClientHello. It does NOT terminate TLS — it only reads the
// unencrypted ClientHello (TLS 1.0–1.3 send it in the clear, unless ECH is in
// play, which the DNS responder prevents by refusing HTTPS/SVCB records).
//
// `data` must contain at least the full ClientHello. The transparent listener
// reads a bounded prefix of the connection into a buffer and passes it here;
// errShortRead signals "need more bytes" so the caller can decide.
//
// Wire format walked here (RFC 8446 §4 / RFC 6066 §3):
//
//	TLS record header: type(1)=22 handshake, version(2), length(2)
//	Handshake header:  type(1)=1 client_hello, length(3)
//	ClientHello:       version(2), random(32),
//	                   session_id: len(1)+bytes,
//	                   cipher_suites: len(2)+bytes,
//	                   compression: len(1)+bytes,
//	                   extensions: len(2)+[ type(2) len(2) body ]...
//	server_name ext (type 0): list_len(2)+[ name_type(1)=0 host_len(2) host ]
func extractSNI(data []byte) (string, error) {
	b := newReader(data)

	// --- TLS record header ---
	recType, ok := b.u8()
	if !ok {
		return "", errShortRead
	}
	if recType != 22 { // not a handshake record
		return "", errors.New("not a TLS handshake record")
	}
	if _, ok := b.skip(2); !ok { // record protocol version
		return "", errShortRead
	}
	recLen, ok := b.u16()
	if !ok {
		return "", errShortRead
	}
	// Bound the handshake body to the record length (defends against a record
	// claiming more than we hold; we still need the bytes present).
	if !b.has(int(recLen)) {
		return "", errShortRead
	}

	// --- Handshake header ---
	hsType, ok := b.u8()
	if !ok {
		return "", errShortRead
	}
	if hsType != 1 { // not a ClientHello
		return "", errors.New("not a ClientHello")
	}
	if _, ok := b.skip(3); !ok { // handshake length (u24)
		return "", errShortRead
	}

	// --- ClientHello body ---
	if _, ok := b.skip(2 + 32); !ok { // client_version + random
		return "", errShortRead
	}
	if !b.skipVec8() { // session_id
		return "", errShortRead
	}
	if !b.skipVec16() { // cipher_suites
		return "", errShortRead
	}
	if !b.skipVec8() { // compression_methods
		return "", errShortRead
	}

	// --- Extensions ---
	extTotal, ok := b.u16()
	if !ok {
		// No extensions block at all: legal old ClientHello, but then no SNI.
		return "", errNoSNI
	}
	ext := newReader(b.take(int(extTotal)))
	if ext.data == nil {
		return "", errShortRead
	}
	for ext.remaining() >= 4 {
		etype, _ := ext.u16()
		elen, _ := ext.u16()
		body := ext.take(int(elen))
		if body == nil {
			return "", errShortRead
		}
		if etype != 0 { // not server_name
			continue
		}
		host, err := parseServerName(body)
		if err != nil {
			return "", err
		}
		return host, nil
	}
	return "", errNoSNI
}

// parseServerName extracts the first host_name (name_type 0) from a server_name
// extension body.
func parseServerName(body []byte) (string, error) {
	r := newReader(body)
	listLen, ok := r.u16()
	if !ok {
		return "", errNoSNI
	}
	list := newReader(r.take(int(listLen)))
	if list.data == nil {
		return "", errShortRead
	}
	for list.remaining() >= 3 {
		nameType, _ := list.u8()
		nameLen, _ := list.u16()
		name := list.take(int(nameLen))
		if name == nil {
			return "", errShortRead
		}
		if nameType == 0 { // host_name
			h := strings.ToLower(strings.TrimSpace(string(name)))
			if h == "" {
				return "", errNoSNI
			}
			return h, nil
		}
	}
	return "", errNoSNI
}

// extractHTTPHost reads the Host header from the start of an HTTP/1.x request.
// It returns the bare host (port stripped). `data` is the peeked request prefix;
// errShortRead means the header block wasn't fully present yet.
func extractHTTPHost(data []byte) (string, error) {
	s := string(data)
	end := strings.Index(s, "\r\n\r\n")
	headerBlock := s
	if end >= 0 {
		headerBlock = s[:end]
	}
	for _, line := range strings.Split(headerBlock, "\r\n") {
		// Case-insensitive "Host:" prefix.
		if len(line) >= 5 && strings.EqualFold(line[:5], "host:") {
			host := strings.TrimSpace(line[5:])
			if i := strings.LastIndexByte(host, ':'); i >= 0 {
				// Strip :port, but not if it's an unbracketed IPv6 (rare for a
				// Host header; bracketed forms keep their colons inside []).
				if !strings.Contains(host, "]") || strings.HasSuffix(host[:i], "]") {
					host = host[:i]
				}
			}
			host = strings.Trim(host, "[]")
			host = strings.ToLower(strings.TrimSpace(host))
			if host == "" {
				return "", errors.New("empty Host header")
			}
			return host, nil
		}
	}
	if end < 0 {
		return "", errShortRead // headers not complete yet
	}
	return "", errors.New("no Host header")
}
