# Native Linux ARM64 AEMU engine bundle

This build context cross-compiles the Google AEMU 37.1.7 headless AArch64 guest
engine for a Linux ARM64 runtime. It produces an engine bundle; it does not
contain an Android system image or start an emulator by itself.

The source lock uses immutable commits and official Gitiles archives from
`android.googlesource.com`. Gitiles gzip/PAX envelope metadata is not stable, so
the build verifies reconstructable Git trees and selected build-critical Git
blobs instead of pinning archive-byte hashes. Sources whose archive cannot
reconstruct the official root tree because it contains gitlinks retain the
official tree ID as provenance and are explicitly marked as not tree-verified.
The modem simulator source and its `common/libs/fs` headers are taken from the
same locked Cuttlefish commit; AEMU continues to compile its own cross-platform
`SharedFD` implementation instead of Cuttlefish's host implementation.
The ARM64 X11 link libraries are a blob-verified minimal closure from Google's
locked Emulator Qt prebuilt rather than mutable distribution packages.
The three GLES SwiftShader libraries are individually blob-verified AArch64
artifacts from the same locked common revision. VirtualScene data and the
legacy-named Android 36 skin resource tree are verified as complete Git
subtrees. A separately locked AArch64 Khronos Vulkan loader and SwiftShader ICD
are packaged and probed; no x86_64 Vulkan loader or ICD is included in the ARM bundle.
The same common revision supplies Google `netsimd` 0.3.112 as one independently
blob-verified x86_64 helper. It is classified outside the AArch64 `DT_NEEDED`
closure and is retained because the amd64 parent runtime executes Google's
x86_64 SDK tools while the AArch64 engine runs natively.

Build the final stage through Docker Compose. The immutable build arguments
must match the current source lock and ordered patch list:

```sh
docker compose --profile build build native-engine
```

The final image is a scratch carrier whose exact bundle root is
`/opt/cloudandx/native-aemu/`. Its stable integration paths are:

- Engine: `/opt/cloudandx/native-aemu/qemu/linux-aarch64/qemu-system-aarch64-headless`
- Runner: `/opt/cloudandx/native-aemu/bin/run-qemu-system-aarch64-headless`
- Native helpers: `/opt/cloudandx/native-aemu/{crashpad_handler,qemu-img,nimble_bridge}`
- Netsim launcher: `/opt/cloudandx/native-aemu/netsimd`
- Mixed-architecture netsim binary: `/opt/cloudandx/native-aemu/libexec/linux-x86_64/netsimd`
- Renderer: `/opt/cloudandx/native-aemu/lib64/libgfxstream_backend.so`
- Renderer X11/XCB dlopen support: `/opt/cloudandx/native-aemu/lib64/libX11-xcb.so.1`
- ARM ELF closure: `/opt/cloudandx/native-aemu/lib64/`
- SwiftShader GLES: `/opt/cloudandx/native-aemu/lib64/gles_swiftshader/`
- Vulkan loader and SwiftShader ICD: `/opt/cloudandx/native-aemu/lib64/vulkan/`
- Vulkan execution probe: `/opt/cloudandx/native-aemu/vulkan-smoke`
- Locked data and firmware: `/opt/cloudandx/native-aemu/lib/` and `lib/pc-bios/`
- Scene and guest-skin data: `/opt/cloudandx/native-aemu/resources/`
- Identity: `/opt/cloudandx/native-aemu/identity.properties`
- Manifest: `/opt/cloudandx/native-aemu/manifest.json`
- Checksums: `/opt/cloudandx/native-aemu/SHA256SUMS`

The runner removes inherited x86_64 dynamic-loader, GLES, and Vulkan variables,
sets `ANDROID_EMULATOR_LAUNCHER_DIR` to the bundle root, selects the packaged
AArch64 Vulkan loader and SwiftShader ICD, installs a controlled `lib64` plus
`gles_swiftshader` search path, fixes `QEMU_AUDIO_DRV=none`, and directly executes
the engine. Packaging and the ARM64 Docker stage execute `vulkan-smoke` through
the bundle loader with an explicit library path and 120-second timeout; only a
reported `PASS` is accepted. The explicit audio driver avoids probing the
container for the unavailable OSS `/dev/dsp`; guest PCM output and microphone
injection remain available through AEMU's gRPC audio streams.
The parent runtime
installs the exact bundled loader at the engine's locked `PT_INTERP` path, so
`/proc/<pid>/exe` identifies the engine rather than the loader. Packaging also
rejects build-directory RPATHs, strips copied ARM ELF artifacts while retaining
their GNU Build IDs, records RPATH/RUNPATH facts, and recursively resolves every
`DT_NEEDED` entry. OCI labels and the identity file bind the revision to the
source-lock and ordered patch-set digests.

When AEMU requests a local packet-streamer daemon, the launcher-root `netsimd`
wrapper clears inherited ARM loader and GPU variables before executing the
locked x86_64 helper. Its interpreter, system-only `DT_NEEDED` set, source Git
blob, runtime SHA-256, and version are fail-closed bundle contracts. It shares
the emulator container's loopback namespace, so no host port, sidecar, guest
modification, or host-network change is required.

The ARM64 runtime selects software TCG (`-accel off`). A pinned AEMU patch keeps
the existing HangDetector pause in effect when AEMU reports
`ANDROID_CPU_ACCELERATOR_NONE`, covering both the minimal and normal entry
paths. Accelerated executions retain the original resume/pause pair. Watcher
registration, CPU-usage monitoring, explicit guest-hang predicates, and the
Google-signed Android system/vendor partitions remain unchanged by these
native-engine patches.

The Android 16 KiB CPU support remains split across two narrow ordered patches:
0011 registers the isolated `android-a57-16k` QOM type, while 0012 only adds that
type to `mach-virt`'s independent hardcoded CPU allowlist.

Run the offline contract test without downloading or building sources:

```sh
docker/emulator/native-engine/tests/static-contract-test.sh
```

After extracting or copying the bundle, its checksums are compatible with:

```sh
cd /opt/cloudandx/native-aemu
sha256sum -c SHA256SUMS
```
