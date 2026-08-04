#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
RUNTIME_ROOT=${CLOUDANDX_NATIVE_RUNTIME_ROOT:-${ROOT}/.runtime/native-android17}
DEFAULT_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
SDK_ROOT=${CLOUDANDX_ANDROID_SDK_ROOT:-${ANDROID_SDK_ROOT:-${DEFAULT_SDK_ROOT}}}
if [ ! -x "${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" ] \
  && [ -z "${CLOUDANDX_ANDROID_SDK_ROOT:-}" ] \
  && [ -x "${DEFAULT_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager" ]; then
  SDK_ROOT=${DEFAULT_SDK_ROOT}
fi
DEFAULT_JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
JAVA_HOME=${CLOUDANDX_JAVA_HOME:-${JAVA_HOME:-${DEFAULT_JAVA_HOME}}}
if [ -x "${DEFAULT_JAVA_HOME}/bin/java" ] && [ -z "${CLOUDANDX_JAVA_HOME:-}" ]; then
  JAVA_HOME=${DEFAULT_JAVA_HOME}
fi
ANDROID_AVD_HOME=${RUNTIME_ROOT}/avd
ANDROID_EMULATOR_HOME=${RUNTIME_ROOT}/emulator-home
ANDROID_PREFS_ROOT=${RUNTIME_ROOT}/prefs
AVD_NAME=${CLOUDANDX_NATIVE_AVD_NAME:-CloudAndx_Android_17_Play}
SYSTEM_IMAGE='system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a'
EXPECTED_EMULATOR_VERSION=37.1.11
EXPECTED_PLATFORM_TOOLS_VERSION=37.0.1
EXPECTED_SYSTEM_IMAGE_REVISION=6
EXPECTED_SCRCPY_VERSION=4.1
CONSOLE_PORT=${CLOUDANDX_NATIVE_CONSOLE_PORT:-5556}
ADB_PORT=$((CONSOLE_PORT + 1))
GRPC_PORT=${CLOUDANDX_NATIVE_GRPC_PORT:-8556}
ADB_SERIAL=emulator-${CONSOLE_PORT}
EMULATOR=${SDK_ROOT}/emulator/emulator
ADB=${SDK_ROOT}/platform-tools/adb
SDKMANAGER=${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager
AVDMANAGER=${SDK_ROOT}/cmdline-tools/latest/bin/avdmanager
PID_FILE=${RUNTIME_ROOT}/emulator.pid
LOG_FILE=${RUNTIME_ROOT}/emulator.log
LAUNCH_LABEL=dev.cloudandx.android17
SCRCPY=${CLOUDANDX_SCRCPY_BIN:-/opt/homebrew/bin/scrcpy}
BOOT_TIMEOUT_SECONDS=${CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS:-120}
LSOF_BIN=${CLOUDANDX_LSOF_BIN:-lsof}

export JAVA_HOME ANDROID_SDK_ROOT=${SDK_ROOT} ANDROID_AVD_HOME ANDROID_EMULATOR_HOME ANDROID_PREFS_ROOT

log() { printf '%s\n' "cloudandx-native: $*"; }
die() { printf '%s\n' "cloudandx-native: ERROR: $*" >&2; exit 1; }

property_value() {
  key=$1
  file=$2
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "${file}" | head -n 1
}

require_host() {
  [ "$(uname -s)" = Darwin ] || die 'native runtime requires macOS'
  [ "$(uname -m)" = arm64 ] || die 'native runtime requires Apple Silicon'
  [ -x "${SDKMANAGER}" ] || die "sdkmanager is missing: ${SDKMANAGER}"
  [ -x "${AVDMANAGER}" ] || die "avdmanager is missing: ${AVDMANAGER}"
  [ -x "${JAVA_HOME}/bin/java" ] || die "JDK 17+ is missing: ${JAVA_HOME}"
  case ${BOOT_TIMEOUT_SECONDS} in *[!0-9]*|'') die 'boot timeout must be a positive integer' ;; esac
  [ "${BOOT_TIMEOUT_SECONDS}" -gt 0 ] || die 'boot timeout must be a positive integer'
}

available_package_version() {
  package=$1
  awk -F'|' -v package="${package}" '
    {
      path = $1
      version = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", path)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", version)
      if (path == package) found = version
    }
    END { print found }
  '
}

verify_repository_versions() {
  repository_packages=$("${SDKMANAGER}" --list)
  emulator_available=$(printf '%s\n' "${repository_packages}" | available_package_version emulator)
  platform_tools_available=$(printf '%s\n' "${repository_packages}" | available_package_version platform-tools)
  system_image_available=$(printf '%s\n' "${repository_packages}" | available_package_version "${SYSTEM_IMAGE}")
  [ "${emulator_available}" = "${EXPECTED_EMULATOR_VERSION}" ] \
    || die "Google repository offers Emulator ${emulator_available:-unknown}; expected ${EXPECTED_EMULATOR_VERSION}"
  [ "${platform_tools_available}" = "${EXPECTED_PLATFORM_TOOLS_VERSION}" ] \
    || die "Google repository offers Platform Tools ${platform_tools_available:-unknown}; expected ${EXPECTED_PLATFORM_TOOLS_VERSION}"
  [ "${system_image_available}" = "${EXPECTED_SYSTEM_IMAGE_REVISION}" ] \
    || die "Google repository offers Android image r${system_image_available:-unknown}; expected r${EXPECTED_SYSTEM_IMAGE_REVISION}"
}

validate_packages() {
  [ -x "${EMULATOR}" ] || die "Android Emulator is missing; run $0 setup"
  [ -x "${ADB}" ] || die "Platform Tools are missing; run $0 setup"
  image_dir=${SDK_ROOT}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a
  [ -d "${image_dir}" ] || die "Android 17 Google Play image is missing; run $0 setup"

  emulator_version=$(property_value Pkg.Revision "${SDK_ROOT}/emulator/source.properties")
  platform_tools_version=$(property_value Pkg.Revision "${SDK_ROOT}/platform-tools/source.properties")
  [ "${emulator_version}" = "${EXPECTED_EMULATOR_VERSION}" ] \
    || die "Emulator ${emulator_version:-unknown} is installed; expected ${EXPECTED_EMULATOR_VERSION}"
  [ "${platform_tools_version}" = "${EXPECTED_PLATFORM_TOOLS_VERSION}" ] \
    || die "Platform Tools ${platform_tools_version:-unknown} is installed; expected ${EXPECTED_PLATFORM_TOOLS_VERSION}"
  grep -Fq "<major>${EXPECTED_SYSTEM_IMAGE_REVISION}</major>" "${image_dir}/package.xml" \
    || die "Android 17 image revision is not r${EXPECTED_SYSTEM_IMAGE_REVISION}"
}

ensure_avd() {
  install -d -m 0700 "${RUNTIME_ROOT}" "${ANDROID_AVD_HOME}" "${ANDROID_EMULATOR_HOME}" "${ANDROID_PREFS_ROOT}"
  if [ ! -d "${ANDROID_AVD_HOME}/${AVD_NAME}.avd" ]; then
    log "creating ${AVD_NAME} from ${SYSTEM_IMAGE}"
    printf 'no\n' | "${AVDMANAGER}" create avd --force --name "${AVD_NAME}" \
      --package "${SYSTEM_IMAGE}" --device pixel_9
  fi
  configure_avd_value hw.sdCard no
  configure_avd_value PlayStore.enabled yes
}

configure_avd_value() {
  key=$1
  value=$2
  config=${ANDROID_AVD_HOME}/${AVD_NAME}.avd/config.ini
  temporary=${config}.tmp.$$
  awk -F= -v key="${key}" -v value="${value}" '
    BEGIN { replaced = 0 }
    {
      field = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", field)
    }
    field == key { if (!replaced) print key "=" value; replaced = 1; next }
    { print }
    END { if (!replaced) print key "=" value }
  ' "${config}" >"${temporary}"
  mv "${temporary}" "${config}"
}

setup() {
  require_host
  [ "${ACCEPT_ANDROID_SDK_LICENSES:-no}" = yes ] \
    || die 'review https://developer.android.com/studio/terms then set ACCEPT_ANDROID_SDK_LICENSES=yes'
  install -d -m 0700 "${RUNTIME_ROOT}"
  verify_repository_versions
  "${SDKMANAGER}" "emulator" "platform-tools" "${SYSTEM_IMAGE}"
  validate_packages
  ensure_avd
  log 'native Android 17 runtime is installed and version-locked'
}

is_running() {
  pid=$(managed_pid)
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

managed_pid() {
  launchctl print "gui/$(id -u)/${LAUNCH_LABEL}" 2>/dev/null \
    | sed -n 's/^[[:space:]]*pid = //p' | head -n 1
}

remove_launch_job() {
  managed=$(managed_pid)
  launchctl remove "${LAUNCH_LABEL}" >/dev/null 2>&1 || true
  elapsed=0
  while [ -n "${managed}" ] && kill -0 "${managed}" 2>/dev/null && [ "${elapsed}" -lt 10 ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  if [ -n "${managed}" ] && kill -0 "${managed}" 2>/dev/null; then
    kill -TERM "${managed}" 2>/dev/null || true
    sleep 1
    kill -0 "${managed}" 2>/dev/null \
      && die "launchd removed ${LAUNCH_LABEL} but emulator pid ${managed} survived"
  fi
  rm -f "${PID_FILE}"
}

stop_docker_android() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 \
    || die 'Docker is installed but unavailable; cannot prove the TCG Android is stopped'
  docker compose -f "${ROOT}/compose.yaml" stop android >/dev/null \
    || die 'failed to stop the Docker TCG Android'
  running=$(docker compose -f "${ROOT}/compose.yaml" ps -q --status running android)
  [ -z "${running}" ] || die "Docker TCG Android is still running: ${running}"
}

verify_loopback_listener() {
  pid=$1
  port=$2
  listeners=$("${LSOF_BIN}" -nP -a -p "${pid}" -iTCP:"${port}" -sTCP:LISTEN -Fn 2>/dev/null) \
    || return 1
  found=0
  while IFS= read -r entry; do
    case ${entry} in
      n127.0.0.1:"${port}"|n\[::1\]:"${port}") found=1 ;;
      n*) return 1 ;;
    esac
  done <<EOF
${listeners}
EOF
  [ "${found}" -eq 1 ]
}

start() {
  require_host
  validate_packages
  ensure_avd
  stop_docker_android
  if is_running; then
    pid=$(managed_pid)
    if ! verify_loopback_listener "${pid}" "${ADB_PORT}" \
      || ! verify_loopback_listener "${pid}" "${GRPC_PORT}"; then
      remove_launch_job
      die 'running ADB or gRPC listener is not exclusively bound to host loopback'
    fi
    log "already running as pid ${pid}"
    return 0
  fi

  # The accelerated host emulator is the only Android instance. The old TCG
  # container is stopped without deleting its volume so rollback stays clean.
  accel_output=$("${EMULATOR}" -accel-check 2>&1) || die "hardware acceleration unavailable: ${accel_output}"
  printf '%s\n' "${accel_output}" | grep -Fq 'Hypervisor.Framework' \
    || die "Hypervisor.Framework was not selected: ${accel_output}"

  : >"${LOG_FILE}"
  log "starting ${AVD_NAME} with Hypervisor.Framework and host GPU"
  remove_launch_job
  launchctl submit -l "${LAUNCH_LABEL}" -o "${LOG_FILE}" -e "${LOG_FILE}" -- \
    /usr/bin/env \
    "ANDROID_SDK_ROOT=${SDK_ROOT}" \
    "ANDROID_AVD_HOME=${ANDROID_AVD_HOME}" \
    "ANDROID_EMULATOR_HOME=${ANDROID_EMULATOR_HOME}" \
    "ANDROID_PREFS_ROOT=${ANDROID_PREFS_ROOT}" \
    "${EMULATOR}" -avd "${AVD_NAME}" \
    -ports "${CONSOLE_PORT},${ADB_PORT}" \
    -grpc "${GRPC_PORT}" -grpc-use-token \
    -accel auto -gpu host -no-boot-anim -no-metrics \
    -memory 4096 -cores 4 -netdelay none -netspeed full \
    >/dev/null
  pid=$(managed_pid)
  if [ -z "${pid}" ]; then
    remove_launch_job
    die 'launchd did not publish an emulator pid'
  fi
  printf '%s\n' "${pid}" >"${PID_FILE}"

  elapsed=0
  while [ "${elapsed}" -lt "${BOOT_TIMEOUT_SECONDS}" ]; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      tail -n 80 "${LOG_FILE}" >&2 || true
      remove_launch_job
      die 'emulator exited before Android became ready'
    fi
    if [ "$("${ADB}" -s "${ADB_SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
      if ! verify_loopback_listener "${pid}" "${ADB_PORT}" \
        || ! verify_loopback_listener "${pid}" "${GRPC_PORT}"; then
        remove_launch_job
        die 'ADB or gRPC is not exclusively bound to host loopback'
      fi
      log "ready: serial=${ADB_SERIAL}, adb=127.0.0.1:${ADB_PORT}, grpc=127.0.0.1:${GRPC_PORT}"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  remove_launch_job
  die "Android did not boot within ${BOOT_TIMEOUT_SECONDS} seconds; see ${LOG_FILE}"
}

stop() {
  if ! is_running; then
    remove_launch_job
    log 'not running'
    return 0
  fi
  pid=$(managed_pid)
  "${ADB}" -s "${ADB_SERIAL}" emu kill >/dev/null 2>&1 || true
  remove_launch_job
  elapsed=0
  while kill -0 "${pid}" 2>/dev/null && [ "${elapsed}" -lt 30 ]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  kill -0 "${pid}" 2>/dev/null && die "emulator pid ${pid} did not stop"
  log 'stopped'
}

status() {
  if is_running; then
    pid=$(managed_pid)
    boot_completed=$("${ADB}" -s "${ADB_SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    log "running pid=${pid} serial=${ADB_SERIAL} boot_completed=${boot_completed:-0}"
  else
    log 'stopped'
    return 1
  fi
}

scrcpy_runtime() {
  if is_running; then
    stop_docker_android
  else
    start
  fi
  [ -x "${SCRCPY}" ] || die "scrcpy ${EXPECTED_SCRCPY_VERSION} is missing: ${SCRCPY}"
  scrcpy_version=$("${SCRCPY}" --version | sed -n '1s/^scrcpy \([^ ]*\).*/\1/p')
  [ "${scrcpy_version}" = "${EXPECTED_SCRCPY_VERSION}" ] \
    || die "scrcpy ${scrcpy_version:-unknown} is installed; expected ${EXPECTED_SCRCPY_VERSION}"
  exec "${SCRCPY}" --serial "${ADB_SERIAL}" --no-audio --stay-awake \
    --video-buffer=0 --audio-buffer=0 --mouse=sdk --keyboard=uhid
}

case ${1:-} in
  setup) setup ;;
  start) start ;;
  stop) stop ;;
  restart) stop; start ;;
  status) status ;;
  scrcpy) scrcpy_runtime ;;
  *) die "usage: $0 {setup|start|stop|restart|status|scrcpy}" ;;
esac
