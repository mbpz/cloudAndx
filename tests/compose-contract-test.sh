#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
compose_file=${ROOT}/compose.yaml

grep -q '^  runtime-compatibility:$' "${compose_file}"
grep -q 'DOCKER_ENGINE_ARCHITECTURE:' "${compose_file}"
grep -q 'ANDROID_RUNTIME_IMPLEMENTATION:' "${compose_file}"
grep -q '^networks:$' "${compose_file}"
grep -q 'enable_ipv6: true' "${compose_file}"
grep -q 'fd37:17:37::/64' "${compose_file}"
emulator_block=$(sed -n '/^  emulator:$/,/^  device-bridge:$/p' "${compose_file}")
bridge_block=$(sed -n '/^  device-bridge:$/,/^  controller:$/p' "${compose_file}")

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
grep -q 'hybrid-aemu-arm64' "${ROOT}/README.md"
grep -q '不会修改' "${ROOT}/README.md"
if grep -q 'KVM_GID:-0' "${ROOT}/compose.kvm.yaml"; then
  printf '%s\n' 'FAIL: KVM override silently falls back to the root group.' >&2
  exit 1
fi
grep -q 'KVM_GID must be supplied by androidctl' "${ROOT}/compose.kvm.yaml"

printf '%s\n' 'PASS: Compose hybrid runtime and fail-closed contracts'
