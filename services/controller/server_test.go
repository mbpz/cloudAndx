package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testSessionID = "ses_0123456789abcdef0123456789abcdef"

func testConfig(dataDir string) Config {
	return Config{
		ListenAddress: ":8080", DataDir: dataDir,
		AndroidVersion: "17", APILevel: 37,
		SystemImageKind: "google_apis_playstore_ps16k",
		KVMAvailable:    false, RuntimeMode: "registry_only", MaxActiveSessions: 1,
		ProbeMaxAge: 30 * time.Second, ProbeTimeout: time.Second,
		MinimumLease: time.Minute, DefaultLease: time.Hour, MaximumLease: 24 * time.Hour,
	}
}

func TestBothGooglePlayImageFamilyValuesReportHighFidelity(t *testing.T) {
	for _, imageKind := range []string{"google_apis_playstore_ps16k", "google_apis_playstore"} {
		t.Run(imageKind, func(t *testing.T) {
			cfg := testConfig(t.TempDir())
			cfg.SystemImageKind = imageKind
			response := capabilitiesFromConfig(cfg)
			statuses := make(map[string]string)
			for _, capability := range response.Capabilities {
				statuses[capability.ID] = capability.Status
			}
			if got := statuses["google_play_store"]; got != CapabilityHighFidelity {
				t.Fatalf("google_play_store status = %q, want %q", got, CapabilityHighFidelity)
			}
			if got := statuses["google_mobile_services"]; got != CapabilityHighFidelity {
				t.Fatalf("google_mobile_services status = %q, want %q", got, CapabilityHighFidelity)
			}
		})
	}
}

func newTestApp(t *testing.T, mutate func(*Config)) (*App, time.Time) {
	t.Helper()
	cfg := testConfig(t.TempDir())
	if mutate != nil {
		mutate(&cfg)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("config validation failed: %v", err)
	}
	store, err := NewStore(cfg.DataDir)
	if err != nil {
		t.Fatalf("NewStore() error = %v", err)
	}
	app := NewApp(cfg, store)
	now := time.Date(2026, 7, 18, 8, 0, 0, 0, time.UTC)
	app.now = func() time.Time { return now }
	app.probe.now = func() time.Time { return now }
	app.newID = func() (string, error) { return testSessionID, nil }
	return app, now
}

func performRequest(app http.Handler, method, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response := httptest.NewRecorder()
	app.ServeHTTP(response, request)
	return response
}

func createHeaders(key string) map[string]string {
	return map[string]string{"Content-Type": "application/json", "Idempotency-Key": key}
}

func decodeSessionEnvelope(t *testing.T, response *httptest.ResponseRecorder) (Session, bool) {
	t.Helper()
	var envelope struct {
		Session  Session `json:"session"`
		Replayed bool    `json:"replayed"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("decode response %q: %v", response.Body.String(), err)
	}
	return envelope.Session, envelope.Replayed
}

func TestSessionNeverRunsWithoutVerifiedProbe(t *testing.T) {
	app, _ := newTestApp(t, nil)
	response := performRequest(app, http.MethodPost, "/v1/sessions", `{}`, createHeaders("request-1"))
	if response.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, body = %s", response.Code, response.Body.String())
	}
	session, replayed := decodeSessionEnvelope(t, response)
	if replayed {
		t.Fatal("new session was reported as replayed")
	}
	if session.State != StateWaitingForRuntime {
		t.Fatalf("state = %q, want %q", session.State, StateWaitingForRuntime)
	}
	if session.Probe.Configured || session.Probe.Verified {
		t.Fatalf("unexpected probe result: %+v", session.Probe)
	}
	if session.LifecycleScope != "lease_registry_only" {
		t.Fatalf("lifecycle scope = %q", session.LifecycleScope)
	}

	response = performRequest(app, http.MethodGet, "/v1/sessions/"+testSessionID, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("GET status = %d, body = %s", response.Code, response.Body.String())
	}
	if err := json.Unmarshal(response.Body.Bytes(), &session); err != nil {
		t.Fatal(err)
	}
	if session.State == StateRunning {
		t.Fatal("session became RUNNING without external proof")
	}
}

func TestFreshMatchingFileProbeAllowsRunningAndLossBecomesUnhealthy(t *testing.T) {
	proofDir := t.TempDir()
	app, now := newTestApp(t, func(cfg *Config) {
		cfg.ProbeFileTemplate = filepath.Join(proofDir, "{id}.json")
	})
	evidence := fmt.Sprintf(`{"session_id":%q,"healthy":true,"observed_at":%q}`, testSessionID, now.Format(time.RFC3339))
	proofPath := filepath.Join(proofDir, testSessionID+".json")
	if err := os.WriteFile(proofPath, []byte(evidence), 0o600); err != nil {
		t.Fatal(err)
	}

	response := performRequest(app, http.MethodPost, "/v1/sessions", `{}`, createHeaders("request-2"))
	session, _ := decodeSessionEnvelope(t, response)
	if session.State != StateRunning || !session.Probe.Verified {
		t.Fatalf("fresh proof result = %+v", session)
	}
	if err := os.Remove(proofPath); err != nil {
		t.Fatal(err)
	}
	response = performRequest(app, http.MethodGet, "/v1/sessions/"+testSessionID, "", nil)
	if err := json.Unmarshal(response.Body.Bytes(), &session); err != nil {
		t.Fatal(err)
	}
	if session.State != StateUnhealthy || session.Probe.Verified {
		t.Fatalf("state after proof loss = %+v", session)
	}
}

func TestStaleOrMismatchedEvidenceIsRejected(t *testing.T) {
	app, now := newTestApp(t, nil)
	checker := app.probe
	checker.fileTemplate = filepath.Join(t.TempDir(), "{id}.json")
	path := strings.ReplaceAll(checker.fileTemplate, "{id}", testSessionID)

	for name, evidence := range map[string]probeEvidence{
		"stale":      {SessionID: testSessionID, Healthy: true, ObservedAt: now.Add(-time.Minute)},
		"mismatched": {SessionID: "ses_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Healthy: true, ObservedAt: now},
		"unhealthy":  {SessionID: testSessionID, Healthy: false, ObservedAt: now},
	} {
		t.Run(name, func(t *testing.T) {
			payload, _ := json.Marshal(evidence)
			if err := os.WriteFile(path, payload, 0o600); err != nil {
				t.Fatal(err)
			}
			result := checker.Check(context.Background(), testSessionID)
			if result.Verified {
				t.Fatalf("evidence unexpectedly verified: %+v", result)
			}
		})
	}
}

func TestURLProbeRequiresStrictFreshEvidence(t *testing.T) {
	now := time.Date(2026, 7, 18, 8, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/sessions/"+testSessionID+"/healthz" {
			http.NotFound(w, r)
			return
		}
		writeJSON(w, http.StatusOK, probeEvidence{SessionID: testSessionID, Healthy: true, ObservedAt: now})
	}))
	defer server.Close()

	app, _ := newTestApp(t, func(cfg *Config) {
		cfg.ProbeURLTemplate = server.URL + "/sessions/{id}/healthz"
	})
	app.probe.now = func() time.Time { return now }
	result := app.probe.Check(context.Background(), testSessionID)
	if !result.Verified || result.Kind != "url" {
		t.Fatalf("URL probe result = %+v", result)
	}
}

func TestCreateIsStrictAndIdempotent(t *testing.T) {
	app, _ := newTestApp(t, nil)
	headers := createHeaders("same-key")
	body := `{"client_reference":"client-1","lease_seconds":3600,"requested_capabilities":["google_play_store","android_framework"]}`
	first := performRequest(app, http.MethodPost, "/v1/sessions", body, headers)
	if first.Code != http.StatusCreated {
		t.Fatalf("first POST status = %d, body = %s", first.Code, first.Body.String())
	}
	firstSession, _ := decodeSessionEnvelope(t, first)

	second := performRequest(app, http.MethodPost, "/v1/sessions", body, headers)
	if second.Code != http.StatusOK {
		t.Fatalf("replay POST status = %d, body = %s", second.Code, second.Body.String())
	}
	secondSession, replayed := decodeSessionEnvelope(t, second)
	if !replayed || secondSession.ID != firstSession.ID {
		t.Fatalf("idempotent replay = %+v, replayed=%v", secondSession, replayed)
	}

	conflict := performRequest(app, http.MethodPost, "/v1/sessions", `{"lease_seconds":7200}`, headers)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("conflict status = %d, body = %s", conflict.Code, conflict.Body.String())
	}

	unknown := performRequest(app, http.MethodPost, "/v1/sessions", `{"image":"arbitrary"}`, createHeaders("unknown-field"))
	if unknown.Code != http.StatusBadRequest {
		t.Fatalf("unknown field status = %d, body = %s", unknown.Code, unknown.Body.String())
	}

	missingKey := performRequest(app, http.MethodPost, "/v1/sessions", `{}`, map[string]string{"Content-Type": "application/json"})
	if missingKey.Code != http.StatusBadRequest {
		t.Fatalf("missing key status = %d", missingKey.Code)
	}
}

func TestActiveSessionCapacityRejectsNewLeaseButAllowsReplay(t *testing.T) {
	app, _ := newTestApp(t, nil)
	body := `{"client_reference":"only-slot"}`
	first := performRequest(app, http.MethodPost, "/v1/sessions", body, createHeaders("capacity-first"))
	if first.Code != http.StatusCreated {
		t.Fatalf("first status = %d, body = %s", first.Code, first.Body.String())
	}

	replay := performRequest(app, http.MethodPost, "/v1/sessions", body, createHeaders("capacity-first"))
	if replay.Code != http.StatusOK {
		t.Fatalf("replay status = %d, body = %s", replay.Code, replay.Body.String())
	}

	second := performRequest(app, http.MethodPost, "/v1/sessions", `{"client_reference":"second"}`, createHeaders("capacity-second"))
	if second.Code != http.StatusConflict || !strings.Contains(second.Body.String(), `"capacity_exhausted"`) {
		t.Fatalf("second status = %d, body = %s", second.Code, second.Body.String())
	}
}

func TestReleaseDoesNotClaimRuntimeTermination(t *testing.T) {
	app, _ := newTestApp(t, nil)
	performRequest(app, http.MethodPost, "/v1/sessions", `{}`, createHeaders("release-key"))
	response := performRequest(app, http.MethodDelete, "/v1/sessions/"+testSessionID, "", nil)
	if response.Code != http.StatusOK {
		t.Fatalf("DELETE status = %d, body = %s", response.Code, response.Body.String())
	}
	var session Session
	if err := json.Unmarshal(response.Body.Bytes(), &session); err != nil {
		t.Fatal(err)
	}
	if session.State != StateReleased || !strings.Contains(session.Probe.Detail, "no runtime stop action") {
		t.Fatalf("release response = %+v", session)
	}

	withBody := performRequest(app, http.MethodDelete, "/v1/sessions/"+testSessionID, `{}`, nil)
	if withBody.Code != http.StatusBadRequest {
		t.Fatalf("DELETE with body status = %d", withBody.Code)
	}
}

func TestLeaseExpires(t *testing.T) {
	app, now := newTestApp(t, nil)
	performRequest(app, http.MethodPost, "/v1/sessions", `{"lease_seconds":60}`, createHeaders("expiry-key"))
	advanced := now.Add(61 * time.Second)
	app.now = func() time.Time { return advanced }
	app.probe.now = func() time.Time { return advanced }

	response := performRequest(app, http.MethodGet, "/v1/sessions/"+testSessionID, "", nil)
	var session Session
	if err := json.Unmarshal(response.Body.Bytes(), &session); err != nil {
		t.Fatal(err)
	}
	if session.State != StateExpired {
		t.Fatalf("state = %q, want EXPIRED", session.State)
	}
}

func TestPlatformCapabilitiesAndMetricsReportFacts(t *testing.T) {
	app, _ := newTestApp(t, nil)
	platformResponse := performRequest(app, http.MethodGet, "/v1/platform", "", nil)
	var platform PlatformResponse
	if err := json.Unmarshal(platformResponse.Body.Bytes(), &platform); err != nil {
		t.Fatal(err)
	}
	if platform.AndroidVersion != "17" || platform.APILevel != 37 || platform.KVMAvailable || platform.RuntimeManaged || platform.MaxActiveSessions != 1 || platform.EvidenceStatus != "unavailable" {
		t.Fatalf("platform = %+v", platform)
	}

	capabilityResponse := performRequest(app, http.MethodGet, "/v1/capabilities", "", nil)
	var capabilities CapabilitiesResponse
	if err := json.Unmarshal(capabilityResponse.Body.Bytes(), &capabilities); err != nil {
		t.Fatal(err)
	}
	statuses := make(map[string]string)
	for _, capability := range capabilities.Capabilities {
		statuses[capability.ID] = capability.Status
	}
	for id, want := range map[string]string{
		"google_play_store":     CapabilityHighFidelity,
		"telephony":             CapabilitySimulated,
		"hardware_acceleration": CapabilityBlocked,
		"strongbox":             CapabilityBlocked,
	} {
		if statuses[id] != want {
			t.Errorf("capability %s status = %q, want %q", id, statuses[id], want)
		}
	}

	metrics := performRequest(app, http.MethodGet, "/metrics", "", nil)
	if metrics.Code != http.StatusOK || !strings.Contains(metrics.Body.String(), "controller_sessions_running 0") {
		t.Fatalf("metrics = %d %s", metrics.Code, metrics.Body.String())
	}
}

func TestPlatformReadsPreflightEvidenceWithoutAffectingHealth(t *testing.T) {
	for name, test := range map[string]struct {
		body string
		want string
	}{
		"status":        {body: `{"status":"PASS","checks":[]}`, want: "PASS"},
		"gate state":    {body: `{"state":"KVM_READY","ready":true}`, want: "KVM_READY"},
		"non string":    {body: `{"status":true}`, want: "unavailable"},
		"unknown value": {body: `{"status":"MAYBE"}`, want: "unavailable"},
		"malformed":     {body: `{"status":`, want: "unavailable"},
		"missing":       {body: `{"ready":true}`, want: "unavailable"},
		"duplicate":     {body: `{"status":"PASS","status":"FAIL"}`, want: "unavailable"},
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "preflight.json")
			if err := os.WriteFile(path, []byte(test.body), 0o600); err != nil {
				t.Fatal(err)
			}
			app, _ := newTestApp(t, func(cfg *Config) { cfg.PreflightEvidenceFile = path })
			response := performRequest(app, http.MethodGet, "/v1/platform", "", nil)
			var platform PlatformResponse
			if err := json.Unmarshal(response.Body.Bytes(), &platform); err != nil {
				t.Fatal(err)
			}
			if platform.EvidenceStatus != test.want {
				t.Fatalf("evidence_status = %q, want %q", platform.EvidenceStatus, test.want)
			}
			health := performRequest(app, http.MethodGet, "/healthz", "", nil)
			if health.Code != http.StatusOK {
				t.Fatalf("health status = %d", health.Code)
			}
		})
	}
}

func TestHealthReadyMethodsAndQueriesAreStrict(t *testing.T) {
	app, _ := newTestApp(t, nil)
	for _, path := range []string{"/healthz", "/readyz"} {
		response := performRequest(app, http.MethodGet, path, "", nil)
		if response.Code != http.StatusOK {
			t.Errorf("GET %s status = %d", path, response.Code)
		}
	}
	wrongMethod := performRequest(app, http.MethodPost, "/healthz", "", nil)
	if wrongMethod.Code != http.StatusMethodNotAllowed {
		t.Fatalf("wrong method status = %d", wrongMethod.Code)
	}
	query := performRequest(app, http.MethodGet, "/v1/sessions?state=RUNNING", "", nil)
	if query.Code != http.StatusBadRequest {
		t.Fatalf("query status = %d", query.Code)
	}
}

func TestStatePersistsAcrossStoreRestart(t *testing.T) {
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 18, 8, 0, 0, 0, time.UTC)
	session := Session{
		ID: testSessionID, State: StateWaitingForRuntime,
		LifecycleScope: "lease_registry_only", RuntimeMode: "registry_only",
		CreatedAt: now, UpdatedAt: now, ExpiresAt: now.Add(time.Hour),
		IdempotencyKey: "persist-key", RequestDigest: strings.Repeat("a", 64),
	}
	if _, _, err := store.Create(session, 1, now); err != nil {
		t.Fatal(err)
	}

	reloaded, err := NewStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := reloaded.Get(testSessionID)
	if err != nil {
		t.Fatal(err)
	}
	if got.IdempotencyKey != "persist-key" || got.State != StateWaitingForRuntime {
		t.Fatalf("reloaded session = %+v", got)
	}

	data, err := os.ReadFile(filepath.Join(dir, "sessions.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte(`"version": 1`)) {
		t.Fatalf("state file missing version: %s", data)
	}
}

func TestRequestBodySizeIsBounded(t *testing.T) {
	app, _ := newTestApp(t, nil)
	large := `{"client_reference":"` + strings.Repeat("x", maximumRequestBodyBytes) + `"}`
	response := performRequest(app, http.MethodPost, "/v1/sessions", large, createHeaders("large-body"))
	if response.Code != http.StatusBadRequest {
		t.Fatalf("large body status = %d", response.Code)
	}
}

func TestJSONResponseDoesNotExposeIdempotencyKeyOrDigest(t *testing.T) {
	app, _ := newTestApp(t, nil)
	response := performRequest(app, http.MethodPost, "/v1/sessions", `{}`, createHeaders("secret-key"))
	payload, err := io.ReadAll(response.Result().Body)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(payload, []byte("secret-key")) || bytes.Contains(payload, []byte("request_digest")) {
		t.Fatalf("internal idempotency fields leaked: %s", payload)
	}
}
