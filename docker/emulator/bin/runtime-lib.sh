#!/bin/sh

runtime_log() {
  printf '%s %s\n' "[android-emulator]" "$*" >&2
}

runtime_die() {
  runtime_log "ERROR: $*"
  return 1
}

is_uint() {
  case ${1-} in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_uint_range() {
  field=$1
  value=$2
  minimum=$3
  maximum=$4

  if ! is_uint "${value}"; then
    runtime_die "${field} must be an integer; got '${value}'."
    return 1
  fi
  if [ "${value}" -lt "${minimum}" ] || [ "${value}" -gt "${maximum}" ]; then
    runtime_die "${field} must be between ${minimum} and ${maximum}; got '${value}'."
    return 1
  fi
}

validate_avd_name() {
  case ${1-} in
    ''|*[!A-Za-z0-9_.-]*) runtime_die "AVD_NAME may contain only letters, digits, dot, underscore, and hyphen." ;;
    *) return 0 ;;
  esac
}

validate_engine_architecture() {
  case ${1-} in
    x86_64|amd64)
      return 0
      ;;
    arm64|aarch64)
      runtime_die "Google does not publish a Linux ARM64 Android Emulator; refusing cross-architecture startup."
      ;;
    '')
      runtime_die "DOCKER_ENGINE_ARCHITECTURE is required; start through androidctl."
      ;;
    *)
      runtime_die "Unsupported Docker Engine architecture '${1}'."
      ;;
  esac
}

# Emulator lock files contain PIDs from the previous container PID namespace.
# A restarted container can legitimately reuse the same PID and be mistaken for
# a second live instance, so remove only the two upstream AVD runtime locks.
remove_stale_avd_locks() {
  avd_dir=$1
  removed=0

  for lock_name in hardware-qemu.ini.lock multiinstance.lock; do
    lock_path=${avd_dir}/${lock_name}
    if [ -e "${lock_path}" ]; then
      rm -f "${lock_path}"
      removed=1
    fi
  done

  if [ "${removed}" -eq 1 ]; then
    runtime_log "Removed stale AVD locks left by the previous container PID namespace."
  fi
}

kvm_is_usable() {
  kvm_device=${1:-/dev/kvm}
  [ -c "${kvm_device}" ] && [ -r "${kvm_device}" ] && [ -w "${kvm_device}" ]
}

resolve_acceleration() {
  requested=${1:-auto}
  kvm_device=${2:-/dev/kvm}

  case "${requested}" in
    auto)
      if kvm_is_usable "${kvm_device}"; then
        printf '%s\n' on
      else
        printf '%s\n' off
      fi
      ;;
    kvm)
      if ! kvm_is_usable "${kvm_device}"; then
        runtime_die "EMULATOR_ACCEL=kvm requires a readable and writable /dev/kvm character device."
        return 1
      fi
      printf '%s\n' on
      ;;
    off)
      printf '%s\n' off
      ;;
    *)
      runtime_die "EMULATOR_ACCEL must be one of auto, kvm, or off; got '${requested}'."
      ;;
  esac
}

validate_runtime_settings() {
  validate_avd_name "${AVD_NAME}" || return 1
  validate_uint_range EMULATOR_CORES "${EMULATOR_CORES}" 1 32 || return 1
  validate_uint_range EMULATOR_MEMORY_MB "${EMULATOR_MEMORY_MB}" 1536 8192 || return 1
  validate_uint_range EMULATOR_CONSOLE_PORT "${EMULATOR_CONSOLE_PORT}" 5554 5682 || return 1
  validate_uint_range EMULATOR_ADB_PORT "${EMULATOR_ADB_PORT}" 5554 5682 || return 1
  validate_uint_range ADB_PROXY_PORT "${ADB_PROXY_PORT}" 1024 65535 || return 1
  validate_uint_range EMULATOR_GRPC_INTERNAL_PORT "${EMULATOR_GRPC_INTERNAL_PORT}" 1024 65535 || return 1
  validate_uint_range EMULATOR_GRPC_PORT "${EMULATOR_GRPC_PORT}" 1024 65535 || return 1

  if [ $((EMULATOR_CONSOLE_PORT % 2)) -ne 0 ]; then
    runtime_die "EMULATOR_CONSOLE_PORT must be even."
    return 1
  fi
  if [ "${EMULATOR_CONSOLE_PORT}" -eq "${EMULATOR_ADB_PORT}" ]; then
    runtime_die "EMULATOR_CONSOLE_PORT and EMULATOR_ADB_PORT must differ."
    return 1
  fi
  if [ "${EMULATOR_ADB_PORT}" -eq "${ADB_PROXY_PORT}" ]; then
    runtime_die "ADB_PROXY_PORT must differ from the emulator's loopback ADB port."
    return 1
  fi
  if [ "${EMULATOR_GRPC_INTERNAL_PORT}" -eq "${EMULATOR_GRPC_PORT}" ]; then
    runtime_die "EMULATOR_GRPC_INTERNAL_PORT must differ from the public gRPC proxy port."
    return 1
  fi
  if [ "${ADB_PROXY_PORT}" -eq "${EMULATOR_GRPC_PORT}" ]; then
    runtime_die "ADB_PROXY_PORT and EMULATOR_GRPC_PORT must differ."
    return 1
  fi
  if [ "${EMULATOR_GRPC_INTERNAL_PORT}" -eq "${EMULATOR_CONSOLE_PORT}" ] \
    || [ "${EMULATOR_GRPC_INTERNAL_PORT}" -eq "${EMULATOR_ADB_PORT}" ]; then
    runtime_die "EMULATOR_GRPC_INTERNAL_PORT must differ from both emulator console and ADB ports."
    return 1
  fi

  case "${EMULATOR_GPU}" in
    auto|software|swiftshader|swangle|lavapipe) ;;
    *)
      runtime_die "EMULATOR_GPU must be auto, software, swiftshader, swangle, or lavapipe."
      return 1
      ;;
  esac

  case "${EMULATOR_WIPE_DATA}" in
    0|1) ;;
    *) runtime_die "EMULATOR_WIPE_DATA must be 0 or 1." ;;
  esac
}
