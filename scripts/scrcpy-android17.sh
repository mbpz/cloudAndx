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
test -s "${ADB_KEY}" || {
  echo >&2 "trusted emulator ADB key is missing: ${ADB_KEY}"
  exit 1
}
test -s "${SERVER_JAR}" || {
  echo >&2 "scrcpy 4.1 server is missing: ${SERVER_JAR}"
  exit 1
}

adb kill-server >/dev/null 2>&1 || true
ADB_VENDOR_KEYS=${ADB_KEY} adb start-server >/dev/null
adb connect "${SERIAL}" >/dev/null
SCRCPY_SERVER_PATH=${SERVER_JAR} \
  exec "${CLIENT}" --serial "${SERIAL}" --force-adb-forward --no-audio --stay-awake "$@"
