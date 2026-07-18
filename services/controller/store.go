package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

var ErrNotFound = errors.New("session not found")
var ErrCapacityExhausted = errors.New("active session capacity is exhausted")

type IdempotencyConflictError struct {
	SessionID string
}

func (e *IdempotencyConflictError) Error() string {
	return "idempotency key was already used with a different request"
}

type Store struct {
	mu        sync.RWMutex
	dataDir   string
	statePath string
	sessions  map[string]Session
	keyToID   map[string]string
}

func NewStore(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o750); err != nil {
		return nil, fmt.Errorf("create data directory: %w", err)
	}
	s := &Store{
		dataDir: dataDir, statePath: filepath.Join(dataDir, "sessions.json"),
		sessions: make(map[string]Session), keyToID: make(map[string]string),
	}
	if err := s.load(); err != nil {
		return nil, err
	}
	if err := s.CheckWritable(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) load() error {
	data, err := os.ReadFile(s.statePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read state: %w", err)
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return fmt.Errorf("state file is empty")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var persisted stateFile
	if err := decoder.Decode(&persisted); err != nil {
		return fmt.Errorf("decode state: %w", err)
	}
	if err := requireJSONEOF(decoder); err != nil {
		return fmt.Errorf("decode state: %w", err)
	}
	if persisted.Version != 1 {
		return fmt.Errorf("unsupported state version %d", persisted.Version)
	}
	for _, item := range persisted.Sessions {
		session := item.session()
		if session.ID == "" || session.IdempotencyKey == "" || session.RequestDigest == "" {
			return fmt.Errorf("state contains an incomplete session")
		}
		if _, exists := s.sessions[session.ID]; exists {
			return fmt.Errorf("state contains duplicate session id %q", session.ID)
		}
		if _, exists := s.keyToID[session.IdempotencyKey]; exists {
			return fmt.Errorf("state contains duplicate idempotency key")
		}
		s.sessions[session.ID] = session
		s.keyToID[session.IdempotencyKey] = session.ID
	}
	return nil
}

func (s *Store) Create(session Session, maxActive int, now time.Time) (Session, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if existingID, ok := s.keyToID[session.IdempotencyKey]; ok {
		existing := s.sessions[existingID]
		if existing.RequestDigest != session.RequestDigest {
			return Session{}, false, &IdempotencyConflictError{SessionID: existingID}
		}
		return cloneSession(existing), true, nil
	}
	active := 0
	for _, existing := range s.sessions {
		isActiveState := existing.State == StateWaitingForRuntime || existing.State == StateRunning || existing.State == StateUnhealthy
		if isActiveState && now.Before(existing.ExpiresAt) {
			active++
		}
	}
	if active >= maxActive {
		return Session{}, false, ErrCapacityExhausted
	}
	if _, exists := s.sessions[session.ID]; exists {
		return Session{}, false, fmt.Errorf("generated duplicate session id")
	}

	s.sessions[session.ID] = cloneSession(session)
	s.keyToID[session.IdempotencyKey] = session.ID
	if err := s.persistLocked(); err != nil {
		delete(s.sessions, session.ID)
		delete(s.keyToID, session.IdempotencyKey)
		return Session{}, false, err
	}
	return cloneSession(session), false, nil
}

func (s *Store) Get(id string) (Session, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	session, ok := s.sessions[id]
	if !ok {
		return Session{}, ErrNotFound
	}
	return cloneSession(session), nil
}

func (s *Store) List() []Session {
	s.mu.RLock()
	defer s.mu.RUnlock()
	items := make([]Session, 0, len(s.sessions))
	for _, session := range s.sessions {
		items = append(items, cloneSession(session))
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].CreatedAt.Equal(items[j].CreatedAt) {
			return items[i].ID < items[j].ID
		}
		return items[i].CreatedAt.Before(items[j].CreatedAt)
	})
	return items
}

func (s *Store) UpdateState(id string, now time.Time, probe ProbeResult) (Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, ok := s.sessions[id]
	if !ok {
		return Session{}, ErrNotFound
	}
	if session.State == StateReleased || session.State == StateExpired {
		return cloneSession(session), nil
	}

	previous := cloneSession(session)
	if !now.Before(session.ExpiresAt) {
		session.State = StateExpired
		session.Probe = ProbeResult{Configured: probe.Configured, Verified: false, CheckedAt: now, Kind: probe.Kind, Detail: "lease expired"}
	} else {
		session.Probe = probe
		if probe.Verified {
			session.State = StateRunning
		} else if session.State == StateRunning || session.State == StateUnhealthy {
			session.State = StateUnhealthy
		} else {
			session.State = StateWaitingForRuntime
		}
	}
	session.UpdatedAt = now
	s.sessions[id] = session
	if err := s.persistLocked(); err != nil {
		s.sessions[id] = previous
		return Session{}, err
	}
	return cloneSession(session), nil
}

func (s *Store) Release(id string, now time.Time) (Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	session, ok := s.sessions[id]
	if !ok {
		return Session{}, ErrNotFound
	}
	if session.State == StateReleased {
		return cloneSession(session), nil
	}
	previous := cloneSession(session)
	session.State = StateReleased
	session.UpdatedAt = now
	session.Probe.Verified = false
	session.Probe.CheckedAt = now
	session.Probe.Detail = "lease released; controller performed no runtime stop action"
	s.sessions[id] = session
	if err := s.persistLocked(); err != nil {
		s.sessions[id] = previous
		return Session{}, err
	}
	return cloneSession(session), nil
}

func (s *Store) Counts() (total, active, running int) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, session := range s.sessions {
		total++
		switch session.State {
		case StateWaitingForRuntime, StateRunning, StateUnhealthy:
			active++
		}
		if session.State == StateRunning {
			running++
		}
	}
	return total, active, running
}

func (s *Store) CheckWritable() error {
	file, err := os.CreateTemp(s.dataDir, ".ready-*")
	if err != nil {
		return fmt.Errorf("data directory is not writable: %w", err)
	}
	name := file.Name()
	if err := file.Close(); err != nil {
		_ = os.Remove(name)
		return fmt.Errorf("close readiness file: %w", err)
	}
	if err := os.Remove(name); err != nil {
		return fmt.Errorf("remove readiness file: %w", err)
	}
	return nil
}

func (s *Store) persistLocked() error {
	items := make([]persistedSession, 0, len(s.sessions))
	for _, session := range s.sessions {
		items = append(items, session.persisted())
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ID < items[j].ID })
	payload, err := json.MarshalIndent(stateFile{Version: 1, Sessions: items}, "", "  ")
	if err != nil {
		return fmt.Errorf("encode state: %w", err)
	}
	payload = append(payload, '\n')

	temporary, err := os.CreateTemp(s.dataDir, ".sessions-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary state: %w", err)
	}
	temporaryName := temporary.Name()
	cleanup := func() {
		_ = temporary.Close()
		_ = os.Remove(temporaryName)
	}
	if err := temporary.Chmod(0o600); err != nil {
		cleanup()
		return fmt.Errorf("set state permissions: %w", err)
	}
	if _, err := temporary.Write(payload); err != nil {
		cleanup()
		return fmt.Errorf("write state: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		cleanup()
		return fmt.Errorf("sync state: %w", err)
	}
	if err := temporary.Close(); err != nil {
		_ = os.Remove(temporaryName)
		return fmt.Errorf("close state: %w", err)
	}
	if err := os.Rename(temporaryName, s.statePath); err != nil {
		_ = os.Remove(temporaryName)
		return fmt.Errorf("replace state: %w", err)
	}
	return nil
}

func cloneSession(session Session) Session {
	copy := session
	copy.RequestedCapabilities = append([]string(nil), session.RequestedCapabilities...)
	return copy
}

func requireJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return fmt.Errorf("request must contain exactly one JSON value")
		}
		return err
	}
	return nil
}
