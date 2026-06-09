package main

import "errors"

// errShortRead means a parser needed more bytes than were available. Callers
// that read from a live connection can grow their buffer and retry; callers
// with a fixed buffer treat it as a hard failure.
var errShortRead = errors.New("short read")

// reader is a tiny big-endian cursor over a byte slice, used by the TLS
// ClientHello parser. Every accessor returns ok=false (rather than panicking)
// when the slice is too short, so malformed/truncated input is handled by
// control flow, not recover().
type reader struct {
	data []byte
	pos  int
}

func newReader(b []byte) *reader { return &reader{data: b} }

func (r *reader) remaining() int { return len(r.data) - r.pos }

// has reports whether at least n bytes remain from the current position.
func (r *reader) has(n int) bool { return n >= 0 && r.remaining() >= n }

func (r *reader) u8() (uint8, bool) {
	if !r.has(1) {
		return 0, false
	}
	v := r.data[r.pos]
	r.pos++
	return v, true
}

func (r *reader) u16() (uint16, bool) {
	if !r.has(2) {
		return 0, false
	}
	v := uint16(r.data[r.pos])<<8 | uint16(r.data[r.pos+1])
	r.pos += 2
	return v, true
}

// skip advances n bytes.
func (r *reader) skip(n int) (bool, bool) {
	if !r.has(n) {
		return false, false
	}
	r.pos += n
	return true, true
}

// take returns the next n bytes and advances past them, or nil if short.
func (r *reader) take(n int) []byte {
	if !r.has(n) {
		return nil
	}
	b := r.data[r.pos : r.pos+n]
	r.pos += n
	return b
}

// skipVec8 skips a vector prefixed by a 1-byte length.
func (r *reader) skipVec8() bool {
	n, ok := r.u8()
	if !ok {
		return false
	}
	_, ok = r.skip(int(n))
	return ok
}

// skipVec16 skips a vector prefixed by a 2-byte length.
func (r *reader) skipVec16() bool {
	n, ok := r.u16()
	if !ok {
		return false
	}
	_, ok = r.skip(int(n))
	return ok
}
