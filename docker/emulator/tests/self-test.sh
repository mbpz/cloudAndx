#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
. "${ROOT}/bin/runtime-lib.sh"

NATIVE_AEMU_REVISION=37.1.7
NATIVE_AEMU_SOURCE_LOCK_SHA256=1111111111111111111111111111111111111111111111111111111111111111
NATIVE_AEMU_PATCH_SET_SHA256=2222222222222222222222222222222222222222222222222222222222222222
export NATIVE_AEMU_REVISION NATIVE_AEMU_SOURCE_LOCK_SHA256 NATIVE_AEMU_PATCH_SET_SHA256

passed=0

pass() {
  passed=$((passed + 1))
}

assert_eq() {
  expected=$1
  actual=$2
  label=$3
  if [ "${expected}" != "${actual}" ]; then
    printf 'FAIL: %s: expected <%s>, got <%s>\n' "${label}" "${expected}" "${actual}" >&2
    exit 1
  fi
  pass
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3
  case "${haystack}" in
    *"${needle}"*) pass ;;
    *)
      printf 'FAIL: %s: output did not contain <%s>\n%s\n' "${label}" "${needle}" "${haystack}" >&2
      exit 1
      ;;
  esac
}

assert_fails() {
  label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s: command unexpectedly succeeded\n' "${label}" >&2
    exit 1
  fi
  pass
}

for script in "${ROOT}"/bin/*.sh "${ROOT}"/tests/*.sh; do
  sh -n "${script}"
done
pass

assert_eq off "$(resolve_acceleration auto /path/that/does/not/exist)" 'auto falls back to software'
assert_eq on "$(resolve_acceleration auto /dev/null)" 'auto selects accessible character device'
assert_eq on "$(resolve_acceleration kvm /dev/null)" 'explicit kvm selects acceleration'
assert_eq off "$(resolve_acceleration off /dev/null)" 'off remains off'
assert_fails 'forced kvm rejects missing device' resolve_acceleration kvm /path/that/does/not/exist
assert_fails 'invalid acceleration rejected' resolve_acceleration turbo /dev/null
assert_eq off "$(resolve_runtime_acceleration arm64 auto /dev/null)" 'ARM64 auto always selects software translation'
assert_eq off "$(resolve_runtime_acceleration aarch64 off /dev/null)" 'ARM64 explicit software mode is accepted'
assert_fails 'ARM64 rejects KVM for the x86_64 guest' resolve_runtime_acceleration arm64 kvm /dev/null
validate_engine_architecture x86_64 native
pass
validate_engine_architecture amd64 native
pass
validate_engine_architecture arm64 hybrid-aemu-arm64
pass
assert_eq native-aemu-arm64 "$(selected_engine_kind aarch64 hybrid-aemu-arm64)" 'ARM64 selects native AEMU child'
assert_eq upstream-x86_64 "$(selected_engine_kind amd64 native)" 'x86_64 selects upstream AEMU child'
assert_fails 'ARM64 rejects an undeclared hybrid runtime' validate_engine_architecture arm64 native
assert_fails 'missing Docker Engine architecture rejected by runtime' validate_engine_architecture ''
assert_fails 'unsafe AVD name rejected' validate_avd_name '../escape'
validate_avd_name Pixel_9_Android_17_Play
pass

tmp=$(mktemp -d)
real_engine_pid=
cleanup() {
  if [ -n "${real_engine_pid}" ] && kill -0 "${real_engine_pid}" 2>/dev/null; then
    kill "${real_engine_pid}" 2>/dev/null || true
    wait "${real_engine_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmp}"
}
trap cleanup EXIT INT TERM
sdk=${tmp}/sdk
data=${tmp}/data
template=${tmp}/template
native_aemu=${tmp}/native-aemu

stale_avd=${tmp}/stale.avd
mkdir -p "${stale_avd}"
printf '38\0' >"${stale_avd}/hardware-qemu.ini.lock"
: >"${stale_avd}/multiinstance.lock"
: >"${stale_avd}/unrelated.lock"
remove_stale_avd_locks "${stale_avd}"
[ ! -e "${stale_avd}/hardware-qemu.ini.lock" ]
pass
[ ! -e "${stale_avd}/multiinstance.lock" ]
pass
[ -e "${stale_avd}/unrelated.lock" ]
pass

mkdir -p \
  "${sdk}/emulator" \
  "${sdk}/emulator/qemu/linux-x86_64" \
  "${sdk}/platform-tools" \
  "${sdk}/system-images/android-37.0/google_apis_playstore_ps16k/x86_64" \
  "${native_aemu}/bin" \
  "${native_aemu}/lib" \
  "${data}" \
  "${template}"

printf '%s\n' \
  '#!/bin/sh' \
  '[ -z "${FAKE_EMULATOR_PID_FILE-}" ] || printf "%s\\n" "$$" >"${FAKE_EMULATOR_PID_FILE}"' \
  'sleep "${FAKE_EMULATOR_SLEEP:-0}"' >"${sdk}/emulator/emulator"
printf '%s\n' \
  '#!/bin/sh' \
  'case ${1-} in' \
  '  keygen)' \
  '    printf "%s\\n" private-key >"$2"' \
  '    printf "%s\\n" public-key >"$2.pub"' \
  '    ;;' \
  '  start-server|kill-server) ;;' \
  'esac' >"${sdk}/platform-tools/adb"
chmod 0755 "${sdk}/emulator/emulator" "${sdk}/platform-tools/adb"
printf '%s\n' '#!/bin/sh' 'printf "upstream:%s\n" "$*"' \
  >"${sdk}/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless.upstream-x86_64"
cp "${ROOT}/bin/qemu-system-x86_64-headless-dispatcher.sh" \
  "${sdk}/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless"
printf '%s\n' '#!/bin/sh' 'printf "native:%s\n" "$*"' \
  >"${native_aemu}/bin/run-qemu-system-x86_64-headless"
printf '%s\n' '#!/bin/sh' 'exit 0' >"${native_aemu}/bin/qemu-system-x86_64-headless"
printf '%s\n' '{"revision":"test","elf_machine":"AArch64"}' >"${native_aemu}/manifest.json"
printf '%s\n' 'locked-arm64-loader' >"${native_aemu}/lib/ld-linux-aarch64.so.1"
ln -s ../lib "${native_aemu}/bin/lib64"
printf '%s\n' \
  "revision=${NATIVE_AEMU_REVISION}" \
  "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
  >"${native_aemu}/identity.properties"
chmod 0755 \
  "${sdk}/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless" \
  "${sdk}/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless.upstream-x86_64" \
  "${native_aemu}/bin/run-qemu-system-x86_64-headless" \
  "${native_aemu}/bin/qemu-system-x86_64-headless" \
  "${native_aemu}/lib/ld-linux-aarch64.so.1"
(cd "${native_aemu}" && sha256sum \
  bin/qemu-system-x86_64-headless \
  bin/run-qemu-system-x86_64-headless \
  identity.properties \
  lib/ld-linux-aarch64.so.1 \
  manifest.json >SHA256SUMS)
validate_native_aemu_bundle "${native_aemu}"
pass
saved_source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}
unset NATIVE_AEMU_SOURCE_LOCK_SHA256
assert_fails 'native bundle identity requires the image source-lock digest' \
  validate_native_aemu_bundle "${native_aemu}"
NATIVE_AEMU_SOURCE_LOCK_SHA256=${saved_source_lock_sha256}
export NATIVE_AEMU_SOURCE_LOCK_SHA256
fake_interpreter=${tmp}/ld-linux-aarch64.so.1
cp "${native_aemu}/lib/ld-linux-aarch64.so.1" "${fake_interpreter}"
chmod 0755 "${fake_interpreter}"
validate_native_aemu_direct_execution "${native_aemu}" "${fake_interpreter}"
pass
printf '%s\n' \
  'revision=wrong' \
  "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
  >"${native_aemu}/identity.properties"
(cd "${native_aemu}" && sha256sum \
  bin/qemu-system-x86_64-headless \
  bin/run-qemu-system-x86_64-headless \
  identity.properties \
  lib/ld-linux-aarch64.so.1 \
  manifest.json >SHA256SUMS)
assert_fails 'native bundle rejects a checksum-valid wrong revision identity' \
  validate_native_aemu_bundle "${native_aemu}"
printf '%s\n' \
  "revision=${NATIVE_AEMU_REVISION}" \
  "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
  >"${native_aemu}/identity.properties"
(cd "${native_aemu}" && sha256sum \
  bin/qemu-system-x86_64-headless \
  bin/run-qemu-system-x86_64-headless \
  identity.properties \
  lib/ld-linux-aarch64.so.1 \
  manifest.json >SHA256SUMS)
dispatcher=${sdk}/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless
assert_contains "$(DOCKER_ENGINE_ARCHITECTURE=x86_64 UPSTREAM_QEMU_ENGINE=${dispatcher}.upstream-x86_64 "${dispatcher}" one two 2>/dev/null)" \
  'upstream:one two' 'dispatcher preserves args for the upstream x86_64 child'
assert_contains "$(DOCKER_ENGINE_ARCHITECTURE=arm64 ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 NATIVE_AEMU_ROOT=${native_aemu} "${dispatcher}" three four 2>/dev/null)" \
  'native:three four' 'dispatcher preserves args for the native ARM64 child'
assert_fails 'dispatcher fails closed for undeclared ARM64 hybrid mode' \
  env DOCKER_ENGINE_ARCHITECTURE=arm64 NATIVE_AEMU_ROOT="${native_aemu}" "${dispatcher}"
printf '%s\n' system >"${sdk}/system-images/android-37.0/google_apis_playstore_ps16k/x86_64/system.img"
printf '%s\n' vendor >"${sdk}/system-images/android-37.0/google_apis_playstore_ps16k/x86_64/vendor.img"
cp "${ROOT}/avd/config.ini" "${template}/config.ini"
cp "${ROOT}/avd/template-version" "${template}/template-version"

socat_stub=${tmp}/fake-socat
printf '%s\n' \
  '#!/bin/sh' \
  '[ "${FAKE_SOCAT_FAIL:-0}" = 0 ] || exit 71' \
  'if [ -n "${FAKE_SOCAT_PID_DIR-}" ]; then printf "%s\\n" "$$" >"${FAKE_SOCAT_PID_DIR}/$$"; fi' \
  'exec sleep 30' >"${socat_stub}"
chmod 0755 "${socat_stub}"
common_env="DOCKER_ENGINE_ARCHITECTURE=x86_64 ANDROID_RUNTIME_IMPLEMENTATION=native NATIVE_AEMU_ROOT=${native_aemu} ANDROID_SDK_ROOT=${sdk} ANDROID_AVD_HOME=${data}/avd ANDROID_EMULATOR_HOME=${data}/emulator-home ANDROID_PREFS_ROOT=${data}/prefs HOME=${data}/home AVD_TEMPLATE_DIR=${template} SOCAT_BIN=${socat_stub} KVM_DEVICE=/missing-kvm"

preflight_output=$(env ${common_env} EMULATOR_ACCEL=auto "${ROOT}/bin/runtime-preflight.sh" 2>&1)
assert_contains "${preflight_output}" 'android.release=17' 'preflight reports Android release'
assert_contains "${preflight_output}" 'android.api=37.0' 'preflight reports API release'
assert_contains "${preflight_output}" 'accel.effective=off' 'preflight reports software fallback'
assert_contains "${preflight_output}" 'engine.selected=upstream-x86_64' 'preflight reports the selected child engine'
assert_contains "${preflight_output}" "native-aemu.revision=${NATIVE_AEMU_REVISION}" 'preflight reports locked native revision'
assert_contains "${preflight_output}" "native-aemu.source-lock-sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" 'preflight reports locked source identity'
assert_contains "${preflight_output}" "native-aemu.patch-set-sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" 'preflight reports locked patch identity'
assert_contains "${preflight_output}" 'android.release-policy=base-stable-qpr1-beta-excluded' 'preflight reports release policy'

assert_fails 'preflight fails closed for unavailable forced KVM' \
  env ${common_env} EMULATOR_ACCEL=kvm "${ROOT}/bin/runtime-preflight.sh"

command_output=$(env ${common_env} EMULATOR_ACCEL=auto \
  "${ROOT}/bin/entrypoint.sh" print-command -prop 'test.value=a b' 2>&1)
assert_contains "${command_output}" '=-accel' 'entrypoint includes acceleration flag'
assert_contains "${command_output}" '=off' 'entrypoint uses software acceleration without KVM'
assert_contains "${command_output}" '=test.value=a b' 'entrypoint preserves one argument containing spaces'
assert_contains "${command_output}" '=-grpc' 'entrypoint enables gRPC'
assert_contains "${command_output}" '=8556' 'entrypoint uses isolated internal gRPC port'

proxy_pid_dir=${tmp}/proxy-pids
mkdir -p "${proxy_pid_dir}"
env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=1 FAKE_SOCAT_PID_DIR="${proxy_pid_dir}" \
  "${ROOT}/bin/entrypoint.sh" >/dev/null 2>&1
[ -s "${data}/home/.android/adbkey" ]
pass
[ -s "${data}/home/.android/adbkey.pub" ]
pass
proxy_count=$(find "${proxy_pid_dir}" -type f | wc -l | tr -d ' ')
assert_eq 2 "${proxy_count}" 'entrypoint starts distinct ADB and gRPC proxies'

mounted_private=${tmp}/mounted-adbkey
mounted_public=${tmp}/mounted-adbkey.pub
printf '%s\n' mounted-private >"${mounted_private}"
printf '%s\n' mounted-public >"${mounted_public}"
env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=1 \
  ADB_PRIVATE_KEY_FILE="${mounted_private}" ADB_PUBLIC_KEY_FILE="${mounted_public}" \
  "${ROOT}/bin/entrypoint.sh" >/dev/null 2>&1
assert_eq mounted-private "$(cat "${data}/home/.android/adbkey")" 'mounted private ADB key is copied'
assert_eq mounted-public "$(cat "${data}/home/.android/adbkey.pub")" 'mounted public ADB key is copied'
assert_fails 'entrypoint rejects incomplete ADB key pair' \
  env ${common_env} EMULATOR_ACCEL=off ADB_PRIVATE_KEY_FILE="${mounted_private}" \
    ADB_PUBLIC_KEY_FILE="${tmp}/missing-adbkey.pub" "${ROOT}/bin/entrypoint.sh"

emulator_pid_file=${tmp}/emulator.pid
assert_fails 'entrypoint fails when a supervised proxy exits' \
  env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=30 FAKE_SOCAT_FAIL=1 \
    FAKE_EMULATOR_PID_FILE="${emulator_pid_file}" "${ROOT}/bin/entrypoint.sh"
[ -s "${emulator_pid_file}" ]
failed_emulator_pid=$(cat "${emulator_pid_file}")
if kill -0 "${failed_emulator_pid}" 2>/dev/null; then
  printf 'FAIL: supervised emulator process %s survived proxy failure\n' "${failed_emulator_pid}" >&2
  exit 1
fi
pass

fake_adb=${tmp}/fake-adb
printf '%s\n' \
  '#!/bin/sh' \
  'case "$*" in' \
  '  *"get-state"*) printf "%s\\n" device ;;' \
  '  *"getprop sys.boot_completed"*) printf "%s\\n" "${FAKE_BOOT:-1}" ;;' \
  '  *"getprop ro.build.version.sdk"*) printf "%s\\n" "${FAKE_SDK:-37}" ;;' \
  '  *"pm path com.android.vending"*) [ "${FAKE_PLAY:-1}" = 1 ] && printf "%s\\n" package:/system/priv-app/Phonesky/Phonesky.apk ;;' \
  '  *"pm path com.google.android.gms"*) [ "${FAKE_GMS:-1}" = 1 ] && printf "%s\\n" package:/system/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk ;;' \
  '  *) exit 1 ;;' \
  'esac' >"${fake_adb}"
chmod 0755 "${fake_adb}"

tcp_probe=${tmp}/fake-tcp-probe
printf '%s\n' '#!/bin/sh' '[ "${FAKE_GRPC:-1}" = 1 ]' >"${tcp_probe}"
chmod 0755 "${tcp_probe}"

real_native_aemu=${tmp}/real-native-aemu
mkdir -p "${real_native_aemu}/bin" "${real_native_aemu}/lib"
cp -L "$(command -v sleep)" "${real_native_aemu}/bin/qemu-system-x86_64-headless"
chmod 0755 "${real_native_aemu}/bin/qemu-system-x86_64-headless"
real_expected_engine=$(readlink -f "${real_native_aemu}/bin/qemu-system-x86_64-headless")
NATIVE_AEMU_ROOT=${real_native_aemu} LD_LIBRARY_PATH=/inherited/x86/library/path \
  "${ROOT}/native-engine/bin/run-qemu-system-x86_64-headless" 30 &
real_engine_pid=$!
attempt=0
real_process=
while [ "${attempt}" -lt 100 ]; do
  real_process=$(readlink "/proc/${real_engine_pid}/exe" 2>/dev/null || true)
  [ "${real_process}" = "${real_expected_engine}" ] && break
  attempt=$((attempt + 1))
  sleep 0.01
done
assert_eq "${real_expected_engine}" "${real_process}" 'native runner directly execs the engine process image'
engine_process_matches_expected "${real_expected_engine}"
pass
tr '\000' '\n' < "/proc/${real_engine_pid}/environ" \
  | grep -Fxq "LD_LIBRARY_PATH=${real_native_aemu}/lib"
pass
env DOCKER_ENGINE_ARCHITECTURE=arm64 \
  ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 \
  NATIVE_AEMU_ROOT="${real_native_aemu}" \
  ADB_BIN="${fake_adb}" SOCAT_BIN="${tcp_probe}" \
  "${ROOT}/bin/healthcheck.sh"
pass
kill "${real_engine_pid}"
wait "${real_engine_pid}" 2>/dev/null || true
real_engine_pid=

expected_process=$(readlink /proc/$$/exe)
health_env="DOCKER_ENGINE_ARCHITECTURE=x86_64 ANDROID_RUNTIME_IMPLEMENTATION=native UPSTREAM_QEMU_ENGINE=${expected_process} ADB_BIN=${fake_adb} SOCAT_BIN=${tcp_probe}"
env ${health_env} "${ROOT}/bin/healthcheck.sh"
pass
assert_fails 'healthcheck requires the selected child process' \
  env DOCKER_ENGINE_ARCHITECTURE=x86_64 ANDROID_RUNTIME_IMPLEMENTATION=native \
    UPSTREAM_QEMU_ENGINE="${tmp}/not-running" ADB_BIN="${fake_adb}" SOCAT_BIN="${tcp_probe}" \
    "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires gRPC proxy' env ${health_env} FAKE_GRPC=0 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects incomplete boot' env ${health_env} FAKE_BOOT=0 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects wrong API' env ${health_env} FAKE_SDK=36 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires Play Store' env ${health_env} FAKE_PLAY=0 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires Google Play services' env ${health_env} FAKE_GMS=0 "${ROOT}/bin/healthcheck.sh"

printf 'PASS: %s assertions\n' "${passed}"
