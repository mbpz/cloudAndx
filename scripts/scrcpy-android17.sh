#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
CLIENT=${ROOT}/.runtime/scrcpy-4.1-arm-tcg/build/app/scrcpy
ADB_KEY=${ROOT}/.runtime/container-adb/adbkey
SERVER_JAR=/opt/homebrew/Cellar/scrcpy/4.1/share/scrcpy/scrcpy-server
SERIAL=${ANDROID_SERIAL:-127.0.0.1:5555}

test -x "${CLIENT}" || {
  echo >&2 "extended-timeout scrcpy client is not built; run scripts/build-scrcpy-arm-tcg-client.sh"
  exit 1
}
if ! test -s "${ADB_KEY}"; then
  install -d -m 0700 "$(dirname "${ADB_KEY}")"
  echo "Exporting the emulator's trusted ADB key into project-local .runtime..."
  docker compose -f "${ROOT}/compose.yaml" cp \
    emulator:/data/runtime/adb/adbkey "${ADB_KEY}"
  chmod 0600 "${ADB_KEY}"
fi
test -s "${SERVER_JAR}" || {
  echo >&2 "scrcpy 4.1 server is missing: ${SERVER_JAR}"
  exit 1
}

adb kill-server >/dev/null 2>&1 || true
ADB_VENDOR_KEYS=${ADB_KEY} adb start-server >/dev/null
adb connect "${SERIAL}"
SCRCPY_SERVER_PATH=${SERVER_JAR} \
  exec "${CLIENT}" --serial "${SERIAL}" --force-adb-forward --no-audio --stay-awake \
    --mouse=uhid --keyboard=uhid "$@"
