# Android Device Bridge

Docker-contained, allowlisted HTTP bridge to ADB and the native Android
Emulator Console. ADB provides read-only device status, screenshots,
application lists and logs, plus input, rotation and package operations. GPS,
SMS, GSM call, network and battery mutations use the Emulator Console's native
line protocol; the bridge never exposes `adb emu` or an arbitrary Console or
shell command endpoint.

The Console client connects only to the Unix-domain socket named by
`EMULATOR_CONSOLE_SOCKET` (Compose path
`/data/runtime/console/console.sock`). Device Bridge and AEMU are supervised by
the same fail-closed entrypoint in the single `android` container; there is no
sidecar, shared socket volume, Console TCP connection, or host port.
`EMULATOR_CONSOLE_TIMEOUT_SECONDS` defaults to 15 seconds and is one monotonic
deadline covering connect, banner, authentication, command and response.

Console access reuses the already loaded HTTP bridge `AUTH_TOKEN`, normally
read from `/data/runtime/secrets/token`. The client requires the exact AEMU
authentication banner, validates a 64-character lowercase hexadecimal token,
waits for an exact `OK` after authentication, and only then sends one
allowlisted command. It accepts exact terminal `OK` and native `KO`/`KO:`
failure lines, rejects EOF, invalid UTF-8, control-character injection and
oversized lines/responses, and makes a best-effort `quit`. Authentication
material and raw failure replies are never included in logs or errors.

SMS text may contain printable UTF-8, including non-Latin scripts and emoji.
C0 controls, DEL, other non-printable characters and line breaks are rejected.
Every Console command, including its trailing CRLF, is limited to 4096 UTF-8
bytes.

`GET /livez` is process liveness only and never invokes ADB. Docker uses this
endpoint so an HTTP timeout cannot leave overlapping guest probes behind.

`GET /healthz` performs the strict device probe below. Concurrent callers share
one in-flight probe, and both successful and failed results are cached for at
most 60 seconds.
Read-only ADB evidence, package, log, app-list, and screenshot calls use an
explicit 180-second ceiling because ARM TCG can legitimately exceed the usual
10-30 second interactive deadlines. One deep health pass also has a 180-second
aggregate budget: each ADB command receives the lesser of its 180-second
ceiling and the remaining aggregate time, including any reconnect. Budget
exhaustion is reported and cached as an unhealthy result. The native Console
`avd name` probe shares that aggregate budget and also retains the Console
client's shorter timeout.
The result is healthy only after all of these checks pass:

- ADB reports `device` and `sys.boot_completed=1`;
- the API level is at least 37;
- `ro.product.cpu.abi` is exactly `arm64-v8a`;
- `adb shell getconf PAGE_SIZE` returns exactly `16384` bytes; and
- both `com.android.vending` (Google Play Store) and `com.google.android.gms`
  (Google Play services) are installed; and
- the Console is reachable and `avd name` exactly matches
  `EXPECTED_AVD_NAME` (default `Pixel_9_Android_17_Play_ARM64`).

The device summary and unhealthy diagnostic evidence expose the architecture
values as `properties.abi` and `properties.page_size_bytes`; both are strings
as returned by ADB. The page-size probe is the fixed, internal command
`getconf PAGE_SIZE`. No request field controls it, and the bridge still exposes
no arbitrary shell endpoint.

It intentionally has no arbitrary shell endpoint. Mutations require `Authorization: Bearer $BRIDGE_TOKEN`. The service is designed to be published on loopback through the root Compose stack.
