#!/bin/sh
set -eu

UPSTREAM_QEMU_ENGINE=${UPSTREAM_QEMU_ENGINE:-/opt/android-sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless.upstream-x86_64}
NATIVE_AEMU_ROOT=${NATIVE_AEMU_ROOT:-/opt/cloudandx/native-aemu}
NATIVE_AEMU_RUNNER=${NATIVE_AEMU_RUNNER:-${NATIVE_AEMU_ROOT}/bin/run-qemu-system-x86_64-headless}

case ${DOCKER_ENGINE_ARCHITECTURE-} in
  x86_64|amd64)
    [ -x "${UPSTREAM_QEMU_ENGINE}" ] || {
      printf 'ERROR: upstream Google x86_64 Emulator engine is missing: %s\n' "${UPSTREAM_QEMU_ENGINE}" >&2
      exit 127
    }
    printf '%s\n' '[android-emulator] selected upstream Google x86_64 AEMU child' >&2
    exec "${UPSTREAM_QEMU_ENGINE}" "$@"
    ;;
  arm64|aarch64)
    [ "${ANDROID_RUNTIME_IMPLEMENTATION-}" = hybrid-aemu-arm64 ] || {
      printf '%s\n' 'ERROR: ARM64 engine selection requires ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64.' >&2
      exit 78
    }
    [ -x "${NATIVE_AEMU_RUNNER}" ] || {
      printf 'ERROR: verified native AArch64 AEMU runner is missing: %s\n' "${NATIVE_AEMU_RUNNER}" >&2
      exit 127
    }
    printf '%s\n' '[android-emulator] selected native AArch64 AEMU child for the official Google x86_64 guest' >&2
    exec "${NATIVE_AEMU_RUNNER}" "$@"
    ;;
  '')
    printf '%s\n' 'ERROR: DOCKER_ENGINE_ARCHITECTURE is required; start through androidctl.' >&2
    exit 78
    ;;
  *)
    printf 'ERROR: unsupported Docker Engine architecture: %s\n' "${DOCKER_ENGINE_ARCHITECTURE}" >&2
    exit 78
    ;;
esac
