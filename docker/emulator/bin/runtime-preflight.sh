#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${SCRIPT_DIR}/runtime-lib.sh"

ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/android-sdk}
ANDROID_AVD_HOME=${ANDROID_AVD_HOME:-/data/avd}
AVD_NAME=${AVD_NAME:-Pixel_9_Android_17_Play}
EMULATOR_ACCEL=${EMULATOR_ACCEL:-auto}
EMULATOR_CORES=${EMULATOR_CORES:-4}
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
EMULATOR_BIN=${EMULATOR_BIN:-${ANDROID_SDK_ROOT}/emulator/emulator}
ADB_BIN=${ADB_BIN:-${ANDROID_SDK_ROOT}/platform-tools/adb}
SOCAT_BIN=${SOCAT_BIN:-socat}
SYSTEM_IMAGE_DIR=${SYSTEM_IMAGE_DIR:-${ANDROID_SDK_ROOT}/system-images/android-37.0/google_apis_playstore_ps16k/x86_64}

validate_engine_architecture "${DOCKER_ENGINE_ARCHITECTURE}"
validate_runtime_settings
effective_accel=$(resolve_acceleration "${EMULATOR_ACCEL}" "${KVM_DEVICE}")

[ -x "${EMULATOR_BIN}" ] || runtime_die "Android Emulator is missing or not executable: ${EMULATOR_BIN}"
[ -x "${ADB_BIN}" ] || runtime_die "adb is missing or not executable: ${ADB_BIN}"
if [ "${SOCAT_BIN}" = "socat" ]; then
  command -v socat >/dev/null 2>&1 || runtime_die "socat is not installed."
else
  [ -x "${SOCAT_BIN}" ] || runtime_die "socat is missing or not executable: ${SOCAT_BIN}"
fi
[ -s "${SYSTEM_IMAGE_DIR}/system.img" ] || runtime_die "Android 17 system.img is missing: ${SYSTEM_IMAGE_DIR}/system.img"
[ -s "${SYSTEM_IMAGE_DIR}/vendor.img" ] || runtime_die "Android 17 vendor.img is missing: ${SYSTEM_IMAGE_DIR}/vendor.img"

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
  "runtime.uid=$(id -u)" \
  "android.release=17" \
  "android.api=37.0" \
  "android.image=google_apis_playstore_ps16k/x86_64/r06" \
  "android.release-policy=base-stable-qpr1-beta-excluded" \
  "emulator.version=36.6.11" \
  "kvm.device=${KVM_DEVICE}" \
  "kvm.usable=$(if kvm_is_usable "${KVM_DEVICE}"; then printf yes; else printf no; fi)" \
  "accel.requested=${EMULATOR_ACCEL}" \
  "accel.effective=${effective_accel}" \
  "adb.proxy-port=${ADB_PROXY_PORT}" \
  "grpc.internal-port=${EMULATOR_GRPC_INTERNAL_PORT}" \
  "grpc.proxy-port=${EMULATOR_GRPC_PORT}"

if [ "${effective_accel}" = off ]; then
  runtime_log "KVM is unavailable or disabled; using -accel off. Android 17 x86_64 will be very slow under software translation."
fi
