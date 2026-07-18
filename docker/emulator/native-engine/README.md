# Native Linux ARM64 AEMU engine bundle

This build context cross-compiles the Google AEMU 37.1.7 headless x86_64 guest
engine for a Linux ARM64 runtime. It produces an engine bundle; it does not
contain an Android system image or start an emulator by itself.

The source lock uses immutable commits and official Gitiles archives from
`android.googlesource.com`. Gitiles gzip/PAX envelope metadata is not stable, so
the build verifies reconstructable Git trees and selected build-critical Git
blobs instead of pinning archive-byte hashes. Sources whose archive cannot
reconstruct the official root tree because it contains gitlinks retain the
official tree ID as provenance and are explicitly marked as not tree-verified.

Build the final stage from the repository root:

```sh
docker build \
  --file docker/emulator/native-engine/Dockerfile \
  --target bundle \
  --tag cloudandx/aemu-native-engine:37.1.7 \
  docker/emulator/native-engine
```

The final image is a scratch carrier whose exact bundle root is
`/opt/cloudandx/native-aemu/`. Its stable integration paths are:

- Engine: `/opt/cloudandx/native-aemu/bin/qemu-system-x86_64-headless`
- Runner: `/opt/cloudandx/native-aemu/bin/run-qemu-system-x86_64-headless`
- Manifest: `/opt/cloudandx/native-aemu/manifest.json`
- Checksums: `/opt/cloudandx/native-aemu/SHA256SUMS`

The runner removes inherited dynamic-loader variables and invokes the bundled
ARM64 loader with a bundle-local library path. The packaging step recursively
resolves every `DT_NEEDED` entry and fails if any dependency is missing or is
not an AArch64 ELF.

Run the offline contract test without downloading or building sources:

```sh
docker/emulator/native-engine/tests/static-contract-test.sh
```

After extracting or copying the bundle, its checksums are compatible with:

```sh
cd /opt/cloudandx/native-aemu
sha256sum -c SHA256SUMS
```
