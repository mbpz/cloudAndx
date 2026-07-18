#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
compose_file=${ROOT}/compose.yaml
emulator_dockerfile=${ROOT}/docker/emulator/Dockerfile
emulator_dockerignore=${ROOT}/docker/emulator/.dockerignore
emulator_readme=${ROOT}/docker/emulator/README.md
emulator_entrypoint=${ROOT}/docker/emulator/bin/entrypoint.sh
emulator_runtime_lib=${ROOT}/docker/emulator/bin/runtime-lib.sh
emulator_preflight=${ROOT}/docker/emulator/bin/runtime-preflight.sh
emulator_healthcheck=${ROOT}/docker/emulator/bin/healthcheck.sh
obsolete_dispatcher=${ROOT}/docker/emulator/bin/qemu-system-x86_64-headless-dispatcher.sh
evidence_google_repo=${ROOT}/services/evidence-gate/src/evidence_gate/google_repo.py
avd_config=${ROOT}/docker/emulator/avd/config.ini
avd_marker=${ROOT}/docker/emulator/avd/template-version

grep -q '^  runtime-compatibility:$' "${compose_file}"
grep -q 'DOCKER_ENGINE_ARCHITECTURE:' "${compose_file}"
grep -q 'ANDROID_RUNTIME_IMPLEMENTATION:' "${compose_file}"
grep -q '^networks:$' "${compose_file}"
grep -q 'enable_ipv6: true' "${compose_file}"
grep -q 'fd37:17:37::/64' "${compose_file}"
emulator_block=$(sed -n '/^  emulator:$/,/^  device-bridge:$/p' "${compose_file}")
bridge_block=$(sed -n '/^  device-bridge:$/,/^  controller:$/p' "${compose_file}")
evidence_block=$(sed -n '/^  evidence-gate:$/,/^  emulator:$/p' "${compose_file}")

for expected in \
  'GOOGLE_PLAY_PACKAGE_PATH: system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a' \
  'GOOGLE_PLAY_ABI: arm64-v8a' \
  'GOOGLE_PLAY_EXPECTED_CHANNEL: stable' \
  'GOOGLE_PLAY_EXPECTED_CHANNEL_ID: channel-0' \
  'GOOGLE_PLAY_EXPECTED_REVISION: "6"' \
  'arm64-v8a-playstore-ps16k-37.0_r06.zip' \
  'sha1:ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4'; do
  if ! printf '%s\n' "${evidence_block}" | grep -Fq "${expected}"; then
    printf 'FAIL: evidence gate is missing ARM64 pin: %s\n' "${expected}" >&2
    exit 1
  fi
done

case "${emulator_block}" in
  *'AVD_NAME: Pixel_9_Android_17_Play_ARM64'*) ;;
  *)
    printf '%s\n' 'FAIL: emulator does not use the isolated ARM64 AVD identity.' >&2
    exit 1
    ;;
esac

grep -Fxq 'AvdId=Pixel_9_Android_17_Play_ARM64' "${avd_config}"
grep -Fxq 'abi.type=arm64-v8a' "${avd_config}"
grep -Fxq 'hw.cpu.arch=arm64' "${avd_config}"
grep -Fxq 'image.sysdir.1=system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/' \
  "${avd_config}"
grep -Fxq 'android-17-api-37.0-google-play-ps16k-arm64-v8a-r06' "${avd_marker}"
grep -Fq 'arm64-v8a-playstore-ps16k-37.0_r06.zip' "${emulator_dockerfile}"
grep -Fq 'SYSTEM_IMAGE_SHA1=ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4' \
  "${emulator_dockerfile}"
grep -Fq 'google_apis_playstore_ps16k/arm64-v8a/system.img' \
  "${emulator_dockerfile}"
if grep -Fq 'x86_64-playstore-ps16k-37.0_r06.zip' "${emulator_dockerfile}"; then
  printf '%s\n' 'FAIL: emulator image still downloads the x86_64 Google Play guest.' >&2
  exit 1
fi
grep -Fq 'NATIVE_AEMU_RUNNER=${NATIVE_AEMU_ROOT}/bin/run-qemu-system-aarch64-headless' \
  "${emulator_entrypoint}"
grep -Fq 'EMULATOR_BIN=${EMULATOR_BIN:-${NATIVE_AEMU_RUNNER}}' \
  "${emulator_entrypoint}"
if grep -Fq 'qemu-system-x86_64-headless-dispatcher.sh' "${emulator_dockerfile}"; then
  printf '%s\n' 'FAIL: ARM64 image still installs the obsolete x86 child dispatcher.' >&2
  exit 1
fi
[ ! -e "${obsolete_dispatcher}" ] || {
  printf '%s\n' 'FAIL: obsolete x86 guest dispatcher remains in the runtime source.' >&2
  exit 1
}
grep -Fq '!native-engine/bin/run-qemu-system-aarch64-headless' \
  "${emulator_dockerignore}"
if grep -Fq '!native-engine/bin/run-qemu-system-x86_64-headless' \
  "${emulator_dockerignore}"; then
  printf '%s\n' 'FAIL: Docker context still names the obsolete x86 guest runner.' >&2
  exit 1
fi
grep -Fq 'qemu/linux-aarch64/qemu-system-aarch64-headless' "${emulator_runtime_lib}"
grep -Fq 'native_aemu_tcg_qemu_args()' "${emulator_runtime_lib}"
grep -Fq 'validate_android_emulator_args "$@"' "${emulator_entrypoint}"
grep -Fq '$(native_aemu_tcg_qemu_args)' "${emulator_entrypoint}"
grep -Fq 'system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a' \
  "${emulator_preflight}"
grep -Fq 'bin/run-qemu-system-aarch64-headless' "${emulator_preflight}"
grep -Fq 'getprop ro.product.cpu.abi' "${emulator_healthcheck}"
grep -Fq 'getconf PAGE_SIZE' "${emulator_healthcheck}"
if grep -Eq 'QEMU_DISPATCHER|UPSTREAM_QEMU_ENGINE|qemu-system-x86_64-headless' \
  "${emulator_entrypoint}" "${emulator_runtime_lib}" "${emulator_preflight}"; then
  printf '%s\n' 'FAIL: ARM runtime scripts still depend on the x86 guest dispatcher path.' >&2
  exit 1
fi

case "${emulator_block}" in
  *'runtime-compatibility:'*'condition: service_completed_successfully'*) ;;
  *)
    printf '%s\n' 'FAIL: emulator is not gated by successful runtime compatibility.' >&2
    exit 1
    ;;
esac

case "${bridge_block}" in
  *'emulator:'*'condition: service_healthy'*) ;;
  *)
    printf '%s\n' 'FAIL: device bridge does not wait for the full emulator health contract.' >&2
    exit 1
    ;;
esac

case "${bridge_block}" in
  *'ADB_SERIAL: emulator:5555'*) ;;
  *)
    printf '%s\n' 'FAIL: device bridge no longer uses the external emulator ADB proxy.' >&2
    exit 1
    ;;
esac

case "${emulator_block}" in
  *'restart: "on-failure:3"'*) ;;
  *)
    printf '%s\n' 'FAIL: emulator restart policy is not bounded.' >&2
    exit 1
    ;;
esac

case "${emulator_block}" in
  *'restart: unless-stopped'*)
    printf '%s\n' 'FAIL: emulator still has an unbounded restart policy.' >&2
    exit 1
    ;;
esac

grep -q 'ARM64 / OrbStack hybrid engine' "${ROOT}/docker/emulator/README.md"
grep -Fq 'gic-version=3' "${ROOT}/docker/emulator/README.md"
grep -Fq 'cortex-a57' "${ROOT}/docker/emulator/README.md"
grep -Fq 'locked final raw QEMU tail' "${ROOT}/docker/emulator/README.md"
grep -q 'hybrid-aemu-arm64' "${ROOT}/README.md"
if grep -Fq 'emulator.version=36.6.11' "${ROOT}/docker/emulator/bin/runtime-preflight.sh"; then
  printf '%s\n' 'FAIL: preflight still labels the SDK artifact version as the selected native engine.' >&2
  exit 1
fi
grep -q '不会修改' "${ROOT}/README.md"
grep -Fq 'ANDROID_RELEASE_STATUS = "stable"' "${evidence_google_repo}"
grep -Fq 'base final/stable release' "${ROOT}/docker/emulator/README.md"
grep -Fq 'Android 17 QPR1 remains Beta and is excluded' "${ROOT}/docker/emulator/README.md"
grep -Fq 'channel-0' "${ROOT}/docker/emulator/README.md"
grep -Fq 'independent evidence' "${ROOT}/docker/emulator/README.md"
grep -Fq 'x86_64 host build' "${ROOT}/docker/emulator/README.md"
grep -Fq 'runtime verification are deferred' "${ROOT}/docker/emulator/README.md"
if grep -Eqi 'Android 17 development|development/latest.public package' \
  "${ROOT}/README.md" "${ROOT}/docker/emulator/README.md" \
  "${ROOT}/services/evidence-gate/README.md"; then
  printf '%s\n' 'FAIL: documentation still misstates the released Android 17 base as development.' >&2
  exit 1
fi
grep -Fq 'HEALTHCHECK --start-period=60m --interval=30s --timeout=15s --retries=10' \
  "${emulator_dockerfile}"
grep -Fq 'The 60-minute health start period accommodates cold ARM64 TCG initialization' \
  "${emulator_readme}"
if grep -q 'KVM_GID:-0' "${ROOT}/compose.kvm.yaml"; then
  printf '%s\n' 'FAIL: KVM override silently falls back to the root group.' >&2
  exit 1
fi
grep -q 'KVM_GID must be supplied by androidctl' "${ROOT}/compose.kvm.yaml"

printf '%s\n' 'PASS: Compose hybrid runtime and fail-closed contracts'
