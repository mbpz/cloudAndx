package main

import "testing"

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
