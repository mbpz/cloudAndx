#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${SCRIPT_DIR}/runtime-lib.sh"

ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/android-sdk}
ANDROID_AVD_HOME=${ANDROID_AVD_HOME:-/data/avd}
AVD_NAME=${AVD_NAME:-Pixel_9_Android_17_Play_ARM64}
EMULATOR_ACCEL=${EMULATOR_ACCEL:-auto}
EMULATOR_CORES=${EMULATOR_CORES:-8}
EMULATOR_MEMORY_MB=${EMULATOR_MEMORY_MB:-4096}
EMULATOR_GPU=${EMULATOR_GPU:-swiftshader}
EMULATOR_CONSOLE_PORT=${EMULATOR_CONSOLE_PORT:-5556}
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
NATIVE_AEMU_INTERPRETER=${NATIVE_AEMU_INTERPRETER:-/lib/ld-linux-aarch64.so.1}
EMULATOR_BIN=${EMULATOR_BIN:-${NATIVE_AEMU_RUNNER}}
ADB_BIN=${ADB_BIN:-${ANDROID_SDK_ROOT}/platform-tools/adb}
SOCAT_BIN=${SOCAT_BIN:-socat}
SYSTEM_IMAGE_DIR=${SYSTEM_IMAGE_DIR:-${ANDROID_SDK_ROOT}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a}
ANDROID_RAMDISK_ROOT=${ANDROID_RAMDISK_ROOT:-/opt/cloudandx/android-ramdisk}
ANDROID_RAMDISK_ORIGINAL_SHA256=${ANDROID_RAMDISK_ORIGINAL_SHA256:-be1c34d44bdf2484c9bb0f4458b1cb3b8133d887bc87441dd5a5cb7c5fcfdff8}
ANDROID_RAMDISK_CPIO_SHA256=${ANDROID_RAMDISK_CPIO_SHA256:-56328ce8b964a5f53c7c6922d4c2415a3d10a2d36f100150d522a817054110ed}
ANDROID_RAMDISK_DERIVED_SHA256=${ANDROID_RAMDISK_DERIVED_SHA256:-28930d955709e5abaa52069cd0a504512f2b3b93dd8538cd2f0a64aad294510e}
ANDROID_RAMDISK_OVERLAY_PATH=${ANDROID_RAMDISK_OVERLAY_PATH:-system/etc/ramdisk/build.prop}
EXPECTED_HW_TIMEOUT_MULTIPLIER=${EXPECTED_HW_TIMEOUT_MULTIPLIER:-50}

validate_engine_architecture "${DOCKER_ENGINE_ARCHITECTURE}" "${ANDROID_RUNTIME_IMPLEMENTATION}"
validate_runtime_settings
validate_runtime_gpu_mode "${DOCKER_ENGINE_ARCHITECTURE}" "${EMULATOR_GPU}"
effective_accel=$(resolve_runtime_acceleration "${DOCKER_ENGINE_ARCHITECTURE}" "${EMULATOR_ACCEL}" "${KVM_DEVICE}")
engine_kind=$(selected_engine_kind "${DOCKER_ENGINE_ARCHITECTURE}" "${ANDROID_RUNTIME_IMPLEMENTATION}")
engine_executable=$(expected_engine_executable "${DOCKER_ENGINE_ARCHITECTURE}")

[ "${EMULATOR_BIN}" = "${NATIVE_AEMU_RUNNER}" ] \
  || runtime_die "ARM64 runtime must execute the locked native AEMU runner directly."
[ -x "${EMULATOR_BIN}" ] || runtime_die "Native AEMU runner is missing or not executable: ${EMULATOR_BIN}"
[ -x "${ADB_BIN}" ] || runtime_die "adb is missing or not executable: ${ADB_BIN}"
validate_native_aemu_bundle "${NATIVE_AEMU_ROOT}"
case ${DOCKER_ENGINE_ARCHITECTURE} in
  arm64|aarch64)
    validate_native_aemu_direct_execution "${NATIVE_AEMU_ROOT}" "${NATIVE_AEMU_INTERPRETER}"
    validate_native_aemu_vulkan "${NATIVE_AEMU_ROOT}"
    ;;
esac
if [ "${SOCAT_BIN}" = "socat" ]; then
  command -v socat >/dev/null 2>&1 || runtime_die "socat is not installed."
else
  [ -x "${SOCAT_BIN}" ] || runtime_die "socat is missing or not executable: ${SOCAT_BIN}"
fi
[ -s "${SYSTEM_IMAGE_DIR}/system.img" ] || runtime_die "Android 17 system.img is missing: ${SYSTEM_IMAGE_DIR}/system.img"
[ -s "${SYSTEM_IMAGE_DIR}/vendor.img" ] || runtime_die "Android 17 vendor.img is missing: ${SYSTEM_IMAGE_DIR}/vendor.img"
[ -s "${SYSTEM_IMAGE_DIR}/ramdisk.img" ] || runtime_die "Android 17 derived ramdisk is missing: ${SYSTEM_IMAGE_DIR}/ramdisk.img"
[ "${ANDROID_RAMDISK_OVERLAY_PATH}" = system/etc/ramdisk/build.prop ] \
  || runtime_die "Android ramdisk overlay path is not the locked second-stage property channel."
validate_uint_range EXPECTED_HW_TIMEOUT_MULTIPLIER "${EXPECTED_HW_TIMEOUT_MULTIPLIER}" 1 1000
for ramdisk_sha256 in \
  "${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
  "${ANDROID_RAMDISK_CPIO_SHA256}" \
  "${ANDROID_RAMDISK_DERIVED_SHA256}"; do
  [ "${#ramdisk_sha256}" -eq 64 ] \
    || runtime_die "Android ramdisk identity is not a SHA-256 value."
done
[ -s "${ANDROID_RAMDISK_ROOT}/official-ramdisk.img" ] \
  || runtime_die "Official Android ramdisk provenance artifact is missing."
[ -s "${ANDROID_RAMDISK_ROOT}/derived-ramdisk.img" ] \
  || runtime_die "Derived Android ramdisk provenance artifact is missing."
[ -s "${ANDROID_RAMDISK_ROOT}/identity.properties" ] \
  || runtime_die "Android ramdisk identity is missing."
printf '%s  %s\n' "${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
  "${ANDROID_RAMDISK_ROOT}/official-ramdisk.img" \
  | sha256sum --check --strict - >/dev/null \
  || runtime_die "Official Android ramdisk provenance hash is invalid."
printf '%s  %s\n' "${ANDROID_RAMDISK_DERIVED_SHA256}" \
  "${ANDROID_RAMDISK_ROOT}/derived-ramdisk.img" \
  | sha256sum --check --strict - >/dev/null \
  || runtime_die "Derived Android ramdisk hash is invalid."
cmp -s "${ANDROID_RAMDISK_ROOT}/derived-ramdisk.img" "${SYSTEM_IMAGE_DIR}/ramdisk.img" \
  || runtime_die "Runtime ramdisk does not match the locked derived artifact."
grep -Fxq "official_ramdisk_sha256=${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Official Android ramdisk identity is inconsistent."
grep -Fxq "official_cpio_sha256=${ANDROID_RAMDISK_CPIO_SHA256}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Official Android ramdisk cpio identity is inconsistent."
grep -Fxq "derived_ramdisk_sha256=${ANDROID_RAMDISK_DERIVED_SHA256}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Derived Android ramdisk identity is inconsistent."
grep -Fxq "overlay_path=${ANDROID_RAMDISK_OVERLAY_PATH}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Android ramdisk overlay path identity is inconsistent."
grep -Fxq "overlay_property=ro.hw_timeout_multiplier=${EXPECTED_HW_TIMEOUT_MULTIPLIER}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Android ramdisk overlay property identity is inconsistent."

data_root=$(dirname "${ANDROID_AVD_HOME}")
[ -d "${data_root}" ] || runtime_die "Runtime data directory does not exist: ${data_root}"
[ -w "${data_root}" ] || runtime_die "Runtime data directory is not writable by uid $(id -u): ${data_root}"

if [ "${1-}" = "--effective-only" ]; then
  printf '%s\n' "${effective_accel}"
  exit 0
fi

printf '%s\n' \
  "runtime.os=$(uname -s)" \
  "runtime.arch=$(uname -m)" \
  "docker.engine-arch=${DOCKER_ENGINE_ARCHITECTURE}" \
  "runtime.implementation=${ANDROID_RUNTIME_IMPLEMENTATION}" \
  "engine.selected=${engine_kind}" \
  "engine.executable=${engine_executable}" \
  "native-aemu.revision=${NATIVE_AEMU_REVISION}" \
  "native-aemu.source-lock-sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  "native-aemu.patch-set-sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
  "runtime.uid=$(id -u)" \
  "android.release=17" \
  "android.api=37.0" \
  "android.image=google_apis_playstore_ps16k/arm64-v8a/r06" \
  "android.ramdisk=derived-official-prefix-plus-second-stage-property" \
  "android.ramdisk.original-sha256=${ANDROID_RAMDISK_ORIGINAL_SHA256}" \
  "android.ramdisk.derived-sha256=${ANDROID_RAMDISK_DERIVED_SHA256}" \
  "android.hw-timeout-multiplier=${EXPECTED_HW_TIMEOUT_MULTIPLIER}" \
  "android.release-policy=base-final-stable-qpr1-beta-excluded" \
  "sdk.emulator-package.version=36.6.11" \
  "kvm.device=${KVM_DEVICE}" \
  "kvm.usable=$(if kvm_is_usable "${KVM_DEVICE}"; then printf yes; else printf no; fi)" \
  "accel.requested=${EMULATOR_ACCEL}" \
  "accel.effective=${effective_accel}" \
  "adb.proxy-port=${ADB_PROXY_PORT}" \
  "grpc.internal-port=${EMULATOR_GRPC_INTERNAL_PORT}" \
  "grpc.proxy-port=${EMULATOR_GRPC_PORT}"

if [ "${effective_accel}" = off ]; then
  runtime_log "KVM is unavailable, incompatible, or disabled; using the verified software-emulation engine path."
fi
