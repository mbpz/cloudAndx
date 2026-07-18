# Android 17 Google Play Emulator — Docker-only runtime

This directory builds one `linux/amd64` container from Google-published stable artifacts:

| Component | Pinned release | Integrity |
|---|---|---|
| Android Emulator | 36.6.11 (`15507667`) | SHA-1 `f8d8b83cf21a04966326eb1378bacda255f63b93` |
| Platform Tools | 37.0.0 | SHA-1 `bcf323933980a59dccc3f14c339aed5fb2171163` |
| Android system image | Android 17 API 37.0, Google Play, x86_64, 16 KB, r06 | SHA-1 `8eaeeceb77452c018c3f6b589913cdc45222a87f` |

The API 37.0 image is the Android 17 base stable release used by this design. Android 17 QPR1/API 37.1 artifacts are excluded while QPR1 remains in beta, even if SDK repository packaging places a beta artifact on `channel-0`.

This is the official Google Play AVD software experience: Android 17 framework/UI, Google Play services, and Play Store. It is not a Pixel hardware clone and does not provide physical modem/eSIM, hardware-backed StrongBox, certified Widevine L1, real biometrics, or a production Play Integrity verdict.

Google publishes the Linux Emulator host package only for x86_64. This project keeps that
official launcher and Google Play guest unchanged, but replaces its fixed headless child path
on ARM64 with a native AArch64 `qemu-system-x86_64-headless` built from pinned Android Emulator
source. A dispatcher preserves the upstream child on x86_64. The image therefore supports
Linux x86_64 and ARM64 Docker Engines without a host SDK or host configuration changes.

## Safety boundary

- Only Docker images, containers, volumes, and published loopback ports are used.
- Nothing changes OrbStack configuration, macOS networking, DNS, routes, hypervisor settings, or system packages.
- The default path does not use `--privileged`, host networking, capabilities, or a host device.
- ADB and insecure emulator gRPC are published only on `127.0.0.1` in every example.
- The container runs as uid/gid `10001`, with all Linux capabilities dropped and a read-only root filesystem.

The `/data` volume is single-instance. On container restart the entrypoint removes only
the Emulator's two stale AVD lock files, whose recorded PIDs belong to the previous
container PID namespace; do not mount one AVD data volume into multiple live emulators.

The Android SDK artifacts are checksum-pinned. The runtime base is also pinned to the Debian `bookworm-slim` manifest digest `sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818`, resolved and built locally for `linux/amd64` during implementation.

## Build

Review the Android SDK license first, then explicitly acknowledge it:

```sh
cd ../..
docker build --platform linux/arm64 --target bundle \
  --tag cloudandx/aemu-native-engine:37.1.7 \
  docker/emulator/native-engine
docker build \
  --platform linux/amd64 \
  --build-arg ACCEPT_ANDROID_SDK_LICENSES=yes \
  --tag cloudandx/android17-play-emulator:37.0-r06 \
  docker/emulator
```

The supported entry point is `ACCEPT_ANDROID_SDK_LICENSES=yes ./androidctl build-emulator`,
which performs those builds in dependency order. The native-engine build and all source
fetching remain inside Docker.

The system image download is about 2.31 GB. The offline self-test target avoids all Android downloads:

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
./androidctl doctor
./androidctl preflight
ACCEPT_ANDROID_SDK_LICENSES=yes ./androidctl up
```

On a native x86_64 Linux engine, `up-kvm` maps an already-present `/dev/kvm`; it never
installs a driver or changes host permissions. `up` selects software translation on both
x86_64 without KVM and ARM64. ARM64 uses the native AEMU child and never attempts KVM for the
official x86_64 guest.

## ARM64 / OrbStack hybrid engine

The official x86_64 launcher still parses the AVD and command line. Its fixed headless-child
path is an immutable dispatcher. On ARM64 it executes the bundled native AArch64 AEMU binary
through a bundle-local loader/library closure; on x86_64 it executes the renamed Google
upstream child. This removes the double-translation hotspot while retaining the unmodified
official Google Play guest. Bundle source commits, patches, DT_NEEDED closure and SHA-256
digests are recorded under `native-engine/`.

Compose enables IPv6 only on this project's Docker bridge for the virtual modem. It does not
invoke `orb`/`orbctl` or change macOS/OrbStack networking, DNS, routes, firewall, or
virtualization settings.

## Access without host installs

Use the bundled `adb` through the root CLI:

```sh
./androidctl adb wait-for-device
./androidctl shell getprop ro.build.version.release
./androidctl shell pm path com.android.vending
./androidctl adb install /data/app.apk
```

Container port `5555` is a `socat` proxy to the emulator's loopback ADB port. If an external ADB client is required, mount both members of an existing key pair read-only so the same key is trusted by the guest:

```sh
--volume "$HOME/.android/adbkey:/run/secrets/adbkey:ro" \
--volume "$HOME/.android/adbkey.pub:/run/secrets/adbkey.pub:ro"
```

Because the runtime is uid `10001`, both secret files must be readable by that uid (or its group). The entrypoint fails closed when mounted key files exist but are unreadable or only one member of the pair is present.

Port `8554` is a supervised `socat` proxy to the Android Emulator gRPC control and display stream on internal port `8556`. This avoids depending on which interface a particular Emulator build binds. gRPC is not itself a browser UI; a compatible gRPC/WebRTC client is required. The emulator's `-grpc` mode is unauthenticated, so keep the host publish address at `127.0.0.1`.

## Runtime controls

| Variable | Values/default | Behavior |
|---|---|---|
| `DOCKER_ENGINE_ARCHITECTURE` | supplied by `androidctl` | Accepts x86_64/amd64 or ARM64/aarch64; missing and unknown values fail closed. |
| `ANDROID_RUNTIME_IMPLEMENTATION` | derived by `androidctl` | `native` on x86_64; exactly `hybrid-aemu-arm64` on ARM64. Other cross-architecture declarations fail closed. |
| `EMULATOR_ACCEL` | `auto` (default), `kvm`, `off` | ARM64 always resolves to `off`; x86_64 `auto` uses usable KVM. Explicit KVM fails without a native-compatible device. |
| `EMULATOR_GPU` | `swiftshader` | Also accepts `auto`, `software`, `swangle`, or `lavapipe`. |
| `EMULATOR_CORES` | `4` | Validated in the range 1–32. |
| `EMULATOR_MEMORY_MB` | `4096` | Validated in the emulator-supported range 1536–8192. |
| `EMULATOR_WIPE_DATA` | `0` | Set to `1` for one destructive guest-data reset. |

Additional Docker command arguments are passed as individual emulator arguments without `eval` or string splitting. For example:

```sh
docker run ... cloudandx/android17-play-emulator:37.0-r06 -camera-back emulated
```

`./androidctl preflight` performs the repository gate. The image's `preflight` and
`print-command` entrypoints also require a supported `DOCKER_ENGINE_ARCHITECTURE`; the root CLI
supplies this fact from Docker Engine metadata rather than trusting a persisted `.env` value.

## Health contract

The image becomes healthy only after all of the following are true:

1. `/proc/*/exe` proves the dispatcher selected the expected upstream x86_64 or native
   AArch64 child executable.
2. ADB reports `device`.
3. `sys.boot_completed=1`.
4. `ro.build.version.sdk=37`.
5. `com.android.vending` (Play Store) is installed.
6. `com.google.android.gms` (Google Play services) is installed.

The 30-minute health start period accommodates software translation. A
successful health check proves the pinned Google Play AVD booted; it does not prove
physical-hardware parity or Google device certification.
