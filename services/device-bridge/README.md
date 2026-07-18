# Android Device Bridge

Docker-contained, allowlisted HTTP-to-ADB bridge. It exposes read-only device status, screenshots, application lists and logs, plus authenticated input, GPS, SMS, call, network, battery, rotation, APK installation and uninstall operations.

`GET /sessions/{session_id}/healthz` emits the controller's strict, fresh
session-probe envelope only when the attached emulator is actually booted.

It intentionally has no arbitrary shell endpoint. Mutations require `Authorization: Bearer $BRIDGE_TOKEN`. The service is designed to be published on loopback through the root Compose stack.
