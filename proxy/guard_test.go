package main

import (
	"bytes"
	"log"
	"strings"
	"testing"
)

// A panic inside a guarded function must NOT propagate (it would otherwise
// crash the whole proxy process), and the recovered value + label must be
// logged so the cause is diagnosable in the persisted proxy log.
func TestGuardRecoversAndLogs(t *testing.T) {
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)

	guard("unit-label", func() { panic("boom-value") }) // must return, not crash

	out := buf.String()
	if !strings.Contains(out, "PANIC in unit-label") {
		t.Errorf("expected panic log with label, got: %q", out)
	}
	if !strings.Contains(out, "boom-value") {
		t.Errorf("expected panic value in log, got: %q", out)
	}
	if !strings.Contains(out, "guard") {
		t.Errorf("expected a stack trace in the log, got: %q", out)
	}
}

// The happy path must run fn to completion and log nothing.
func TestGuardRunsFnNormally(t *testing.T) {
	var buf bytes.Buffer
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)

	ran := false
	guard("unit", func() { ran = true })

	if !ran {
		t.Error("guard did not run fn")
	}
	if buf.Len() != 0 {
		t.Errorf("guard logged on the happy path: %q", buf.String())
	}
}
