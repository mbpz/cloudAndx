#!/bin/sh
set -eu

IMAGE=${1-}

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: docker CLI is not available.' >&2
  exit 1
}

docker info >/dev/null 2>&1 || {
  printf '%s\n' 'ERROR: Docker Engine is not reachable.' >&2
  exit 1
}

server_os=$(docker info --format '{{.OSType}}')
server_arch=$(docker info --format '{{.Architecture}}')
server_memory=$(docker info --format '{{.MemTotal}}')
server_cpus=$(docker info --format '{{.NCPU}}')

[ "${server_os}" = linux ] || {
  printf 'ERROR: the Android Emulator image requires a Linux Docker engine; got %s.\n' "${server_os}" >&2
  exit 1
}

printf '%s\n' \
  "docker.server-os=${server_os}" \
  "docker.server-arch=${server_arch}" \
  "docker.cpus=${server_cpus}" \
  "docker.memory-bytes=${server_memory}" \
  'required.image-platform=linux/amd64' \
  'required.host-mutations=none'

case "${server_arch}" in
  x86_64|amd64) ;;
  *)
    printf 'ERROR: a native x86_64 Linux Docker engine is required; got %s.\n' "${server_arch}" >&2
    printf '%s\n' 'No host or Docker Engine setting was changed.' >&2
    exit 78
    ;;
esac

if [ -n "${IMAGE}" ]; then
  image_os=$(docker image inspect "${IMAGE}" --format '{{.Os}}')
  image_arch=$(docker image inspect "${IMAGE}" --format '{{.Architecture}}')
  [ "${image_os}/${image_arch}" = linux/amd64 ] || {
    printf 'ERROR: image %s is %s/%s, expected linux/amd64.\n' "${IMAGE}" "${image_os}" "${image_arch}" >&2
    exit 1
  }

  docker run --rm \
    --platform linux/amd64 \
    --network none \
    --read-only \
    --security-opt no-new-privileges \
    --cap-drop ALL \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
    --env "DOCKER_ENGINE_ARCHITECTURE=${server_arch}" \
    "${IMAGE}" preflight
fi
