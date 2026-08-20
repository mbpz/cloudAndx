# Self-contained macOS Android runtime contract

Status: Phase 2C offline supply-chain pipeline plus Phase 2B packaging contract.
No Google SDK, Android Studio, Google
APIs image, Google Play image, signing material, or runtime binary is included
in this repository or in the development app.

The product shape is one installed app with a bundled source-built ARM64
AEMU/AOSP runtime. `qemu-system-aarch64` is an internal signed engine process,
not a separately installed emulator. The current development artifact embeds
the sandboxed descriptor XPC agent but intentionally does not package a
development authority runner or project path; lifecycle remains unavailable
until a bundle-owned runtime or separately audited helper exists. It is not distributable; release payload,
Developer ID identity and notarization remain fail-closed.

## Runtime modes

`CLOUDANDX_RUNTIME_MODE` is mandatory at the shell authority boundary:

- `development-sdk` is an explicitly labelled, non-product compatibility mode.
  It may use the existing local, version-locked Android SDK prototype. Its AVD
  and snapshots stay in the development runtime root.
- `bundled-release` is the intended only release mode. The signed launcher will
  supply the one `CLOUDANDX_BUNDLED_RUNTIME_ROOT` locator, pointing at
  `CloudAndx.app/Contents/Resources/AndroidRuntime`. External SDK roots,
  Homebrew/path lookup, `sdkmanager`, `avdmanager`, setup/downloads and Google
  Play / Google APIs classifications fail closed.

Mutable first-run data must be staged outside the signed app at
`~/Library/Application Support/CloudAndx/Runtime/<runtime-id>/`. The immutable
bundle layout is `manifest.json`, `engine/`, `images/`, `tools/`, `templates/`,
`licenses/`, and `provenance/`.

## Manifest and verification

`manifest.json` uses schema version 1. It records the runtime ID, target
macOS/ARM64 platform, source-built marker, immutable-root identity, every
regular immutable artifact, default template digest, AEMU/AOSP/adb/scrcpy
revisions, build and toolchain attestations, SBOM, licenses and NOTICE
references. Each artifact has a normalized relative path, SHA-256, byte size,
role, executable flag, ARM64 requirement where executable, source provenance,
license and NOTICE references.

The Core verifier does not invoke a shell. It rejects traversal, absolute or
case-colliding paths, symlinks, missing/extra files, hash/size/mode drift,
non-ARM64 Mach-O executables, unaudited source or reference gaps, and Google
SDK/Google APIs/Google Play artifact classifications. The runner stores runtime
mode plus manifest/template identity in trusted snapshot metadata so a runtime
change makes a requested snapshot incompatible; it never silently cold-boots a
trusted-snapshot request.

Android SDK terms section 3.4 generally prohibit copying or redistributing SDK
components except where open-source licenses permit it. Therefore shipping
bytes requires source-build provenance and license review. This is an
engineering release gate, not legal advice.

## Release gate and current implementation boundary

Phase 2C adds `runtime/macos-arm64/runtime_pipeline.py`: an offline Python
standard-library assembler that preflights pinned AOSP/AEMU/scrcpy source
checkouts, creates canonical unsigned build claims, authenticates a detached
RSA-SHA256 builder attestation under a pinned public-key policy, atomically
assembles the exact schema-1 `AndroidRuntime` closure, and re-verifies it
independently. It rejects dirty/unlocked source evidence, symlinks,
undeclared/tampered files, Google SDK/API/Play classifications, mixed scrcpy
revisions, non-arm64 artifacts, and unsafe Mach-O dependency/RPATH metadata.
The repository production policy deliberately trusts zero builders today;
therefore bundled release preflight fails before signing or output mutation.
Adding a key is a reviewable policy diff, not a build argument.
The local AOSP `repo` launcher is additionally caller-locked by exact path,
SHA-256 and size before it is executed: no immutable launcher digest is yet
repository-pinned, so this is an explicit build-lane evidence requirement and
not a claim that the repository itself authenticates that launcher. Source
attestation creation/assembly also recomputes an explicit no-symlink toolchain
root closure against path/size/hash evidence.

This completion does **not** show that a redistributable macOS AEMU/gfxstream/
adb binary closure has actually been built or legally approved. Phase 2D is a
separate boundary: it must prove a truly embedded, low-latency client display,
not an external scrcpy or AEMU window.

`client/macos/scripts/build-app.sh` requires an explicit `--mode`.
Development builds may omit a payload and are ad-hoc signed only as a local
inspection convenience. Release preflight requires a verified payload, a real
installed signing identity, expected Team ID, and notarization profile before
an app output is replaced. This slice intentionally exposes release as a
preflight-only gate: only successful `--dry-run` is permitted after every gate;
non-dry-run release emission always fails. The shell similarly allows only a
static `runtime-preflight` action and rejects every lifecycle/capability action
before touching mutable AVD state. Source-built payload bytes, bundle-owned
release launcher/payload, Team-ID signing, notarized DMG and notarization submission
are not implemented yet. Development already packages a descriptor-only embedded XPC
agent and signs it before the sandboxed outer app. The script deliberately does not submit notarization
from a development workstation.

The XPC Capability Agent boundary is descriptor-only: the main app resolves
security-scoped bookmarks and passes already-open `FileHandle` objects; the
agent never accepts arbitrary host paths or bookmarks. Virtualization.framework is likewise a separate research
gate requiring measured graphics, input, audio, ADB and snapshot parity.
