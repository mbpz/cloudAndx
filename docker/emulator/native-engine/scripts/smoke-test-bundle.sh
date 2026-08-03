#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

BUNDLE_DIR=${BUNDLE_DIR:-/out/bundle/opt/cloudandx/native-aemu}
READELF=${READELF:-aarch64-linux-gnu-readelf}
HOST_READELF=${HOST_READELF:-readelf}
NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION:-}
NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256:-}
NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256:-}

ENGINE=${BUNDLE_DIR}/qemu/linux-aarch64/qemu-system-aarch64-headless
RUNNER=${BUNDLE_DIR}/bin/run-qemu-system-aarch64-headless
LOADER=${BUNDLE_DIR}/lib64/ld-linux-aarch64.so.1
GFXSTREAM_BACKEND=${BUNDLE_DIR}/lib64/libgfxstream_backend.so
X11_XCB=${BUNDLE_DIR}/lib64/libX11-xcb.so.1
CRASHPAD_HANDLER=${BUNDLE_DIR}/crashpad_handler
QEMU_IMG=${BUNDLE_DIR}/qemu-img
NIMBLE_BRIDGE=${BUNDLE_DIR}/nimble_bridge
NETSIMD_LAUNCHER=${BUNDLE_DIR}/netsimd
NETSIMD_BINARY=${BUNDLE_DIR}/libexec/linux-x86_64/netsimd
SWIFTSHADER_DIR=${BUNDLE_DIR}/lib64/gles_swiftshader
VULKAN_DIR=${BUNDLE_DIR}/lib64/vulkan
VULKAN_LOADER=${VULKAN_DIR}/libvulkan.so
VULKAN_LOADER_SONAME=${VULKAN_DIR}/libvulkan.so.1
VULKAN_LOADER_REAL=${VULKAN_DIR}/libvulkan.so.1.4.344
VULKAN_ICD=${VULKAN_DIR}/libvk_swiftshader.so
VULKAN_ICD_JSON=${VULKAN_DIR}/vk_swiftshader_icd.json
VULKAN_PROBE=${BUNDLE_DIR}/vulkan-smoke
IDENTITY=${BUNDLE_DIR}/identity.properties

die() {
  printf 'smoke-test-bundle: %s\n' "$*" >&2
  exit 1
}

elf_build_id() {
  local path=$1
  "${READELF}" -n "${path}" 2>/dev/null \
    | sed -n 's/.*Build ID: \([0-9a-f][0-9a-f]*\).*/\1/p' \
    | sed -n '1p'
}

validate_origin_search_path() {
  local search_path=$1 tag=$2 entry relative component
  local -a entries=()
  local -a components=()

  [[ -n "${search_path}" ]] || return 0
  case ${search_path} in
    :*|*:|*::*) die "${tag} contains an empty ELF search-path entry" ;;
  esac

  IFS=: read -r -a entries <<<"${search_path}"
  for entry in "${entries[@]}"; do
    case ${entry} in
      '$ORIGIN') continue ;;
      '$ORIGIN/'*)
        relative=${entry#\$ORIGIN/}
        [[ -n "${relative}" && "${relative}" != */ && "${relative}" != *//* ]] \
          || die "${tag} contains a non-normalized ELF search path: ${entry}"
        IFS=/ read -r -a components <<<"${relative}"
        for component in "${components[@]}"; do
          [[ -n "${component}" && "${component}" != . && "${component}" != .. ]] \
            || die "${tag} contains a non-normalized ELF search path: ${entry}"
        done
        ;;
      *) die "${tag} escapes the bundle: ${entry}" ;;
    esac
  done
}

search_path_contains() {
  local search_path=$1 expected=$2
  [[ ":${search_path}:" == *":${expected}:"* ]]
}

qmp_probe_failure() {
  local log=$1 message=$2

  printf 'smoke-test-bundle: mach-virt QMP probe output (last 8192 bytes):\n' >&2
  tail -c 8192 "${log}" >&2 || true
  printf '\n' >&2
  rm -f "${log}"
  die "${message}"
}

verify_android_a57_16k_mach_virt() {
  local qmp_log qmp_status

  qmp_log=$(mktemp)
  if printf '%s\n' \
      '{"execute":"qmp_capabilities","id":"capabilities"}' \
      '{"execute":"quit","id":"quit"}' \
    | env -i \
      LC_ALL=C \
      TMPDIR=/tmp \
      HOME=/tmp \
      ANDROID_EMULATOR_LAUNCHER_DIR="${BUNDLE_DIR}" \
      ANDROID_EMU_VK_LOADER_PATH="${BUNDLE_DIR}/lib64/vulkan/libvulkan.so" \
      ANDROID_EMU_VK_ICD=swiftshader \
      QEMU_AUDIO_DRV=none \
      /usr/bin/timeout --signal=TERM --kill-after=5s 30s \
      "${LOADER}" \
      --library-path "${BUNDLE_DIR}/lib64:${BUNDLE_DIR}/lib64/gles_swiftshader" \
      "${ENGINE}" \
      -fuchsia \
      -machine virt,gic-version=2 \
      -cpu android-a57-16k \
      -S \
      -nodefaults \
      -qmp stdio \
      -nographic >"${qmp_log}" 2>&1; then
    qmp_status=0
  else
    qmp_status=$?
  fi

  if grep -Eq 'CPU type .*android-a57-16k.*not supported' "${qmp_log}"; then
    qmp_probe_failure "${qmp_log}" \
      'mach-virt rejected the android-a57-16k CPU model'
  fi
  if grep -Eq '"error"[[:space:]]*:' "${qmp_log}"; then
    qmp_probe_failure "${qmp_log}" \
      'mach-virt returned a QMP command error for android-a57-16k'
  fi
  if ! grep -Eq '"id"[[:space:]]*:[[:space:]]*"capabilities"' "${qmp_log}"; then
    qmp_probe_failure "${qmp_log}" \
      'mach-virt did not acknowledge qmp_capabilities for android-a57-16k'
  fi
  if ! grep -Eq '"event"[[:space:]]*:[[:space:]]*"SHUTDOWN"' "${qmp_log}"; then
    qmp_probe_failure "${qmp_log}" \
      'mach-virt did not emit QMP SHUTDOWN for android-a57-16k'
  fi
  case ${qmp_status} in
    0|138) ;;
    *)
      qmp_probe_failure "${qmp_log}" \
        "mach-virt QMP probe exited with unexpected status ${qmp_status}"
      ;;
  esac

  rm -f "${qmp_log}"
}

for required in \
  "${ENGINE}" \
  "${RUNNER}" \
  "${LOADER}" \
  "${GFXSTREAM_BACKEND}" \
  "${X11_XCB}" \
  "${CRASHPAD_HANDLER}" \
  "${QEMU_IMG}" \
  "${NIMBLE_BRIDGE}" \
  "${NETSIMD_LAUNCHER}" \
  "${NETSIMD_BINARY}" \
  "${VULKAN_LOADER_REAL}" \
  "${VULKAN_ICD}" \
  "${VULKAN_ICD_JSON}" \
  "${VULKAN_PROBE}" \
  "${IDENTITY}" \
  "${BUNDLE_DIR}/manifest.json" \
  "${BUNDLE_DIR}/SHA256SUMS"; do
  [[ -f "${required}" ]] || die "required bundle file is missing: ${required}"
done

for executable in "${ENGINE}" "${RUNNER}" "${LOADER}" \
  "${CRASHPAD_HANDLER}" "${QEMU_IMG}" "${NIMBLE_BRIDGE}" \
  "${NETSIMD_LAUNCHER}" "${NETSIMD_BINARY}" "${VULKAN_PROBE}"; do
  [[ -x "${executable}" ]] || die "bundle executable is not executable: ${executable}"
done

(
  cd "${BUNDLE_DIR}"
  sha256sum -c SHA256SUMS
)

sh -n "${RUNNER}"
sh -n "${NETSIMD_LAUNCHER}"
grep -Fq 'ROOT=${NATIVE_AEMU_ROOT:-/opt/cloudandx/native-aemu}' "${RUNNER}" \
  || die 'runner does not default to the fixed bundle root'
grep -Fq 'ENGINE=${ROOT}/qemu/linux-aarch64/qemu-system-aarch64-headless' "${RUNNER}" \
  || die 'runner does not use the launcher-compatible engine path'
grep -Fq 'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT' "${RUNNER}" \
  || die 'runner does not clear inherited dynamic-loader variables'
grep -Fq 'unset ANDROID_EGL_LIB ANDROID_GLESv1_LIB ANDROID_GLESv2_LIB' "${RUNNER}" \
  || die 'runner does not clear inherited GLES library selection'
grep -Fq 'unset ANDROID_EMU_VK_LOADER_PATH' "${RUNNER}" \
  || die 'runner does not clear the inherited Emulator Vulkan loader path'
grep -Fq 'unset VK_ICD_FILENAMES VK_DRIVER_FILES' "${RUNNER}" \
  || die 'runner does not clear inherited Vulkan driver selection'
grep -Fq 'ANDROID_EMULATOR_LAUNCHER_DIR=${ROOT}' "${RUNNER}" \
  || die 'runner does not replace the inherited launcher directory'
grep -Fq 'ANDROID_EMU_VK_LOADER_PATH=${ROOT}/lib64/vulkan/libvulkan.so' "${RUNNER}" \
  || die 'runner does not select the locked AArch64 Vulkan loader'
grep -Fq 'ANDROID_EMU_VK_ICD=swiftshader' "${RUNNER}" \
  || die 'runner does not select the locked SwiftShader Vulkan ICD'
grep -Fq 'LIBRARY_PATH=${ROOT}/lib64:${ROOT}/lib64/gles_swiftshader' "${RUNNER}" \
  || die 'runner does not select the ARM64 library and SwiftShader directories'
grep -Fq 'LD_LIBRARY_PATH=${LIBRARY_PATH}' "${RUNNER}" \
  || die 'runner does not replace the inherited library path'
grep -Fq 'QEMU_AUDIO_DRV=none' "${RUNNER}" \
  || die 'runner does not select the host-device-free QEMU audio backend'
grep -Fq 'ANDROID_EMU_VK_ICD LD_LIBRARY_PATH QEMU_AUDIO_DRV' "${RUNNER}" \
  || die 'runner does not export the locked audio backend'
grep -Fq 'exec "${ENGINE}" "$@"' "${RUNNER}" \
  || die 'runner does not directly exec the engine'
if grep -Fq 'exec "${LOADER}"' "${RUNNER}"; then
  die 'runner still executes the ELF loader as the process image'
fi

[[ -L "${VULKAN_LOADER}" && $(readlink "${VULKAN_LOADER}") == libvulkan.so.1 ]] \
  || die 'Vulkan loader unversioned symlink is invalid'
[[ -L "${VULKAN_LOADER_SONAME}" \
  && $(readlink "${VULKAN_LOADER_SONAME}") == libvulkan.so.1.4.344 ]] \
  || die 'Vulkan loader SONAME symlink is invalid'
[[ $("${READELF}" -d "${VULKAN_LOADER_REAL}" 2>/dev/null \
  | sed -n 's/.*(SONAME).*\[\([^]]*\)\].*/\1/p') == libvulkan.so.1 ]] \
  || die 'Vulkan loader ELF SONAME is invalid'
jq -e '
  .file_format_version == "1.0.0" and
  .ICD.library_path == "./libvk_swiftshader.so" and
  .ICD.api_version == "1.0.5"
' "${VULKAN_ICD_JSON}" >/dev/null \
  || die 'SwiftShader Vulkan ICD manifest is invalid'
VULKAN_PROBE_RUNPATH=$("${READELF}" -d "${VULKAN_PROBE}" 2>/dev/null \
  | sed -n 's/.*(RUNPATH).*\[\([^]]*\)\].*/\1/p')
search_path_contains "${VULKAN_PROBE_RUNPATH}" '$ORIGIN/lib64/vulkan' \
  || die 'Vulkan probe does not use the bundle-local loader path'
validate_origin_search_path "${VULKAN_PROBE_RUNPATH}" RUNPATH

grep -Fq 'NETSIMD=${ROOT}/libexec/linux-x86_64/netsimd' "${NETSIMD_LAUNCHER}" \
  || die 'netsimd launcher does not use the classified mixed-architecture helper path'
grep -Fq 'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT' "${NETSIMD_LAUNCHER}" \
  || die 'netsimd launcher does not clear inherited ARM loader variables'
grep -Fq 'unset ANDROID_EGL_LIB ANDROID_GLESv1_LIB ANDROID_GLESv2_LIB' \
  "${NETSIMD_LAUNCHER}" \
  || die 'netsimd launcher does not clear inherited GPU library selection'
grep -Fq 'unset VK_ICD_FILENAMES VK_DRIVER_FILES' "${NETSIMD_LAUNCHER}" \
  || die 'netsimd launcher does not clear inherited Vulkan driver selection'
grep -Fq 'exec "${NETSIMD}" "$@"' "${NETSIMD_LAUNCHER}" \
  || die 'netsimd launcher does not preserve daemon arguments'

"${HOST_READELF}" -h "${NETSIMD_BINARY}" \
  | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
  || die 'mixed-architecture netsimd helper is not x86_64'
NETSIMD_INTERPRETER=$("${HOST_READELF}" -l "${NETSIMD_BINARY}" \
  | sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p')
[[ "${NETSIMD_INTERPRETER}" == /lib64/ld-linux-x86-64.so.2 ]] \
  || die "unexpected netsimd ELF interpreter: ${NETSIMD_INTERPRETER:-missing}"
EXPECTED_NETSIMD_NEEDED=$'ld-linux-x86-64.so.2\nlibc.so.6\nlibdl.so.2\nlibm.so.6\nlibpthread.so.0\nlibrt.so.1'
ACTUAL_NETSIMD_NEEDED=$("${HOST_READELF}" -d "${NETSIMD_BINARY}" 2>/dev/null \
  | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' | sort -u)
[[ "${ACTUAL_NETSIMD_NEEDED}" == "${EXPECTED_NETSIMD_NEEDED}" ]] \
  || die 'netsimd system-library dependency set changed'
[[ ! -e "${BUNDLE_DIR}/lib64/netsimd" ]] \
  || die 'x86_64 netsimd leaked into the AArch64 library closure'
if [[ $(uname -m) == x86_64 ]]; then
  NETSIMD_VERSION_OUTPUT=$("${NETSIMD_LAUNCHER}" --version 2>&1) \
    || die 'netsimd launcher did not execute on the amd64 smoke-test platform'
  grep -Eq '(^|[^0-9])0\.3\.112([^0-9]|$)' <<<"${NETSIMD_VERSION_OUTPUT}" \
    || die "unexpected netsimd version output: ${NETSIMD_VERSION_OUTPUT}"
else
  [[ $(uname -m) == aarch64 ]] \
    || die 'native engine smoke-test platform must be amd64 or arm64'
fi
NETSIMD_SHA256=$(sha256sum "${NETSIMD_BINARY}" | awk '{print $1}')
VULKAN_LOADER_SHA256=$(sha256sum "${VULKAN_LOADER_REAL}" | awk '{print $1}')
VULKAN_ICD_SHA256=$(sha256sum "${VULKAN_ICD}" | awk '{print $1}')
VULKAN_ICD_JSON_SHA256=$(sha256sum "${VULKAN_ICD_JSON}" | awk '{print $1}')
VULKAN_PROBE_SHA256=$(sha256sum "${VULKAN_PROBE}" | awk '{print $1}')
VULKAN_PROBE_BUILD_ID=$(elf_build_id "${VULKAN_PROBE}")
[[ -n "${VULKAN_PROBE_BUILD_ID}" ]] || die 'Vulkan probe has no GNU Build ID'

[[ -L "${BUNDLE_DIR}/qemu/linux-aarch64/lib64" \
  && $(readlink "${BUNDLE_DIR}/qemu/linux-aarch64/lib64") == ../../lib64 ]] \
  || die 'engine $ORIGIN/lib64 link does not resolve to the bundle library directory'

INTERPRETER=$("${READELF}" -l "${ENGINE}" \
  | sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p')
RPATH=$("${READELF}" -d "${ENGINE}" 2>/dev/null \
  | sed -n 's/.*(RPATH).*\[\([^]]*\)\].*/\1/p')
RUNPATH=$("${READELF}" -d "${ENGINE}" 2>/dev/null \
  | sed -n 's/.*(RUNPATH).*\[\([^]]*\)\].*/\1/p')
BUILD_ID=$(elf_build_id "${ENGINE}")
[[ "${INTERPRETER}" == /lib/ld-linux-aarch64.so.1 ]] \
  || die "unexpected direct-exec ELF interpreter: ${INTERPRETER:-missing}"
if ! search_path_contains "${RPATH}" '$ORIGIN/lib64' \
  && ! search_path_contains "${RUNPATH}" '$ORIGIN/lib64'; then
  die 'engine ELF search path does not contain $ORIGIN/lib64'
fi
validate_origin_search_path "${RPATH}" RPATH
validate_origin_search_path "${RUNPATH}" RUNPATH
[[ -n "${BUILD_ID}" ]] || die 'stripped engine has no GNU Build ID'

for data_file in \
  advancedFeatures.ini \
  emu-original-feature-flags.protobuf \
  ca-bundle.pem \
  hostapd.conf \
  emulator_access.json; do
  [[ -s "${BUNDLE_DIR}/lib/${data_file}" ]] \
    || die "locked AEMU runtime data is missing: ${data_file}"
done
[[ -d "${BUNDLE_DIR}/lib/pc-bios" ]] || die 'locked AEMU pc-bios directory is missing'
find "${BUNDLE_DIR}/lib/pc-bios" -type f -print -quit | grep -q . \
  || die 'locked AEMU pc-bios directory is empty'
[[ -z $(find "${BUNDLE_DIR}/lib" -mindepth 1 -maxdepth 1 \
  ! -name pc-bios \
  ! -name advancedFeatures.ini \
  ! -name emu-original-feature-flags.protobuf \
  ! -name ca-bundle.pem \
  ! -name hostapd.conf \
  ! -name emulator_access.json \
  -print -quit) ]] || die 'bundle lib contains unlocked runtime data'

verify_android_a57_16k_mach_virt

[[ -d "${BUNDLE_DIR}/resources/skins/android-36" ]] \
  || die 'locked x86_64 guest skin resources are missing'
find "${BUNDLE_DIR}/resources" -type f -print -quit | grep -q . \
  || die 'locked native AEMU runtime resources are empty'
[[ -z $(find "${BUNDLE_DIR}/resources" -name BUILD.bazel -print -quit) ]] \
  || die 'build-only metadata leaked into runtime resources'

EXPECTED_SWIFTSHADER=$'libEGL.so\nlibGLES_CM.so\nlibGLESv2.so'
ACTUAL_SWIFTSHADER=$(find "${SWIFTSHADER_DIR}" -maxdepth 1 -type f \
  -printf '%f\n' | sort)
[[ "${ACTUAL_SWIFTSHADER}" == "${EXPECTED_SWIFTSHADER}" ]] \
  || die 'SwiftShader directory does not contain exactly the three locked GLES libraries'

while IFS= read -r elf_file; do
  "${READELF}" -h "${elf_file}" \
    | grep -Eq 'Machine:[[:space:]]+AArch64' \
    || die "ELF is not AArch64: ${elf_file}"
  if "${READELF}" -S "${elf_file}" 2>/dev/null \
    | grep -Eq '\.debug_(info|line|str)([[:space:]]|$)'; then
    die "ELF still contains debug sections after packaging: ${elf_file}"
  fi
  ELF_RPATH=$("${READELF}" -d "${elf_file}" 2>/dev/null \
    | sed -n 's/.*(RPATH).*\[\([^]]*\)\].*/\1/p')
  ELF_RUNPATH=$("${READELF}" -d "${elf_file}" 2>/dev/null \
    | sed -n 's/.*(RUNPATH).*\[\([^]]*\)\].*/\1/p')
  validate_origin_search_path "${ELF_RPATH}" RPATH
  validate_origin_search_path "${ELF_RUNPATH}" RUNPATH
  while IFS= read -r needed; do
    [[ -f "${BUNDLE_DIR}/lib64/${needed}" \
      || -f "${SWIFTSHADER_DIR}/${needed}" \
      || -f "${VULKAN_DIR}/${needed}" ]] \
      || die "unresolved bundled DT_NEEDED entry ${needed} from ${elf_file}"
  done < <("${READELF}" -d "${elf_file}" 2>/dev/null \
    | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' | sort -u)
done < <(
  printf '%s\n' \
    "${ENGINE}" \
    "${CRASHPAD_HANDLER}" \
    "${QEMU_IMG}" \
    "${NIMBLE_BRIDGE}" \
    "${VULKAN_PROBE}"
  find "${BUNDLE_DIR}/lib64" -type f ! -name '*.json' -print | sort
)

if grep -Fq '/out/build' "${BUNDLE_DIR}/manifest.json"; then
  die 'build-tree path leaked into the bundle manifest'
fi

jq -e \
  --arg interpreter "${INTERPRETER}" \
  --arg rpath "${RPATH}" \
  --arg runpath "${RUNPATH}" \
  --arg build_id "${BUILD_ID}" \
  --arg netsimd_sha256 "${NETSIMD_SHA256}" \
  --arg vulkan_loader_sha256 "${VULKAN_LOADER_SHA256}" \
  --arg vulkan_icd_sha256 "${VULKAN_ICD_SHA256}" \
  --arg vulkan_icd_json_sha256 "${VULKAN_ICD_JSON_SHA256}" \
  --arg vulkan_probe_sha256 "${VULKAN_PROBE_SHA256}" \
  --arg vulkan_probe_build_id "${VULKAN_PROBE_BUILD_ID}" '
  .schema_version == 2 and
  .product == "cloudandx-aemu-native-engine" and
  .revision == "37.1.7" and
  .architecture == "arm64" and
  .binary == "/opt/cloudandx/native-aemu/qemu/linux-aarch64/qemu-system-aarch64-headless" and
  .runner == "/opt/cloudandx/native-aemu/bin/run-qemu-system-aarch64-headless" and
  .loader == "/opt/cloudandx/native-aemu/lib64/ld-linux-aarch64.so.1" and
  .helpers.gfxstream_backend == "/opt/cloudandx/native-aemu/lib64/libgfxstream_backend.so" and
  .helpers.crashpad_handler == "/opt/cloudandx/native-aemu/crashpad_handler" and
  .helpers.qemu_img == "/opt/cloudandx/native-aemu/qemu-img" and
  .helpers.nimble_bridge == "/opt/cloudandx/native-aemu/nimble_bridge" and
  .helpers.netsimd == "/opt/cloudandx/native-aemu/netsimd" and
  .helpers.vulkan_smoke == "/opt/cloudandx/native-aemu/vulkan-smoke" and
  .mixed_arch_helpers.netsimd == {
    "architecture": "x86_64",
    "version": "0.3.112",
    "launcher": "/opt/cloudandx/native-aemu/netsimd",
    "binary": "/opt/cloudandx/native-aemu/libexec/linux-x86_64/netsimd",
    "interpreter": "/lib64/ld-linux-x86-64.so.2",
    "sha256": $netsimd_sha256,
    "dt_needed": [
      "ld-linux-x86-64.so.2",
      "libc.so.6",
      "libdl.so.2",
      "libm.so.6",
      "libpthread.so.0",
      "librt.so.1"
    ],
    "included_in_aarch64_dt_needed_closure": false,
    "source": {
      "lock_id": "common-netsimd-linux-x86_64",
      "repository": "https://android.googlesource.com/platform/prebuilts/android-emulator-build/common",
      "commit": "f64c458fc47ac18f738f9c8bdecb64d265f530f4",
      "tree": "e81f67597e83b179f8aff5417d2282ddb9a1d4e5",
      "path": "netsim/linux-x86_64/netsimd",
      "git_blob_sha1": "1f0af5c2d0a266ffbda044cdf7b48cd584608319"
    }
  } and
  .runtime_dlopen == {
    "gfxstream_backend": "/opt/cloudandx/native-aemu/lib64/libgfxstream_backend.so",
    "x11_xcb": "/opt/cloudandx/native-aemu/lib64/libX11-xcb.so.1",
    "swiftshader_egl": "/opt/cloudandx/native-aemu/lib64/gles_swiftshader/libEGL.so",
    "swiftshader_gles_cm": "/opt/cloudandx/native-aemu/lib64/gles_swiftshader/libGLES_CM.so",
    "swiftshader_gles_v2": "/opt/cloudandx/native-aemu/lib64/gles_swiftshader/libGLESv2.so",
    "vulkan_loader": "/opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so",
    "swiftshader_vulkan_icd": "/opt/cloudandx/native-aemu/lib64/vulkan/libvk_swiftshader.so",
    "swiftshader_vulkan_manifest": "/opt/cloudandx/native-aemu/lib64/vulkan/vk_swiftshader_icd.json"
  } and
  .vulkan.loader.path == "/opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so" and
  .vulkan.loader.soname_path == "/opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so.1" and
  .vulkan.loader.real_path == "/opt/cloudandx/native-aemu/lib64/vulkan/libvulkan.so.1.4.344" and
  .vulkan.loader.version == "1.4.344" and
  .vulkan.loader.soname == "libvulkan.so.1" and
  .vulkan.loader.sha256 == $vulkan_loader_sha256 and
  (.vulkan.loader.dt_needed | length > 0) and
  .vulkan.loader.source.repository == "https://github.com/KhronosGroup/Vulkan-Loader" and
  .vulkan.loader.source.commit == "bac41319cafb4527a2a959237b17611dd08bfe11" and
  .vulkan.loader.source.git_tree == "179d52738e39d20391e78551ad42d24ed6005663" and
  .vulkan.headers_source.repository == "https://github.com/KhronosGroup/Vulkan-Headers" and
  .vulkan.headers_source.commit == "ad9ce1235e88dc09287e19171dfac384db8ec32c" and
  .vulkan.headers_source.git_tree == "66aac757224c771c25cea6ed942d5bc8483f06eb" and
  .vulkan.swiftshader_icd.path == "/opt/cloudandx/native-aemu/lib64/vulkan/libvk_swiftshader.so" and
  .vulkan.swiftshader_icd.manifest == "/opt/cloudandx/native-aemu/lib64/vulkan/vk_swiftshader_icd.json" and
  .vulkan.swiftshader_icd.manifest_file_format_version == "1.0.0" and
  .vulkan.swiftshader_icd.manifest_api_version == "1.0.5" and
  .vulkan.swiftshader_icd.manifest_library_path == "./libvk_swiftshader.so" and
  .vulkan.swiftshader_icd.sha256 == $vulkan_icd_sha256 and
  .vulkan.swiftshader_icd.manifest_sha256 == $vulkan_icd_json_sha256 and
  (.vulkan.swiftshader_icd.dt_needed | length > 0) and
  .vulkan.swiftshader_icd.source.repository == "https://android.googlesource.com/platform/external/swiftshader" and
  .vulkan.swiftshader_icd.source.commit == "9a22bb9de00f5d8ddf4fc5ba5c2f425c2816e679" and
  .vulkan.swiftshader_icd.source.git_tree == "bf4997626a7621c64b0dcc57317e7fa6e4b78018" and
  .vulkan.smoke_probe.path == "/opt/cloudandx/native-aemu/vulkan-smoke" and
  .vulkan.smoke_probe.sha256 == $vulkan_probe_sha256 and
  .vulkan.smoke_probe.build_id == $vulkan_probe_build_id and
  .vulkan.smoke_probe.verifies == ["instance", "physical-device", "device", "queue", "submit", "fence"] and
  .data.pc_bios == "/opt/cloudandx/native-aemu/lib/pc-bios" and
  .data.swiftshader == "/opt/cloudandx/native-aemu/lib64/gles_swiftshader" and
  .data.resources == "/opt/cloudandx/native-aemu/resources" and
  .execution.model == "direct-engine" and
  .execution.interpreter == $interpreter and
  .execution.rpath == $rpath and
  .execution.runpath == $runpath and
  .execution.build_id == $build_id and
  .execution.library_path == "/opt/cloudandx/native-aemu/lib64:/opt/cloudandx/native-aemu/lib64/gles_swiftshader" and
  .execution.audio_driver == "none"
' "${BUNDLE_DIR}/manifest.json" >/dev/null \
  || die 'bundle manifest contract is invalid'

REVISION=$(jq -r '.revision' "${BUNDLE_DIR}/manifest.json")
SOURCE_LOCK_SHA256=$(sha256sum "${BUNDLE_DIR}/share/provenance/sources.lock.json" \
  | awk '{print $1}')
PATCH_SET_SHA256=$(jq -r '.provenance.patch_set_sha256' "${BUNDLE_DIR}/manifest.json")
[[ $(wc -l < "${IDENTITY}" | tr -d ' ') == 3 ]] \
  || die 'bundle identity must contain exactly three immutable fields'
grep -Fxq "revision=${REVISION}" "${IDENTITY}" || die 'revision identity mismatch'
grep -Fxq "source_lock_sha256=${SOURCE_LOCK_SHA256}" "${IDENTITY}" \
  || die 'source-lock identity mismatch'
grep -Fxq "patch_set_sha256=${PATCH_SET_SHA256}" "${IDENTITY}" \
  || die 'patch-set identity mismatch'
[[ -z "${NATIVE_AEMU_REVISION}" || "${REVISION}" == "${NATIVE_AEMU_REVISION}" ]] \
  || die 'expected revision identity mismatch'
[[ -z "${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  || "${SOURCE_LOCK_SHA256}" == "${NATIVE_AEMU_SOURCE_LOCK_SHA256}" ]] \
  || die 'expected source-lock identity mismatch'
[[ -z "${NATIVE_AEMU_PATCH_SET_SHA256}" \
  || "${PATCH_SET_SHA256}" == "${NATIVE_AEMU_PATCH_SET_SHA256}" ]] \
  || die 'expected patch-set identity mismatch'

printf 'smoke-test-bundle: launcher layout, AArch64 closure, mach-virt CPU model, mixed-arch netsimd, audio policy, identity, and checksums verified\n'
