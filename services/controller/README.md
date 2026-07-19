# Docker-only Android session controller

This service is a persistent control API for an externally operated Android
Emulator. It deliberately does **not** start containers, mount the Docker
socket, modify OrbStack, change host networking, or claim that a lease is a
running emulator.

The lifecycle scope is `lease_registry_only`. A session starts as
`WAITING_FOR_RUNTIME` and becomes `RUNNING` only when every configured external
probe returns fresh evidence for that exact session ID. Deleting a session
marks its lease `RELEASED`; it performs no runtime stop action.

## Run using Docker only

```sh
docker build -t cloudandx-controller:local services/controller
docker volume create cloudandx-controller-data
docker run -d --name cloudandx-controller \
  -p 127.0.0.1:18080:8080 \
  -v cloudandx-controller-data:/data \
  -e ANDROID_VERSION=17 \
  -e API_LEVEL=37 \
  -e SYSTEM_IMAGE_KIND=google_apis_playstore_ps16k \
  -e KVM_AVAILABLE=false \
  -e RUNTIME_MODE=registry_only \
  -e MAX_ACTIVE_SESSIONS=1 \
  cloudandx-controller:local
```

The command creates only Docker-managed objects and binds the API to localhost.
It requires no privileged mode, `/dev/kvm`, Docker socket, host mount, or host
network changes.

## API

- `GET /healthz` — process liveness.
- `GET /readyz` — persistent state directory is writable.
- `GET /v1/platform` — exact environment-derived platform facts.
- `GET /v1/capabilities` — capability fidelity as `real`, `high_fidelity`,
  `simulated`, or `blocked`.
- `POST /v1/sessions` — create an idempotent lease.
- `GET /v1/sessions` — list and refresh lease states.
- `GET /v1/sessions/{id}` — read and refresh one lease.
- `DELETE /v1/sessions/{id}` — release one lease; no runtime command is run.
- `GET /metrics` — Prometheus text metrics.

Creation requires `Content-Type: application/json` and an `Idempotency-Key`
header. The only accepted JSON fields are:

```json
{
  "client_reference": "local-test",
  "lease_seconds": 3600,
  "requested_capabilities": ["android_framework", "google_play_store"]
}
```

The controller rejects image names, commands, mounts, devices, environment
variables, port mappings, and all other unknown request fields.

`MAX_ACTIVE_SESSIONS` defaults to `1`. Capacity is enforced atomically in the
persistent registry so one emulator slot cannot be assigned to two active
leases. A retry with the same idempotency key remains valid; a new lease beyond
the limit returns HTTP 409 with `capacity_exhausted`.

Optionally set `PREFLIGHT_EVIDENCE_FILE=/evidence/preflight.json` and mount the
evidence file read-only. `/v1/platform` then reports its strict top-level
`status` (or the companion evidence-gate's `state`) as `evidence_status`.
Missing, oversized, malformed, non-string, or unknown values are reported as
`unavailable`; they never affect `/healthz`.

## Runtime proof contract

Set either or both templates below. Each must contain `{id}`:

- `EMULATOR_HEALTH_FILE_TEMPLATE=/proof/{id}.json`
- `EMULATOR_HEALTH_URL_TEMPLATE=http://runtime:8081/sessions/{id}/healthz`

When both are set, both must pass. Evidence is limited to 4096 bytes, rejects
unknown fields, must be recent (30 seconds by default), and has this exact form:

```json
{
  "session_id": "ses_0123456789abcdef0123456789abcdef",
  "healthy": true,
  "observed_at": "2026-07-18T08:00:00Z"
}
```

`PROBE_MAX_AGE_SECONDS` and `PROBE_TIMEOUT_MILLIS` tune freshness and probe HTTP
timeout. `HTTP_WRITE_TIMEOUT_MILLIS` defaults to the probe timeout plus five
seconds and cannot be configured below that relationship, so a synchronous
session probe can finish before the controller closes its response connection.
The project Compose sets the maximum age to 90 seconds so it remains
strictly bounded while covering the device bridge's 60-second single-flight
cache. Its probe timeout is five minutes so one slow ARM TCG evidence pass can
finish without turning a healthy guest into a false timeout. Without valid
proof the state can never be `RUNNING`.

## Important capability boundary

`SYSTEM_IMAGE_KIND=google_apis_playstore_ps16k` describes the Android 17 stable
Google Play SDK image family. The compatibility value `google_apis_playstore`
is also recognized. Neither value alone proves that an API 37 artifact is
currently published,
grant redistribution rights, or turn simulated radios/security hardware into
physical capabilities. NFC/UWB/eSIM/IMS/StrongBox/Widevine L1 and
hardware-backed Play Integrity remain explicitly `blocked` for this generic
Docker emulator lane.
