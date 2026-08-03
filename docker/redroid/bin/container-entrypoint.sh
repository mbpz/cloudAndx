#!/usr/bin/dash
set -eu

log() { printf '%s\n' "cloudandx-runtime: $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "runtime architecture $(uname -m) is not ARM64" ;;
esac

page_size=$(getconf PAGESIZE 2>/dev/null || true)
[ "${page_size}" = 4096 ] || die "page size is ${page_size:-unknown}; expected 4096"

ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf '1')
[ "${ipv6_disabled}" = 0 ] || die 'IPv6 is disabled in the Docker Linux runtime'

for device in \
  /dev/ashmem \
  /dev/dma_heap/system \
  /dev/binder \
  /dev/hwbinder \
  /dev/vndbinder; do
  [ -c "${device}" ] || die "required character device is missing: ${device}"
done

log 'runtime preflight passed'

umask 077
mkdir -p /data/runtime
rm -f /data/runtime/scrcpy-first-frame.ready
mkdir -p /data/runtime/bridge
if [ ! -s /data/runtime/bridge/token ]; then
  /usr/bin/openssl rand -hex 32 >/data/runtime/bridge/token
fi
chmod 0600 /data/runtime/bridge/token

/usr/bin/dash /opt/cloudandx/bin/ui-supervisor.sh &
supervisor_pid=$!
printf '%s\n' "${supervisor_pid}" >/data/runtime/ui-supervisor.pid

# Android init must remain PID 1. The supervisor closes every remote-control
# surface if a mandatory UI process exits, leaving Docker health unhealthy so
# the configured restart policy can recover the whole container.
exec /init qemu=1 androidboot.hardware=redroid "$@"
