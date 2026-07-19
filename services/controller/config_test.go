package main

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestConfigFromEnvReportsRequiredFacts(t *testing.T) {
	t.Setenv("ANDROID_VERSION", "17")
	t.Setenv("API_LEVEL", "37")
	t.Setenv("SYSTEM_IMAGE_KIND", "google_apis_playstore")
	t.Setenv("KVM_AVAILABLE", "true")
	t.Setenv("RUNTIME_MODE", "external_emulator")
	t.Setenv("MAX_ACTIVE_SESSIONS", "2")
	t.Setenv("PREFLIGHT_EVIDENCE_FILE", "/evidence/preflight.json")
	t.Setenv("DATA_DIR", t.TempDir())

	cfg, err := ConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AndroidVersion != "17" || cfg.APILevel != 37 || !cfg.KVMAvailable || cfg.RuntimeMode != "external_emulator" || cfg.MaxActiveSessions != 2 || cfg.PreflightEvidenceFile != "/evidence/preflight.json" {
		t.Fatalf("config = %+v", cfg)
	}
}

func TestConfigRejectsUnsafeProbeTemplates(t *testing.T) {
	cfg := testConfig(t.TempDir())
	cfg.ProbeFileTemplate = "/proof/fixed.json"
	if err := cfg.Validate(); err == nil {
		t.Fatal("file template without {id} was accepted")
	}
	cfg.ProbeFileTemplate = ""
	cfg.ProbeURLTemplate = "file:///tmp/{id}.json"
	if err := cfg.Validate(); err == nil {
		t.Fatal("non-HTTP URL template was accepted")
	}
}

func TestConfigDerivesHTTPWriteTimeoutFromSlowProbe(t *testing.T) {
	t.Setenv("PROBE_TIMEOUT_MILLIS", "300000")
	t.Setenv("HTTP_WRITE_TIMEOUT_MILLIS", "")

	cfg, err := ConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := cfg.HTTPWriteTimeout, 305*time.Second; got != want {
		t.Fatalf("HTTP write timeout = %s, want %s", got, want)
	}
	server := newHTTPServer(cfg, http.NotFoundHandler())
	if server.WriteTimeout != cfg.HTTPWriteTimeout || server.WriteTimeout-cfg.ProbeTimeout < minimumHTTPWriteTimeoutHeadroom {
		t.Fatalf("server write timeout %s does not cover probe timeout %s", server.WriteTimeout, cfg.ProbeTimeout)
	}
}

func TestConfigRejectsHTTPWriteTimeoutWithoutProbeHeadroom(t *testing.T) {
	for name, writeTimeout := range map[string]string{
		"equal to probe":   "300000",
		"one ms too short": "304999",
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("PROBE_TIMEOUT_MILLIS", "300000")
			t.Setenv("HTTP_WRITE_TIMEOUT_MILLIS", writeTimeout)
			_, err := ConfigFromEnv()
			if err == nil || !strings.Contains(err.Error(), "HTTP_WRITE_TIMEOUT_MILLIS") {
				t.Fatalf("ConfigFromEnv() error = %v", err)
			}
		})
	}
}

func TestConfigRejectsMillisecondDurationOverflow(t *testing.T) {
	t.Setenv("PROBE_TIMEOUT_MILLIS", "9223372036855")
	_, err := ConfigFromEnv()
	if err == nil || !strings.Contains(err.Error(), "PROBE_TIMEOUT_MILLIS") {
		t.Fatalf("ConfigFromEnv() error = %v", err)
	}
}
