#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
compose_file=${ROOT}/compose.yaml

grep -q '^  runtime-compatibility:$' "${compose_file}"
grep -q 'DOCKER_ENGINE_ARCHITECTURE:' "${compose_file}"
emulator_block=$(sed -n '/^  emulator:$/,/^  device-bridge:$/p' "${compose_file}")

case "${emulator_block}" in
  *'runtime-compatibility:'*'condition: service_completed_successfully'*) ;;
  *)
    printf '%s\n' 'FAIL: emulator is not gated by successful runtime compatibility.' >&2
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

if grep -q 'Run on the current ARM64 OrbStack engine' "${ROOT}/docker/emulator/README.md"; then
  printf '%s\n' 'FAIL: emulator README still advertises the rejected ARM64 run path.' >&2
  exit 1
fi
grep -q 'ARM64 / OrbStack is deliberately blocked' "${ROOT}/docker/emulator/README.md"
grep -q 'runtime=blocked-requires-native-x86_64-linux' "${ROOT}/README.md"
if grep -q 'KVM_GID:-0' "${ROOT}/compose.kvm.yaml"; then
  printf '%s\n' 'FAIL: KVM override silently falls back to the root group.' >&2
  exit 1
fi
grep -q 'KVM_GID must be supplied by androidctl' "${ROOT}/compose.kvm.yaml"

printf '%s\n' 'PASS: Compose and documentation fail-closed contracts'
