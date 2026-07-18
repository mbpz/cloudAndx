package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const maximumProbeBodyBytes = 4096

type ProbeChecker struct {
	fileTemplate string
	urlTemplate  string
	maxAge       time.Duration
	client       *http.Client
	now          func() time.Time
}

func NewProbeChecker(cfg Config) *ProbeChecker {
	return &ProbeChecker{
		fileTemplate: cfg.ProbeFileTemplate,
		urlTemplate:  cfg.ProbeURLTemplate,
		maxAge:       cfg.ProbeMaxAge,
		client:       &http.Client{Timeout: cfg.ProbeTimeout},
		now:          func() time.Time { return time.Now().UTC() },
	}
}

func (p *ProbeChecker) Check(ctx context.Context, sessionID string) ProbeResult {
	now := p.now()
	configured := p.fileTemplate != "" || p.urlTemplate != ""
	if !configured {
		return ProbeResult{Configured: false, Verified: false, CheckedAt: now, Kind: "none", Detail: "no external emulator health probe is configured"}
	}

	kinds := make([]string, 0, 2)
	if p.fileTemplate != "" {
		kinds = append(kinds, "file")
		path := strings.ReplaceAll(p.fileTemplate, "{id}", sessionID)
		body, err := readLimitedFile(path, maximumProbeBodyBytes)
		if err != nil {
			return ProbeResult{Configured: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: "file probe failed: " + safeProbeError(err)}
		}
		if err := p.validateEvidence(body, sessionID, now); err != nil {
			return ProbeResult{Configured: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: "file probe rejected: " + safeProbeError(err)}
		}
	}

	if p.urlTemplate != "" {
		kinds = append(kinds, "url")
		probeURL := strings.ReplaceAll(p.urlTemplate, "{id}", sessionID)
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, probeURL, nil)
		if err != nil {
			return ProbeResult{Configured: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: "URL probe request failed"}
		}
		request.Header.Set("Accept", "application/json")
		response, err := p.client.Do(request)
		if err != nil {
			return ProbeResult{Configured: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: "URL probe failed: " + safeProbeError(err)}
		}
		body, readErr := io.ReadAll(io.LimitReader(response.Body, maximumProbeBodyBytes+1))
		closeErr := response.Body.Close()
		if readErr != nil || closeErr != nil || len(body) > maximumProbeBodyBytes {
			return ProbeResult{Configured: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: "URL probe returned an unreadable or oversized body"}
		}
		if response.StatusCode != http.StatusOK {
			return ProbeResult{Configured: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: fmt.Sprintf("URL probe returned HTTP %d", response.StatusCode)}
		}
		if err := p.validateEvidence(body, sessionID, now); err != nil {
			return ProbeResult{Configured: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: "URL probe rejected: " + safeProbeError(err)}
		}
	}

	return ProbeResult{Configured: true, Verified: true, CheckedAt: now, Kind: strings.Join(kinds, "+"), Detail: "all configured external probes supplied fresh matching health evidence"}
}

func (p *ProbeChecker) validateEvidence(body []byte, sessionID string, now time.Time) error {
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var evidence probeEvidence
	if err := decoder.Decode(&evidence); err != nil {
		return fmt.Errorf("invalid JSON evidence")
	}
	if err := requireJSONEOF(decoder); err != nil {
		return fmt.Errorf("invalid trailing JSON data")
	}
	if evidence.SessionID != sessionID {
		return fmt.Errorf("session_id does not match")
	}
	if !evidence.Healthy {
		return fmt.Errorf("healthy is false")
	}
	if evidence.ObservedAt.IsZero() {
		return fmt.Errorf("observed_at is required")
	}
	if evidence.ObservedAt.After(now.Add(5 * time.Second)) {
		return fmt.Errorf("observed_at is in the future")
	}
	if now.Sub(evidence.ObservedAt) > p.maxAge {
		return fmt.Errorf("evidence is stale")
	}
	return nil
}

func readLimitedFile(path string, maximum int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil {
		return nil, err
	}
	if len(body) > int(maximum) {
		return nil, fmt.Errorf("evidence exceeds %d bytes", maximum)
	}
	return body, nil
}

func safeProbeError(err error) string {
	if err == nil {
		return "unknown error"
	}
	if errors.Is(err, os.ErrNotExist) {
		return "evidence not found"
	}
	message := err.Error()
	if len(message) > 160 {
		message = message[:160]
	}
	return message
}
