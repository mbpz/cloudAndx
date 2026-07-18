package main

import "sync/atomic"

type Metrics struct {
	HTTPRequests       atomic.Uint64
	CreatedSessions    atomic.Uint64
	IdempotentHits     atomic.Uint64
	ProbeChecks        atomic.Uint64
	ProbeFailures      atomic.Uint64
	PersistFailures    atomic.Uint64
	CapacityRejections atomic.Uint64
}
