# Android 17 Google Play Emulator — Docker compatibility runtime

> This is an explicit `docker-compat` evidence path for the single-container Docker
> topology. On this M1 OrbStack host it is ARM TCG/SwiftShader, not native-parity or
> the default local interaction path; use `scripts/native-android17.sh` for that.

This directory builds one `linux/amd64` container userland from pinned Google-published artifacts:

| Component | Pinned release | Integrity |
|---|---|---|
| Google Linux Emulator SDK resources/tools | 37.1.11 (`15917651`) | SHA-1 `1b1f78891abf8ec268264356e1365c25519e8379` |
| Executed native AEMU engine | source revision 37.1.7 | source-lock and ordered patch-set SHA-256 identities |
| Platform Tools | 37.0.1 | SHA-1 `477254aa5f903c15cf51001717bdf347fb6b53e0` |
| Android system image | Android 17 API 37.0, Google Play, arm64-v8a, 16 KB, r06 | SHA-1 `ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4` |

The API 37.0 r06 image is pinned from the Android 17 base final/stable release announced by
Google on 2026-06-16. Android 17 QPR1 remains Beta and is excluded from this design. Its SDK
repository channel is `channel-0`, whose text value is also `stable`, but product release
status and SDK repository channel are independent evidence: neither is inferred from the
other. The evidence gate separately pins the product status, package, revision, URL, checksum,
channel text, and channel ID.

This is the official Google Play AVD software experience: Android 17 framework/UI, Google Play services, and Play Store. It is not a Pixel hardware clone and does not provide physical modem/eSIM, hardware-backed StrongBox, certified Widevine L1, real biometrics, or a production Play Integrity verdict.

Google publishes the Linux Emulator host package only for x86_64. The project uses its pinned
SDK resources and tools in the amd64 container userland, but the ARM path does not ask that
x86_64 launcher to parse an ARM64 AVD: AEMU rejects that combination for API 28 and newer.
Instead, the entrypoint directly executes a native AArch64 runner built from pinned Android
Emulator source, which launches `qemu-system-aarch64-headless`. The default guest is the
official arm64-v8a package, avoiding the x86-to-ARM TCG boot bottleneck. x86_64 host build and
runtime verification are deferred until an x86_64 machine is available; repository metadata
for that ABI remains queryable, but the runtime path fails closed rather than claiming support.

## Safety boundary

- Only Docker images, containers, volumes, and published loopback ports are used.
- Nothing changes Docker Engine configuration, macOS networking, DNS, routes, hypervisor settings, or system packages.
- The default path does not use `--privileged`, host networking, capabilities, or a host device.
- ADB and insecure emulator gRPC are published only on `127.0.0.1` in every example.
- The authenticated Emulator Console is available only through a mode-`0600` Unix socket shared with the device bridge; it has no container-network or host TCP exposure.
- The container runs as uid/gid `10001`, with all Linux capabilities dropped and a read-only root filesystem.

The `/data` volume is single-instance. On container restart the entrypoint removes only
the Emulator's two stale AVD lock files, whose recorded PIDs belong to the previous
container PID namespace; do not mount one AVD data volume into multiple live emulators.

The Android SDK artifacts are checksum-pinned. The runtime base is also pinned to the Debian `bookworm-slim` manifest digest `sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818`, resolved and built locally for `linux/amd64` during implementation.

## Build

Review the Android SDK license first, then explicitly acknowledge it:

```sh
cd ../..
ACCEPT_ANDROID_SDK_LICENSES=yes docker compose --profile build build native-engine
```

Compose supplies the immutable native-engine source-lock and ordered patch-set
identities. This command only prebuilds `native-engine`; the subsequent
`docker compose --profile docker-compat up -d --build` builds the main runtime image
and consumes that bundle. All source fetching remains inside Docker.
The main image verifies that bundle before merging only the pinned Google SDK
`macros/` and `macroPreviews/` resource directories. Those additions receive a
separate sorted SHA-256 manifest that runtime preflight checks again.
The amd64 runtime also executes the bundle's locked Google `netsimd --version`
and requires 0.3.112 before the image can be produced.

The offline self-test target avoids all Android downloads:

```sh
docker build --pull=false --target self-test --tag android17-emulator-self-test .
```

The smaller tools smoke target downloads and checksum-verifies Emulator and Platform Tools, installs the real amd64 runtime libraries, and executes both version commands without downloading the system image:

```sh
docker build --pull=false --platform linux/amd64 \
  --target runtime-tools-smoke \
  --build-arg ACCEPT_ANDROID_SDK_LICENSES=yes \
  --tag android17-emulator-runtime-tools-smoke .
```

## Run

Use the root Compose stack so architecture, Google metadata, ADB keys, loopback ports, and KVM
permissions are all gated consistently:

```sh
cd ../..
docker compose --profile docker-compat config --quiet
ACCEPT_ANDROID_SDK_LICENSES=yes docker compose --profile build build native-engine
ACCEPT_ANDROID_SDK_LICENSES=yes docker compose --profile docker-compat up -d --build
```

The current ARM64 path uses the native AEMU child and never attempts KVM for the official
arm64-v8a guest. Native x86_64 `up-kvm` build and runtime verification are intentionally
deferred to an x86_64 host; nothing on this ARM machine attempts to build or run x86 AEMU.

## ARM64 / Docker Engine hybrid engine

The amd64 container entrypoint bypasses the x86_64 launcher for the ARM64 AVD and directly
executes the bundled native AArch64 runner with the locked ARM64 `PT_INTERP` and bundle-local
library closure. Direct execution keeps `/proc/<pid>/exe` bound to the engine. The ARM engine
uses the bundle's `qemu/linux-aarch64`
layout, locked pc-bios/runtime data, an AArch64 gfxstream backend, and three
verified SwiftShader GLES libraries. ARM startup is fixed to SwiftShader and
uses a separately locked AArch64 Khronos Vulkan loader and SwiftShader ICD. The build executes
the loader through the bundle's AArch64 interpreter and library path, requires the 120-second
Vulkan smoke probe to report `PASS`, leaves Vulkan enabled, and disables unsupported Guest ANGLE
and Vulkan snapshot features. This
removes cross-ISA guest translation while retaining the official signed arm64-v8a Google
Play system and vendor partitions. Bundle source commits, patches, DT_NEEDED closure, immutable
identity labels and SHA-256 digests are recorded under `native-engine/`.

Linux AArch64 AEMU otherwise selects the KVM-only `gic-version=host` and `-cpu host`
defaults even when acceleration is off. The entrypoint therefore appends
`-qemu -machine gic-version=2 -cpu android-a57-16k` as a locked final raw QEMU tail,
after user-supplied Android options and the graphics safety arguments. User-supplied
`-qemu` sentinels are rejected so they cannot move or override that TCG boundary;
`android-a57-16k` derives from the source tree's existing Cortex-A57 model without
changing the generic Cortex-A57, A53, `max`, or KVM `host` contracts. The native
0011 patch registers that QOM type and advertises TGran16 only for it because the
same TCG implementation already handles 16 KB stage-1 and stage-2 walks; the
separate 0012 patch only admits that registered type through `mach-virt`'s
hardcoded CPU allowlist. Headless
startup locks the back camera to `emulated`: both cameras remain functional
software devices while the synchronous virtual-scene loader is kept out of the
no-window boot path.

The ARM TCG path also disables the visual-only boot animation. The downloaded
Google ZIP is SHA-1 verified before extraction; `system.img`, `vendor.img`, the
kernel, and the initial-userdata seed remain byte-for-byte unchanged. Pure TCG is
slow enough that Android's default framework watchdog and ART's independent
10-second Finalizer watchdog can repeatedly terminate SystemServer, so the build
creates one explicitly derived boot ramdisk. It keeps the decompressed official
cpio as an exact byte prefix and adds only `system/etc/ramdisk/build.prop` with
`ro.hw_timeout_multiplier=50` and `dalvik.vm.finalizer-timeout-ms=500000`, the
Android 17 first-stage/second-stage property channel. It also sets the Bluetooth
module's documented `bluetooth.hci.timeout_milliseconds=100000` and
`bluetooth.hci.restart_timeout_milliseconds=250000`. These are the AOSP 2,000 ms
command and 5,000 ms abort defaults multiplied by the same factor of 50, preventing
cold TCG scheduling from killing and restarting Bluetooth during initialization.
The ART value similarly scales its 10,000 ms platform default. The build records
and verifies both
the official ramdisk SHA-256
`be1c34d44bdf2484c9bb0f4458b1cb3b8133d887bc87441dd5a5cb7c5fcfdff8` and the
deterministic derived SHA-256
`bfaeb73b28c50733a90337ceb93d66b5eb652f713b807744d86532f28344035c`.
It does not add `force_debuggable`, use a debug ramdisk, or alter SELinux policy.
This preserves Google's signed user-build system and GMS, but the boot ramdisk is
not byte-for-byte the ZIP artifact; a strictly untouched-artifact path remains
deferred to x86_64/KVM verification. The AVD template marker includes the
A57/GICv2/ramdisk-timeout50/finalizer500000/hci100000-250000 contract, so a volume created by an older image is
rejected instead of silently reusing incompatible state. A first cold boot
performs substantial userdata setup and package optimization; an ARM64 Docker
Engine run took about 25 minutes. Do not interrupt it while the container still
shows sustained CPU or block-I/O activity and has not restarted or been OOM-killed.

Bluetooth, UWB, and netsim Wi-Fi packet streams use the official Google
`netsimd` 0.3.112 helper locked from the same common revision. A launcher-root
wrapper runs it in the existing container loopback namespace after removing the
ARM engine's loader/GPU environment. The helper is explicitly mixed-architecture,
excluded from the ARM ELF closure, checksum-covered, and does not add a host port
or sidecar. The native runner fixes `QEMU_AUDIO_DRV=none` because Docker exposes
no OSS `/dev/dsp`; this keeps guest audio timing and AEMU gRPC PCM/microphone
paths without changing the guest or binding host audio devices.

Compose enables IPv6 only on this project's Docker bridge for the virtual modem. It does not
invoke provider CLIs or change macOS/Docker Engine networking, DNS, routes, firewall, or
virtualization settings.

## Access without host installs

Use the bundled `adb` through the root CLI:

```sh
docker compose --profile docker-compat exec -T android adb -s emulator-5556 wait-for-device
docker compose --profile docker-compat exec -T android adb -s emulator-5556 shell getprop ro.build.version.release
docker compose --profile docker-compat exec -T android adb -s emulator-5556 shell pm path com.android.vending
docker compose --profile docker-compat exec -T android adb -s emulator-5556 install /data/app.apk
```

Container port `5555` is a `socat` proxy to the emulator's loopback ADB port. If an external ADB client is required, mount both members of an existing key pair read-only so the same key is trusted by the guest:

```sh
--volume "$HOME/.android/adbkey:/run/secrets/adbkey:ro" \
--volume "$HOME/.android/adbkey.pub:/run/secrets/adbkey.pub:ro"
```

Because the runtime is uid `10001`, both secret files must be readable by that uid (or its group). The entrypoint fails closed when mounted key files exist but are unreadable or only one member of the pair is present.

The mode-`0600` Unix socket `/data/runtime/console/console.sock` is a supervised `socat` proxy to AEMU's loopback-only Console on port `5556`; each connection to that loopback target has a five-second deadline. It and the generated token `/data/runtime/secrets/token` reside in the `android` container's persistent `/data` volume. Device Bridge and AEMU run under the same fail-closed entrypoint in that one container; there is no sidecar or shared socket volume. There is no container-network-facing Console TCP listener, Dockerfile `EXPOSE`, Compose `expose`, or host `ports` mapping. The entrypoint accepts only a regular, non-symlink token file containing exactly 64 lowercase hexadecimal characters. It atomically installs the unchanged token at `$HOME/.emulator_console_auth_token` with mode `0600` before AEMU starts, without logging its contents. AEMU therefore requires the Console client's initial `auth` command. Invalid or uncopyable token input fails closed, as does any later exit of the supervised Unix-socket proxy.

Port `8554` is a supervised `socat` proxy to the Android Emulator gRPC control and display stream on internal port `8556`. This avoids depending on which interface a particular Emulator build binds. gRPC is not itself a browser UI; a compatible gRPC/WebRTC client is required. The emulator's `-grpc` mode is unauthenticated, so keep the host publish address at `127.0.0.1`.

Port `6080` serves the encrypted HTTPS/WSS browser interaction path from the same runtime container. The root page immediately opens noVNC with automatic connection and local scaling, so the Pixel 9 display appears without a separate connection step. The bridge consumes AEMU's event-driven `streamScreenshot` RGB stream and exposes raw RFB only on `127.0.0.1:5900`; pinned websockify/noVNC scales it to the browser viewport. RFB pointer DOWN/MOVE/UP events become AEMU touchscreen pressure events, while keyboard and clipboard text use the same persistent `streamInputEvent` connection. The locked grpcurl 1.9.3 binary is copied from an image pinned by digest and communicates only with AEMU's internal loopback gRPC endpoint. Its screenshot response ceiling is derived from the configured RGB frame size plus bounded protocol overhead, allowing the 1080x2424 Pixel 9 frame without widening the input path. A local noVNC adapter converts macOS trackpad wheel bursts into one touchscreen gesture. The first-frame marker is created only after a correctly sized live AEMU frame is decoded. Compose publishes only HTTPS noVNC on host loopback. Raw RFB, ADB internals and emulator gRPC are never browser-facing, and closing or reconnecting the browser does not create another Android instance.

## Runtime controls

| Variable | Values/default | Behavior |
|---|---|---|
| `DOCKER_ENGINE_ARCHITECTURE` | `arm64` | ARM64/aarch64 is the current supported build path; x86_64/amd64 is deferred and fails closed. |
| `ANDROID_RUNTIME_IMPLEMENTATION` | `hybrid-aemu-arm64` | Exactly `hybrid-aemu-arm64` for the current Docker build path. |
| `EMULATOR_ACCEL` | `auto` (default), `off` | Both resolve to software execution on ARM64. `kvm` and every x86_64 path fail closed. |
| `EMULATOR_GPU` | `swiftshader` | The ARM64 runtime requires the packaged SwiftShader GLES/Vulkan stack; every other value fails closed. |
| `EMULATOR_CORES` | `4` | Validated in the range 1–32 and aligned with the native Pixel 9 AVD. |
| `EMULATOR_MEMORY_MB` | `4096` | Validated in the emulator-supported range 1536–8192. |
| `ANDROID_DISPLAY_WIDTH` / `ANDROID_DISPLAY_HEIGHT` | `1080` / `2424` | Pixel 9 effective display geometry; reconciled into persisted AVD configuration on every start. |
| `ANDROID_DISPLAY_DENSITY` / `ANDROID_DISPLAY_DEPTH` | `420` / `32` | Pixel 9 effective density and color depth; validated before startup. |
| `EMULATOR_CONSOLE_SOCKET` | `/data/runtime/console/console.sock` | Mode-`0600` Unix socket used by Device Bridge in the same `android` container; no Console TCP port is exposed. |
| `EMULATOR_CONSOLE_AUTH_TOKEN_FILE` | `/data/runtime/secrets/token` | Persistent token source copied to AEMU's required home-directory path before startup. |
| `EMULATOR_WIPE_DATA` | `0` | Set to `1` for one destructive guest-data reset. |

Additional Docker command arguments are passed as individual emulator arguments without `eval` or string splitting. For example:

```sh
docker run ... cloudandx/android17-play-emulator:37.0-r06 -camera-back emulated
```

The root `docker compose --profile docker-compat exec -T android /usr/local/bin/runtime-preflight.sh`
command performs the runtime gate. The image's `preflight` and
`print-command` entrypoints also require a supported `DOCKER_ENGINE_ARCHITECTURE`; the root CLI
supplies this fact from Docker Engine metadata rather than trusting a persisted `.env` value.

## Health contract

The image becomes healthy only after all of the following are true:

1. `/proc/*/exe` proves the entrypoint directly selected the expected native AArch64 engine.
2. ADB reports `device`.
3. `sys.boot_completed=1`.
4. `pidof system_server` returns a live process.
5. ActivityManager, WindowManager, and CameraService are registered with Binder.
6. `ro.build.version.sdk=37`.
7. `ro.product.cpu.abi=arm64-v8a`.
8. Guest page size is exactly 16384 bytes.
9. `ro.hw_timeout_multiplier=50` came through the locked second-stage ramdisk property.
10. `dalvik.vm.finalizer-timeout-ms=500000` came through the same property file.
11. The image identity and runtime preflight lock
    `bluetooth.hci.timeout_milliseconds=100000` and
    `bluetooth.hci.restart_timeout_milliseconds=250000` in that property file.
12. BluetoothManager is registered with Binder.
13. `com.android.vending` (Play Store) is installed.
14. `com.google.android.gms` (Google Play services) is installed.

The Google `user` build intentionally prevents the ADB shell domain from reading
properties that fall under the generic `bluetooth_prop` SELinux context. The two
HCI properties are therefore verified from the deterministic ramdisk identity by
the image build and runtime preflight; the guest health probe verifies the public
BluetoothManager Binder service instead of treating SELinux isolation as a
missing property.

Before evaluating ADB state, the internal health check makes a five-second-bounded
connection to `127.0.0.1:${EMULATOR_ADB_PORT}` and then checks only
`emulator-${EMULATOR_CONSOLE_PORT}`. This prevents an ADB server rescan of proxy
port `5555` as `emulator-5554` from controlling readiness; the device bridge keeps
using its external `emulator:5555` endpoint.

The 60-minute health start period accommodates cold ARM64 TCG initialization,
which can continue making guest disk and renderer progress beyond 30 minutes.
Each check has a five-minute Docker deadline and every ADB operation is bounded
to 180 seconds, preventing the former 15-second deadline from repeatedly killing
valid but slow ADB calls. The start interval is one minute; after the first success,
the interval becomes ten minutes. API, ABI, page size, the two guest-readable
watchdog values, SystemServer/core-service liveness, Play, and GMS checks share
one guest-shell probe so readiness does not continuously
occupy PackageManager on TCG. Checks still fail closed during the start window.
A successful health check proves the pinned Google Play AVD booted; it does not
prove physical-hardware parity or Google device certification.
