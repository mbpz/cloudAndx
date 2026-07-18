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
  architecture=${1-}
  implementation=${2:-${ANDROID_RUNTIME_IMPLEMENTATION-}}

  case ${architecture} in
    x86_64|amd64)
      if [ "${implementation}" = native ]; then
        return 0
      fi
      runtime_die "x86_64 requires ANDROID_RUNTIME_IMPLEMENTATION=native."
      ;;
    arm64|aarch64)
      if [ "${implementation}" = hybrid-aemu-arm64 ]; then
        return 0
      fi
      runtime_die "ARM64 requires the verified hybrid-aemu-arm64 implementation."
      ;;
    '')
      runtime_die "DOCKER_ENGINE_ARCHITECTURE is required; start through androidctl."
      ;;
    *)
      runtime_die "Unsupported Docker Engine architecture '${1}'."
      ;;
  esac
}

selected_engine_kind() {
  architecture=${1-}
  implementation=${2:-${ANDROID_RUNTIME_IMPLEMENTATION-}}

  validate_engine_architecture "${architecture}" "${implementation}" || return 1
  case ${architecture} in
    x86_64|amd64) printf '%s\n' upstream-x86_64 ;;
    arm64|aarch64) printf '%s\n' native-aemu-arm64 ;;
  esac
}

validate_native_aemu_bundle() {
  bundle_root=${1:-/opt/cloudandx/native-aemu}
  runner=${bundle_root}/bin/run-qemu-system-x86_64-headless
  engine=${bundle_root}/bin/qemu-system-x86_64-headless
  manifest=${bundle_root}/manifest.json
  checksums=${bundle_root}/SHA256SUMS
  identity=${bundle_root}/identity.properties

  [ -n "${NATIVE_AEMU_REVISION-}" ] \
    || runtime_die "Native AEMU required revision is missing from the image environment." \
    || return 1
  case ${NATIVE_AEMU_SOURCE_LOCK_SHA256-} in
    ''|*[!0-9a-f]*) runtime_die "Native AEMU required source-lock digest is invalid."; return 1 ;;
  esac
  case ${NATIVE_AEMU_PATCH_SET_SHA256-} in
    ''|*[!0-9a-f]*) runtime_die "Native AEMU required patch-set digest is invalid."; return 1 ;;
  esac
  [ "${#NATIVE_AEMU_SOURCE_LOCK_SHA256}" -eq 64 ] \
    || runtime_die "Native AEMU required source-lock digest is not SHA-256." \
    || return 1
  [ "${#NATIVE_AEMU_PATCH_SET_SHA256}" -eq 64 ] \
    || runtime_die "Native AEMU required patch-set digest is not SHA-256." \
    || return 1

  [ -x "${runner}" ] || runtime_die "Native AEMU runner is missing or not executable: ${runner}" || return 1
  [ -x "${engine}" ] || runtime_die "Native AEMU engine is missing or not executable: ${engine}" || return 1
  [ -s "${manifest}" ] || runtime_die "Native AEMU provenance manifest is missing: ${manifest}" || return 1
  [ -s "${checksums}" ] || runtime_die "Native AEMU checksum manifest is missing: ${checksums}" || return 1
  [ -s "${identity}" ] || runtime_die "Native AEMU immutable identity is missing: ${identity}" || return 1
  (cd "${bundle_root}" && sha256sum -c SHA256SUMS >/dev/null 2>&1) \
    || runtime_die "Native AEMU bundle checksum verification failed." \
    || return 1
  [ "$(wc -l < "${identity}" | tr -d ' ')" = 3 ] \
    || runtime_die "Native AEMU identity must contain exactly three fields." \
    || return 1
  grep -Fxq "revision=${NATIVE_AEMU_REVISION}" "${identity}" \
    || runtime_die "Native AEMU revision identity does not match the required bundle." \
    || return 1
  grep -Fxq "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" "${identity}" \
    || runtime_die "Native AEMU source-lock identity does not match the required bundle." \
    || return 1
  grep -Fxq "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" "${identity}" \
    || runtime_die "Native AEMU patch-set identity does not match the required bundle." \
    || return 1
}

validate_native_aemu_direct_execution() {
  bundle_root=${1:-/opt/cloudandx/native-aemu}
  bundled_loader=${bundle_root}/lib/ld-linux-aarch64.so.1
  engine_lib_link=${bundle_root}/bin/lib64
  interpreter=${2:-/lib/ld-linux-aarch64.so.1}

  [ -x "${interpreter}" ] \
    || runtime_die "Native AEMU PT_INTERP is unavailable: ${interpreter}" \
    || return 1
  cmp -s "${bundled_loader}" "${interpreter}" \
    || runtime_die "Native AEMU PT_INTERP does not match the locked bundle loader." \
    || return 1
  [ -L "${engine_lib_link}" ] \
    || runtime_die "Native AEMU engine lib64 path is not a symbolic link." \
    || return 1
  [ "$(readlink "${engine_lib_link}")" = ../lib ] \
    || runtime_die "Native AEMU engine lib64 path does not resolve inside the bundle." \
    || return 1
}

expected_engine_executable() {
  architecture=${1-}
  case ${architecture} in
    x86_64|amd64)
      printf '%s\n' "${UPSTREAM_QEMU_ENGINE:-/opt/android-sdk/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless.upstream-x86_64}"
      ;;
    arm64|aarch64)
      printf '%s\n' "${NATIVE_AEMU_ROOT:-/opt/cloudandx/native-aemu}/bin/qemu-system-x86_64-headless"
      ;;
    *)
      runtime_die "Cannot select an engine executable for architecture '${architecture}'."
      ;;
  esac
}

engine_process_matches_expected() {
  expected=$1
  for executable_link in /proc/[0-9]*/exe; do
    executable=$(readlink "${executable_link}" 2>/dev/null || true)
    if [ "${executable}" = "${expected}" ]; then
      return 0
    fi
  done
  return 1
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

resolve_runtime_acceleration() {
  architecture=$1
  requested=${2:-auto}
  kvm_device=${3:-/dev/kvm}

  case ${architecture} in
    arm64|aarch64)
      case ${requested} in
        auto|off) printf '%s\n' off ;;
        kvm)
          runtime_die "KVM cannot accelerate the official x86_64 guest on an ARM64 Docker Engine."
          return 1
          ;;
        *)
          runtime_die "EMULATOR_ACCEL must be one of auto, kvm, or off; got '${requested}'."
          return 1
          ;;
      esac
      ;;
    x86_64|amd64)
      resolve_acceleration "${requested}" "${kvm_device}"
      ;;
    *)
      runtime_die "Cannot resolve acceleration for unsupported architecture '${architecture}'."
      return 1
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
