package main

import "time"

const (
	StateWaitingForRuntime = "WAITING_FOR_RUNTIME"
	StateRunning           = "RUNNING"
	StateUnhealthy         = "UNHEALTHY"
	StateExpired           = "EXPIRED"
	StateReleased          = "RELEASED"
)

type CreateSessionRequest struct {
	ClientReference       string   `json:"client_reference,omitempty"`
	LeaseSeconds          int      `json:"lease_seconds,omitempty"`
	RequestedCapabilities []string `json:"requested_capabilities,omitempty"`
}

type Session struct {
	ID                    string      `json:"id"`
	ClientReference       string      `json:"client_reference,omitempty"`
	RequestedCapabilities []string    `json:"requested_capabilities,omitempty"`
	State                 string      `json:"state"`
	LifecycleScope        string      `json:"lifecycle_scope"`
	RuntimeMode           string      `json:"runtime_mode"`
	CreatedAt             time.Time   `json:"created_at"`
	UpdatedAt             time.Time   `json:"updated_at"`
	ExpiresAt             time.Time   `json:"expires_at"`
	Probe                 ProbeResult `json:"probe"`
	IdempotencyKey        string      `json:"-"`
	RequestDigest         string      `json:"-"`
}

type persistedSession struct {
	ID                    string      `json:"id"`
	ClientReference       string      `json:"client_reference,omitempty"`
	RequestedCapabilities []string    `json:"requested_capabilities,omitempty"`
	State                 string      `json:"state"`
	LifecycleScope        string      `json:"lifecycle_scope"`
	RuntimeMode           string      `json:"runtime_mode"`
	CreatedAt             time.Time   `json:"created_at"`
	UpdatedAt             time.Time   `json:"updated_at"`
	ExpiresAt             time.Time   `json:"expires_at"`
	Probe                 ProbeResult `json:"probe"`
	IdempotencyKey        string      `json:"idempotency_key"`
	RequestDigest         string      `json:"request_digest"`
}

func (s Session) persisted() persistedSession {
	return persistedSession{
		ID: s.ID, ClientReference: s.ClientReference,
		RequestedCapabilities: append([]string(nil), s.RequestedCapabilities...),
		State:                 s.State, LifecycleScope: s.LifecycleScope, RuntimeMode: s.RuntimeMode,
		CreatedAt: s.CreatedAt, UpdatedAt: s.UpdatedAt, ExpiresAt: s.ExpiresAt,
		Probe: s.Probe, IdempotencyKey: s.IdempotencyKey, RequestDigest: s.RequestDigest,
	}
}

func (s persistedSession) session() Session {
	return Session{
		ID: s.ID, ClientReference: s.ClientReference,
		RequestedCapabilities: append([]string(nil), s.RequestedCapabilities...),
		State:                 s.State, LifecycleScope: s.LifecycleScope, RuntimeMode: s.RuntimeMode,
		CreatedAt: s.CreatedAt, UpdatedAt: s.UpdatedAt, ExpiresAt: s.ExpiresAt,
		Probe: s.Probe, IdempotencyKey: s.IdempotencyKey, RequestDigest: s.RequestDigest,
	}
}

type ProbeResult struct {
	Configured bool      `json:"configured"`
	Verified   bool      `json:"verified"`
	CheckedAt  time.Time `json:"checked_at"`
	Kind       string    `json:"kind"`
	Detail     string    `json:"detail"`
}

type probeEvidence struct {
	SessionID  string    `json:"session_id"`
	Healthy    bool      `json:"healthy"`
	ObservedAt time.Time `json:"observed_at"`
}

type stateFile struct {
	Version  int                `json:"version"`
	Sessions []persistedSession `json:"sessions"`
}

type APIError struct {
	Error ErrorDetail `json:"error"`
}

type ErrorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
