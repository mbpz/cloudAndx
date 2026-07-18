package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"
)

const maximumRequestBodyBytes = 8192

var (
	idempotencyKeyPattern  = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	clientReferencePattern = regexp.MustCompile(`^[A-Za-z0-9._:@/-]{0,128}$`)
	sessionIDPattern       = regexp.MustCompile(`^ses_[a-f0-9]{32}$`)
)

type App struct {
	cfg     Config
	store   *Store
	probe   *ProbeChecker
	metrics *Metrics
	now     func() time.Time
	newID   func() (string, error)
}

func NewApp(cfg Config, store *Store) *App {
	return &App{
		cfg: cfg, store: store, probe: NewProbeChecker(cfg), metrics: &Metrics{},
		now: func() time.Time { return time.Now().UTC() }, newID: generateSessionID,
	}
}

func (a *App) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
	defer a.metrics.HTTPRequests.Add(1)

	switch {
	case r.URL.Path == "/healthz":
		a.handleHealth(w, r)
	case r.URL.Path == "/readyz":
		a.handleReady(w, r)
	case r.URL.Path == "/v1/platform":
		a.handlePlatform(w, r)
	case r.URL.Path == "/v1/capabilities":
		a.handleCapabilities(w, r)
	case r.URL.Path == "/v1/sessions":
		a.handleSessions(w, r)
	case strings.HasPrefix(r.URL.Path, "/v1/sessions/"):
		a.handleSession(w, r)
	case r.URL.Path == "/metrics":
		a.handleMetrics(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "endpoint not found")
	}
}

func (a *App) handleHealth(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) || !requireNoQuery(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "alive"})
}

func (a *App) handleReady(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) || !requireNoQuery(w, r) {
		return
	}
	if err := a.store.CheckWritable(); err != nil {
		writeError(w, http.StatusServiceUnavailable, "storage_unavailable", "persistent state directory is not writable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready", "storage": "writable"})
}

func (a *App) handlePlatform(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) || !requireNoQuery(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, platformFromConfig(a.cfg))
}

func (a *App) handleCapabilities(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) || !requireNoQuery(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, capabilitiesFromConfig(a.cfg))
}

func (a *App) handleSessions(w http.ResponseWriter, r *http.Request) {
	if !requireNoQuery(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		sessions := a.store.List()
		for index := range sessions {
			refreshed, err := a.refreshSession(r.Context(), sessions[index])
			if err != nil {
				a.metrics.PersistFailures.Add(1)
				writeError(w, http.StatusInternalServerError, "state_persist_failed", "failed to update persistent session state")
				return
			}
			sessions[index] = refreshed
		}
		writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions, "count": len(sessions)})
	case http.MethodPost:
		a.createSession(w, r)
	default:
		w.Header().Set("Allow", "GET, POST")
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func (a *App) createSession(w http.ResponseWriter, r *http.Request) {
	if err := requireJSONContentType(r); err != nil {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", err.Error())
		return
	}
	idempotencyKey := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if !idempotencyKeyPattern.MatchString(idempotencyKey) {
		writeError(w, http.StatusBadRequest, "invalid_idempotency_key", "Idempotency-Key must contain 1-128 allowlisted characters")
		return
	}

	var request CreateSessionRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maximumRequestBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "body must be one JSON object using only allowlisted fields")
		return
	}
	if err := requireJSONEOF(decoder); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "body must contain exactly one JSON object")
		return
	}
	normalized, err := a.validateAndNormalizeRequest(request)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	digest, err := requestDigest(normalized)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "request_digest_failed", "failed to process request")
		return
	}
	id, err := a.newID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "id_generation_failed", "failed to generate session id")
		return
	}

	now := a.now()
	lease := time.Duration(normalized.LeaseSeconds) * time.Second
	probe := a.checkProbe(r.Context(), id)
	state := StateWaitingForRuntime
	if probe.Verified {
		state = StateRunning
	}
	session := Session{
		ID: id, ClientReference: normalized.ClientReference,
		RequestedCapabilities: append([]string(nil), normalized.RequestedCapabilities...),
		State:                 state, LifecycleScope: "lease_registry_only", RuntimeMode: a.cfg.RuntimeMode,
		CreatedAt: now, UpdatedAt: now, ExpiresAt: now.Add(lease), Probe: probe,
		IdempotencyKey: idempotencyKey, RequestDigest: digest,
	}
	stored, replayed, err := a.store.Create(session, a.cfg.MaxActiveSessions, now)
	if err != nil {
		if errors.Is(err, ErrCapacityExhausted) {
			a.metrics.CapacityRejections.Add(1)
			writeError(w, http.StatusConflict, "capacity_exhausted", "maximum active session capacity has been reached")
			return
		}
		var conflict *IdempotencyConflictError
		if errors.As(err, &conflict) {
			writeError(w, http.StatusConflict, "idempotency_conflict", "Idempotency-Key was already used with a different request")
			return
		}
		a.metrics.PersistFailures.Add(1)
		writeError(w, http.StatusInternalServerError, "state_persist_failed", "failed to persist session state")
		return
	}
	if replayed {
		a.metrics.IdempotentHits.Add(1)
		stored, err = a.refreshSession(r.Context(), stored)
		if err != nil {
			a.metrics.PersistFailures.Add(1)
			writeError(w, http.StatusInternalServerError, "state_persist_failed", "failed to update persistent session state")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"session": stored, "replayed": true})
		return
	}
	a.metrics.CreatedSessions.Add(1)
	writeJSON(w, http.StatusCreated, map[string]any{"session": stored, "replayed": false})
}

func (a *App) handleSession(w http.ResponseWriter, r *http.Request) {
	if !requireNoQuery(w, r) {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/v1/sessions/")
	if !sessionIDPattern.MatchString(id) {
		writeError(w, http.StatusNotFound, "not_found", "session not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		session, err := a.store.Get(id)
		if errors.Is(err, ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "session not found")
			return
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, "state_read_failed", "failed to read session state")
			return
		}
		session, err = a.refreshSession(r.Context(), session)
		if err != nil {
			a.metrics.PersistFailures.Add(1)
			writeError(w, http.StatusInternalServerError, "state_persist_failed", "failed to update persistent session state")
			return
		}
		writeJSON(w, http.StatusOK, session)
	case http.MethodDelete:
		if !requestBodyEmpty(r) {
			writeError(w, http.StatusBadRequest, "unexpected_body", "DELETE does not accept a request body")
			return
		}
		session, err := a.store.Release(id, a.now())
		if errors.Is(err, ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "session not found")
			return
		}
		if err != nil {
			a.metrics.PersistFailures.Add(1)
			writeError(w, http.StatusInternalServerError, "state_persist_failed", "failed to persist released lease")
			return
		}
		writeJSON(w, http.StatusOK, session)
	default:
		w.Header().Set("Allow", "GET, DELETE")
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func (a *App) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) || !requireNoQuery(w, r) {
		return
	}
	total, active, running := a.store.Counts()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintf(w, "# TYPE controller_up gauge\ncontroller_up 1\n")
	_, _ = fmt.Fprintf(w, "# TYPE controller_http_requests_total counter\ncontroller_http_requests_total %d\n", a.metrics.HTTPRequests.Load())
	_, _ = fmt.Fprintf(w, "# TYPE controller_sessions_created_total counter\ncontroller_sessions_created_total %d\n", a.metrics.CreatedSessions.Load())
	_, _ = fmt.Fprintf(w, "# TYPE controller_idempotent_replays_total counter\ncontroller_idempotent_replays_total %d\n", a.metrics.IdempotentHits.Load())
	_, _ = fmt.Fprintf(w, "# TYPE controller_probe_checks_total counter\ncontroller_probe_checks_total %d\n", a.metrics.ProbeChecks.Load())
	_, _ = fmt.Fprintf(w, "# TYPE controller_probe_failures_total counter\ncontroller_probe_failures_total %d\n", a.metrics.ProbeFailures.Load())
	_, _ = fmt.Fprintf(w, "# TYPE controller_state_persist_failures_total counter\ncontroller_state_persist_failures_total %d\n", a.metrics.PersistFailures.Load())
	_, _ = fmt.Fprintf(w, "# TYPE controller_capacity_rejections_total counter\ncontroller_capacity_rejections_total %d\n", a.metrics.CapacityRejections.Load())
	_, _ = fmt.Fprintf(w, "# TYPE controller_sessions gauge\ncontroller_sessions %d\n", total)
	_, _ = fmt.Fprintf(w, "# TYPE controller_sessions_active gauge\ncontroller_sessions_active %d\n", active)
	_, _ = fmt.Fprintf(w, "# TYPE controller_sessions_running gauge\ncontroller_sessions_running %d\n", running)
}

func (a *App) refreshSession(ctx context.Context, session Session) (Session, error) {
	if session.State == StateReleased || session.State == StateExpired {
		return session, nil
	}
	probe := a.checkProbe(ctx, session.ID)
	return a.store.UpdateState(session.ID, a.now(), probe)
}

func (a *App) checkProbe(ctx context.Context, id string) ProbeResult {
	a.metrics.ProbeChecks.Add(1)
	result := a.probe.Check(ctx, id)
	if !result.Verified {
		a.metrics.ProbeFailures.Add(1)
	}
	return result
}

func (a *App) validateAndNormalizeRequest(request CreateSessionRequest) (CreateSessionRequest, error) {
	if !clientReferencePattern.MatchString(request.ClientReference) {
		return CreateSessionRequest{}, fmt.Errorf("client_reference contains unsupported characters or exceeds 128 characters")
	}
	if request.LeaseSeconds == 0 {
		request.LeaseSeconds = int(a.cfg.DefaultLease.Seconds())
	}
	lease := time.Duration(request.LeaseSeconds) * time.Second
	if lease < a.cfg.MinimumLease || lease > a.cfg.MaximumLease {
		return CreateSessionRequest{}, fmt.Errorf("lease_seconds must be between %d and %d", int(a.cfg.MinimumLease.Seconds()), int(a.cfg.MaximumLease.Seconds()))
	}
	if len(request.RequestedCapabilities) > len(knownCapabilities) {
		return CreateSessionRequest{}, fmt.Errorf("too many requested_capabilities")
	}
	seen := make(map[string]struct{}, len(request.RequestedCapabilities))
	for _, capability := range request.RequestedCapabilities {
		if _, ok := knownCapabilities[capability]; !ok {
			return CreateSessionRequest{}, fmt.Errorf("requested_capabilities contains unknown value %q", capability)
		}
		if _, duplicate := seen[capability]; duplicate {
			return CreateSessionRequest{}, fmt.Errorf("requested_capabilities contains duplicate value %q", capability)
		}
		seen[capability] = struct{}{}
	}
	sort.Strings(request.RequestedCapabilities)
	return request, nil
}

func requestDigest(request CreateSessionRequest) (string, error) {
	payload, err := json.Marshal(request)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(payload)
	return hex.EncodeToString(digest[:]), nil
}

func generateSessionID() (string, error) {
	random := make([]byte, 16)
	if _, err := rand.Read(random); err != nil {
		return "", err
	}
	return "ses_" + hex.EncodeToString(random), nil
}

func requireMethod(w http.ResponseWriter, r *http.Request, method string) bool {
	if r.Method == method {
		return true
	}
	w.Header().Set("Allow", method)
	writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	return false
}

func requireNoQuery(w http.ResponseWriter, r *http.Request) bool {
	if r.URL.RawQuery == "" {
		return true
	}
	writeError(w, http.StatusBadRequest, "unexpected_query", "query parameters are not supported")
	return false
}

func requireJSONContentType(r *http.Request) error {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return fmt.Errorf("Content-Type must be application/json")
	}
	return nil
}

func requestBodyEmpty(r *http.Request) bool {
	if r.Body == nil {
		return true
	}
	data, err := io.ReadAll(io.LimitReader(r.Body, 1))
	return err == nil && len(data) == 0
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, APIError{Error: ErrorDetail{Code: code, Message: message}})
}
