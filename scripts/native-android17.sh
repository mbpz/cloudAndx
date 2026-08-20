#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
RUNTIME_MODE=${CLOUDANDX_RUNTIME_MODE:-}
case ${RUNTIME_MODE} in
  development-sdk|bundled-release) ;;
  '') printf '%s\n' 'cloudandx-native: ERROR: CLOUDANDX_RUNTIME_MODE must explicitly be development-sdk or bundled-release' >&2; exit 1 ;;
  *) printf '%s\n' 'cloudandx-native: ERROR: unsupported CLOUDANDX_RUNTIME_MODE' >&2; exit 1 ;;
esac

if [ "${RUNTIME_MODE}" = bundled-release ]; then
  [ -n "${CLOUDANDX_BUNDLED_RUNTIME_ROOT:-}" ] \
    || { printf '%s\n' 'cloudandx-native: ERROR: bundled-release requires launcher-provided CLOUDANDX_BUNDLED_RUNTIME_ROOT' >&2; exit 1; }
  case ${CLOUDANDX_BUNDLED_RUNTIME_ROOT} in /*) ;; *) printf '%s\n' 'cloudandx-native: ERROR: bundled runtime root must be absolute' >&2; exit 1 ;; esac
  for forbidden in ANDROID_SDK_ROOT CLOUDANDX_ANDROID_SDK_ROOT CLOUDANDX_SCRCPY_BIN; do
    eval "value=\${$forbidden:-}"
    [ -z "${value}" ] || { printf '%s\n' "cloudandx-native: ERROR: ${forbidden} is forbidden in bundled-release" >&2; exit 1; }
  done
  BUNDLED_RUNTIME_ROOT=${CLOUDANDX_BUNDLED_RUNTIME_ROOT}
  [ -f "${BUNDLED_RUNTIME_ROOT}/manifest.json" ] && [ ! -L "${BUNDLED_RUNTIME_ROOT}/manifest.json" ] \
    || { printf '%s\n' 'cloudandx-native: ERROR: bundled runtime manifest is missing' >&2; exit 1; }
  for directory in engine images tools templates licenses provenance; do
    [ -d "${BUNDLED_RUNTIME_ROOT}/${directory}" ] && [ ! -L "${BUNDLED_RUNTIME_ROOT}/${directory}" ] \
      || { printf '%s\n' "cloudandx-native: ERROR: bundled runtime layout is incomplete: ${directory}" >&2; exit 1; }
  done
  RUNTIME_ID=$(sed -n 's/.*"runtimeID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${BUNDLED_RUNTIME_ROOT}/manifest.json" | head -n 1)
  [ -n "${RUNTIME_ID}" ] || { printf '%s\n' 'cloudandx-native: ERROR: bundled manifest runtimeID is missing' >&2; exit 1; }
  RUNTIME_ROOT=${CLOUDANDX_NATIVE_RUNTIME_ROOT:-${HOME}/Library/Application Support/CloudAndx/Runtime/${RUNTIME_ID}}
  # The manifest/layout preflight intentionally remains static until the
  # signed bundle launcher and source-built template stager exist.
  case ${1:-} in
    runtime-preflight) log() { printf '%s\n' "cloudandx-native: $*"; }; log "bundled release preflight only runtime_id=${RUNTIME_ID}"; exit 0 ;;
    *) printf '%s\n' 'cloudandx-native: ERROR: bundled-release lifecycle is unavailable until the signed bundle launcher and source-built template staging are implemented' >&2; exit 1 ;;
  esac
else
  if [ -n "${CLOUDANDX_DEVELOPMENT_PROJECT_ROOT:-}" ]; then
    case ${CLOUDANDX_DEVELOPMENT_PROJECT_ROOT} in /*) ;; *) printf '%s\n' 'cloudandx-native: ERROR: development project root must be absolute' >&2; exit 1 ;; esac
    ROOT=${CLOUDANDX_DEVELOPMENT_PROJECT_ROOT}
    [ -d "${ROOT}" ] && [ ! -L "${ROOT}" ] && [ -x "${ROOT}/scripts/native-android17.sh" ] && [ -f "${ROOT}/compose.yaml" ] \
      || { printf '%s\n' 'cloudandx-native: ERROR: development project root is invalid' >&2; exit 1; }
    root_owner=$(stat -f '%u' "${ROOT}")
    root_mode=$(stat -f '%Lp' "${ROOT}")
    case ${root_mode} in [0-7][0145][0145]) safe_mode=yes ;; *) safe_mode=no ;; esac
    [ "${root_owner}" = "$(id -u)" ] && [ "${safe_mode}" = yes ] \
      || { printf '%s\n' 'cloudandx-native: ERROR: development project root permissions are unsafe' >&2; exit 1; }
  fi
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
  if [ -x "${DEFAULT_JAVA_HOME}/bin/java" ] && [ -z "${CLOUDANDX_JAVA_HOME:-}" ]; then JAVA_HOME=${DEFAULT_JAVA_HOME}; fi
  ANDROID_AVD_HOME=${RUNTIME_ROOT}/avd; ANDROID_EMULATOR_HOME=${RUNTIME_ROOT}/emulator-home; ANDROID_PREFS_ROOT=${RUNTIME_ROOT}/prefs
  AVD_NAME=${CLOUDANDX_NATIVE_AVD_NAME:-CloudAndx_Android_17_Play}; SYSTEM_IMAGE='system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a'
  EXPECTED_EMULATOR_VERSION=37.1.11; EXPECTED_PLATFORM_TOOLS_VERSION=37.0.1; EXPECTED_SYSTEM_IMAGE_REVISION=6; EXPECTED_SCRCPY_VERSION=4.1
  CONSOLE_PORT=${CLOUDANDX_NATIVE_CONSOLE_PORT:-5556}; ADB_PORT=$((CONSOLE_PORT + 1)); GRPC_PORT=${CLOUDANDX_NATIVE_GRPC_PORT:-8556}; ADB_SERIAL=emulator-${CONSOLE_PORT}
  EMULATOR=${SDK_ROOT}/emulator/emulator; ADB=${SDK_ROOT}/platform-tools/adb; SDKMANAGER=${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager; AVDMANAGER=${SDK_ROOT}/cmdline-tools/latest/bin/avdmanager
  PID_FILE=${RUNTIME_ROOT}/emulator.pid; LOG_FILE=${RUNTIME_ROOT}/emulator.log; SNAPSHOT_NAME=cloudandx-ready; SNAPSHOT_META_FILE=${RUNTIME_ROOT}/trusted-snapshot.env
  SNAPSHOT_DIRECTORY=${ANDROID_AVD_HOME}/${AVD_NAME}.avd/snapshots/${SNAPSHOT_NAME}; LAUNCH_LABEL=dev.cloudandx.android17; LAUNCH_PLIST=${RUNTIME_ROOT}/${LAUNCH_LABEL}.plist; SCRCPY=${CLOUDANDX_SCRCPY_BIN:-/opt/homebrew/bin/scrcpy}
  BOOT_TIMEOUT_SECONDS=${CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS:-120}; LSOF_BIN=${CLOUDANDX_LSOF_BIN:-lsof}
  export JAVA_HOME ANDROID_SDK_ROOT=${SDK_ROOT} ANDROID_AVD_HOME ANDROID_EMULATOR_HOME ANDROID_PREFS_ROOT
fi

log() { printf '%s\n' "cloudandx-native: $*"; }
die() { printf '%s\n' "cloudandx-native: ERROR: $*" >&2; exit 1; }

property_value() {
  key=$1
  file=$2
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "${file}" | head -n 1
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_host() {
  [ "$(uname -s)" = Darwin ] || die 'native runtime requires macOS'
  [ "$(uname -m)" = arm64 ] || die 'native runtime requires Apple Silicon'
  if [ "${RUNTIME_MODE}" = development-sdk ]; then
    [ -x "${JAVA_HOME}/bin/java" ] || die "JDK 17+ is missing: ${JAVA_HOME}"
    [ -x "${SDKMANAGER}" ] || die "sdkmanager is missing: ${SDKMANAGER}"
    [ -x "${AVDMANAGER}" ] || die "avdmanager is missing: ${AVDMANAGER}"
  else
    [ -x "${EMULATOR}" ] || die "bundled AEMU is missing: ${EMULATOR}"
    [ -x "${ADB}" ] || die "bundled adb is missing: ${ADB}"
    [ -x "${SCRCPY}" ] || die "bundled scrcpy is missing: ${SCRCPY}"
  fi
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
  [ "${RUNTIME_MODE}" = development-sdk ] || die 'bundled-release forbids SDK repository resolution'
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
  if [ "${RUNTIME_MODE}" = bundled-release ]; then
    [ -x "${EMULATOR}" ] || die "bundled AEMU is missing: ${EMULATOR}"
    [ -x "${ADB}" ] || die "bundled adb is missing: ${ADB}"
    return 0
  fi
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
    [ "${RUNTIME_MODE}" = development-sdk ] || die 'bundled-release requires a source-built template staging flow; it must not create an SDK AVD'
    log "creating ${AVD_NAME} from ${SYSTEM_IMAGE}"
    printf 'no\n' | "${AVDMANAGER}" create avd --force --name "${AVD_NAME}" \
      --package "${SYSTEM_IMAGE}" --device pixel_9
  fi
  configure_avd_value hw.sdCard no
  if [ "${RUNTIME_MODE}" = development-sdk ]; then
    configure_avd_value PlayStore.enabled yes
  fi
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

current_snapshot_identity() {
  config=${ANDROID_AVD_HOME}/${AVD_NAME}.avd/config.ini
  printf '%s\n' "snapshot_name=${SNAPSHOT_NAME}"
  printf '%s\n' "avd_name=${AVD_NAME}"
  printf '%s\n' "system_image=${SYSTEM_IMAGE}"
  printf '%s\n' "emulator_version=${EXPECTED_EMULATOR_VERSION}"
  printf '%s\n' "platform_tools_version=${EXPECTED_PLATFORM_TOOLS_VERSION}"
  printf '%s\n' "system_image_revision=${EXPECTED_SYSTEM_IMAGE_REVISION}"
  printf '%s\n' 'gpu_mode=host'
  printf '%s\n' "config_sha256=$(sha256_file "${config}")"
  printf '%s\n' "runtime_mode=${RUNTIME_MODE}"
  if [ "${RUNTIME_MODE}" = bundled-release ]; then
    printf '%s\n' "runtime_manifest_sha256=$(sha256_file "${BUNDLED_RUNTIME_ROOT}/manifest.json")"
    printf '%s\n' "runtime_template_sha256=$(sed -n 's/.*"defaultTemplateDigest"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f]*\)".*/\1/p' "${BUNDLED_RUNTIME_ROOT}/manifest.json" | head -n 1)"
  else
    printf '%s\n' 'runtime_manifest_sha256=development-sdk-prototype-aemu-37.1.11-platform-tools-37.0.1-api-37.0-r06-scrcpy-4.1'
    printf '%s\n' 'runtime_template_sha256=development-sdk-prototype-no-bundled-template'
  fi
}

current_identity_value() {
  current_snapshot_identity | sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" | head -n 1
}

write_snapshot_metadata() {
  temporary=${SNAPSHOT_META_FILE}.tmp.$$
  current_snapshot_identity >"${temporary}"
  chmod 0600 "${temporary}"
  mv "${temporary}" "${SNAPSHOT_META_FILE}"
}

snapshot_entity_exists() {
  if is_running; then
    snapshot_list=$("${ADB}" -s "${ADB_SERIAL}" emu avd snapshot list 2>&1) || return 1
  else
    snapshot_list=$("${EMULATOR}" -avd "${AVD_NAME}" -snapshot-list 2>&1) || return 1
  fi
  printf '%s\n' "${snapshot_list}" | awk -v name="${SNAPSHOT_NAME}" '
    {
      entry = $0
      sub(/^[[:space:]]+/, "", entry)
      sub(/[[:space:]]+$/, "", entry)
      if (entry == name || entry == "Snapshot: " name || ($1 != "ID" && $2 == name)) found = 1
    }
    END { exit !found }
  '
}

snapshot_identity_state() {
  if [ ! -f "${SNAPSHOT_META_FILE}" ] || [ -L "${SNAPSHOT_META_FILE}" ]; then
    printf '%s\n' unavailable
    return 0
  fi
  if [ ! -d "${SNAPSHOT_DIRECTORY}" ] || [ -L "${SNAPSHOT_DIRECTORY}" ]; then
    printf '%s\n' unavailable
    return 0
  fi
  if ! snapshot_entity_exists; then
    printf '%s\n' unavailable
    return 0
  fi
  for key in snapshot_name avd_name system_image emulator_version platform_tools_version system_image_revision gpu_mode config_sha256 runtime_mode runtime_manifest_sha256 runtime_template_sha256; do
    current=$(current_identity_value "${key}")
    saved=$(property_value "${key}" "${SNAPSHOT_META_FILE}")
    if [ -z "${saved}" ] || [ "${current}" != "${saved}" ]; then
      printf '%s\n' incompatible
      return 0
    fi
  done
  printf '%s\n' ready
}

setup() {
  [ "${RUNTIME_MODE}" = development-sdk ] || die 'bundled-release forbids setup, package downloads, sdkmanager, and avdmanager'
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
  launchctl bootout "gui/$(id -u)/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
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
  rm -f "${LAUNCH_PLIST}"
}

write_launch_agent() {
  temporary=${LAUNCH_PLIST}.tmp.$$
  # KeepAlive=false is explicit: an exited AEMU stays exited until an explicit
  # start/restart/snapshot-resume invokes kickstart again.
  # Dynamic plist values are deliberately rejected rather than interpolated
  # with incomplete XML escaping. Every value here is an internally selected
  # path or fixed AEMU argument, never caller-provided XML.
  for plist_value in "${LAUNCH_LABEL}" "${LOG_FILE}" "${SDK_ROOT}" "${ANDROID_AVD_HOME}" "${ANDROID_EMULATOR_HOME}" "${ANDROID_PREFS_ROOT}" "${EMULATOR}" "${AVD_NAME}" "${CONSOLE_PORT}" "${ADB_PORT}" "${GRPC_PORT}" "$@"; do
    case ${plist_value} in
      *'&'*|*'<'*|*'>'*|*\"*|*\'*|*[![:print:]]*) die 'LaunchAgent plist value contains unsafe XML characters' ;;
    esac
  done
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>Label</key><string>'"${LAUNCH_LABEL}"'</string>' \
    '<key>KeepAlive</key><false/>' \
    '<key>ProcessType</key><string>Background</string>' \
    '<key>StandardOutPath</key><string>'"${LOG_FILE}"'</string>' \
    '<key>StandardErrorPath</key><string>'"${LOG_FILE}"'</string>' \
    '<key>EnvironmentVariables</key><dict>' \
    '<key>ANDROID_SDK_ROOT</key><string>'"${SDK_ROOT}"'</string>' \
    '<key>ANDROID_AVD_HOME</key><string>'"${ANDROID_AVD_HOME}"'</string>' \
    '<key>ANDROID_EMULATOR_HOME</key><string>'"${ANDROID_EMULATOR_HOME}"'</string>' \
    '<key>ANDROID_PREFS_ROOT</key><string>'"${ANDROID_PREFS_ROOT}"'</string>' \
    '</dict><key>ProgramArguments</key><array>' \
    '<string>'"${EMULATOR}"'</string><string>-avd</string><string>'"${AVD_NAME}"'</string>' \
    '<string>-ports</string><string>'"${CONSOLE_PORT},${ADB_PORT}"'</string>' \
    '<string>-grpc</string><string>'"${GRPC_PORT}"'</string><string>-grpc-use-token</string>' \
    '<string>-accel</string><string>auto</string><string>-gpu</string><string>host</string>' \
    '<string>-no-boot-anim</string><string>-no-metrics</string><string>-memory</string><string>4096</string><string>-cores</string><string>4</string><string>-netdelay</string><string>none</string><string>-netspeed</string><string>full</string>' >"${temporary}"
  for argument do printf '%s\n' '<string>'"${argument}"'</string>' >>"${temporary}"; done
  printf '%s\n' '</array></dict></plist>' >>"${temporary}"
  chmod 0600 "${temporary}"
  mv "${temporary}" "${LAUNCH_PLIST}"
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

guest_services_ready() {
  for service in SurfaceFlinger activity package; do
    service_output=$("${ADB}" -s "${ADB_SERIAL}" shell service check "${service}" 2>/dev/null) \
      || return 1
    printf '%s\n' "${service_output}" | grep -Fq ': found' || return 1
  done
}

wait_for_ready() {
  pid=$1
  elapsed=0
  while [ "${elapsed}" -lt "${BOOT_TIMEOUT_SECONDS}" ]; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      tail -n 80 "${LOG_FILE}" >&2 || true
      remove_launch_job
      die 'emulator exited before Android became ready'
    fi
    boot_completed=$("${ADB}" -s "${ADB_SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [ "${boot_completed}" = 1 ] && guest_services_ready; then
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
  die "Android did not become healthy within ${BOOT_TIMEOUT_SECONDS} seconds; see ${LOG_FILE}"
}

verify_trusted_snapshot_load() {
  grep -Fq "Successfully loaded snapshot '${SNAPSHOT_NAME}'" "${LOG_FILE}" \
    || {
      remove_launch_job
      die 'AEMU did not prove that the trusted snapshot loaded; cold-boot fallback is rejected'
    }
  grep -Fq "Failed to load snapshot '${SNAPSHOT_NAME}'" "${LOG_FILE}" \
    && {
      remove_launch_job
      die 'AEMU reported trusted snapshot load failure'
    }
  return 0
}

require_ready_runtime() {
  is_running || die 'Android is not running'
  pid=$(managed_pid)
  [ "$("${ADB}" -s "${ADB_SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] \
    || die 'Android is not ready'
  guest_services_ready || die 'Android framework services are not ready'
  verify_loopback_listener "${pid}" "${ADB_PORT}" \
    && verify_loopback_listener "${pid}" "${GRPC_PORT}" \
    || die 'ADB or gRPC is not exclusively bound to host loopback'
}

start() {
  mode=${1:-default}
  case ${mode} in
    default) set -- ;;
    trusted-snapshot) set -- -snapshot "${SNAPSHOT_NAME}" -no-snapshot-save ;;
    *) die 'internal launch mode is invalid' ;;
  esac
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
  write_launch_agent "$@"
  launchctl bootstrap "gui/$(id -u)" "${LAUNCH_PLIST}" >/dev/null
  launchctl kickstart "gui/$(id -u)/${LAUNCH_LABEL}" >/dev/null
  pid=$(managed_pid)
  if [ -z "${pid}" ]; then
    remove_launch_job
    die 'launchd did not publish an emulator pid'
  fi
  printf '%s\n' "${pid}" >"${PID_FILE}"
  wait_for_ready "${pid}"
}

snapshot_save() {
  require_host
  validate_packages
  ensure_avd
  require_ready_runtime
  "${ADB}" -s "${ADB_SERIAL}" shell sync >/dev/null \
    || die 'failed to sync Android data before snapshot save'
  output=$("${ADB}" -s "${ADB_SERIAL}" emu avd snapshot save "${SNAPSHOT_NAME}" 2>&1) \
    || die "failed to save trusted snapshot: ${output}"
  [ -d "${SNAPSHOT_DIRECTORY}" ] && [ ! -L "${SNAPSHOT_DIRECTORY}" ] \
    || die 'emulator reported success but trusted snapshot files are missing'
  snapshot_entity_exists \
    || die 'emulator reported success but trusted snapshot entity is not listed'
  write_snapshot_metadata
  log "snapshot_ready=1 snapshot_name=${SNAPSHOT_NAME} saved"
}

snapshot_status() {
  require_host
  validate_packages
  ensure_avd
  state=$(snapshot_identity_state)
  case ${state} in
    ready) log "snapshot_ready=1 snapshot_name=${SNAPSHOT_NAME}" ;;
    unavailable) log "snapshot_ready=0 snapshot_name=${SNAPSHOT_NAME} reason=no trusted snapshot" ;;
    incompatible) log "snapshot_incompatible=1 snapshot_name=${SNAPSHOT_NAME} reason=runtime identity changed" ;;
    *) die 'trusted snapshot state is unknown' ;;
  esac
}

snapshot_resume() {
  require_host
  validate_packages
  ensure_avd
  state=$(snapshot_identity_state)
  [ "${state}" = ready ] || die "trusted snapshot is not recoverable: ${state}"
  started_at=$(date +%s)
  if is_running; then
    require_ready_runtime
    output=$("${ADB}" -s "${ADB_SERIAL}" emu avd snapshot load "${SNAPSHOT_NAME}" 2>&1) \
      || die "failed to load trusted snapshot: ${output}"
    wait_for_ready "$(managed_pid)"
  else
    start trusted-snapshot
    verify_trusted_snapshot_load
  fi
  elapsed=$(( $(date +%s) - started_at ))
  log "snapshot_ready=1 snapshot_name=${SNAPSHOT_NAME} resumed elapsed_seconds=${elapsed} destructive_guest_restore=1"
}

require_regular_host_file() {
  path=$1
  label=$2
  [ -n "${path}" ] || die "${label} path is required"
  [ -f "${path}" ] && [ ! -L "${path}" ] && [ -r "${path}" ] \
    || die "${label} must be a readable regular file, not a symlink"
}

install_apk() {
  require_host
  validate_packages
  require_ready_runtime
  path=${CLOUDANDX_NATIVE_APK_PATH:-}
  require_regular_host_file "${path}" APK
  case ${path} in *.apk|*.APK) ;; *) die 'APK path must end in .apk' ;; esac
  output=$("${ADB}" -s "${ADB_SERIAL}" install -r "${path}" 2>&1) \
    || die "APK install failed: ${output}"
  printf '%s\n' "${output}"
}

push_file() {
  require_host
  validate_packages
  require_ready_runtime
  path=${CLOUDANDX_NATIVE_HOST_FILE_PATH:-}
  require_regular_host_file "${path}" 'host file'
  basename=${path##*/}
  case ${basename} in ''|.|..|*/*) die 'host file basename is invalid' ;; esac
  safe_basename=$(printf '%s' "${basename}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c 1-120)
  case ${safe_basename} in ''|.|..) die 'sanitized host file basename is invalid' ;; esac
  target=/sdcard/Download/${safe_basename}
  output=$("${ADB}" -s "${ADB_SERIAL}" push "${path}" "${target}" 2>&1) \
    || die "file push failed: ${output}"
  log "device_target=${target}"
}

capture_screenshot() {
  require_host
  validate_packages
  require_ready_runtime
  destination=${CLOUDANDX_NATIVE_SCREENSHOT_PATH:-}
  [ -n "${destination}" ] || die 'screenshot path is required'
  case ${destination} in *.png|*.PNG) ;; *) die 'screenshot path must end in .png' ;; esac
  [ ! -L "${destination}" ] || die 'screenshot path must not be a symlink'
  parent=${destination%/*}
  [ "${parent}" != "${destination}" ] || parent=.
  [ -d "${parent}" ] && [ -w "${parent}" ] && [ ! -L "${parent}" ] \
    || die 'screenshot parent must be a writable real directory'
  temporary=$(mktemp "${parent}/.cloudandx-screenshot.XXXXXX") \
    || die 'failed to create screenshot staging file'
  trap 'rm -f "${temporary}"' EXIT INT TERM
  "${ADB}" -s "${ADB_SERIAL}" exec-out screencap -p >"${temporary}" \
    || die 'Android screenshot capture failed'
  magic=$(od -An -tx1 -N8 "${temporary}" | tr -d ' \n')
  [ "${magic}" = 89504e470d0a1a0a ] || die 'Android screenshot output is not PNG'
  chmod 0600 "${temporary}"
  mv "${temporary}" "${destination}"
  trap - EXIT INT TERM
  log "screenshot_saved=1"
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
  status | grep -Fq 'boot_completed=1' || die 'scrcpy requires an explicitly started, ready Android runtime'
  [ -x "${SCRCPY}" ] || die "scrcpy ${EXPECTED_SCRCPY_VERSION} is missing: ${SCRCPY}"
  if [ "${RUNTIME_MODE}" = development-sdk ]; then
    scrcpy_version=$("${SCRCPY}" --version | sed -n '1s/^scrcpy \([^ ]*\).*/\1/p')
    [ "${scrcpy_version}" = "${EXPECTED_SCRCPY_VERSION}" ] \
      || die "scrcpy ${scrcpy_version:-unknown} is installed; expected ${EXPECTED_SCRCPY_VERSION}"
  fi
  exec "${SCRCPY}" --serial "${ADB_SERIAL}" --no-audio --stay-awake \
    --video-buffer=0 --audio-buffer=0 --mouse=sdk --keyboard=uhid
}

case ${1:-} in
  setup) setup ;;
  start) [ "$#" -eq 1 ] || die 'start does not accept additional arguments'; start default ;;
  stop) stop ;;
  restart) [ "$#" -eq 1 ] || die 'restart does not accept additional arguments'; stop; start default ;;
  status) status ;;
  scrcpy) scrcpy_runtime ;;
  snapshot-save) snapshot_save ;;
  snapshot-resume) snapshot_resume ;;
  snapshot-status) snapshot_status ;;
  install-apk) install_apk ;;
  push-file) push_file ;;
  capture-screenshot) capture_screenshot ;;
  *) die "usage: $0 {setup|start|stop|restart|status|scrcpy|snapshot-save|snapshot-resume|snapshot-status|install-apk|push-file|capture-screenshot}" ;;
esac
