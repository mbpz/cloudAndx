# Android evidence gate

This directory contains a Docker-only, fail-closed preflight and evidence validator for the Android 17 design. It does not start Android, change the host, configure OrbStack, or manage Kubernetes.

## What it proves

The service performs four independent checks:

1. normalizes the container architecture, validates the declared Android runtime implementation, and inspects `/dev/kvm` while accepting it as readiness evidence only for an eligible native runtime;
2. fetches only allowlisted Google HTTPS repository XML, then requires the Android 17 base
   final release tuple `system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a` on
   SDK repository `channel-0` with the pinned revision, archive URL, and checksum;
3. validates image-manifest and capability-evidence JSON instances against Draft 2020-12 contracts mounted read-only at `/contracts`;
4. atomically writes `/evidence/preflight.json` and exits nonzero unless the selected readiness policy passes.

Repository metadata verification proves that an advertised package tuple exists. It does not download the system-image archive, re-hash the archive itself, grant a GMS license, or prove that Android runtime tests have run. Those remain separate promotion gates.

## Readiness states

| State | Meaning | Default exit |
|---|---|---:|
| `DESIGN_READY` | Both contract schemas are valid, but no repository URL was supplied | 2 |
| `SOFTWARE_EMULATION_ONLY` | Pinned Google Play metadata is valid and either a compatible native runtime lacks usable KVM or the exact ARM64 hybrid runtime was declared | 2 |
| `KVM_READY` | Metadata is valid, `/dev/kvm` is usable, and the selected native host/guest pair is verified | 0 |
| `BLOCKED` | Architecture, contracts, repository metadata, or an optional evidence instance failed | 2 |

`ALLOW_SOFTWARE_EMULATION_ONLY=true` changes only the exit policy for
`SOFTWARE_EMULATION_ONLY`; it does not relabel that state as KVM-ready. Cross-architecture
host/guest combinations are `BLOCKED` except for the exact, explicitly declared
`hybrid-aemu-arm64` pairing described below. `DESIGN_READY` never passes a runtime preflight.

## Build and test

Use the repository root as Docker build context:

```sh
docker build --target test -f services/evidence-gate/Dockerfile -t android-evidence-gate:test .
docker run --rm android-evidence-gate:test
docker build --target runtime -f services/evidence-gate/Dockerfile -t android-evidence-gate:1.0.0 .
```

Tests use local XML fixtures and make no network calls.

## Preflight

```sh
docker run --rm \
  --device /dev/kvm:/dev/kvm \
  --group-add "$(stat -c '%g' /dev/kvm)" \
  -v "$PWD/contracts:/contracts:ro" \
  -v "$PWD/evidence:/evidence" \
  -e GOOGLE_REPOSITORY_URLS=https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-4.xml \
  -e GOOGLE_PLAY_EXPECTED_CHANNEL=stable \
  android-evidence-gate:1.0.0 preflight
```

The container runs as UID/GID `65532`; the evidence volume must be writable by that identity. Do not mount the Docker socket.

Optional exact-match pins make repository changes fail closed:

- `GOOGLE_PLAY_PACKAGE_PATH` (default `system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a`)
- `GOOGLE_PLAY_ABI` (default `arm64-v8a`)
- `GOOGLE_PLAY_EXPECTED_CHANNEL_ID` (default `channel-0`)
- `GOOGLE_PLAY_EXPECTED_REVISION`
- `GOOGLE_PLAY_EXPECTED_URL`
- `GOOGLE_PLAY_EXPECTED_CHECKSUM` (`sha1:<hex>`, `sha256:<hex>`, or bare hex)
- `GOOGLE_REPOSITORY_TIMEOUT_SECONDS` (default `20`, maximum `120`)
- `ANDROID_RUNTIME_IMPLEMENTATION` (exact allowlist: `native` or `hybrid-aemu-arm64`; default `native`)

The exact defaults are revision `6`, archive
`arm64-v8a-playstore-ps16k-37.0_r06.zip`, SHA-1
`ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4`, and SDK repository
`channel-0` whose text value is `stable`. Android 17 base was formally released by Google on
2026-06-16; the machine-readable `android_release_status` is therefore independently pinned to
`stable`. Android 17 QPR1 remains Beta and is excluded. Product release status and SDK
repository channel are separate evidence and are never inferred from each other.
`ANDROID_VERSION`, `ANDROID_API_LEVEL`, and the XML type-details `GOOGLE_PLAY_TAG` default to
`17`, `37`, and `google_apis_playstore`. The package path is independently pinned to the PS16K
variant because the official XML's tag ID does not include the `_ps16k` suffix.

This runtime uses resources from Google's Linux x86_64 Emulator package and the arm64-v8a Play
image. The ARM path does not send the ARM64 AVD through the x86_64 launcher; the container
entrypoint directly invokes the native AArch64 runner. The default
`ANDROID_RUNTIME_IMPLEMENTATION=native` behavior remains fail-closed: KVM readiness requires a
matching host/guest ISA. The Compose ARM64 path declares `hybrid-aemu-arm64` and is always
classified as software emulation, even though the selected guest ISA is also ARM64.

`ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64` is valid only when the normalized container
host architecture is `arm64` (both `arm64` and `aarch64` normalize to that value) and the guest
is the default official `arm64-v8a` Play image. The gate reports this pairing as
`SOFTWARE_EMULATION_ONLY`, never `KVM_READY`, even if `/dev/kvm` is visible. A successful exit additionally requires
`ALLOW_SOFTWARE_EMULATION_ONLY=true`.

Any unknown implementation value, hybrid use on x86_64, hybrid use with a guest other than
`arm64-v8a`, or an unsupported host architecture remains fail-closed as `BLOCKED`. Native
x86_64 runtime is also `BLOCKED`: x86_64 host build and runtime verification are deferred until
an x86_64 machine is available, and no x86 AEMU build is attempted on the current ARM host. The
emitted `runtime_implementation` check and `policy.runtime` object record the
implementation, execution mode, normalized host architecture, guest ABI, native/hybrid
compatibility, and KVM-readiness eligibility.

Set `IMAGE_MANIFEST_PATH` and/or `CAPABILITY_EVIDENCE_PATH` to validate those mounted JSON instances as part of preflight. A failed optional instance changes the state to `BLOCKED`.

## Validate evidence instances

```sh
docker run --rm \
  -v "$PWD/contracts:/contracts:ro" \
  -v "$PWD/evidence:/evidence:ro" \
  android-evidence-gate:1.0.0 \
  validate-image /evidence/android-image-manifest.json

docker run --rm \
  -v "$PWD/contracts:/contracts:ro" \
  -v "$PWD/evidence:/evidence:ro" \
  android-evidence-gate:1.0.0 \
  validate-capabilities /evidence/android-capability-evidence.json
```

Both commands emit a JSON report containing schema/instance digests and every validation error. Exit code `0` means valid; exit code `2` means invalid, unreadable, or missing.

## Trust boundaries

- Repository XML and archive URLs must use HTTPS on `dl.google.com`, `redirector.gvt1.com`, or `storage.googleapis.com`; redirects are rechecked.
- XML size is capped at 16 MiB and parsed without entity expansion.
- Contracts are inputs, not baked into the image, so the runtime mount can be read-only and independently digested.
- Preflight output is written by create-and-rename to avoid exposing a partially written decision.
- A valid Schema instance is evidence structure, not proof that its referenced test artifacts are truthful; the promotion system must independently fetch and verify referenced evidence digests and expiry.
