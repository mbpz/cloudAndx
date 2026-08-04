#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
RUNNER=${ROOT}/scripts/native-android17.sh
TMP=$(mktemp -d)
FAKE_BIN=${TMP}/bin
SDK=${TMP}/sdk
RUNTIME=${TMP}/runtime
STATE=${TMP}/launch.state

cleanup() {
  if [ -s "${STATE}" ]; then
    kill "$(cat "${STATE}")" 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

mkdir -p \
  "${FAKE_BIN}" \
  "${SDK}/cmdline-tools/latest/bin" \
  "${SDK}/emulator" \
  "${SDK}/platform-tools" \
  "${SDK}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a" \
  "${RUNTIME}/avd/CloudAndx_Android_17_Play.avd" \
  "${TMP}/java/bin"

printf '%s\n' 'Pkg.Revision=37.1.11' >"${SDK}/emulator/source.properties"
printf '%s\n' 'Pkg.Revision=37.0.1' >"${SDK}/platform-tools/source.properties"
printf '%s\n' '<major>6</major>' \
  >"${SDK}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/package.xml"
printf '%s\n' 'hw.sdCard=yes' 'PlayStore.enabled=no' \
  >"${RUNTIME}/avd/CloudAndx_Android_17_Play.avd/config.ini"

printf '%s\n' '#!/bin/sh' 'exit 0' >"${SDK}/cmdline-tools/latest/bin/sdkmanager"
cp "${SDK}/cmdline-tools/latest/bin/sdkmanager" "${SDK}/cmdline-tools/latest/bin/avdmanager"
cp "${SDK}/cmdline-tools/latest/bin/sdkmanager" "${TMP}/java/bin/java"

printf '%s\n' \
  '#!/bin/sh' \
  'case ${1:-} in' \
  '  -s) echo Darwin ;;' \
  '  -m) echo arm64 ;;' \
  '  *) exit 1 ;;' \
  'esac' >"${FAKE_BIN}/uname"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = -accel-check ]; then' \
  '  echo "Hypervisor.Framework OS X"' \
  '  exit 0' \
  'fi' \
  'exit 0' >"${SDK}/emulator/emulator"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = info ]; then exit 0; fi' \
  'if [ "${1:-}" = compose ]; then' \
  '  for argument do [ "${argument}" = stop ] && [ "${DOCKER_STOP_FAIL:-0}" = 1 ] && exit 1; done' \
  '  exit 0' \
  'fi' \
  'exit 1' >"${FAKE_BIN}/docker"

printf '%s\n' \
  '#!/bin/sh' \
  'case ${1:-} in' \
  '  remove)' \
  '    if [ -s "${FAKE_LAUNCH_STATE}" ]; then kill "$(cat "${FAKE_LAUNCH_STATE}")" 2>/dev/null || true; fi' \
  '    rm -f "${FAKE_LAUNCH_STATE}" ;;' \
  '  submit)' \
  '    sleep 60 &' \
  '    echo $! >"${FAKE_LAUNCH_STATE}" ;;' \
  '  print)' \
  '    [ -s "${FAKE_LAUNCH_STATE}" ] || exit 1' \
  '    echo "pid = $(cat "${FAKE_LAUNCH_STATE}")" ;;' \
  '  *) exit 1 ;;' \
  'esac' >"${FAKE_BIN}/launchctl"

printf '%s\n' \
  '#!/bin/sh' \
  'case " $* " in' \
  '  *" getprop sys.boot_completed "*) echo "${ADB_BOOT_COMPLETED:-0}" ;;' \
  'esac' \
  'exit 0' >"${SDK}/platform-tools/adb"

printf '%s\n' \
  '#!/bin/sh' \
  'port=' \
  'for argument do case ${argument} in -iTCP:*) port=${argument#-iTCP:} ;; esac; done' \
  '[ -n "${port}" ] || exit 1' \
  'echo "p${FAKE_PID:-1}"' \
  'if [ "${LSOF_EXPOSE:-0}" = 1 ] && [ "${port}" = 8556 ]; then echo "n*:8556"; else echo "n127.0.0.1:${port}"; fi' \
  >"${FAKE_BIN}/lsof"

chmod +x "${FAKE_BIN}"/* "${SDK}/cmdline-tools/latest/bin"/* \
  "${SDK}/emulator/emulator" "${SDK}/platform-tools/adb" "${TMP}/java/bin/java"

run_native() {
  env \
    PATH="${FAKE_BIN}:/usr/bin:/bin" \
    CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
    CLOUDANDX_JAVA_HOME="${TMP}/java" \
    CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
    CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS=2 \
    CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
    FAKE_LAUNCH_STATE="${STATE}" \
    "$@" "${RUNNER}" start
}

if run_native DOCKER_STOP_FAIL=1 >/dev/null 2>&1; then
  echo 'FAIL: Docker stop failure was accepted' >&2
  exit 1
fi
[ ! -e "${STATE}" ]

if run_native ADB_BOOT_COMPLETED=0 >/dev/null 2>&1; then
  echo 'FAIL: boot timeout was accepted' >&2
  exit 1
fi
[ ! -e "${STATE}" ]
[ ! -e "${RUNTIME}/emulator.pid" ]

if run_native ADB_BOOT_COMPLETED=1 LSOF_EXPOSE=1 >/dev/null 2>&1; then
  echo 'FAIL: non-loopback listener was accepted' >&2
  exit 1
fi
[ ! -e "${STATE}" ]
[ ! -e "${RUNTIME}/emulator.pid" ]

run_native ADB_BOOT_COMPLETED=1 >/dev/null
[ -s "${STATE}" ]
env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  "${RUNNER}" stop >/dev/null
[ ! -e "${STATE}" ]
[ ! -e "${RUNTIME}/emulator.pid" ]

printf '%s\n' 'PASS: native macOS lifecycle and security behavior'
