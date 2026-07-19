#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "${SCRIPT_DIR}/runtime-lib.sh"

ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/android-sdk}
ADB_BIN=${ADB_BIN:-${ANDROID_SDK_ROOT}/platform-tools/adb}
EMULATOR_CONSOLE_PORT=${EMULATOR_CONSOLE_PORT:-5556}
EMULATOR_ADB_PORT=${EMULATOR_ADB_PORT:-5557}
EMULATOR_GRPC_PORT=${EMULATOR_GRPC_PORT:-8554}
SOCAT_BIN=${SOCAT_BIN:-socat}
TIMEOUT_BIN=${TIMEOUT_BIN:-timeout}
DOCKER_ENGINE_ARCHITECTURE=${DOCKER_ENGINE_ARCHITECTURE:-}
ANDROID_RUNTIME_IMPLEMENTATION=${ANDROID_RUNTIME_IMPLEMENTATION:-hybrid-aemu-arm64}
EXPECTED_ANDROID_ABI=${EXPECTED_ANDROID_ABI:-arm64-v8a}
EXPECTED_PAGE_SIZE_BYTES=${EXPECTED_PAGE_SIZE_BYTES:-16384}
EXPECTED_HW_TIMEOUT_MULTIPLIER=${EXPECTED_HW_TIMEOUT_MULTIPLIER:-50}
ADB_HEALTH_COMMAND_TIMEOUT_SECONDS=${ADB_HEALTH_COMMAND_TIMEOUT_SECONDS:-180}
serial=emulator-${EMULATOR_CONSOLE_PORT}
adb_endpoint=127.0.0.1:${EMULATOR_ADB_PORT}

adb_command() {
  "${TIMEOUT_BIN}" "${ADB_HEALTH_COMMAND_TIMEOUT_SECONDS}s" "${ADB_BIN}" "$@"
}

validate_engine_architecture "${DOCKER_ENGINE_ARCHITECTURE}" "${ANDROID_RUNTIME_IMPLEMENTATION}"
validate_uint_range EXPECTED_HW_TIMEOUT_MULTIPLIER "${EXPECTED_HW_TIMEOUT_MULTIPLIER}" 1 1000
validate_uint_range ADB_HEALTH_COMMAND_TIMEOUT_SECONDS "${ADB_HEALTH_COMMAND_TIMEOUT_SECONDS}" 1 300
expected_engine=$(expected_engine_executable "${DOCKER_ENGINE_ARCHITECTURE}")
engine_process_matches_expected "${expected_engine}"
"${SOCAT_BIN}" -T2 -u OPEN:/dev/null "TCP4:127.0.0.1:${EMULATOR_GRPC_PORT},connect-timeout=2" >/dev/null 2>&1
"${TIMEOUT_BIN}" 5s "${ADB_BIN}" connect "${adb_endpoint}" >/dev/null 2>&1
[ "$(adb_command -s "${serial}" get-state 2>/dev/null)" = device ]
[ "$(adb_command -s "${serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]
guest_health=$(
  adb_command -s "${serial}" shell '
    printf "sdk=%s\n" "$(getprop ro.build.version.sdk)"
    printf "abi=%s\n" "$(getprop ro.product.cpu.abi)"
    printf "page_size=%s\n" "$(getconf PAGE_SIZE)"
    printf "timeout_multiplier=%s\n" "$(getprop ro.hw_timeout_multiplier)"
    printf "play=%s\n" "$(pm path com.android.vending | head -n 1)"
    printf "gms=%s\n" "$(pm path com.google.android.gms | head -n 1)"
  ' 2>/dev/null | tr -d '\r'
)
printf '%s\n' "${guest_health}" | grep -Fxq 'sdk=37'
printf '%s\n' "${guest_health}" | grep -Fxq "abi=${EXPECTED_ANDROID_ABI}"
printf '%s\n' "${guest_health}" | grep -Fxq "page_size=${EXPECTED_PAGE_SIZE_BYTES}"
printf '%s\n' "${guest_health}" | grep -Fxq "timeout_multiplier=${EXPECTED_HW_TIMEOUT_MULTIPLIER}"
printf '%s\n' "${guest_health}" | grep -q '^play=package:'
printf '%s\n' "${guest_health}" | grep -q '^gms=package:'
