#!/bin/sh
set -eu

ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/android-sdk}
ADB_BIN=${ADB_BIN:-${ANDROID_SDK_ROOT}/platform-tools/adb}
EMULATOR_CONSOLE_PORT=${EMULATOR_CONSOLE_PORT:-5556}
EMULATOR_GRPC_PORT=${EMULATOR_GRPC_PORT:-8554}
SOCAT_BIN=${SOCAT_BIN:-socat}
serial=emulator-${EMULATOR_CONSOLE_PORT}

"${SOCAT_BIN}" -T2 -u OPEN:/dev/null "TCP4:127.0.0.1:${EMULATOR_GRPC_PORT},connect-timeout=2" >/dev/null 2>&1
[ "$("${ADB_BIN}" -s "${serial}" get-state 2>/dev/null)" = device ]
[ "$("${ADB_BIN}" -s "${serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]
[ "$("${ADB_BIN}" -s "${serial}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')" = 37 ]
"${ADB_BIN}" -s "${serial}" shell pm path com.android.vending 2>/dev/null | tr -d '\r' | grep -q '^package:'
"${ADB_BIN}" -s "${serial}" shell pm path com.google.android.gms 2>/dev/null | tr -d '\r' | grep -q '^package:'
