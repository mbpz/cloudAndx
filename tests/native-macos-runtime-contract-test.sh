#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
runner=${ROOT}/scripts/native-android17.sh

test -x "${runner}"
grep -Fq 'system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a' "${runner}"
grep -Fq 'EXPECTED_EMULATOR_VERSION=37.1.11' "${runner}"
grep -Fq 'EXPECTED_PLATFORM_TOOLS_VERSION=37.0.1' "${runner}"
grep -Fq 'EXPECTED_SCRCPY_VERSION=4.1' "${runner}"
grep -Fq 'Hypervisor.Framework' "${runner}"
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
grep -Fq 'SNAPSHOT_NAME=cloudandx-ready' "${runner}"
grep -Fq 'trusted-snapshot.env' "${runner}"
grep -Fq 'snapshot-save' "${runner}"
grep -Fq 'snapshot-resume' "${runner}"
grep -Fq 'snapshot-status' "${runner}"
grep -Fq 'emu avd snapshot save "${SNAPSHOT_NAME}"' "${runner}"
grep -Fq 'emu avd snapshot load "${SNAPSHOT_NAME}"' "${runner}"
grep -Fq 'emu avd snapshot list' "${runner}"
grep -Fq -- '-avd "${AVD_NAME}" -snapshot-list' "${runner}"
grep -Fq '$2 == name' "${runner}"
grep -Fq 'trusted snapshot entity is not listed' "${runner}"
grep -Fq -- '-snapshot "${SNAPSHOT_NAME}"' "${runner}"
grep -Fq -- '-no-snapshot-save' "${runner}"
grep -Fq '"$@"' "${runner}"
grep -Fq 'guest_services_ready' "${runner}"
grep -Fq 'verify_trusted_snapshot_load' "${runner}"
grep -Fq 'cold-boot fallback is rejected' "${runner}"
grep -Fq 'install-apk) install_apk' "${runner}"
grep -Fq 'push-file) push_file' "${runner}"
grep -Fq 'capture-screenshot) capture_screenshot' "${runner}"
grep -Fq 'exec-out screencap -p' "${runner}"
grep -Fq "tr -c 'A-Za-z0-9._-' '_'" "${runner}"
grep -Fq 'target=/sdcard/Download/${safe_basename}' "${runner}"
if grep -Fq 'start) shift' "${runner}"; then
  echo 'FAIL: start must not forward arbitrary user arguments to AEMU' >&2
  exit 1
fi
if grep -Eq '0\.0\.0\.0|adb -a|host\.docker\.internal' "${runner}"; then
  echo 'FAIL: native runtime must not expose ADB/gRPC outside host loopback' >&2
  exit 1
fi

printf '%s\n' 'PASS: native macOS Android runtime contracts'
