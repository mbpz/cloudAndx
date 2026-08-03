# Android Device Bridge

`bridge.py` is the allowlisted HTTP control boundary used by the Android 16
ReDroid container. It exposes liveness, deep health, screenshots, app/package
operations, logs, and bounded input operations through ADB. It never exposes an
arbitrary shell or accepts caller-provided ADB arguments.

Mutations require `Authorization: Bearer $BRIDGE_TOKEN`. The production
container loads the token from `/data/runtime/bridge/token`, publishes the API
only on host loopback, and supervises the process with the browser bridge.

## Runtime defaults

The standalone defaults match the supported ReDroid runtime:

- Android API level 36 or newer;
- `arm64-v8a` guest ABI;
- 4096-byte guest page size;
- no required Google packages;
- Android Emulator Console disabled.

The Docker image sets these values explicitly as a fail-closed runtime
contract. `GET /livez` checks only the HTTP process. `GET /healthz` performs a
bounded ADB probe for boot completion, API level, ABI, page size, and configured
required packages. Concurrent health requests share one in-flight probe and
cache both success and failure for at most 60 seconds.

## Optional emulator-console adapter

The source retains a disabled-by-default adapter for environments that provide
the native Android Emulator Console. When explicitly enabled, it connects only
to the Unix socket in `EMULATOR_CONSOLE_SOCKET`, authenticates with the loaded
bridge token, validates the exact console protocol, and sends only fixed
allowlisted GPS, SMS, GSM, network, battery, and AVD-name commands. There is no
Console TCP listener or generic command endpoint.

ReDroid does not provide this Console, so those adapter-specific operations
fail closed in the supported deployment. Screenshot, app, package, log, input,
rotation, and restart operations continue to use the ADB allowlist.

## Tests

```sh
python3 -m unittest discover -s services/device-bridge/tests -v
```
