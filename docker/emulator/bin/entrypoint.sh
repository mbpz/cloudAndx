#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${SCRIPT_DIR}/runtime-lib.sh"

umask 077

ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/android-sdk}
ANDROID_AVD_HOME=${ANDROID_AVD_HOME:-/data/avd}
ANDROID_EMULATOR_HOME=${ANDROID_EMULATOR_HOME:-/data/emulator-home}
ANDROID_PREFS_ROOT=${ANDROID_PREFS_ROOT:-/data/prefs}
HOME=${HOME:-/data/home}
AVD_TEMPLATE_DIR=${AVD_TEMPLATE_DIR:-/opt/android-avd-template}
AVD_NAME=${AVD_NAME:-Pixel_9_Android_17_Play_ARM64}
EMULATOR_ACCEL=${EMULATOR_ACCEL:-auto}
EMULATOR_CORES=${EMULATOR_CORES:-8}
EMULATOR_MEMORY_MB=${EMULATOR_MEMORY_MB:-4096}
EMULATOR_GPU=${EMULATOR_GPU:-swiftshader}
EMULATOR_CONSOLE_PORT=${EMULATOR_CONSOLE_PORT:-5556}
EMULATOR_CONSOLE_SOCKET=${EMULATOR_CONSOLE_SOCKET:-/run/emulator-console/console.sock}
EMULATOR_CONSOLE_AUTH_TOKEN_FILE=${EMULATOR_CONSOLE_AUTH_TOKEN_FILE:-/run/bridge-secrets/token}
EMULATOR_ADB_PORT=${EMULATOR_ADB_PORT:-5557}
ADB_PROXY_PORT=${ADB_PROXY_PORT:-5555}
EMULATOR_GRPC_INTERNAL_PORT=${EMULATOR_GRPC_INTERNAL_PORT:-8556}
EMULATOR_GRPC_PORT=${EMULATOR_GRPC_PORT:-8554}
EMULATOR_WIPE_DATA=${EMULATOR_WIPE_DATA:-0}
KVM_DEVICE=${KVM_DEVICE:-/dev/kvm}
DOCKER_ENGINE_ARCHITECTURE=${DOCKER_ENGINE_ARCHITECTURE:-}
ANDROID_RUNTIME_IMPLEMENTATION=${ANDROID_RUNTIME_IMPLEMENTATION:-hybrid-aemu-arm64}
NATIVE_AEMU_ROOT=${NATIVE_AEMU_ROOT:-/opt/cloudandx/native-aemu}
NATIVE_AEMU_RUNNER=${NATIVE_AEMU_ROOT}/bin/run-qemu-system-aarch64-headless
EMULATOR_BIN=${EMULATOR_BIN:-${NATIVE_AEMU_RUNNER}}
ADB_BIN=${ADB_BIN:-${ANDROID_SDK_ROOT}/platform-tools/adb}
SOCAT_BIN=${SOCAT_BIN:-socat}
ADB_PRIVATE_KEY_FILE=${ADB_PRIVATE_KEY_FILE:-/run/secrets/adbkey}
ADB_PUBLIC_KEY_FILE=${ADB_PUBLIC_KEY_FILE:-/run/secrets/adbkey.pub}
BRIDGE_SCRIPT=${BRIDGE_SCRIPT:-/opt/cloudandx/device-bridge/bridge.py}
ANDROID_DISPLAY_WIDTH=${ANDROID_DISPLAY_WIDTH:-480}
ANDROID_DISPLAY_HEIGHT=${ANDROID_DISPLAY_HEIGHT:-1080}
ANDROID_DISPLAY_DENSITY=${ANDROID_DISPLAY_DENSITY:-187}
NOVNC_PORT=${NOVNC_PORT:-6080}
NOVNC_TLS=${NOVNC_TLS:-true}
NOVNC_TLS_CERT=${NOVNC_TLS_CERT:-/data/runtime/novnc/tls-cert.pem}
NOVNC_TLS_KEY=${NOVNC_TLS_KEY:-/data/runtime/novnc/tls-key.pem}
VNC_PORT=${VNC_PORT:-5900}
NOVNC_ROOT=${NOVNC_ROOT:-/opt/cloudandx/novnc}
SCRCPY_ROOT=${SCRCPY_ROOT:-/opt/cloudandx/scrcpy}
SCRCPY_BIN=${SCRCPY_BIN:-${SCRCPY_ROOT}/scrcpy}
SCRCPY_SERIAL=${SCRCPY_SERIAL:-emulator-${EMULATOR_CONSOLE_PORT}}
ANDROID_READY_RETRY_SECONDS=${ANDROID_READY_RETRY_SECONDS:-2}
BROWSER_READY_FILE=${BROWSER_READY_FILE:-/data/runtime/aemu-rfb-first-frame.ready}
GRPCURL_BIN=${GRPCURL_BIN:-/opt/cloudandx/grpcurl/grpcurl}
AEMU_RFB_BRIDGE=${AEMU_RFB_BRIDGE:-/usr/local/bin/aemu-rfb-bridge.py}
AEMU_PROTO_DIR=${AEMU_PROTO_DIR:-${ANDROID_SDK_ROOT}/emulator/lib}
WEBSOCKIFY_BIN=${WEBSOCKIFY_BIN:-websockify}
PYTHON_BIN=${PYTHON_BIN:-python3}

export ANDROID_SDK_ROOT ANDROID_AVD_HOME ANDROID_EMULATOR_HOME ANDROID_PREFS_ROOT HOME
export AVD_NAME EMULATOR_ACCEL EMULATOR_CORES EMULATOR_MEMORY_MB EMULATOR_GPU
export EMULATOR_CONSOLE_PORT EMULATOR_CONSOLE_SOCKET EMULATOR_CONSOLE_AUTH_TOKEN_FILE
export EMULATOR_ADB_PORT ADB_PROXY_PORT EMULATOR_GRPC_INTERNAL_PORT EMULATOR_GRPC_PORT EMULATOR_WIPE_DATA
export KVM_DEVICE DOCKER_ENGINE_ARCHITECTURE ANDROID_RUNTIME_IMPLEMENTATION NATIVE_AEMU_ROOT NATIVE_AEMU_RUNNER
export EMULATOR_BIN ADB_BIN SOCAT_BIN
export NOVNC_PORT VNC_PORT NOVNC_ROOT
export SCRCPY_ROOT SCRCPY_BIN SCRCPY_SERIAL ANDROID_READY_RETRY_SECONDS BROWSER_READY_FILE

initialize_single_container_state() {
  token_dir=${EMULATOR_CONSOLE_AUTH_TOKEN_FILE%/*}
  private_key_dir=${ADB_PRIVATE_KEY_FILE%/*}
  console_dir=${EMULATOR_CONSOLE_SOCKET%/*}
  mkdir -p "${token_dir}" "${private_key_dir}" "${console_dir}"
  chmod 0700 "${token_dir}" "${private_key_dir}" "${console_dir}"

  token=${EMULATOR_CONSOLE_AUTH_TOKEN_FILE}
  if [ ! -s "${token}" ]; then
    case ${token} in
      /data/runtime/secrets/token)
        temporary_token=${token}.tmp.$$
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"${temporary_token}"
        mv "${temporary_token}" "${token}"
        ;;
      *) runtime_die "Emulator Console auth token is missing: ${token}" ;;
    esac
  fi
  chmod 0600 "${token}"

  private_present=0
  public_present=0
  [ -s "${ADB_PRIVATE_KEY_FILE}" ] && private_present=1
  [ -s "${ADB_PUBLIC_KEY_FILE}" ] && public_present=1
  if [ "${private_present}" -ne "${public_present}" ]; then
    runtime_die "Persistent ADB key pair is incomplete under ${private_key_dir}."
  fi
  if [ "${private_present}" -eq 0 ]; then
    case ${ADB_PRIVATE_KEY_FILE} in
      /data/runtime/adb/adbkey)
        "${ADB_BIN}" keygen "${ADB_PRIVATE_KEY_FILE}" >/dev/null
        ;;
    esac
  fi
  if [ -s "${ADB_PRIVATE_KEY_FILE}" ]; then
    chmod 0600 "${ADB_PRIVATE_KEY_FILE}"
    chmod 0644 "${ADB_PUBLIC_KEY_FILE}"
  fi
}

MODE=run
case ${1-} in
  preflight)
    exec "${SCRIPT_DIR}/runtime-preflight.sh"
    ;;
  print-command)
    MODE=print
    shift
    ;;
  --)
    shift
    ;;
esac

validate_android_emulator_args "$@"
validate_uint_range ANDROID_DISPLAY_WIDTH "${ANDROID_DISPLAY_WIDTH}" 320 2160
validate_uint_range ANDROID_DISPLAY_HEIGHT "${ANDROID_DISPLAY_HEIGHT}" 480 3840
validate_uint_range ANDROID_DISPLAY_DENSITY "${ANDROID_DISPLAY_DENSITY}" 120 640
validate_uint_range ANDROID_READY_RETRY_SECONDS "${ANDROID_READY_RETRY_SECONDS}" 1 30

set_avd_config_value() {
  config_file=$1
  config_key=$2
  config_value=$3
  config_tmp=${config_file}.tmp.$$

  awk -F= -v key="${config_key}" -v value="${config_value}" '
    BEGIN { replaced = 0 }
    $1 == key { if (!replaced) print key "=" value; replaced = 1; next }
    { print }
    END { if (!replaced) print key "=" value }
  ' "${config_file}" >"${config_tmp}"
  mv "${config_tmp}" "${config_file}"
}

seed_avd() {
  template_config=${AVD_TEMPLATE_DIR}/config.ini
  template_version_file=${AVD_TEMPLATE_DIR}/template-version
  avd_dir=${ANDROID_AVD_HOME}/${AVD_NAME}.avd
  descriptor=${ANDROID_AVD_HOME}/${AVD_NAME}.ini

  [ -s "${template_config}" ] || runtime_die "AVD template config is missing: ${template_config}"
  [ -s "${template_version_file}" ] || runtime_die "AVD template version is missing: ${template_version_file}"

  mkdir -p "${ANDROID_AVD_HOME}" "${ANDROID_EMULATOR_HOME}" "${ANDROID_PREFS_ROOT}" "${HOME}/.android"

  if [ ! -e "${avd_dir}" ]; then
    mkdir -p "${avd_dir}"
    cp "${template_config}" "${avd_dir}/config.ini"
    cp "${template_version_file}" "${avd_dir}/template-version"
  fi

  [ -s "${avd_dir}/config.ini" ] || runtime_die "Persisted AVD is missing config.ini: ${avd_dir}"
  [ -s "${avd_dir}/template-version" ] || runtime_die "Persisted AVD has no template-version marker; use a fresh Docker volume."
  cmp -s "${template_version_file}" "${avd_dir}/template-version" \
    || runtime_die "Persisted AVD belongs to a different image revision; use a fresh Docker volume."

  # Display geometry is operational rather than user data. Reconcile it on
  # every start so existing volumes receive rendering fixes without a wipe.
  set_avd_config_value "${avd_dir}/config.ini" hw.lcd.width "${ANDROID_DISPLAY_WIDTH}"
  set_avd_config_value "${avd_dir}/config.ini" hw.lcd.height "${ANDROID_DISPLAY_HEIGHT}"
  set_avd_config_value "${avd_dir}/config.ini" hw.lcd.density "${ANDROID_DISPLAY_DENSITY}"
  set_avd_config_value "${avd_dir}/config.ini" skin.name "${ANDROID_DISPLAY_WIDTH}x${ANDROID_DISPLAY_HEIGHT}"
  set_avd_config_value "${avd_dir}/config.ini" skin.path "${ANDROID_DISPLAY_WIDTH}x${ANDROID_DISPLAY_HEIGHT}"

  descriptor_tmp=${descriptor}.tmp.$$
  {
    printf '%s\n' 'avd.ini.encoding=UTF-8'
    printf 'path=%s\n' "${avd_dir}"
    printf 'path.rel=avd/%s.avd\n' "${AVD_NAME}"
    printf '%s\n' 'target=android-37.0'
  } >"${descriptor_tmp}"
  mv "${descriptor_tmp}" "${descriptor}"
}

install_adb_keys() {
  key_dir=${HOME}/.android
  private_present=0
  public_present=0

  [ ! -e "${ADB_PRIVATE_KEY_FILE}" ] || [ -r "${ADB_PRIVATE_KEY_FILE}" ] \
    || runtime_die "ADB private key exists but uid $(id -u) cannot read it: ${ADB_PRIVATE_KEY_FILE}"
  [ ! -e "${ADB_PUBLIC_KEY_FILE}" ] || [ -r "${ADB_PUBLIC_KEY_FILE}" ] \
    || runtime_die "ADB public key exists but uid $(id -u) cannot read it: ${ADB_PUBLIC_KEY_FILE}"

  [ -s "${ADB_PRIVATE_KEY_FILE}" ] && private_present=1
  [ -s "${ADB_PUBLIC_KEY_FILE}" ] && public_present=1

  if [ "${private_present}" -ne "${public_present}" ]; then
    runtime_die "Mount both ${ADB_PRIVATE_KEY_FILE} and ${ADB_PUBLIC_KEY_FILE}, or mount neither."
  fi

  if [ "${private_present}" -eq 1 ]; then
    cp "${ADB_PRIVATE_KEY_FILE}" "${key_dir}/adbkey"
    cp "${ADB_PUBLIC_KEY_FILE}" "${key_dir}/adbkey.pub"
  elif [ -n "${ADBKEY-}" ] || [ -n "${ADBKEY_PUB-}" ]; then
    [ -n "${ADBKEY-}" ] && [ -n "${ADBKEY_PUB-}" ] \
      || runtime_die "ADBKEY and ADBKEY_PUB must be supplied together. Prefer read-only secret mounts."
    printf '%s\n' "${ADBKEY}" >"${key_dir}/adbkey"
    printf '%s\n' "${ADBKEY_PUB}" >"${key_dir}/adbkey.pub"
  fi

  if [ -s "${key_dir}/adbkey" ]; then
    chmod 0600 "${key_dir}/adbkey"
    chmod 0644 "${key_dir}/adbkey.pub"
  else
    "${ADB_BIN}" keygen "${key_dir}/adbkey" >/dev/null
  fi

  [ -s "${key_dir}/adbkey" ] || runtime_die "adb key generation failed in ${key_dir}."
  [ -s "${key_dir}/adbkey.pub" ] || runtime_die "adb public key generation failed in ${key_dir}."
  chmod 0600 "${key_dir}/adbkey"
  chmod 0644 "${key_dir}/adbkey.pub"
  export ADB_VENDOR_KEYS="${key_dir}"
  unset ADBKEY ADBKEY_PUB

  "${ADB_BIN}" start-server >/dev/null
}

install_console_auth_token() {
  source_token=${EMULATOR_CONSOLE_AUTH_TOKEN_FILE}
  installed_token=${HOME}/.emulator_console_auth_token
  temporary_token=${installed_token}.tmp.$$

  [ -f "${source_token}" ] \
    || runtime_die "Emulator Console auth token is missing: ${source_token}" \
    || return 1
  [ ! -L "${source_token}" ] \
    || runtime_die "Emulator Console auth token source must not be a symbolic link: ${source_token}" \
    || return 1
  [ -r "${source_token}" ] \
    || runtime_die "Emulator Console auth token is not readable by uid $(id -u): ${source_token}" \
    || return 1
  token_size=$(wc -c <"${source_token}" | tr -d '[:space:]')
  if [ "${token_size}" != 64 ] \
    || ! LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "${source_token}"; then
    runtime_die "Emulator Console auth token must contain exactly 64 lowercase hexadecimal characters: ${source_token}"
    return 1
  fi
  [ ! -L "${installed_token}" ] \
    || runtime_die "Installed Emulator Console auth token path must not be a symbolic link: ${installed_token}" \
    || return 1
  [ ! -e "${installed_token}" ] || [ -f "${installed_token}" ] \
    || runtime_die "Installed Emulator Console auth token path is not a regular file: ${installed_token}" \
    || return 1

  rm -f "${temporary_token}" \
    || runtime_die "Could not clear temporary Emulator Console auth token path: ${temporary_token}" \
    || return 1
  [ ! -e "${temporary_token}" ] && [ ! -L "${temporary_token}" ] \
    || runtime_die "Temporary Emulator Console auth token path is unsafe: ${temporary_token}" \
    || return 1
  cp "${source_token}" "${temporary_token}" \
    || runtime_die "Could not copy Emulator Console auth token from ${source_token}." \
    || return 1
  [ -f "${temporary_token}" ] && [ ! -L "${temporary_token}" ] \
    || runtime_die "Temporary Emulator Console auth token is not a regular file: ${temporary_token}" \
    || return 1
  chmod 0600 "${temporary_token}"
  cmp -s "${source_token}" "${temporary_token}" \
    || runtime_die "Copied Emulator Console auth token does not match ${source_token}." \
    || return 1
  [ ! -L "${installed_token}" ] \
    || runtime_die "Installed Emulator Console auth token path must not be a symbolic link: ${installed_token}" \
    || return 1
  [ ! -e "${installed_token}" ] || [ -f "${installed_token}" ] \
    || runtime_die "Installed Emulator Console auth token path is not a regular file: ${installed_token}" \
    || return 1
  mv "${temporary_token}" "${installed_token}"
  chmod 0600 "${installed_token}"
  [ -f "${installed_token}" ] && [ ! -L "${installed_token}" ] \
    || runtime_die "Installed Emulator Console auth token is not a regular file: ${installed_token}" \
    || return 1
}

validate_console_socket_path() {
  case ${EMULATOR_CONSOLE_SOCKET} in
    /*/console.sock) ;;
    *)
      runtime_die "EMULATOR_CONSOLE_SOCKET must be an absolute path ending in /console.sock."
      return 1
      ;;
  esac
  case ${EMULATOR_CONSOLE_SOCKET} in
    *'/../'*|*'/./'*|*'//'*)
      runtime_die "EMULATOR_CONSOLE_SOCKET must not contain relative or empty path segments."
      return 1
      ;;
  esac

  console_socket_dir=${EMULATOR_CONSOLE_SOCKET%/*}
  [ -d "${console_socket_dir}" ] && [ ! -L "${console_socket_dir}" ] \
    || runtime_die "Emulator Console socket directory is missing or unsafe: ${console_socket_dir}" \
    || return 1
  [ -w "${console_socket_dir}" ] && [ -x "${console_socket_dir}" ] \
    || runtime_die "Emulator Console socket directory is not writable and searchable by uid $(id -u): ${console_socket_dir}" \
    || return 1
  if [ -e "${EMULATOR_CONSOLE_SOCKET}" ] || [ -L "${EMULATOR_CONSOLE_SOCKET}" ]; then
    [ -S "${EMULATOR_CONSOLE_SOCKET}" ] && [ ! -L "${EMULATOR_CONSOLE_SOCKET}" ] \
      || runtime_die "Existing Emulator Console socket path is not a Unix socket: ${EMULATOR_CONSOLE_SOCKET}" \
      || return 1
  fi
}

print_argv() {
  index=0
  for argument do
    printf 'argv[%s]=%s\n' "${index}" "${argument}"
    index=$((index + 1))
  done
}

start_emulator() {
  effective_accel=$1
  shift

  if [ "${EMULATOR_WIPE_DATA}" = 1 ]; then
    set -- "${EMULATOR_BIN}" \
      -avd "${AVD_NAME}" \
      -no-window \
      -no-snapshot \
      -no-metrics \
      -gpu "${EMULATOR_GPU}" \
      -accel "${effective_accel}" \
      -cores "${EMULATOR_CORES}" \
      -memory "${EMULATOR_MEMORY_MB}" \
      -ports "${EMULATOR_CONSOLE_PORT},${EMULATOR_ADB_PORT}" \
      -grpc "${EMULATOR_GRPC_INTERNAL_PORT}" \
      -netdelay none \
      -netspeed full \
      -wipe-data \
      "$@"
  else
    set -- "${EMULATOR_BIN}" \
      -avd "${AVD_NAME}" \
      -no-window \
      -no-snapshot \
      -no-metrics \
      -gpu "${EMULATOR_GPU}" \
      -accel "${effective_accel}" \
      -cores "${EMULATOR_CORES}" \
      -memory "${EMULATOR_MEMORY_MB}" \
      -ports "${EMULATOR_CONSOLE_PORT},${EMULATOR_ADB_PORT}" \
      -grpc "${EMULATOR_GRPC_INTERNAL_PORT}" \
      -netdelay none \
      -netspeed full \
      "$@"
  fi

  case ${DOCKER_ENGINE_ARCHITECTURE} in
    arm64|aarch64)
      set -- "$@" -no-boot-anim -camera-back emulated
      while IFS= read -r graphics_argument; do
        set -- "$@" "${graphics_argument}"
      done <<EOF
$(native_aemu_graphics_args)
EOF
      while IFS= read -r qemu_argument; do
        set -- "$@" "${qemu_argument}"
      done <<EOF
$(native_aemu_tcg_qemu_args)
EOF
      ;;
  esac

  if [ "${MODE}" = print ]; then
    print_argv "$@"
    return 0
  fi

  engine_kind=$(selected_engine_kind "${DOCKER_ENGINE_ARCHITECTURE}" "${ANDROID_RUNTIME_IMPLEMENTATION}")
  runtime_log "Starting Android 17 API 37.0 Google Play r06 with engine=${engine_kind}, acceleration=${effective_accel}, gpu=${EMULATOR_GPU}."
  runtime_log "The authenticated Emulator Console stays on loopback port ${EMULATOR_CONSOLE_PORT}; a supervised Unix socket is available at ${EMULATOR_CONSOLE_SOCKET}."
  runtime_log "gRPC is enabled internally on ${EMULATOR_GRPC_INTERNAL_PORT}; a supervised proxy exposes container port ${EMULATOR_GRPC_PORT}. Publish it to host loopback only."
  "$@" &
  EMULATOR_PID=$!
}

start_novnc() {
  if [ "${NOVNC_TLS}" = true ]; then
    install -d -m 0700 "$(dirname "${NOVNC_TLS_CERT}")"
    if [ ! -s "${NOVNC_TLS_CERT}" ] || [ ! -s "${NOVNC_TLS_KEY}" ]; then
      openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
        -subj '/CN=cloudAndx Android noVNC' \
        -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
        -keyout "${NOVNC_TLS_KEY}" -out "${NOVNC_TLS_CERT}"
      chmod 0600 "${NOVNC_TLS_CERT}" "${NOVNC_TLS_KEY}"
    fi
    "${WEBSOCKIFY_BIN}" --web "${NOVNC_ROOT}" --cert "${NOVNC_TLS_CERT}" --key "${NOVNC_TLS_KEY}" --ssl-only \
      "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
    runtime_log "Encrypted noVNC is listening on container port ${NOVNC_PORT} and proxying loopback VNC port ${VNC_PORT}."
  else
    "${WEBSOCKIFY_BIN}" --web "${NOVNC_ROOT}" "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" &
    runtime_log "noVNC is listening without TLS on container port ${NOVNC_PORT} and proxying loopback VNC port ${VNC_PORT}."
  fi
  NOVNC_PID=$!
}

wait_for_android_target() {
  while :; do
    if [ -n "${EMULATOR_PID-}" ] && ! kill -0 "${EMULATOR_PID}" 2>/dev/null; then
      return 1
    fi
    state=$("${ADB_BIN}" -s "${SCRCPY_SERIAL}" get-state 2>/dev/null || true)
    boot_completed=$("${ADB_BIN}" -s "${SCRCPY_SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    if [ "${state}" = device ] && [ "${boot_completed}" = 1 ]; then
      return 0
    fi
    sleep "${ANDROID_READY_RETRY_SECONDS}"
  done
}

start_aemu_rfb_bridge() {
  rm -f "${BROWSER_READY_FILE}"
  (
    set -eu
    wait_for_android_target || exit 1
    "${ADB_BIN}" -s "${SCRCPY_SERIAL}" shell input keyevent WAKEUP >/dev/null 2>&1 || true
    "${ADB_BIN}" -s "${SCRCPY_SERIAL}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
    runtime_log "Starting the event-driven AEMU framebuffer/input bridge on loopback RFB port ${VNC_PORT}."
    exec "${PYTHON_BIN}" "${AEMU_RFB_BRIDGE}" \
      --grpcurl "${GRPCURL_BIN}" \
      --proto-dir "${AEMU_PROTO_DIR}" \
      --endpoint "127.0.0.1:${EMULATOR_GRPC_INTERNAL_PORT}" \
      --listen-host 127.0.0.1 --listen-port "${VNC_PORT}" \
      --width "${ANDROID_DISPLAY_WIDTH}" --height "${ANDROID_DISPLAY_HEIGHT}" \
      --ready-file "${BROWSER_READY_FILE}"
  ) &
  AEMU_RFB_PID=$!
}

stop_children() {
  trap - EXIT INT TERM HUP

  for child in "${BRIDGE_PID-}" "${ADB_SOCAT_PID-}" "${CONSOLE_SOCAT_PID-}" "${GRPC_SOCAT_PID-}" "${NOVNC_PID-}" "${AEMU_RFB_PID-}" "${EMULATOR_PID-}"; do
    if [ -n "${child}" ] && kill -0 "${child}" 2>/dev/null; then
      kill -TERM "${child}" 2>/dev/null || true
    fi
  done

  remaining=20
  while [ "${remaining}" -gt 0 ]; do
    live=0
    for child in "${BRIDGE_PID-}" "${ADB_SOCAT_PID-}" "${CONSOLE_SOCAT_PID-}" "${GRPC_SOCAT_PID-}" "${NOVNC_PID-}" "${AEMU_RFB_PID-}" "${EMULATOR_PID-}"; do
      if [ -n "${child}" ] && kill -0 "${child}" 2>/dev/null; then
        live=1
      fi
    done
    [ "${live}" -eq 0 ] && break
    sleep 1
    remaining=$((remaining - 1))
  done

  for child in "${BRIDGE_PID-}" "${ADB_SOCAT_PID-}" "${CONSOLE_SOCAT_PID-}" "${GRPC_SOCAT_PID-}" "${NOVNC_PID-}" "${AEMU_RFB_PID-}" "${EMULATOR_PID-}"; do
    if [ -n "${child}" ] && kill -0 "${child}" 2>/dev/null; then
      kill -KILL "${child}" 2>/dev/null || true
    fi
  done

  "${ADB_BIN}" kill-server >/dev/null 2>&1 || true
}

on_signal() {
  runtime_log "Received termination signal; stopping emulator, browser runtime, and supervised proxies."
  stop_children
  exit 143
}

if [ "${MODE}" = run ]; then
  initialize_single_container_state
fi
seed_avd
if [ "${MODE}" = run ]; then
  remove_stale_avd_locks "${ANDROID_AVD_HOME}/${AVD_NAME}.avd"
fi
"${SCRIPT_DIR}/runtime-preflight.sh"
effective_accel=$(resolve_runtime_acceleration "${DOCKER_ENGINE_ARCHITECTURE}" "${EMULATOR_ACCEL}" "${KVM_DEVICE}")

if [ "${MODE}" = print ]; then
  start_emulator "${effective_accel}" "$@"
  exit 0
fi

validate_console_socket_path
install_console_auth_token
install_adb_keys

trap on_signal INT TERM HUP
trap stop_children EXIT

start_emulator "${effective_accel}" "$@"
"${SOCAT_BIN}" "TCP4-LISTEN:${ADB_PROXY_PORT},reuseaddr,fork" "TCP4:127.0.0.1:${EMULATOR_ADB_PORT}" &
ADB_SOCAT_PID=$!
runtime_log "ADB proxy is listening on container port ${ADB_PROXY_PORT} and forwarding to emulator loopback port ${EMULATOR_ADB_PORT}."
"${SOCAT_BIN}" "UNIX-LISTEN:${EMULATOR_CONSOLE_SOCKET},unlink-early,fork,mode=0600" "TCP4:127.0.0.1:${EMULATOR_CONSOLE_PORT},connect-timeout=5" &
CONSOLE_SOCAT_PID=$!
runtime_log "Authenticated Console proxy is listening on Unix socket ${EMULATOR_CONSOLE_SOCKET} and forwarding to emulator loopback port ${EMULATOR_CONSOLE_PORT}."
"${SOCAT_BIN}" "TCP4-LISTEN:${EMULATOR_GRPC_PORT},reuseaddr,fork" "TCP4:127.0.0.1:${EMULATOR_GRPC_INTERNAL_PORT}" &
GRPC_SOCAT_PID=$!
runtime_log "gRPC proxy is listening on container port ${EMULATOR_GRPC_PORT} and forwarding to emulator port ${EMULATOR_GRPC_INTERNAL_PORT}."
"${PYTHON_BIN}" "${BRIDGE_SCRIPT}" &
BRIDGE_PID=$!
runtime_log "Device bridge is listening on container port ${LISTEN_PORT:-8090}."
start_novnc
start_aemu_rfb_bridge

status=0
while :; do
  if ! kill -0 "${EMULATOR_PID}" 2>/dev/null; then
    set +e
    wait "${EMULATOR_PID}"
    status=$?
    set -e
    runtime_log "Emulator exited with status ${status}."
    break
  fi
  if ! kill -0 "${ADB_SOCAT_PID}" 2>/dev/null; then
    runtime_log "ERROR: ADB proxy exited unexpectedly."
    status=1
    break
  fi
  if ! kill -0 "${CONSOLE_SOCAT_PID}" 2>/dev/null; then
    runtime_log "ERROR: authenticated Console proxy exited unexpectedly."
    status=1
    break
  fi
  if ! kill -0 "${GRPC_SOCAT_PID}" 2>/dev/null; then
    runtime_log "ERROR: gRPC proxy exited unexpectedly."
    status=1
    break
  fi
  if ! kill -0 "${BRIDGE_PID}" 2>/dev/null; then
    runtime_log "ERROR: device bridge exited unexpectedly."
    status=1
    break
  fi
  if ! kill -0 "${NOVNC_PID}" 2>/dev/null; then
    runtime_log "ERROR: noVNC exited unexpectedly."
    status=1
    break
  fi
  if ! kill -0 "${AEMU_RFB_PID}" 2>/dev/null; then
    runtime_log "ERROR: AEMU framebuffer/input bridge exited unexpectedly."
    status=1
    break
  fi
  sleep 2
done

stop_children
trap - EXIT
exit "${status}"
