package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "sandy-proxy.json")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadConfig_OK(t *testing.T) {
	p := writeTemp(t, `{
		"proxy_ip": "192.168.229.2",
		"allow": ["api.anthropic.com", "*.githubusercontent.com", "github.com:22"],
		"local_llm": "127.0.0.1:11434"
	}`)
	c, err := LoadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.ProxyIP != "192.168.229.2" {
		t.Errorf("ProxyIP = %q", c.ProxyIP)
	}
	if len(c.Allow) != 3 {
		t.Errorf("Allow len = %d, want 3", len(c.Allow))
	}
	if c.LocalLLM != "127.0.0.1:11434" {
		t.Errorf("LocalLLM = %q", c.LocalLLM)
	}
	if c.LocalLLMTarget != "host.docker.internal" {
		t.Errorf("LocalLLMTarget default = %q, want host.docker.internal", c.LocalLLMTarget)
	}
}

func TestLoadConfig_MissingProxyIP(t *testing.T) {
	p := writeTemp(t, `{"allow": ["x.com"]}`)
	if _, err := LoadConfig(p); err == nil {
		t.Error("expected error for missing proxy_ip")
	}
}

func TestLoadConfig_BadJSON(t *testing.T) {
	p := writeTemp(t, `{not json`)
	if _, err := LoadConfig(p); err == nil {
		t.Error("expected parse error")
	}
}

func TestLoadConfig_Missing(t *testing.T) {
	if _, err := LoadConfig("/no/such/path.json"); err == nil {
		t.Error("expected error for missing file")
	}
}

func TestLoadConfig_ModeDefaultsStrict(t *testing.T) {
	p := writeTemp(t, `{"proxy_ip":"1.2.3.4","allow":["x.com"]}`)
	c, err := LoadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.Mode != modeStrict {
		t.Errorf("Mode = %q, want %q (fail-closed default)", c.Mode, modeStrict)
	}
}

func TestLoadConfig_ModePermissive(t *testing.T) {
	p := writeTemp(t, `{"proxy_ip":"1.2.3.4","mode":"permissive"}`)
	c, err := LoadConfig(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.Mode != modePermissive {
		t.Errorf("Mode = %q, want permissive", c.Mode)
	}
}

func TestLoadConfig_ModeInvalid(t *testing.T) {
	p := writeTemp(t, `{"proxy_ip":"1.2.3.4","mode":"yolo"}`)
	if _, err := LoadConfig(p); err == nil {
		t.Error("expected error for invalid mode")
	}
}
