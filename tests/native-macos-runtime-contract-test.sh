#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
runner=${ROOT}/scripts/native-android17.sh

test -x "${runner}"
grep -Fq 'system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a' "${runner}"
grep -Fq 'EXPECTED_EMULATOR_VERSION=37.1.11' "${runner}"
grep -Fq 'EXPECTED_PLATFORM_TOOLS_VERSION=37.0.1' "${runner}"
grep -Fq 'EXPECTED_SCRCPY_VERSION=4.1' "${runner}"
grep -Fq 'ANDROID_AVD_HOME=${RUNTIME_ROOT}/avd' "${runner}"
grep -Fq 'stop_docker_android' "${runner}"
grep -Fq -- '-accel auto' "${runner}"
grep -Fq -- '-gpu host' "${runner}"
grep -Fq -- '-grpc-use-token' "${runner}"
grep -Fq 'configure_avd_value hw.sdCard no' "${runner}"
grep -Fq 'configure_avd_value PlayStore.enabled yes' "${runner}"
grep -Fq '127.0.0.1:${ADB_PORT}' "${runner}"
grep -Fq 'launchctl submit -l "${LAUNCH_LABEL}"' "${runner}"
grep -Fq 'launchctl remove "${LAUNCH_LABEL}"' "${runner}"
grep -Fq 'verify_repository_versions' "${runner}"
grep -Fq 'verify_loopback_listener "${pid}" "${ADB_PORT}"' "${runner}"
grep -Fq 'remove_launch_job' "${runner}"
grep -Fq -- '--serial "${ADB_SERIAL}" --no-audio --stay-awake' "${runner}"
if grep -Eq '0\.0\.0\.0|adb -a|host\.docker\.internal' "${runner}"; then
  echo 'FAIL: native runtime must not expose ADB/gRPC outside host loopback' >&2
  exit 1
fi

printf '%s\n' 'PASS: native macOS Android runtime contracts'
