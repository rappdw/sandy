package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

func TestEgressLoggerDedup(t *testing.T) {
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)

	e := newEgressLogger(true)
	e.note(443, "example.com")
	e.note(443, "example.com") // duplicate (host,port) — must not log again
	e.note(443, "other.com")
	e.note(80, "example.com") // same host, different port — distinct

	out := buf.String()
	if got := strings.Count(out, "allow :443 example.com"); got != 1 {
		t.Fatalf("example.com:443 logged %d times, want 1 (dedup failed)", got)
	}
	if !strings.Contains(out, "allow :443 other.com") {
		t.Fatal("other.com:443 not logged")
	}
	if !strings.Contains(out, "allow :80 example.com") {
		t.Fatal("example.com:80 (distinct port) not logged")
	}
}

func TestEgressLoggerDisabledAndNil(t *testing.T) {
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)

	newEgressLogger(false).note(443, "example.com") // disabled: no output
	var nilLogger *egressLogger
	nilLogger.note(443, "x.com")        // nil receiver: must not panic
	newEgressLogger(true).note(443, "") // empty host: skipped

	if buf.Len() != 0 {
		t.Fatalf("disabled/nil/empty logger emitted output: %q", buf.String())
	}
}
