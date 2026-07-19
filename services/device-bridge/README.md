# Android Device Bridge

Docker-contained, allowlisted HTTP-to-ADB bridge. It exposes read-only device status, screenshots, application lists and logs, plus authenticated input, GPS, SMS, call, network, battery, rotation, APK installation and uninstall operations.

`GET /livez` is process liveness only and never invokes ADB. Docker uses this
endpoint so an HTTP timeout cannot leave overlapping guest probes behind.

`GET /healthz` and `GET /sessions/{session_id}/healthz` perform the strict
device probe below. Concurrent callers share one in-flight probe, and both
successful and failed results are cached for at most 60 seconds (explicitly
matched by the project controller's 90-second evidence window). Session
`observed_at` records the time of the underlying probe, not the cache-hit time.
The result is healthy only after all of these checks pass:

- ADB reports `device` and `sys.boot_completed=1`;
- the API level is at least 37;
- `ro.product.cpu.abi` is exactly `arm64-v8a`;
- `adb shell getconf PAGE_SIZE` returns exactly `16384` bytes; and
- both `com.android.vending` (Google Play Store) and `com.google.android.gms`
  (Google Play services) are installed.

The device summary and unhealthy diagnostic evidence expose the architecture
values as `properties.abi` and `properties.page_size_bytes`; both are strings
as returned by ADB. The page-size probe is the fixed, internal command
`getconf PAGE_SIZE`. No request field controls it, and the bridge still exposes
no arbitrary shell endpoint.

A healthy response keeps the controller's exact three-field evidence contract:
`session_id`, `healthy`, and `observed_at`. An unhealthy `503` response adds
`reason` and `observed` fields for diagnosis.

It intentionally has no arbitrary shell endpoint. Mutations require `Authorization: Bearer $BRIDGE_TOKEN`. The service is designed to be published on loopback through the root Compose stack.
