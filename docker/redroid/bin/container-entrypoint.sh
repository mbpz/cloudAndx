#!/usr/bin/dash
set -eu

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

# Android init must remain PID 1. The supervisor kills PID 1 if a mandatory UI
# process exits, preserving the one-container fail-closed boundary.
exec /init qemu=1 androidboot.hardware=redroid "$@"
