#!/bin/sh
set -eu

architecture=${1:-${DOCKER_ENGINE_ARCHITECTURE:-}}
implementation=${ANDROID_RUNTIME_IMPLEMENTATION:-}

if [ -z "${architecture}" ]; then
  printf '%s\n' 'ERROR: Docker Engine architecture was not supplied by androidctl; refusing direct startup.' >&2
  exit 78
fi

case "${architecture}" in
  x86_64|amd64)
    printf 'ERROR: runtime architecture %s is deferred until the x86_64 path is built and verified on x86_64 hardware.\n' "${architecture}" >&2
    exit 78
    ;;
  arm64|aarch64)
    if [ "${implementation}" != hybrid-aemu-arm64 ]; then
      printf 'ERROR: runtime architecture %s requires ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64.\n' "${architecture}" >&2
      exit 78
    fi
    printf 'runtime-architecture=%s supported engine=native-aemu-arm64 guest=arm64-v8a\n' "${architecture}"
    ;;
  *)
    printf 'ERROR: unknown runtime architecture %s; refusing to start.\n' "${architecture}" >&2
    exit 78
    ;;
esac
