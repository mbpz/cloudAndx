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
EMULATOR_CONSOLE_SOCKET=${EMULATOR_CONSOLE_SOCKET:-/run/emulator-console/console.sock}
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
NOVNC_PORT=${NOVNC_PORT:-6080}
VNC_PORT=${VNC_PORT:-5900}
NOVNC_ROOT=${NOVNC_ROOT:-/opt/cloudandx/novnc}
SCRCPY_ROOT=${SCRCPY_ROOT:-/opt/cloudandx/scrcpy}
SCRCPY_BIN=${SCRCPY_BIN:-${SCRCPY_ROOT}/scrcpy}
SCRCPY_SERIAL=${SCRCPY_SERIAL:-emulator-${EMULATOR_CONSOLE_PORT}}
GRPCURL_BIN=${GRPCURL_BIN:-/opt/cloudandx/grpcurl/grpcurl}
AEMU_RFB_BRIDGE=${AEMU_RFB_BRIDGE:-/usr/local/bin/aemu-rfb-bridge.py}
AEMU_PROTO_DIR=${AEMU_PROTO_DIR:-${ANDROID_SDK_ROOT}/emulator/lib}
WEBSOCKIFY_BIN=${WEBSOCKIFY_BIN:-websockify}
SYSTEM_IMAGE_DIR=${SYSTEM_IMAGE_DIR:-${ANDROID_SDK_ROOT}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a}
ANDROID_RAMDISK_ROOT=${ANDROID_RAMDISK_ROOT:-/opt/cloudandx/android-ramdisk}
ANDROID_RAMDISK_ORIGINAL_SHA256=${ANDROID_RAMDISK_ORIGINAL_SHA256:-be1c34d44bdf2484c9bb0f4458b1cb3b8133d887bc87441dd5a5cb7c5fcfdff8}
ANDROID_RAMDISK_CPIO_SHA256=${ANDROID_RAMDISK_CPIO_SHA256:-56328ce8b964a5f53c7c6922d4c2415a3d10a2d36f100150d522a817054110ed}
ANDROID_RAMDISK_DERIVED_SHA256=${ANDROID_RAMDISK_DERIVED_SHA256:-bfaeb73b28c50733a90337ceb93d66b5eb652f713b807744d86532f28344035c}
ANDROID_RAMDISK_OVERLAY_PATH=${ANDROID_RAMDISK_OVERLAY_PATH:-system/etc/ramdisk/build.prop}
EXPECTED_HW_TIMEOUT_MULTIPLIER=${EXPECTED_HW_TIMEOUT_MULTIPLIER:-50}
EXPECTED_FINALIZER_TIMEOUT_MS=${EXPECTED_FINALIZER_TIMEOUT_MS:-500000}
EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS=${EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS:-100000}
EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS=${EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS:-250000}

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
validate_uint_range NOVNC_PORT "${NOVNC_PORT}" 1024 65535
validate_uint_range VNC_PORT "${VNC_PORT}" 1024 65535
[ "${NOVNC_PORT}" -ne "${VNC_PORT}" ] \
  || runtime_die "NOVNC_PORT and VNC_PORT must differ."
[ "${NOVNC_PORT}" -ne "${ADB_PROXY_PORT}" ] \
  || runtime_die "NOVNC_PORT must differ from ADB_PROXY_PORT."
[ "${NOVNC_PORT}" -ne "${EMULATOR_GRPC_PORT}" ] \
  || runtime_die "NOVNC_PORT must differ from EMULATOR_GRPC_PORT."
[ "${VNC_PORT}" -ne "${ADB_PROXY_PORT}" ] \
  || runtime_die "VNC_PORT must differ from ADB_PROXY_PORT."
[ "${VNC_PORT}" -ne "${EMULATOR_GRPC_PORT}" ] \
  || runtime_die "VNC_PORT must differ from EMULATOR_GRPC_PORT."
[ -d "${NOVNC_ROOT}" ] || runtime_die "noVNC root is missing: ${NOVNC_ROOT}"
[ -f "${NOVNC_ROOT}/vnc.html" ] || runtime_die "noVNC UI is missing vnc.html."
grep -Fq "\"version\": \"${NOVNC_VERSION:-1.7.0}\"" "${NOVNC_ROOT}/package.json" \
  || runtime_die "noVNC package.json does not match the locked version."
[ -d "${SCRCPY_ROOT}" ] || runtime_die "scrcpy root is missing: ${SCRCPY_ROOT}"
[ -x "${SCRCPY_BIN}" ] || runtime_die "scrcpy binary is missing or not executable: ${SCRCPY_BIN}"
[ -s "${SCRCPY_ROOT}/scrcpy-server" ] || runtime_die "scrcpy server is missing from ${SCRCPY_ROOT}."
[ "${SCRCPY_SERIAL}" = "emulator-${EMULATOR_CONSOLE_PORT}" ] \
  || runtime_die "SCRCPY_SERIAL must match the in-container emulator serial."
command -v "${WEBSOCKIFY_BIN}" >/dev/null 2>&1 || runtime_die "websockify is not installed."
[ -x "${GRPCURL_BIN}" ] || runtime_die "grpcurl is missing or not executable: ${GRPCURL_BIN}"
[ -x "${AEMU_RFB_BRIDGE}" ] || runtime_die "AEMU RFB bridge is missing or not executable: ${AEMU_RFB_BRIDGE}"
[ -s "${AEMU_PROTO_DIR}/emulator_controller.proto" ] \
  || runtime_die "AEMU controller proto is missing from ${AEMU_PROTO_DIR}."
grpcurl_version_output=$("${GRPCURL_BIN}" -version 2>&1 || true)
[ "${grpcurl_version_output}" = "grpcurl v${GRPCURL_VERSION:-1.9.3}" ] \
  || runtime_die "grpcurl does not match the locked version."
scrcpy_version_output=$("${SCRCPY_BIN}" --version 2>&1 || true)
printf '%s\n' "${scrcpy_version_output}" | grep -Fq "scrcpy ${SCRCPY_VERSION:-4.1}" \
  || runtime_die "scrcpy binary does not match the locked version."
[ -s "${SYSTEM_IMAGE_DIR}/system.img" ] || runtime_die "Android 17 system.img is missing: ${SYSTEM_IMAGE_DIR}/system.img"
[ -s "${SYSTEM_IMAGE_DIR}/vendor.img" ] || runtime_die "Android 17 vendor.img is missing: ${SYSTEM_IMAGE_DIR}/vendor.img"
[ -s "${SYSTEM_IMAGE_DIR}/ramdisk.img" ] || runtime_die "Android 17 derived ramdisk is missing: ${SYSTEM_IMAGE_DIR}/ramdisk.img"
[ "${ANDROID_RAMDISK_OVERLAY_PATH}" = system/etc/ramdisk/build.prop ] \
  || runtime_die "Android ramdisk overlay path is not the locked second-stage property channel."
validate_uint_range EXPECTED_HW_TIMEOUT_MULTIPLIER "${EXPECTED_HW_TIMEOUT_MULTIPLIER}" 1 1000
validate_uint_range EXPECTED_FINALIZER_TIMEOUT_MS "${EXPECTED_FINALIZER_TIMEOUT_MS}" 10000 10000000
[ "${EXPECTED_FINALIZER_TIMEOUT_MS}" -eq "$((EXPECTED_HW_TIMEOUT_MULTIPLIER * 10000))" ] \
  || runtime_die "ART finalizer timeout must match the hardware timeout multiplier."
validate_uint_range EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS "${EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS}" 2000 2000000
validate_uint_range EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS "${EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS}" 5000 5000000
[ "${EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS}" -eq "$((EXPECTED_HW_TIMEOUT_MULTIPLIER * 2000))" ] \
  || runtime_die "Bluetooth HCI command timeout must match the hardware timeout multiplier."
[ "${EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS}" -eq "$((EXPECTED_HW_TIMEOUT_MULTIPLIER * 5000))" ] \
  || runtime_die "Bluetooth HCI restart timeout must match the hardware timeout multiplier."
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
grep -Fxq "overlay_property.ro_hw_timeout_multiplier=${EXPECTED_HW_TIMEOUT_MULTIPLIER}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Android ramdisk hardware timeout identity is inconsistent."
grep -Fxq "overlay_property.dalvik_vm_finalizer_timeout_ms=${EXPECTED_FINALIZER_TIMEOUT_MS}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Android ramdisk ART finalizer timeout identity is inconsistent."
grep -Fxq "overlay_property.bluetooth_hci_timeout_ms=${EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Android ramdisk Bluetooth HCI command timeout identity is inconsistent."
grep -Fxq "overlay_property.bluetooth_hci_restart_timeout_ms=${EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS}" \
  "${ANDROID_RAMDISK_ROOT}/identity.properties" \
  || runtime_die "Android ramdisk Bluetooth HCI restart timeout identity is inconsistent."

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
  "android.finalizer-timeout-ms=${EXPECTED_FINALIZER_TIMEOUT_MS}" \
  "android.bluetooth-hci-timeout-ms=${EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS}" \
  "android.bluetooth-hci-restart-timeout-ms=${EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS}" \
  "android.release-policy=base-final-stable-qpr1-beta-excluded" \
  "sdk.emulator-package.version=36.6.11" \
  "kvm.device=${KVM_DEVICE}" \
  "kvm.usable=$(if kvm_is_usable "${KVM_DEVICE}"; then printf yes; else printf no; fi)" \
  "accel.requested=${EMULATOR_ACCEL}" \
  "accel.effective=${effective_accel}" \
  "console.internal-port=${EMULATOR_CONSOLE_PORT}" \
  "console.socket=${EMULATOR_CONSOLE_SOCKET}" \
  "adb.proxy-port=${ADB_PROXY_PORT}" \
  "grpc.internal-port=${EMULATOR_GRPC_INTERNAL_PORT}" \
  "grpc.proxy-port=${EMULATOR_GRPC_PORT}"

if [ "${effective_accel}" = off ]; then
  runtime_log "KVM is unavailable, incompatible, or disabled; using the verified software-emulation engine path."
fi
