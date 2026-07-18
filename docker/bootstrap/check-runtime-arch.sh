#!/bin/sh
set -eu

architecture=${1:-${DOCKER_ENGINE_ARCHITECTURE:-}}

if [ -z "${architecture}" ]; then
  printf '%s\n' 'ERROR: Docker Engine architecture was not supplied by androidctl; refusing direct startup.' >&2
  exit 78
fi

case "${architecture}" in
  x86_64|amd64)
    printf 'runtime-architecture=%s supported\n' "${architecture}"
    ;;
  arm64|aarch64)
    printf 'ERROR: runtime architecture %s is unsupported.\n' "${architecture}" >&2
    printf '%s\n' 'Google does not publish a Linux ARM64 Android Emulator host binary.' >&2
    printf '%s\n' 'Cross-architecture Rosetta/QEMU execution is not a full-function runtime.' >&2
    exit 78
    ;;
  *)
    printf 'ERROR: unknown runtime architecture %s; refusing to start.\n' "${architecture}" >&2
    exit 78
    ;;
esac
