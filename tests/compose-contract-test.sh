#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
compose_file=${ROOT}/compose.yaml
dockerfile=${ROOT}/docker/emulator/Dockerfile
entrypoint=${ROOT}/docker/emulator/bin/entrypoint.sh
supervisor=${ROOT}/docker/emulator/bin/single-container-entrypoint.sh
healthcheck=${ROOT}/docker/emulator/bin/healthcheck.sh
runtime_lib=${ROOT}/docker/emulator/bin/runtime-lib.sh
preflight=${ROOT}/docker/emulator/bin/runtime-preflight.sh
avd_config=${ROOT}/docker/emulator/avd/config.ini

# Default runtime must be exactly one service/container and one image.
runtime_services=$(awk '
  /^services:/ { in_services=1; next }
  in_services && /^  [a-zA-Z0-9_-]+:$/ {
    service=$1; sub(/:$/, "", service)
    if (service != "native-engine") print service
  }
  /^volumes:/ { in_services=0 }
' "${compose_file}")
[ "${runtime_services}" = emulator ] || {
  printf 'FAIL: expected only emulator runtime service, got: %s\n' "${runtime_services}" >&2
  exit 1
}
grep -Fq 'image: cloudandx/android17-play-emulator:37.0-r06' "${compose_file}"
if grep -Eq '^  (device-bridge|evidence-gate|runtime-compatibility|volume-init|adb-key-init):' "${compose_file}"; then
  echo 'FAIL: auxiliary runtime containers must be folded into emulator' >&2
  exit 1
fi
grep -q '^  native-engine:$' "${compose_file}"
grep -Fq 'profiles: ["build"]' "${compose_file}"

# One process supervisor must retain every former boundary and fail closed.
grep -Fq '"${SCRIPT_DIR}/check-runtime-arch.sh"' "${supervisor}"
grep -Fq 'python3 -m evidence_gate preflight' "${supervisor}"
grep -Fq 'exec "${SCRIPT_DIR}/entrypoint.sh" "$@"' "${supervisor}"
grep -Fq 'initialize_single_container_state' "${entrypoint}"
grep -Fq '"${PYTHON_BIN}" "${BRIDGE_SCRIPT}" &' "${entrypoint}"
grep -Fq 'BRIDGE_PID=$!' "${entrypoint}"
grep -Fq 'device bridge exited unexpectedly' "${entrypoint}"
grep -Fq '"${BRIDGE_PID-}"' "${entrypoint}"
grep -Fq 'head -c 32 /dev/urandom' "${entrypoint}"
grep -Fq 'ADB_PRIVATE_KEY_FILE: /data/runtime/adb/adbkey' "${compose_file}"
grep -Fq 'PREFLIGHT_OUTPUT: /data/runtime/evidence/preflight.json' "${compose_file}"
grep -Fq 'BRIDGE_TOKEN_FILE: /data/runtime/secrets/token' "${compose_file}"
grep -Fq '127.0.0.1:${DEVICE_BRIDGE_PORT:-8090}:8090/tcp' "${compose_file}"
grep -Fq "urllib.request.urlopen('http://127.0.0.1:8090/livez'" "${healthcheck}"

# Host exposure remains loopback-only; authenticated Console is Unix-only.
grep -Fq '127.0.0.1:${ANDROID_ADB_PORT:-5555}:5555/tcp' "${compose_file}"
grep -Fq '127.0.0.1:${ANDROID_GRPC_PORT:-8554}:8554/tcp' "${compose_file}"
grep -Fq '127.0.0.1:${ANDROID_NOVNC_PORT:-6080}:6080/tcp' "${compose_file}"
grep -Fq 'NOVNC_PORT: "6080"' "${compose_file}"
grep -Fq 'NOVNC_TLS: "true"' "${compose_file}"
grep -Fq 'VNC_PORT: "5900"' "${compose_file}"
if grep -Eq '127\.0\.0\.1:.*:5900|0\.0\.0\.0:.*:(5555|5900|6080|8090|8554)' "${compose_file}"; then
  echo 'FAIL: raw VNC and public remote-control ports must not be published' >&2
  exit 1
fi
if grep -Eq '(^|[^0-9])(5554|5556)([^0-9]|$)' "${compose_file}"; then
  echo 'FAIL: authenticated Console must not be published' >&2
  exit 1
fi
grep -Fq 'EMULATOR_CONSOLE_SOCKET: /data/runtime/console/console.sock' "${compose_file}"
grep -Fq 'UNIX-LISTEN:${EMULATOR_CONSOLE_SOCKET}' "${entrypoint}"

# Locked Android/native identities remain unchanged.
grep -Fq 'NATIVE_AEMU_REVISION: ${NATIVE_AEMU_REVISION:-37.1.7}' "${compose_file}"
grep -Fq 'arm64-v8a-playstore-ps16k-37.0_r06.zip' "${dockerfile}"
grep -Fq 'SYSTEM_IMAGE_SHA1=ef7d53e7b2fba3cf00917364f6d3e4f6dbebe7b4' "${dockerfile}"
grep -Fxq 'abi.type=arm64-v8a' "${avd_config}"
grep -Fxq 'hw.cpu.arch=arm64' "${avd_config}"
grep -Fq 'qemu/linux-aarch64/qemu-system-aarch64-headless' "${runtime_lib}"
grep -Fq 'system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a' "${preflight}"
grep -Fq 'HEALTHCHECK --start-period=60m' "${dockerfile}"
grep -Fq 'EXPOSE 5555/tcp 6080/tcp 8090/tcp 8554/tcp' "${dockerfile}"

# Browser interaction stays inside the one supervised runtime image.
grep -Fq 'NOVNC_VERSION=1.7.0' "${dockerfile}"
grep -Fq 'WEBSOCKIFY_VERSION=0.13.0' "${dockerfile}"
grep -Fq 'SCRCPY_VERSION=4.1' "${dockerfile}"
grep -Fq 'Xvfb' "${entrypoint}"
grep -Fq 'x11vnc' "${entrypoint}"
grep -Fq 'websockify' "${entrypoint}"
grep -Fq -- '--ssl-only' "${entrypoint}"
grep -Fq 'XVFB_RESOLUTION=${XVFB_RESOLUTION:-1080x2424x24}' "${entrypoint}"
grep -Fq -- '--fullscreen --window-borderless' "${entrypoint}"
grep -Fq 'scrcpy' "${entrypoint}"
grep -Fq 'noVNC exited unexpectedly' "${entrypoint}"

# Container remains least-privileged with one persistent project volume.
grep -Fq 'read_only: true' "${compose_file}"
grep -Fq 'no-new-privileges:true' "${compose_file}"
grep -Fq 'cap_drop:' "${compose_file}"
[ "$(grep -Ec '^  emulator-data:$' "${compose_file}" | tr -d ' ')" -eq 1 ]

printf '%s\n' 'PASS: single-container Android runtime contracts'
