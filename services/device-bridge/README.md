# Android Device Bridge

Docker-contained, allowlisted HTTP-to-ADB bridge. It exposes read-only device status, screenshots, application lists and logs, plus authenticated input, GPS, SMS, call, network, battery, rotation, APK installation and uninstall operations.

`GET /sessions/{session_id}/healthz` emits the controller's strict, fresh
session-probe envelope only after ADB reports `device`, `sys.boot_completed=1`,
the API level is at least 37, and both `com.android.vending` (Google Play Store)
and `com.google.android.gms` (Google Play services) are installed. A healthy
response keeps the controller's exact three-field evidence contract. An
unhealthy `503` response adds `reason` and `observed` fields for diagnosis.

It intentionally has no arbitrary shell endpoint. Mutations require `Authorization: Bearer $BRIDGE_TOKEN`. The service is designed to be published on loopback through the root Compose stack.
