#!/bin/sh
set -eu

# ReDroid is a Linux kernel workload.  Docker context selection is deliberately
# left to the caller: this probe validates the capabilities exposed by the
# selected engine instead of treating one macOS VM provider as part of the
# application contract.

DOCKER_BIN=${DOCKER_BIN:-docker}
# The Android base intentionally has no POSIX userland shell. Use the same
# pinned ARM64 Debian base used by the final image's Linux tooling to inspect
# the selected engine's host devices.
PROBE_IMAGE=${REDROID_HOST_PROBE_IMAGE:-debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd}
PAGE_SIZE=${REDROID_PAGE_SIZE_BYTES:-4096}

log() { printf '%s\n' "cloudandx-host: $*"; }
die() { printf '%s\n' "cloudandx-host: ERROR: $*" >&2; exit 1; }

command -v "${DOCKER_BIN}" >/dev/null 2>&1 || die 'docker is required'

info=$(${DOCKER_BIN} info --format '{{.OSType}} {{.Architecture}} {{.KernelVersion}}' 2>/dev/null) \
  || die 'selected Docker context is unavailable'
set -- ${info}
ostype=${1:-}
architecture=${2:-}
kernel=${3:-unknown}
[ "${ostype}" = linux ] || die "Docker server OS is ${ostype:-unknown}; ReDroid requires Linux"
case "${architecture}" in
  aarch64|arm64) ;;
  *) die "Docker server architecture is ${architecture:-unknown}; this image is ARM64-only" ;;
esac

log "checking Docker Linux ${architecture} kernel ${kernel}"

# The probe uses the selected engine's own /dev namespace.  A privileged probe
# is intentional: the final Compose service is privileged as well, and a
# non-privileged check would report the container sandbox rather than the host
# kernel device contract.
${DOCKER_BIN} run --rm --privileged --platform linux/arm64 \
  --volume /dev:/cloudandx-host-dev:ro \
  --entrypoint /bin/sh "${PROBE_IMAGE}" -s cloudandx-host-probe "${PAGE_SIZE}" <<'EOF'
set -eu
expected_page_size=$1
page_size=$(getconf PAGESIZE 2>/dev/null || true)
[ "${page_size}" = "${expected_page_size}" ] || {
  echo "page size is ${page_size:-unknown}; expected ${expected_page_size}" >&2
  exit 1
}

ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf '1')
[ "${ipv6_disabled}" = 0 ] || {
  echo 'IPv6 is disabled in the Docker Linux runtime' >&2
  exit 1
}

for device in \
  /cloudandx-host-dev/ashmem \
  /cloudandx-host-dev/dma_heap/system \
  /cloudandx-host-dev/binderfs/binder \
  /cloudandx-host-dev/binderfs/hwbinder \
  /cloudandx-host-dev/binderfs/vndbinder; do
  [ -c "${device}" ] || {
    echo "required character device is missing: ${device}" >&2
    exit 1
  }
done

[ -d /cloudandx-host-dev/binderfs ] || {
  echo 'binderfs mount is missing' >&2
  exit 1
}
EOF

log 'ARM64, 4 KiB pages, IPv6, ashmem, binderfs and DMA-BUF are ready'
