#!/usr/bin/dash
set -eu

DISPLAY=${DISPLAY:-:0}
ADB_SERIAL=${ANDROID_ADB_SERIAL:-127.0.0.1:5555}
NOVNC_PORT=${NOVNC_PORT:-6080}
VNC_PORT=${VNC_PORT:-5900}
TLS_CERT=${NOVNC_TLS_CERT:-/data/runtime/novnc/tls-cert.pem}
TLS_KEY=${NOVNC_TLS_KEY:-/data/runtime/novnc/tls-key.pem}
READY_FILE=${SCRCPY_READY_FILE:-/data/runtime/scrcpy-first-frame.ready}
SCRCPY_LOG=/data/runtime/scrcpy.log

log() { printf '%s\n' "cloudandx-ui: $*"; }

fail() {
  log "ERROR: $*"
  # EXIT cleanup closes every remote-control surface. Android init deliberately
  # remains PID 1, so Docker health becomes unhealthy and external orchestration
  # can restart the container without exposing a partially supervised UI.
  exit 1
}

cleanup() {
  trap - EXIT INT TERM HUP
  rm -f "${READY_FILE}"
  for pid in "${BRIDGE_PID-}" "${SCRCPY_PID-}" "${NOVNC_PID-}" "${X11VNC_PID-}" "${OPENBOX_PID-}" "${XVFB_PID-}"; do
    [ -z "${pid}" ] || kill -TERM "${pid}" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM HUP

log "waiting for Android ${ADB_SERIAL}"
while :; do
  /usr/bin/adb connect "${ADB_SERIAL}" >/dev/null 2>&1 || true
  state=$(/usr/bin/adb -s "${ADB_SERIAL}" get-state 2>/dev/null || true)
  boot=$(/usr/bin/adb -s "${ADB_SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  [ "${state}" = device ] && [ "${boot}" = 1 ] && break
  sleep 1
done

ADB_PATH=/usr/bin/adb ADB_SERIAL="${ADB_SERIAL}" \
  BRIDGE_TOKEN_FILE=/data/runtime/bridge/token \
  MIN_ANDROID_API_LEVEL=36 EXPECTED_ANDROID_ABI=arm64-v8a \
  EXPECTED_PAGE_SIZE_BYTES=4096 REQUIRED_ANDROID_PACKAGES= \
  EMULATOR_CONSOLE_ENABLED=false LISTEN_HOST=0.0.0.0 LISTEN_PORT=8090 \
  /usr/bin/python3 /opt/cloudandx/device-bridge/bridge.py \
    >/data/runtime/device-bridge.log 2>&1 &
BRIDGE_PID=$!

mkdir -p /tmp/.X11-unix "$(dirname "${TLS_CERT}")"
chmod 1777 /tmp /tmp/.X11-unix
/usr/bin/Xvfb "${DISPLAY}" -screen 0 540x960x24 -nolisten tcp -ac &
XVFB_PID=$!

remaining=15
while [ "${remaining}" -gt 0 ]; do
  [ -S /tmp/.X11-unix/X0 ] && break
  kill -0 "${XVFB_PID}" 2>/dev/null || fail 'Xvfb exited before exposing DISPLAY=:0'
  sleep 1
  remaining=$((remaining - 1))
done
[ -S /tmp/.X11-unix/X0 ] || fail 'Xvfb socket was not ready in 15 seconds'

# Xvfb has no window manager. SDL can render without one, but it cannot
# reliably transfer focus when a VNC client sends the first click. A tiny
# in-container WM keeps the Android surface focused without adding a second
# runtime container or changing Android input semantics.
DISPLAY="${DISPLAY}" /usr/bin/openbox --sm-disable \
  --config-file /opt/cloudandx/openbox/rc.xml \
  >/data/runtime/openbox.log 2>&1 &
OPENBOX_PID=$!
sleep 1
kill -0 "${OPENBOX_PID}" 2>/dev/null || fail 'openbox exited before scrcpy started'

/usr/bin/x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" -localhost \
  -shared -forever -nopw -wait 1 -defer 1 -nonap -noxdamage -nowait_bog -quiet &
X11VNC_PID=$!

if [ ! -s "${TLS_CERT}" ] || [ ! -s "${TLS_KEY}" ]; then
  /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj '/CN=cloudAndx ReDroid noVNC' \
    -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    -keyout "${TLS_KEY}" -out "${TLS_CERT}" >/dev/null 2>&1
  chmod 0600 "${TLS_CERT}" "${TLS_KEY}"
fi

/usr/local/bin/websockify --web /opt/cloudandx/novnc \
  --cert "${TLS_CERT}" --key "${TLS_KEY}" --ssl-only \
  "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
NOVNC_PID=$!

: >"${SCRCPY_LOG}"
ADB=/usr/bin/adb SCRCPY_SERVER_PATH=/opt/cloudandx/scrcpy/scrcpy-server \
  DISPLAY="${DISPLAY}" SDL_VIDEODRIVER=x11 \
  SDL_VIDEO_X11_XINPUT2=0 SDL_MOUSE_FOCUS_CLICKTHROUGH=1 \
  /usr/bin/stdbuf -oL -eL /opt/cloudandx/scrcpy/scrcpy \
    --serial "${ADB_SERIAL}" --no-audio \
    --stay-awake --max-size=1080 --max-fps=60 --video-bit-rate=8M \
    --video-buffer=0 --mouse=sdk --keyboard=sdk \
    --window-x=0 --window-y=0 --window-width=540 --window-height=960 \
    --window-borderless --always-on-top --window-title='CloudAndx Android' \
    >"${SCRCPY_LOG}" 2>&1 &
SCRCPY_PID=$!

remaining=30
while [ "${remaining}" -gt 0 ]; do
  if grep -Fq 'INFO: Texture:' "${SCRCPY_LOG}"; then
    : >"${READY_FILE}"
    log 'scrcpy/noVNC first frame is ready'
    break
  fi
  kill -0 "${SCRCPY_PID}" 2>/dev/null || fail "scrcpy exited before first frame; see ${SCRCPY_LOG}"
  sleep 1
  remaining=$((remaining - 1))
done
[ -f "${READY_FILE}" ] || fail 'scrcpy produced no first frame in 30 seconds'

while :; do
  kill -0 "${XVFB_PID}" 2>/dev/null || fail 'Xvfb exited unexpectedly'
  kill -0 "${OPENBOX_PID}" 2>/dev/null || fail 'openbox exited unexpectedly'
  kill -0 "${X11VNC_PID}" 2>/dev/null || fail 'x11vnc exited unexpectedly'
  kill -0 "${NOVNC_PID}" 2>/dev/null || fail 'websockify exited unexpectedly'
  kill -0 "${SCRCPY_PID}" 2>/dev/null || fail 'scrcpy exited unexpectedly'
  kill -0 "${BRIDGE_PID}" 2>/dev/null || fail 'device bridge exited unexpectedly'
  sleep 2
done
