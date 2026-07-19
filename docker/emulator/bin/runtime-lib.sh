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
      runtime_die "x86_64 Docker Engine runtime is deferred until it is built and verified on an x86_64 host."
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
    arm64|aarch64) printf '%s\n' native-aemu-arm64 ;;
  esac
}

validate_native_aemu_bundle() {
  bundle_root=${1:-/opt/cloudandx/native-aemu}
  runner=${bundle_root}/bin/run-qemu-system-aarch64-headless
  engine=${bundle_root}/qemu/linux-aarch64/qemu-system-aarch64-headless
  gfxstream_backend=${bundle_root}/lib64/libgfxstream_backend.so
  x11_xcb=${bundle_root}/lib64/libX11-xcb.so.1
  crashpad_handler=${bundle_root}/crashpad_handler
  qemu_img=${bundle_root}/qemu-img
  nimble_bridge=${bundle_root}/nimble_bridge
  netsimd_launcher=${bundle_root}/netsimd
  netsimd_binary=${bundle_root}/libexec/linux-x86_64/netsimd
  pc_bios=${bundle_root}/lib/pc-bios
  swiftshader=${bundle_root}/lib64/gles_swiftshader
  vulkan_dir=${bundle_root}/lib64/vulkan
  vulkan_loader=${vulkan_dir}/libvulkan.so
  vulkan_loader_soname=${vulkan_dir}/libvulkan.so.1
  vulkan_loader_real=${vulkan_dir}/libvulkan.so.1.4.344
  vulkan_icd=${vulkan_dir}/libvk_swiftshader.so
  vulkan_icd_json=${vulkan_dir}/vk_swiftshader_icd.json
  vulkan_probe=${bundle_root}/vulkan-smoke
  resources=${bundle_root}/resources
  sdk_resource_checksums=${bundle_root}/sdk-resources.SHA256SUMS
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
  [ -s "${gfxstream_backend}" ] || runtime_die "Native AEMU gfxstream backend is missing: ${gfxstream_backend}" || return 1
  [ -s "${x11_xcb}" ] || runtime_die "Native AEMU X11-XCB runtime library is missing: ${x11_xcb}" || return 1
  [ -x "${crashpad_handler}" ] || runtime_die "Native AEMU crashpad handler is missing: ${crashpad_handler}" || return 1
  [ -x "${qemu_img}" ] || runtime_die "Native AEMU qemu-img is missing: ${qemu_img}" || return 1
  [ -x "${nimble_bridge}" ] || runtime_die "Native AEMU NimBLE bridge is missing: ${nimble_bridge}" || return 1
  [ -x "${netsimd_launcher}" ] \
    || runtime_die "Native AEMU netsimd launcher is missing: ${netsimd_launcher}" \
    || return 1
  [ -x "${netsimd_binary}" ] \
    || runtime_die "Native AEMU mixed-architecture netsimd helper is missing: ${netsimd_binary}" \
    || return 1
  [ -d "${pc_bios}" ] || runtime_die "Native AEMU pc-bios data is missing: ${pc_bios}" || return 1
  find "${pc_bios}" -type f -print -quit | grep -q . \
    || runtime_die "Native AEMU pc-bios data is empty." \
    || return 1
  for data_file in advancedFeatures.ini emu-original-feature-flags.protobuf \
    ca-bundle.pem hostapd.conf emulator_access.json; do
    [ -s "${bundle_root}/lib/${data_file}" ] \
      || runtime_die "Native AEMU locked data file is missing: ${data_file}" \
      || return 1
  done
  [ -z "$(find "${bundle_root}/lib" -mindepth 1 -maxdepth 1 \
    ! -name pc-bios \
    ! -name advancedFeatures.ini \
    ! -name emu-original-feature-flags.protobuf \
    ! -name ca-bundle.pem \
    ! -name hostapd.conf \
    ! -name emulator_access.json \
    -print -quit)" ] \
    || runtime_die "Native AEMU lib directory contains unlocked runtime data." \
    || return 1
  for swiftshader_library in libEGL.so libGLES_CM.so libGLESv2.so; do
    [ -s "${swiftshader}/${swiftshader_library}" ] \
      || runtime_die "Native AEMU SwiftShader library is missing: ${swiftshader_library}" \
      || return 1
  done
  [ -s "${vulkan_loader_real}" ] \
    || runtime_die "Native AEMU Vulkan loader is missing: ${vulkan_loader_real}" \
    || return 1
  [ -L "${vulkan_loader_soname}" ] \
    && [ "$(readlink "${vulkan_loader_soname}")" = libvulkan.so.1.4.344 ] \
    || runtime_die "Native AEMU Vulkan loader SONAME link is invalid." \
    || return 1
  [ -L "${vulkan_loader}" ] \
    && [ "$(readlink "${vulkan_loader}")" = libvulkan.so.1 ] \
    || runtime_die "Native AEMU Vulkan loader link is invalid." \
    || return 1
  [ -s "${vulkan_icd}" ] \
    || runtime_die "Native AEMU SwiftShader Vulkan ICD is missing: ${vulkan_icd}" \
    || return 1
  [ -s "${vulkan_icd_json}" ] \
    || runtime_die "Native AEMU SwiftShader Vulkan manifest is missing: ${vulkan_icd_json}" \
    || return 1
  grep -Fq '"library_path": "./libvk_swiftshader.so"' "${vulkan_icd_json}" \
    || runtime_die "Native AEMU SwiftShader Vulkan manifest selects an unexpected ICD." \
    || return 1
  [ -x "${vulkan_probe}" ] \
    || runtime_die "Native AEMU Vulkan smoke probe is missing: ${vulkan_probe}" \
    || return 1
  [ -s "${manifest}" ] || runtime_die "Native AEMU provenance manifest is missing: ${manifest}" || return 1
  [ -s "${checksums}" ] || runtime_die "Native AEMU checksum manifest is missing: ${checksums}" || return 1
  [ -s "${identity}" ] || runtime_die "Native AEMU immutable identity is missing: ${identity}" || return 1
  (cd "${bundle_root}" && sha256sum -c SHA256SUMS >/dev/null 2>&1) \
    || runtime_die "Native AEMU bundle checksum verification failed." \
    || return 1
  if ! netsimd_version=$(NATIVE_AEMU_ROOT="${bundle_root}" \
    "${netsimd_launcher}" --version 2>&1); then
    runtime_die "Native AEMU netsimd helper cannot execute in the amd64 runtime." \
      || return 1
  fi
  printf '%s\n' "${netsimd_version}" \
    | grep -Eq '(^|[^0-9])0\.3\.112([^0-9]|$)' \
    || runtime_die "Native AEMU netsimd helper is not the locked 0.3.112 release." \
    || return 1
  [ -d "${resources}" ] \
    || runtime_die "Google Emulator runtime resources are missing: ${resources}" \
    || return 1
  find "${resources}" -type f -print -quit | grep -q . \
    || runtime_die "Google Emulator runtime resources are empty." \
    || return 1
  [ -s "${sdk_resource_checksums}" ] \
    || runtime_die "Google Emulator resource checksum manifest is missing." \
    || return 1
  (cd "${bundle_root}" && sha256sum -c sdk-resources.SHA256SUMS >/dev/null 2>&1) \
    || runtime_die "Google Emulator runtime resource checksum verification failed." \
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

validate_native_aemu_vulkan() {
  bundle_root=${1:-/opt/cloudandx/native-aemu}
  probe=${bundle_root}/vulkan-smoke
  icd_manifest=${bundle_root}/lib64/vulkan/vk_swiftshader_icd.json

  if ! probe_output=$(env -i \
    PATH=/usr/bin:/bin \
    TMPDIR=/tmp \
    LD_LIBRARY_PATH="${bundle_root}/lib64" \
    VK_DRIVER_FILES="${icd_manifest}" \
    VK_LOADER_DEBUG=error,warn \
    "${probe}" 2>&1); then
    runtime_die "Native AEMU Vulkan host probe failed: ${probe_output}" \
      || return 1
  fi
  printf '%s\n' "${probe_output}" | grep -Fq ' PASS' \
    || runtime_die "Native AEMU Vulkan host probe returned no PASS result." \
    || return 1
}

validate_native_aemu_direct_execution() {
  bundle_root=${1:-/opt/cloudandx/native-aemu}
  bundled_loader=${bundle_root}/lib64/ld-linux-aarch64.so.1
  engine_lib_link=${bundle_root}/qemu/linux-aarch64/lib64
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
  [ "$(readlink "${engine_lib_link}")" = ../../lib64 ] \
    || runtime_die "Native AEMU engine lib64 path does not resolve inside the bundle." \
    || return 1
}

expected_engine_executable() {
  architecture=${1-}
  case ${architecture} in
    x86_64|amd64)
      runtime_die "x86_64 engine selection is deferred until x86_64 host verification."
      ;;
    arm64|aarch64)
      printf '%s\n' "${NATIVE_AEMU_ROOT:-/opt/cloudandx/native-aemu}/qemu/linux-aarch64/qemu-system-aarch64-headless"
      ;;
    *)
      runtime_die "Cannot select an engine executable for architecture '${architecture}'."
      ;;
  esac
}

validate_runtime_gpu_mode() {
  architecture=${1-}
  gpu=${2-}

  case ${architecture} in
    arm64|aarch64)
      [ "${gpu}" = swiftshader ] \
        || runtime_die "ARM64 native AEMU requires EMULATOR_GPU=swiftshader for first boot."
      ;;
    x86_64|amd64)
      runtime_die "x86_64 GPU runtime is deferred until x86_64 host verification."
      ;;
    *)
      runtime_die "Cannot validate GPU mode for unsupported architecture '${architecture}'."
      ;;
  esac
}

native_aemu_graphics_args() {
  printf '%s\n' \
    -gpu swiftshader \
    -feature -GuestAngle \
    -feature -GuestUsesAngle \
    -feature -VulkanNativeSwapchain \
    -feature -VulkanSnapshots
}

native_aemu_tcg_qemu_args() {
  printf '%s\n' \
    -qemu \
    -machine gic-version=2 \
    -cpu android-a57-16k
}

validate_android_emulator_args() {
  for argument do
    [ "${argument}" != -qemu ] \
      || runtime_die "Raw QEMU arguments are runtime-controlled; remove the user-supplied -qemu sentinel." \
      || return 1
  done
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
          runtime_die "The Docker-only ARM64 guest path is fixed to software execution and does not map KVM."
          return 1
          ;;
        *)
          runtime_die "EMULATOR_ACCEL must be one of auto, kvm, or off; got '${requested}'."
          return 1
          ;;
      esac
      ;;
    x86_64|amd64)
      runtime_die "x86_64 acceleration is deferred until x86_64 host verification."
      return 1
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
