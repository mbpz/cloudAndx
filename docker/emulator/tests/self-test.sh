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

assert_not_contains() {
  haystack=$1
  needle=$2
  label=$3
  case "${haystack}" in
    *"${needle}"*)
      printf 'FAIL: %s: output unexpectedly contained <%s>\n%s\n' "${label}" "${needle}" "${haystack}" >&2
      exit 1
      ;;
    *) pass ;;
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
assert_eq off "$(resolve_runtime_acceleration arm64 auto /dev/null)" 'ARM64 auto selects software TCG for the AEMU NONE-accelerator guard'
assert_eq off "$(resolve_runtime_acceleration aarch64 off /dev/null)" 'ARM64 explicit software TCG is accepted'
assert_fails 'x86_64 runtime remains deferred' resolve_runtime_acceleration x86_64 kvm /dev/null
assert_fails 'ARM64 Docker-only guest rejects KVM' resolve_runtime_acceleration arm64 kvm /dev/null
assert_fails 'x86_64 engine path remains deferred' validate_engine_architecture x86_64 native
assert_fails 'amd64 engine path remains deferred' validate_engine_architecture amd64 native
validate_engine_architecture arm64 hybrid-aemu-arm64
pass
assert_eq native-aemu-arm64 "$(selected_engine_kind aarch64 hybrid-aemu-arm64)" 'ARM64 selects native AEMU child'
assert_fails 'x86_64 child selection remains deferred' selected_engine_kind amd64 native
assert_fails 'ARM64 rejects an undeclared hybrid runtime' validate_engine_architecture arm64 native
assert_fails 'missing Docker Engine architecture rejected by runtime' validate_engine_architecture ''
assert_fails 'unsafe AVD name rejected' validate_avd_name '../escape'
validate_avd_name Pixel_9_Android_17_Play_ARM64
pass
validate_runtime_gpu_mode arm64 swiftshader
pass
assert_fails 'x86_64 GPU path remains deferred' validate_runtime_gpu_mode x86_64 auto
assert_fails 'ARM64 rejects non-SwiftShader first boot' validate_runtime_gpu_mode arm64 auto
assert_eq "$(printf '%s\n' -gpu swiftshader -feature -GuestAngle -feature -GuestUsesAngle -feature -VulkanNativeSwapchain -feature -VulkanSnapshots)" \
  "$(native_aemu_graphics_args)" 'ARM64 graphics guard enables packaged SwiftShader Vulkan while disabling unsupported ANGLE and snapshot features'
assert_eq "$(printf '%s\n' -qemu -machine gic-version=2 -cpu android-a57-16k)" \
  "$(native_aemu_tcg_qemu_args)" 'ARM64 TCG guard overrides the Linux AArch64 KVM-only GIC and CPU defaults'

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
  "${sdk}/emulator/lib" \
  "${sdk}/platform-tools" \
  "${sdk}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a" \
  "${native_aemu}/bin" \
  "${native_aemu}/qemu/linux-aarch64" \
  "${native_aemu}/lib/pc-bios" \
  "${native_aemu}/lib64/gles_swiftshader" \
  "${native_aemu}/lib64/vulkan" \
  "${native_aemu}/libexec/linux-x86_64" \
  "${native_aemu}/resources/skins/android-36" \
  "${native_aemu}/resources/macros" \
  "${native_aemu}/resources/macroPreviews" \
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
printf '%s\n' 'syntax = "proto3";' >"${sdk}/emulator/lib/emulator_controller.proto"
cp "${ROOT}/native-engine/bin/run-qemu-system-aarch64-headless" \
  "${native_aemu}/bin/run-qemu-system-aarch64-headless"
printf '%s\n' \
  '#!/bin/sh' \
  '[ -z "${FAKE_EMULATOR_PID_FILE-}" ] || printf "%s\\n" "$$" >"${FAKE_EMULATOR_PID_FILE}"' \
  'if [ "${1-}" = --print-audio-driver ]; then printf "%s\n" "${QEMU_AUDIO_DRV-}"; fi' \
  'sleep "${FAKE_EMULATOR_SLEEP:-0}"' \
  'exit 0' \
  >"${native_aemu}/qemu/linux-aarch64/qemu-system-aarch64-headless"
cp "${ROOT}/native-engine/bin/netsimd" "${native_aemu}/netsimd"
printf '%s\n' \
  '#!/bin/sh' \
  '[ -z "${LD_LIBRARY_PATH-}" ] || exit 81' \
  '[ -z "${ANDROID_EGL_LIB-}" ] || exit 82' \
  '[ -z "${VK_DRIVER_FILES-}" ] || exit 83' \
  '[ -z "${LIBGL_DRIVERS_PATH-}" ] || exit 84' \
  '[ "${1-}" = --version ] || exit 85' \
  'printf "%s\n" "netsimd 0.3.112"' \
  >"${native_aemu}/libexec/linux-x86_64/netsimd"
for helper in crashpad_handler qemu-img nimble_bridge; do
  printf '%s\n' '#!/bin/sh' 'exit 0' >"${native_aemu}/${helper}"
done
printf '%s\n' gfxstream >"${native_aemu}/lib64/libgfxstream_backend.so"
printf '%s\n' x11-xcb >"${native_aemu}/lib64/libX11-xcb.so.1"
printf '%s\n' '{"revision":"test","elf_machine":"AArch64"}' >"${native_aemu}/manifest.json"
printf '%s\n' 'locked-arm64-loader' >"${native_aemu}/lib64/ld-linux-aarch64.so.1"
ln -s ../../lib64 "${native_aemu}/qemu/linux-aarch64/lib64"
printf '%s\n' vulkan-loader >"${native_aemu}/lib64/vulkan/libvulkan.so.1.4.344"
ln -s libvulkan.so.1.4.344 "${native_aemu}/lib64/vulkan/libvulkan.so.1"
ln -s libvulkan.so.1 "${native_aemu}/lib64/vulkan/libvulkan.so"
printf '%s\n' swiftshader-vulkan >"${native_aemu}/lib64/vulkan/libvk_swiftshader.so"
printf '%s\n' \
  '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvk_swiftshader.so", "api_version": "1.0.5"}}' \
  >"${native_aemu}/lib64/vulkan/vk_swiftshader_icd.json"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "vulkan-smoke: fake PASS"' \
  >"${native_aemu}/vulkan-smoke"
for data_file in advancedFeatures.ini emu-original-feature-flags.protobuf \
  ca-bundle.pem hostapd.conf emulator_access.json; do
  printf '%s\n' "${data_file}" >"${native_aemu}/lib/${data_file}"
done
printf '%s\n' pc-bios >"${native_aemu}/lib/pc-bios/bios.bin"
for swiftshader_library in libEGL.so libGLES_CM.so libGLESv2.so; do
  printf '%s\n' "${swiftshader_library}" \
    >"${native_aemu}/lib64/gles_swiftshader/${swiftshader_library}"
done
printf '%s\n' virtualscene >"${native_aemu}/resources/virtualscene.dat"
printf '%s\n' skin >"${native_aemu}/resources/skins/android-36/layout"
printf '%s\n' macro >"${native_aemu}/resources/macros/default.proto"
printf '%s\n' preview >"${native_aemu}/resources/macroPreviews/default.png"
printf '%s\n' \
  "revision=${NATIVE_AEMU_REVISION}" \
  "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
  >"${native_aemu}/identity.properties"
chmod 0755 \
  "${native_aemu}/bin/run-qemu-system-aarch64-headless" \
  "${native_aemu}/qemu/linux-aarch64/qemu-system-aarch64-headless" \
  "${native_aemu}/crashpad_handler" \
  "${native_aemu}/qemu-img" \
  "${native_aemu}/nimble_bridge" \
  "${native_aemu}/netsimd" \
  "${native_aemu}/libexec/linux-x86_64/netsimd" \
  "${native_aemu}/lib64/ld-linux-aarch64.so.1" \
  "${native_aemu}/vulkan-smoke"

write_fake_bundle_checksums() {
  (
    cd "${native_aemu}"
    find . -type f \
      ! -name SHA256SUMS \
      ! -name sdk-resources.SHA256SUMS \
      ! -path './resources/macros/*' \
      ! -path './resources/macroPreviews/*' \
      -print | sort \
      | while IFS= read -r bundle_file; do sha256sum "${bundle_file#./}"; done \
      >SHA256SUMS
    find resources/macros resources/macroPreviews -type f -print | sort \
      | while IFS= read -r resource_file; do sha256sum "${resource_file}"; done \
      >sdk-resources.SHA256SUMS
  )
}

write_fake_bundle_checksums
mixed_helper_output=$(env \
  NATIVE_AEMU_ROOT="${native_aemu}" \
  LD_LIBRARY_PATH=/arm64/lib \
  ANDROID_EGL_LIB=/arm64/libEGL.so \
  VK_DRIVER_FILES=/arm64/vk.json \
  LIBGL_DRIVERS_PATH=/arm64/dri \
  "${native_aemu}/netsimd" --version)
assert_contains "${mixed_helper_output}" 'netsimd 0.3.112' \
  'netsimd launcher clears ARM loader and GPU variables before the x86_64 helper'
runner_audio_output=$(env NATIVE_AEMU_ROOT="${native_aemu}" QEMU_AUDIO_DRV=oss \
  "${ROOT}/native-engine/bin/run-qemu-system-aarch64-headless" \
  --print-audio-driver)
assert_eq none "${runner_audio_output}" \
  'native runner replaces inherited OSS audio with the no-host-device backend'
validate_native_aemu_bundle "${native_aemu}"
pass
validate_native_aemu_vulkan "${native_aemu}"
pass
mv "${native_aemu}/lib64/vulkan/libvulkan.so.1.4.344" \
  "${native_aemu}/lib64/vulkan/libvulkan.so.1.4.344.missing"
write_fake_bundle_checksums
assert_fails 'native bundle rejects a checksum-valid missing Vulkan loader' \
  validate_native_aemu_bundle "${native_aemu}"
mv "${native_aemu}/lib64/vulkan/libvulkan.so.1.4.344.missing" \
  "${native_aemu}/lib64/vulkan/libvulkan.so.1.4.344"
write_fake_bundle_checksums
mv "${native_aemu}/lib64/vulkan/libvk_swiftshader.so" \
  "${native_aemu}/lib64/vulkan/libvk_swiftshader.so.missing"
write_fake_bundle_checksums
assert_fails 'native bundle rejects a checksum-valid missing Vulkan ICD' \
  validate_native_aemu_bundle "${native_aemu}"
mv "${native_aemu}/lib64/vulkan/libvk_swiftshader.so.missing" \
  "${native_aemu}/lib64/vulkan/libvk_swiftshader.so"
write_fake_bundle_checksums
mv "${native_aemu}/vulkan-smoke" "${native_aemu}/vulkan-smoke.missing"
write_fake_bundle_checksums
assert_fails 'native bundle rejects a checksum-valid missing Vulkan probe' \
  validate_native_aemu_bundle "${native_aemu}"
mv "${native_aemu}/vulkan-smoke.missing" "${native_aemu}/vulkan-smoke"
write_fake_bundle_checksums
printf '%s\n' \
  '{"file_format_version": "1.0.0", "ICD": {"library_path": "/host/libvk.so", "api_version": "1.0.5"}}' \
  >"${native_aemu}/lib64/vulkan/vk_swiftshader_icd.json"
write_fake_bundle_checksums
assert_fails 'native bundle rejects a checksum-valid escaping Vulkan ICD path' \
  validate_native_aemu_bundle "${native_aemu}"
printf '%s\n' \
  '{"file_format_version": "1.0.0", "ICD": {"library_path": "./libvk_swiftshader.so", "api_version": "1.0.5"}}' \
  >"${native_aemu}/lib64/vulkan/vk_swiftshader_icd.json"
write_fake_bundle_checksums
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "vulkan-smoke: fake FAIL"' 'exit 1' \
  >"${native_aemu}/vulkan-smoke"
chmod 0755 "${native_aemu}/vulkan-smoke"
assert_fails 'native Vulkan preflight rejects a failing probe' \
  validate_native_aemu_vulkan "${native_aemu}"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "vulkan-smoke: fake PASS"' \
  >"${native_aemu}/vulkan-smoke"
chmod 0755 "${native_aemu}/vulkan-smoke"
write_fake_bundle_checksums
mv "${native_aemu}/libexec/linux-x86_64/netsimd" \
  "${native_aemu}/libexec/linux-x86_64/netsimd.missing"
write_fake_bundle_checksums
assert_fails 'native bundle rejects a checksum-valid missing mixed-architecture netsimd helper' \
  validate_native_aemu_bundle "${native_aemu}"
mv "${native_aemu}/libexec/linux-x86_64/netsimd.missing" \
  "${native_aemu}/libexec/linux-x86_64/netsimd"
write_fake_bundle_checksums
mv "${native_aemu}/lib64/libX11-xcb.so.1" \
  "${native_aemu}/lib64/libX11-xcb.so.1.missing"
write_fake_bundle_checksums
assert_fails 'native bundle rejects a checksum-valid missing X11-XCB dlopen library' \
  validate_native_aemu_bundle "${native_aemu}"
mv "${native_aemu}/lib64/libX11-xcb.so.1.missing" \
  "${native_aemu}/lib64/libX11-xcb.so.1"
write_fake_bundle_checksums
printf '%s\n' tampered >"${native_aemu}/resources/macros/default.proto"
assert_fails 'native bundle rejects a modified SDK runtime resource' \
  validate_native_aemu_bundle "${native_aemu}"
printf '%s\n' macro >"${native_aemu}/resources/macros/default.proto"
write_fake_bundle_checksums
saved_source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}
unset NATIVE_AEMU_SOURCE_LOCK_SHA256
assert_fails 'native bundle identity requires the image source-lock digest' \
  validate_native_aemu_bundle "${native_aemu}"
NATIVE_AEMU_SOURCE_LOCK_SHA256=${saved_source_lock_sha256}
export NATIVE_AEMU_SOURCE_LOCK_SHA256
fake_interpreter=${tmp}/ld-linux-aarch64.so.1
cp "${native_aemu}/lib64/ld-linux-aarch64.so.1" "${fake_interpreter}"
chmod 0755 "${fake_interpreter}"
validate_native_aemu_direct_execution "${native_aemu}" "${fake_interpreter}"
pass
printf '%s\n' \
  'revision=wrong' \
  "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
  >"${native_aemu}/identity.properties"
write_fake_bundle_checksums
assert_fails 'native bundle rejects a checksum-valid wrong revision identity' \
  validate_native_aemu_bundle "${native_aemu}"
printf '%s\n' \
  "revision=${NATIVE_AEMU_REVISION}" \
  "source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  "patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" \
  >"${native_aemu}/identity.properties"
write_fake_bundle_checksums
printf '%s\n' system >"${sdk}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/system.img"
printf '%s\n' vendor >"${sdk}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/vendor.img"
ramdisk_root=${tmp}/android-ramdisk
mkdir -p "${ramdisk_root}"
printf '%s\n' official-ramdisk >"${ramdisk_root}/official-ramdisk.img"
printf '%s\n' derived-ramdisk >"${ramdisk_root}/derived-ramdisk.img"
cp "${ramdisk_root}/derived-ramdisk.img" \
  "${sdk}/system-images/android-37.0/google_apis_playstore_ps16k/arm64-v8a/ramdisk.img"
ramdisk_original_sha256=$(sha256sum "${ramdisk_root}/official-ramdisk.img" | cut -d' ' -f1)
ramdisk_cpio_sha256=$(printf '%s\n' official-cpio | sha256sum | cut -d' ' -f1)
ramdisk_derived_sha256=$(sha256sum "${ramdisk_root}/derived-ramdisk.img" | cut -d' ' -f1)
printf '%s\n' \
  "official_ramdisk_sha256=${ramdisk_original_sha256}" \
  "official_cpio_sha256=${ramdisk_cpio_sha256}" \
  "derived_ramdisk_sha256=${ramdisk_derived_sha256}" \
  'overlay_path=system/etc/ramdisk/build.prop' \
  'overlay_property.ro_hw_timeout_multiplier=50' \
  'overlay_property.dalvik_vm_finalizer_timeout_ms=500000' \
  'overlay_property.bluetooth_hci_timeout_ms=100000' \
  'overlay_property.bluetooth_hci_restart_timeout_ms=250000' \
  >"${ramdisk_root}/identity.properties"
cp "${ROOT}/avd/config.ini" "${template}/config.ini"
cp "${ROOT}/avd/template-version" "${template}/template-version"

socat_stub=${tmp}/fake-socat
printf '%s\n' \
  '#!/bin/sh' \
  'if [ -n "${FAKE_SOCAT_PID_DIR-}" ]; then printf "%s\\n" "$*" >"${FAKE_SOCAT_PID_DIR}/$$"; fi' \
  '[ "${FAKE_SOCAT_FAIL:-0}" = 0 ] || exit 71' \
  'case "${1-}" in "${FAKE_SOCAT_FAIL_PREFIX-}"*) [ -z "${FAKE_SOCAT_FAIL_PREFIX-}" ] || exit 71 ;; esac' \
  'exec sleep 30' >"${socat_stub}"
chmod 0755 "${socat_stub}"
console_socket_dir=${tmp}/emulator-console
console_socket=${console_socket_dir}/console.sock
mkdir -p "${console_socket_dir}"
chmod 0700 "${console_socket_dir}"
console_auth_token_source=${tmp}/console-auth-token
printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  >"${console_auth_token_source}"
novnc_root=${tmp}/novnc
scrcpy_root=${tmp}/scrcpy
mkdir -p "${novnc_root}" "${scrcpy_root}"
printf '%s\n' '<!doctype html>' >"${novnc_root}/vnc.html"
printf '%s\n' '{"version": "1.7.0"}' >"${novnc_root}/package.json"
printf '%s\n' '#!/bin/sh' 'case ${1-} in --version) echo "scrcpy 4.1" ;; *) exec sleep 30 ;; esac' \
  >"${scrcpy_root}/scrcpy"
printf '%s\n' server >"${scrcpy_root}/scrcpy-server"
chmod 0755 "${scrcpy_root}/scrcpy"
websockify_stub=${tmp}/websockify
printf '%s\n' '#!/bin/sh' 'case ${1-} in --version) echo "websockify 0.13.0" ;; *) exec sleep 30 ;; esac' >"${websockify_stub}"
chmod 0755 "${websockify_stub}"
grpcurl_stub=${tmp}/grpcurl
printf '%s\n' '#!/bin/sh' 'case ${1-} in -version) echo "grpcurl v1.9.3" ;; *) exec sleep 30 ;; esac' >"${grpcurl_stub}"
chmod 0755 "${grpcurl_stub}"
aemu_rfb_stub=${tmp}/aemu-rfb-bridge.py
printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"${aemu_rfb_stub}"
chmod 0755 "${aemu_rfb_stub}"
python_stub=${tmp}/python3
printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"${python_stub}"
chmod 0755 "${python_stub}"
common_env="DOCKER_ENGINE_ARCHITECTURE=arm64 ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 NATIVE_AEMU_ROOT=${native_aemu} NATIVE_AEMU_INTERPRETER=${fake_interpreter} ANDROID_SDK_ROOT=${sdk} ANDROID_AVD_HOME=${data}/avd ANDROID_EMULATOR_HOME=${data}/emulator-home ANDROID_PREFS_ROOT=${data}/prefs HOME=${data}/home XDG_RUNTIME_DIR=${data}/runtime/xdg AVD_TEMPLATE_DIR=${template} SOCAT_BIN=${socat_stub} EMULATOR_CONSOLE_SOCKET=${console_socket} EMULATOR_CONSOLE_AUTH_TOKEN_FILE=${console_auth_token_source} ADB_PRIVATE_KEY_FILE=${data}/adb/adbkey ADB_PUBLIC_KEY_FILE=${data}/adb/adbkey.pub KVM_DEVICE=/missing-kvm ANDROID_RAMDISK_ROOT=${ramdisk_root} ANDROID_RAMDISK_ORIGINAL_SHA256=${ramdisk_original_sha256} ANDROID_RAMDISK_CPIO_SHA256=${ramdisk_cpio_sha256} ANDROID_RAMDISK_DERIVED_SHA256=${ramdisk_derived_sha256} NOVNC_ROOT=${novnc_root} NOVNC_TLS=false SCRCPY_ROOT=${scrcpy_root} SCRCPY_BIN=${scrcpy_root}/scrcpy WEBSOCKIFY_BIN=${websockify_stub} GRPCURL_BIN=${grpcurl_stub} AEMU_RFB_BRIDGE=${aemu_rfb_stub} PYTHON_BIN=${python_stub}"

preflight_output=$(env ${common_env} EMULATOR_ACCEL=auto "${ROOT}/bin/runtime-preflight.sh" 2>&1)
assert_contains "${preflight_output}" 'android.release=17' 'preflight reports Android release'
assert_contains "${preflight_output}" 'android.api=37.0' 'preflight reports API release'
assert_contains "${preflight_output}" 'accel.effective=off' 'preflight reports software fallback'
assert_contains "${preflight_output}" 'engine.selected=native-aemu-arm64' 'preflight reports the selected native engine'
assert_contains "${preflight_output}" "native-aemu.revision=${NATIVE_AEMU_REVISION}" 'preflight reports locked native revision'
assert_contains "${preflight_output}" "native-aemu.source-lock-sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}" 'preflight reports locked source identity'
assert_contains "${preflight_output}" "native-aemu.patch-set-sha256=${NATIVE_AEMU_PATCH_SET_SHA256}" 'preflight reports locked patch identity'
assert_contains "${preflight_output}" 'android.image=google_apis_playstore_ps16k/arm64-v8a/r06' 'preflight reports ARM64 image'
assert_contains "${preflight_output}" 'android.ramdisk=derived-official-prefix-plus-second-stage-property' 'preflight reports the derived boot artifact honestly'
assert_contains "${preflight_output}" "android.ramdisk.original-sha256=${ramdisk_original_sha256}" 'preflight reports official ramdisk provenance'
assert_contains "${preflight_output}" "android.ramdisk.derived-sha256=${ramdisk_derived_sha256}" 'preflight reports the locked derived ramdisk'
assert_contains "${preflight_output}" 'android.hw-timeout-multiplier=50' 'preflight reports the TCG watchdog multiplier'
assert_contains "${preflight_output}" 'android.finalizer-timeout-ms=500000' 'preflight reports the ART finalizer watchdog timeout'
assert_contains "${preflight_output}" 'android.bluetooth-hci-timeout-ms=100000' 'preflight reports the Bluetooth HCI command timeout'
assert_contains "${preflight_output}" 'android.bluetooth-hci-restart-timeout-ms=250000' 'preflight reports the Bluetooth HCI restart timeout'
assert_contains "${preflight_output}" 'android.release-policy=base-final-stable-qpr1-beta-excluded' 'preflight reports release policy'
assert_contains "${preflight_output}" 'sdk.emulator-package.version=36.6.11' 'preflight distinguishes the SDK artifact from the native engine revision'
assert_contains "${preflight_output}" 'console.internal-port=5556' 'preflight reports the loopback Console port'
assert_contains "${preflight_output}" "console.socket=${console_socket}" 'preflight reports the shared Console Unix socket'
assert_not_contains "${preflight_output}" 'emulator.version=' 'preflight does not mislabel the SDK package as the selected native engine version'

assert_fails 'preflight fails closed for unavailable forced KVM' \
  env ${common_env} EMULATOR_ACCEL=kvm "${ROOT}/bin/runtime-preflight.sh"

command_output=$(env ${common_env} EMULATOR_ACCEL=auto \
  "${ROOT}/bin/entrypoint.sh" print-command -prop 'test.value=a b' 2>&1)
assert_contains "${command_output}" '=-accel' 'entrypoint includes acceleration flag'
assert_contains "${command_output}" '=off' 'entrypoint uses software acceleration without KVM'
cores_value=$(printf '%s\n' "${command_output}" | grep -A1 '=-cores$' | tail -n 1 \
  | sed 's/^argv\[[0-9][0-9]*\]=//')
assert_eq 8 "${cores_value}" 'entrypoint defaults ARM TCG to all eight available guest vCPUs'
assert_contains "${command_output}" '=test.value=a b' 'entrypoint preserves one argument containing spaces'
assert_contains "${command_output}" '=-grpc' 'entrypoint enables gRPC'
assert_contains "${command_output}" '=8556' 'entrypoint uses isolated internal gRPC port'
assert_contains "${command_output}" '=-camera-back' \
  'ARM64 command locks the headless back camera mode'
assert_contains "${command_output}" '=-no-boot-anim' \
  'ARM64 command releases boot-animation CPU time for framework initialization'
assert_contains "${command_output}" '=emulated' \
  'ARM64 command keeps both cameras as functional software devices'
if printf '%s\n' "${command_output}" | grep -Eq '^argv\[[0-9]+\]=-Vulkan$'; then
  printf '%s\n' 'FAIL: ARM64 command disables Vulkan despite the packaged host loader and ICD.' >&2
  exit 1
fi
pass
assert_contains "${command_output}" '=-VulkanSnapshots' \
  'ARM64 command retains the Vulkan snapshot safety guard'
raw_qemu_tail=$(printf '%s\n' "${command_output}" | tail -n 5 \
  | sed 's/^argv\[[0-9][0-9]*\]=//')
assert_eq "$(printf '%s\n' -qemu -machine gic-version=2 -cpu android-a57-16k)" \
  "${raw_qemu_tail}" 'entrypoint keeps the locked ARM TCG override as the final argv tail'
qemu_sentinel_count=$(printf '%s\n' "${command_output}" \
  | grep -Ec '^argv\[[0-9]+\]=-qemu$')
assert_eq 1 "${qemu_sentinel_count}" 'entrypoint emits exactly one raw QEMU sentinel'
user_argument_line=$(printf '%s\n' "${command_output}" \
  | grep -nF '=test.value=a b' | cut -d: -f1)
qemu_sentinel_line=$(printf '%s\n' "${command_output}" \
  | grep -nE '^argv\[[0-9]+\]=-qemu$' | cut -d: -f1)
if [ "${user_argument_line}" -ge "${qemu_sentinel_line}" ]; then
  printf '%s\n' 'FAIL: user Android argument escaped into the locked raw QEMU tail.' >&2
  exit 1
fi
pass
assert_fails 'entrypoint rejects a user-supplied raw QEMU sentinel' \
  env ${common_env} EMULATOR_ACCEL=auto \
    "${ROOT}/bin/entrypoint.sh" print-command -qemu -machine gic-version=host

missing_token_emulator_pid_file=${tmp}/missing-token-emulator.pid
assert_fails 'entrypoint fails closed when the Console auth token is missing' \
  env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=30 \
    EMULATOR_CONSOLE_AUTH_TOKEN_FILE="${tmp}/missing-console-auth-token" \
    FAKE_EMULATOR_PID_FILE="${missing_token_emulator_pid_file}" \
    "${ROOT}/bin/entrypoint.sh"
[ ! -e "${missing_token_emulator_pid_file}" ]
pass

malformed_console_auth_token=${tmp}/malformed-console-auth-token
printf '%s' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
  >"${malformed_console_auth_token}"
assert_fails 'entrypoint rejects a Console auth token that is not 64 lowercase hex characters' \
  env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=30 \
    EMULATOR_CONSOLE_AUTH_TOKEN_FILE="${malformed_console_auth_token}" \
    FAKE_EMULATOR_PID_FILE="${missing_token_emulator_pid_file}" \
    "${ROOT}/bin/entrypoint.sh"
[ ! -e "${missing_token_emulator_pid_file}" ]
pass

symlinked_console_auth_token=${tmp}/symlinked-console-auth-token
ln -s "${console_auth_token_source}" "${symlinked_console_auth_token}"
assert_fails 'entrypoint rejects a symlinked Console auth token source' \
  env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=30 \
    EMULATOR_CONSOLE_AUTH_TOKEN_FILE="${symlinked_console_auth_token}" \
    FAKE_EMULATOR_PID_FILE="${missing_token_emulator_pid_file}" \
    "${ROOT}/bin/entrypoint.sh"
[ ! -e "${missing_token_emulator_pid_file}" ]
pass

installed_console_auth_token=${data}/home/.emulator_console_auth_token
installed_token_symlink_target=${tmp}/installed-token-symlink-target
printf '%s' sentinel >"${installed_token_symlink_target}"
ln -s "${installed_token_symlink_target}" "${installed_console_auth_token}"
assert_fails 'entrypoint refuses to follow a symlink at the installed Console token path' \
  env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=30 \
    FAKE_EMULATOR_PID_FILE="${missing_token_emulator_pid_file}" \
    "${ROOT}/bin/entrypoint.sh"
assert_eq sentinel "$(cat "${installed_token_symlink_target}")" \
  'Console token installation does not overwrite a symlink target'
rm -f "${installed_console_auth_token}"
[ ! -e "${missing_token_emulator_pid_file}" ]
pass

proxy_pid_dir=${tmp}/proxy-pids
mkdir -p "${proxy_pid_dir}"
entrypoint_output=$(env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=1 \
  FAKE_SOCAT_PID_DIR="${proxy_pid_dir}" "${ROOT}/bin/entrypoint.sh" 2>&1)
assert_not_contains "${entrypoint_output}" "$(cat "${console_auth_token_source}")" \
  'entrypoint never logs the Console auth token'
[ -s "${data}/home/.android/adbkey" ]
pass
[ -s "${data}/home/.android/adbkey.pub" ]
pass
proxy_count=$(find "${proxy_pid_dir}" -type f | wc -l | tr -d ' ')
assert_eq 3 "${proxy_count}" 'entrypoint starts distinct ADB, authenticated Console, and gRPC proxies'
console_proxy_count=$(grep -Fxl \
  "UNIX-LISTEN:${console_socket},unlink-early,fork,mode=0600 TCP4:127.0.0.1:5556,connect-timeout=5" \
  "${proxy_pid_dir}"/* | wc -l | tr -d ' ')
assert_eq 1 "${console_proxy_count}" 'Console proxy forwards the mode-0600 Unix socket to AEMU loopback port 5556'
for proxy_pid_file in "${proxy_pid_dir}"/*; do
  proxy_pid=${proxy_pid_file##*/}
  if kill -0 "${proxy_pid}" 2>/dev/null; then
    printf 'FAIL: supervised proxy process %s survived normal emulator shutdown\n' "${proxy_pid}" >&2
    exit 1
  fi
done
pass
assert_eq "$(cat "${console_auth_token_source}")" \
  "$(cat "${installed_console_auth_token}")" \
  'entrypoint copies the shared token into the AEMU Console auth path'
installed_token_permissions=$(LC_ALL=C ls -ld "${installed_console_auth_token}" \
  | awk '{ print substr($1, 2, 9) }')
assert_eq rw------- "${installed_token_permissions}" \
  'entrypoint restricts the installed Console auth token to mode 0600'

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
failed_proxy_pid_dir=${tmp}/failed-proxy-pids
mkdir -p "${failed_proxy_pid_dir}"
assert_fails 'entrypoint fails when the authenticated Console proxy exits' \
  env ${common_env} EMULATOR_ACCEL=off FAKE_EMULATOR_SLEEP=30 \
    FAKE_SOCAT_FAIL_PREFIX=UNIX-LISTEN: FAKE_SOCAT_PID_DIR="${failed_proxy_pid_dir}" \
    FAKE_EMULATOR_PID_FILE="${emulator_pid_file}" "${ROOT}/bin/entrypoint.sh"
[ -s "${emulator_pid_file}" ]
failed_emulator_pid=$(cat "${emulator_pid_file}")
if kill -0 "${failed_emulator_pid}" 2>/dev/null; then
  printf 'FAIL: supervised emulator process %s survived proxy failure\n' "${failed_emulator_pid}" >&2
  exit 1
fi
pass
failed_proxy_count=$(find "${failed_proxy_pid_dir}" -type f | wc -l | tr -d ' ')
assert_eq 3 "${failed_proxy_count}" 'Console proxy failure still starts all three supervised transports'
for proxy_pid_file in "${failed_proxy_pid_dir}"/*; do
  proxy_pid=${proxy_pid_file##*/}
  if kill -0 "${proxy_pid}" 2>/dev/null; then
    printf 'FAIL: supervised proxy process %s survived Console proxy failure\n' "${proxy_pid}" >&2
    exit 1
  fi
done
pass

fake_adb=${tmp}/fake-adb
fake_adb_log=${tmp}/fake-adb.log
printf '%s\n' \
  '#!/bin/sh' \
  'expected_endpoint=${FAKE_ADB_ENDPOINT:-127.0.0.1:5557}' \
  'expected_serial=${FAKE_ADB_SERIAL:-emulator-5556}' \
  '[ -z "${FAKE_ADB_LOG:-}" ] || printf "%s\\n" "$*" >>"${FAKE_ADB_LOG}"' \
  'case "$*" in' \
  '  "connect ${expected_endpoint}")' \
  '    [ "${FAKE_CONNECT:-1}" = 1 ] || exit 1' \
  '    printf "connected to %s\\n" "${expected_endpoint}"' \
  '    ;;' \
  '  "-s ${expected_serial} get-state") printf "%s\\n" "${FAKE_STATE:-device}" ;;' \
  '  "-s ${expected_serial} shell getprop sys.boot_completed") printf "%s\\n" "${FAKE_BOOT:-1}" ;;' \
  '  "-s ${expected_serial} shell "*)' \
  '    play_path=; gms_path=' \
  '    [ "${FAKE_PLAY:-1}" = 1 ] && play_path=package:/system/priv-app/Phonesky/Phonesky.apk' \
  '    [ "${FAKE_GMS:-1}" = 1 ] && gms_path=package:/system/priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk' \
  '    printf "sdk=%s\\nabi=%s\\npage_size=%s\\ntimeout_multiplier=%s\\nfinalizer_timeout_ms=%s\\nsystem_server=%s\\nactivity=Service activity: %s\\nwindow=Service window: %s\\ncamera=Service media.camera: %s\\nbluetooth=Service bluetooth_manager: %s\\nplay=%s\\ngms=%s\\n" "${FAKE_SDK:-37}" "${FAKE_ABI:-arm64-v8a}" "${FAKE_PAGE_SIZE:-16384}" "${FAKE_MULTIPLIER:-50}" "${FAKE_FINALIZER_TIMEOUT:-500000}" "${FAKE_SYSTEM_SERVER_PID:-1076}" "${FAKE_ACTIVITY_STATE:-found}" "${FAKE_WINDOW_STATE:-found}" "${FAKE_CAMERA_STATE:-found}" "${FAKE_BLUETOOTH_STATE:-found}" "${play_path}" "${gms_path}"' \
  '    ;;' \
  '  *) exit 1 ;;' \
  'esac' >"${fake_adb}"
chmod 0755 "${fake_adb}"
: >"${fake_adb_log}"

tcp_probe=${tmp}/fake-tcp-probe
printf '%s\n' '#!/bin/sh' '[ "${FAKE_GRPC:-1}" = 1 ]' >"${tcp_probe}"
chmod 0755 "${tcp_probe}"

if [ -e /proc/self/exe ]; then
real_native_aemu=${tmp}/real-native-aemu
mkdir -p "${real_native_aemu}/qemu/linux-aarch64" \
  "${real_native_aemu}/lib64/gles_swiftshader"
cp -L "$(command -v sleep)" \
  "${real_native_aemu}/qemu/linux-aarch64/qemu-system-aarch64-headless"
chmod 0755 "${real_native_aemu}/qemu/linux-aarch64/qemu-system-aarch64-headless"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - \
    "${real_native_aemu}/qemu/linux-aarch64/qemu-system-aarch64-headless" \
    >/dev/null 2>&1
fi
real_expected_engine=$(readlink -f "${real_native_aemu}/qemu/linux-aarch64/qemu-system-aarch64-headless")
NATIVE_AEMU_ROOT=${real_native_aemu} \
  LD_LIBRARY_PATH=/inherited/x86/library/path \
  ANDROID_EGL_LIB=/inherited/x86/libEGL.so \
  ANDROID_EMU_VK_LOADER_PATH=/inherited/x86/libvulkan.so \
  VK_ICD_FILENAMES=/inherited/x86/icd.json \
  VK_ADD_DRIVER_FILES=/inherited/x86/additional-icd.json \
  QEMU_AUDIO_DRV=oss \
  "${ROOT}/native-engine/bin/run-qemu-system-aarch64-headless" 30 &
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
  | grep -Fxq "LD_LIBRARY_PATH=${real_native_aemu}/lib64:${real_native_aemu}/lib64/gles_swiftshader"
pass
tr '\000' '\n' < "/proc/${real_engine_pid}/environ" \
  | grep -Fxq "ANDROID_EMULATOR_LAUNCHER_DIR=${real_native_aemu}"
pass
tr '\000' '\n' < "/proc/${real_engine_pid}/environ" \
  | grep -Fxq "ANDROID_EMU_VK_LOADER_PATH=${real_native_aemu}/lib64/vulkan/libvulkan.so"
pass
tr '\000' '\n' < "/proc/${real_engine_pid}/environ" \
  | grep -Fxq 'ANDROID_EMU_VK_ICD=swiftshader'
pass
tr '\000' '\n' < "/proc/${real_engine_pid}/environ" \
  | grep -Fxq 'QEMU_AUDIO_DRV=none'
pass
if tr '\000' '\n' < "/proc/${real_engine_pid}/environ" \
  | grep -Eq '^(ANDROID_EGL_LIB|VK_ICD_FILENAMES|VK_ADD_DRIVER_FILES)='; then
  printf '%s\n' 'FAIL: native runner preserved inherited x86 graphics environment.' >&2
  exit 1
fi
pass
browser_ready_file=${tmp}/aemu-rfb-first-frame.ready
: >"${browser_ready_file}"
env DOCKER_ENGINE_ARCHITECTURE=arm64 \
  ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 \
  NATIVE_AEMU_ROOT="${real_native_aemu}" \
  ADB_BIN="${fake_adb}" FAKE_ADB_LOG="${fake_adb_log}" SOCAT_BIN="${tcp_probe}" \
  BROWSER_READY_FILE="${browser_ready_file}" \
  "${ROOT}/bin/healthcheck.sh"
pass
health_env="DOCKER_ENGINE_ARCHITECTURE=arm64 ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 NATIVE_AEMU_ROOT=${real_native_aemu} ADB_BIN=${fake_adb} FAKE_ADB_LOG=${fake_adb_log} SOCAT_BIN=${tcp_probe} BROWSER_READY_FILE=${browser_ready_file}"
: >"${fake_adb_log}"
env ${health_env} "${ROOT}/bin/healthcheck.sh"
pass
grep -Fxq 'connect 127.0.0.1:5557' "${fake_adb_log}"
pass
grep -Fxq -- '-s emulator-5556 get-state' "${fake_adb_log}"
pass
if grep -Eq -- '^-s (127\.0\.0\.1:5557|emulator-5554) ' "${fake_adb_log}"; then
  printf '%s\n' 'FAIL: healthcheck selected a direct TCP or proxy-discovered ADB serial.' >&2
  exit 1
fi
pass
: >"${fake_adb_log}"
env ${health_env} \
  EMULATOR_CONSOLE_PORT=5580 EMULATOR_ADB_PORT=5581 \
  FAKE_ADB_ENDPOINT=127.0.0.1:5581 FAKE_ADB_SERIAL=emulator-5580 \
  "${ROOT}/bin/healthcheck.sh"
grep -Fxq 'connect 127.0.0.1:5581' "${fake_adb_log}"
grep -Fxq -- '-s emulator-5580 get-state' "${fake_adb_log}"
pass
assert_fails 'healthcheck requires the selected child process' \
  env DOCKER_ENGINE_ARCHITECTURE=arm64 ANDROID_RUNTIME_IMPLEMENTATION=hybrid-aemu-arm64 \
    NATIVE_AEMU_ROOT="${tmp}/not-running" ADB_BIN="${fake_adb}" SOCAT_BIN="${tcp_probe}" \
    "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires a browser video first frame' \
  env ${health_env} BROWSER_READY_FILE="${tmp}/missing-browser-ready" "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires gRPC proxy' env ${health_env} FAKE_GRPC=0 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires the internal ADB connect to succeed' \
  env ${health_env} FAKE_CONNECT=0 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires the configured emulator serial after connect' \
  env ${health_env} FAKE_ADB_SERIAL=emulator-5554 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects an offline configured emulator serial' \
  env ${health_env} FAKE_STATE=offline "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects incomplete boot' env ${health_env} FAKE_BOOT=0 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects wrong API' env ${health_env} FAKE_SDK=36 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects wrong ABI' env ${health_env} FAKE_ABI=x86_64 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects a 4 KB guest' env ${health_env} FAKE_PAGE_SIZE=4096 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects the wrong watchdog multiplier' \
  env ${health_env} FAKE_MULTIPLIER=1 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects the wrong ART finalizer watchdog timeout' \
  env ${health_env} FAKE_FINALIZER_TIMEOUT=10000 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects an inconsistent expected Bluetooth HCI command timeout' \
  env ${health_env} EXPECTED_BLUETOOTH_HCI_TIMEOUT_MS=2000 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck rejects an inconsistent expected Bluetooth HCI restart timeout' \
  env ${health_env} EXPECTED_BLUETOOTH_HCI_RESTART_TIMEOUT_MS=5000 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires a live SystemServer process' \
  env ${health_env} FAKE_SYSTEM_SERVER_PID=missing "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires ActivityManager service' \
  env ${health_env} FAKE_ACTIVITY_STATE='not found' "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires WindowManager service' \
  env ${health_env} FAKE_WINDOW_STATE='not found' "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires CameraService' \
  env ${health_env} FAKE_CAMERA_STATE='not found' "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires BluetoothManager service' \
  env ${health_env} FAKE_BLUETOOTH_STATE='not found' "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires Play Store' env ${health_env} FAKE_PLAY=0 "${ROOT}/bin/healthcheck.sh"
assert_fails 'healthcheck requires Google Play services' env ${health_env} FAKE_GMS=0 "${ROOT}/bin/healthcheck.sh"

kill "${real_engine_pid}"
wait "${real_engine_pid}" 2>/dev/null || true
real_engine_pid=
fi

printf 'PASS: %s assertions\n' "${passed}"
