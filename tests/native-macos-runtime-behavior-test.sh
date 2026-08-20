#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
RUNNER=${ROOT}/scripts/native-android17.sh
export CLOUDANDX_RUNTIME_MODE=development-sdk
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
  'for argument do' \
  '  if [ "${argument}" = -snapshot-list ]; then' \
  '    [ ! -f "${FAKE_SNAPSHOT_LIST}" ] || cat "${FAKE_SNAPSHOT_LIST}"' \
  '    exit 0' \
  '  fi' \
  'done' \
  'for argument do [ "${argument}" = cloudandx-ready ] && echo "Successfully loaded snapshot '\''cloudandx-ready'\''"; done' \
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
  '  bootout)' \
  '    [ -z "${FAKE_LIFECYCLE_LOG:-}" ] || printf "%s\\n" bootout >>"${FAKE_LIFECYCLE_LOG}"' \
  '    if [ -s "${FAKE_LAUNCH_STATE}" ]; then kill "$(cat "${FAKE_LAUNCH_STATE}")" 2>/dev/null || true; fi' \
  '    rm -f "${FAKE_LAUNCH_STATE}" "${FAKE_LAUNCH_STATE}.plist" ;;' \
  '  bootstrap)' \
  '    [ -z "${FAKE_LIFECYCLE_LOG:-}" ] || printf "%s\\n" bootstrap >>"${FAKE_LIFECYCLE_LOG}"' \
  '    cp "${3}" "${FAKE_LAUNCH_STATE}.plist" ;;' \
  '  kickstart)' \
  '    [ -z "${FAKE_LIFECYCLE_LOG:-}" ] || printf "%s\\n" kickstart >>"${FAKE_LIFECYCLE_LOG}"' \
  '    log_file=$(sed -n "s#.*<key>StandardOutPath</key><string>\(.*\)</string>.*#\1#p" "${FAKE_LAUNCH_STATE}.plist")' \
  '    grep -Fq "cloudandx-ready" "${FAKE_LAUNCH_STATE}.plist" && printf "%s\n" "Successfully loaded snapshot '\''cloudandx-ready'\''" >"${log_file}"' \
  '    sleep 60 &' \
  '    echo $! >"${FAKE_LAUNCH_STATE}"' \
  '    if [ -n "${FAKE_LAUNCH_COUNT:-}" ]; then count=0; [ ! -f "${FAKE_LAUNCH_COUNT}" ] || count=$(cat "${FAKE_LAUNCH_COUNT}"); echo $((count + 1)) >"${FAKE_LAUNCH_COUNT}"; fi ;;' \
  '  print)' \
  '    [ -s "${FAKE_LAUNCH_STATE}" ] || exit 1' \
  '    echo "pid = $(cat "${FAKE_LAUNCH_STATE}")" ;;' \
  '  *) exit 1 ;;' \
  'esac' >"${FAKE_BIN}/launchctl"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = --version ]; then echo "scrcpy 4.1"; exit 0; fi' \
  'printf "%s %s\\n" "$0" "$*" >>"${FAKE_SCRCPY_LOG}"' \
  'exit 0' >"${FAKE_BIN}/scrcpy"

printf '%s\n' \
  '#!/bin/sh' \
  'case " $* " in' \
  '  *" getprop sys.boot_completed "*) echo "${ADB_BOOT_COMPLETED:-0}" ;;' \
  '  *" service check "*) echo "Service: found" ;;' \
  '  *" emu avd snapshot save "*) [ "${ADB_SNAPSHOT_SAVE_FAIL:-0}" = 1 ] && exit 1; mkdir -p "${CLOUDANDX_NATIVE_RUNTIME_ROOT}/avd/CloudAndx_Android_17_Play.avd/snapshots/cloudandx-ready"; if [ "${ADB_SNAPSHOT_SAVE_OMIT_ENTITY:-0}" = 1 ]; then tag=cloudandx-ready-old; else tag=cloudandx-ready; fi; printf "%s\n" "List of snapshots present on all disks:" "ID        TAG                 VM SIZE   DATE" "--        ${tag} 74M       2026-08-12" "OK" >"${FAKE_SNAPSHOT_LIST}" ;;' \
  '  *" emu avd snapshot list "*) [ -f "${FAKE_SNAPSHOT_LIST}" ] && cat "${FAKE_SNAPSHOT_LIST}" ;;' \
  '  *" emu avd snapshot load "*) [ "${ADB_SNAPSHOT_LOAD_FAIL:-0}" = 1 ] && exit 1 ;;' \
  '  *" shell sync "*) exit 0 ;;' \
  '  *" install -r "*) echo Success ;;' \
  '  *" push "*) echo "1 file pushed" ;;' \
  '  *" exec-out screencap -p "*) printf "\211PNG\r\n\032\ncloudandx" ;;' \
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

mkdir -p "${RUNTIME}/avd/unsafe&name.avd"
printf '%s\n' 'hw.sdCard=no' 'PlayStore.enabled=yes' >"${RUNTIME}/avd/unsafe&name.avd/config.ini"
if unsafe_output=$(run_native ADB_BOOT_COMPLETED=1 CLOUDANDX_NATIVE_AVD_NAME='unsafe&name' 2>&1); then
  echo 'FAIL: unsafe XML LaunchAgent value was accepted' >&2
  exit 1
fi
printf '%s\n' "${unsafe_output}" | grep -Fq 'LaunchAgent plist value contains unsafe XML characters'
[ ! -e "${STATE}" ]

if unsafe_output=$(run_native ADB_BOOT_COMPLETED=1 CLOUDANDX_NATIVE_GRPC_PORT='8556&unsafe' 2>&1); then
  echo 'FAIL: unsafe XML LaunchAgent port was accepted' >&2
  exit 1
fi
printf '%s\n' "${unsafe_output}" | grep -Fq 'LaunchAgent plist value contains unsafe XML characters'
[ ! -e "${STATE}" ]

launch_count=${TMP}/launch.count
run_native ADB_BOOT_COMPLETED=1 FAKE_LAUNCH_COUNT="${launch_count}" >/dev/null
first_pid=$(cat "${STATE}")
[ -f "${STATE}.plist" ]
grep -Fq '<key>KeepAlive</key><false/>' "${STATE}.plist"
/usr/bin/plutil -lint "${STATE}.plist" >/dev/null
kill "${first_pid}" 2>/dev/null || true
sleep 1
[ "$(cat "${launch_count}")" = 1 ]
if kill -0 "${first_pid}" 2>/dev/null; then
  echo 'FAIL: exited LaunchAgent child was restarted' >&2
  exit 1
fi
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
[ ! -e "${STATE}.plist" ]

# scrcpy is interaction-only: a stopped runtime must not start/stop/relaunch,
# and a ready runtime must exec the fixed 4.1 client exactly once.
scrcpy_log=${TMP}/scrcpy.log
lifecycle_log=${TMP}/scrcpy-lifecycle.log
if env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_SCRCPY_BIN="${FAKE_BIN}/scrcpy" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_LIFECYCLE_LOG="${lifecycle_log}" \
  FAKE_SCRCPY_LOG="${scrcpy_log}" \
  ADB_BOOT_COMPLETED=1 \
  "${RUNNER}" scrcpy >/dev/null 2>&1; then
  echo 'FAIL: stopped runtime accepted scrcpy' >&2
  exit 1
fi
[ ! -e "${scrcpy_log}" ]
[ ! -e "${lifecycle_log}" ]

run_native ADB_BOOT_COMPLETED=1 >/dev/null
ready_pid=$(cat "${STATE}")
rm -f "${scrcpy_log}" "${lifecycle_log}"
env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_SCRCPY_BIN="${FAKE_BIN}/scrcpy" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_LIFECYCLE_LOG="${lifecycle_log}" \
  FAKE_SCRCPY_LOG="${scrcpy_log}" \
  ADB_BOOT_COMPLETED=1 \
  "${RUNNER}" scrcpy >/dev/null
[ "$(cat "${STATE}")" = "${ready_pid}" ]
[ ! -e "${lifecycle_log}" ]
[ "$(wc -l <"${scrcpy_log}" | tr -d ' ')" = 1 ]
grep -Fq "${FAKE_BIN}/scrcpy --serial emulator-5556" "${scrcpy_log}"
grep -Fq -- '--no-audio --stay-awake' "${scrcpy_log}"
env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  ADB_BOOT_COMPLETED=1 \
  "${RUNNER}" snapshot-save >/dev/null
[ -f "${RUNTIME}/trusted-snapshot.env" ]
grep -Fq 'snapshot_name=cloudandx-ready' "${RUNTIME}/trusted-snapshot.env"

if env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  ADB_BOOT_COMPLETED=1 \
  ADB_SNAPSHOT_SAVE_OMIT_ENTITY=1 \
  "${RUNNER}" snapshot-save >/dev/null 2>&1; then
  echo 'FAIL: snapshot save accepted directory without named entity evidence' >&2
  exit 1
fi

env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  ADB_BOOT_COMPLETED=1 \
  "${RUNNER}" snapshot-save >/dev/null

snapshot_status=$(env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  "${RUNNER}" snapshot-status)
printf '%s\n' "${snapshot_status}" | grep -Fq 'snapshot_ready=1'

printf '%s\n' \
  'List of snapshots present on all disks:' \
  'ID        TAG                 VM SIZE   DATE' \
  '--        cloudandx-ready-old 74M       2026-08-12' \
  'OK' >"${TMP}/snapshot.list"
snapshot_status=$(env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  "${RUNNER}" snapshot-status)
printf '%s\n' "${snapshot_status}" | grep -Fq 'snapshot_ready=0'

if env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  "${RUNNER}" snapshot-resume >/dev/null 2>&1; then
  echo 'FAIL: snapshot resume accepted stale named entity evidence' >&2
  exit 1
fi

printf '%s\n' \
  'List of snapshots present on all disks:' \
  'ID        TAG                 VM SIZE   DATE' \
  '--        cloudandx-ready 74M       2026-08-12' \
  'OK' >"${TMP}/snapshot.list"

printf '%s\n' 'snapshot.test.drift=yes' >>"${RUNTIME}/avd/CloudAndx_Android_17_Play.avd/config.ini"
snapshot_status=$(env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  "${RUNNER}" snapshot-status)
printf '%s\n' "${snapshot_status}" | grep -Fq 'snapshot_incompatible=1'

printf '%s\n' 'hw.sdCard=no' 'PlayStore.enabled=yes' \
  >"${RUNTIME}/avd/CloudAndx_Android_17_Play.avd/config.ini"
env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  ADB_BOOT_COMPLETED=1 \
  "${RUNNER}" snapshot-resume >/dev/null

env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  "${RUNNER}" stop >/dev/null

snapshot_status=$(env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  "${RUNNER}" snapshot-status)
printf '%s\n' "${snapshot_status}" | grep -Fq 'snapshot_ready=1'

printf '%s\n' \
  'List of snapshots present on all disks:' \
  'ID        TAG                 VM SIZE   DATE' \
  '--        cloudandx-ready-old 74M       2026-08-12' \
  'OK' >"${TMP}/snapshot.list"
snapshot_status=$(env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  "${RUNNER}" snapshot-status)
printf '%s\n' "${snapshot_status}" | grep -Fq 'snapshot_ready=0'

if env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  "${RUNNER}" snapshot-resume >/dev/null 2>&1; then
  echo 'FAIL: stopped snapshot resume accepted stale named entity evidence' >&2
  exit 1
fi

printf '%s\n' \
  'List of snapshots present on all disks:' \
  'ID        TAG                 VM SIZE   DATE' \
  '--        cloudandx-ready 74M       2026-08-12' \
  'OK' >"${TMP}/snapshot.list"

env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  FAKE_SNAPSHOT_LIST="${TMP}/snapshot.list" \
  ADB_BOOT_COMPLETED=1 \
  "${RUNNER}" snapshot-resume >/dev/null
[ -s "${STATE}" ]

printf '%s\n' 'apk' >"${TMP}/sample.apk"
printf '%s\n' 'document' >"${TMP}/document.txt"
env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  ADB_BOOT_COMPLETED=1 \
  CLOUDANDX_NATIVE_APK_PATH="${TMP}/sample.apk" \
  "${RUNNER}" install-apk >/dev/null
env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  ADB_BOOT_COMPLETED=1 \
  CLOUDANDX_NATIVE_HOST_FILE_PATH="${TMP}/document.txt" \
  "${RUNNER}" push-file >/dev/null
env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  ADB_BOOT_COMPLETED=1 \
  CLOUDANDX_NATIVE_SCREENSHOT_PATH="${TMP}/screen.png" \
  "${RUNNER}" capture-screenshot >/dev/null
[ "$(od -An -tx1 -N8 "${TMP}/screen.png" | tr -d ' \n')" = 89504e470d0a1a0a ]

ln -s "${TMP}/sample.apk" "${TMP}/linked.apk"
if env \
  PATH="${FAKE_BIN}:/usr/bin:/bin" \
  CLOUDANDX_ANDROID_SDK_ROOT="${SDK}" \
  CLOUDANDX_JAVA_HOME="${TMP}/java" \
  CLOUDANDX_NATIVE_RUNTIME_ROOT="${RUNTIME}" \
  CLOUDANDX_LSOF_BIN="${FAKE_BIN}/lsof" \
  FAKE_LAUNCH_STATE="${STATE}" \
  ADB_BOOT_COMPLETED=1 \
  CLOUDANDX_NATIVE_APK_PATH="${TMP}/linked.apk" \
  "${RUNNER}" install-apk >/dev/null 2>&1; then
  echo 'FAIL: symlink APK input was accepted' >&2
  exit 1
fi

printf '%s\n' 'PASS: native macOS lifecycle and security behavior'
