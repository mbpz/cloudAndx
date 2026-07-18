#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
LOCK_FILE=${LOCK_FILE:-${ENGINE_DIR}/sources.lock.json}
WORKSPACE=${WORKSPACE:-/workspace}
BUILD_DIR=${BUILD_DIR:-/out/build}
VULKAN_BUILD_ROOT=${VULKAN_BUILD_ROOT:-/out/vulkan}
BUNDLE_DIR=${BUNDLE_DIR:-/out/bundle/opt/cloudandx/native-aemu}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(jq -r '.source_date_epoch' "${LOCK_FILE}")}
READELF=${READELF:-aarch64-linux-gnu-readelf}
HOST_READELF=${HOST_READELF:-readelf}
STRIP=${STRIP:-aarch64-linux-gnu-strip}
NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION:-}
NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256:-}
NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256:-}

ENGINE_RELATIVE=qemu/linux-aarch64/qemu-system-aarch64-headless
RUNNER_RELATIVE=bin/run-qemu-system-aarch64-headless
LOADER_RELATIVE=lib64/ld-linux-aarch64.so.1
GFXSTREAM_RELATIVE=lib64/libgfxstream_backend.so
X11_XCB_RELATIVE=lib64/libX11-xcb.so.1
CRASHPAD_RELATIVE=crashpad_handler
QEMU_IMG_RELATIVE=qemu-img
NIMBLE_BRIDGE_RELATIVE=nimble_bridge
NETSIMD_LAUNCHER_RELATIVE=netsimd
NETSIMD_BINARY_RELATIVE=libexec/linux-x86_64/netsimd
NETSIMD_VERSION=0.3.112
VULKAN_LOADER_RELATIVE=lib64/vulkan/libvulkan.so
VULKAN_LOADER_SONAME_RELATIVE=lib64/vulkan/libvulkan.so.1
VULKAN_LOADER_REAL_RELATIVE=lib64/vulkan/libvulkan.so.1.4.344
VULKAN_ICD_RELATIVE=lib64/vulkan/libvk_swiftshader.so
VULKAN_ICD_JSON_RELATIVE=lib64/vulkan/vk_swiftshader_icd.json
VULKAN_PROBE_RELATIVE=vulkan-smoke
LIBRARY_PATH=/opt/cloudandx/native-aemu/lib64:/opt/cloudandx/native-aemu/lib64/gles_swiftshader

die() {
  printf 'package-bundle: %s\n' "$*" >&2
  exit 1
}

is_aarch64_elf() {
  local path=$1
  "${READELF}" -h "${path}" 2>/dev/null \
    | grep -Eq 'Machine:[[:space:]]+AArch64'
}

is_x86_64_elf() {
  local path=$1
  "${HOST_READELF}" -h "${path}" 2>/dev/null \
    | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
}

needed_names() {
  local path=$1
  "${READELF}" -d "${path}" 2>/dev/null \
    | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' \
    | sort -u
}

host_needed_names() {
  local path=$1
  "${HOST_READELF}" -d "${path}" 2>/dev/null \
    | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' \
    | sort -u
}

elf_interpreter() {
  local path=$1
  "${READELF}" -l "${path}" 2>/dev/null \
    | sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p'
}

host_elf_interpreter() {
  local path=$1
  "${HOST_READELF}" -l "${path}" 2>/dev/null \
    | sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p'
}

elf_search_path() {
  local path=$1 tag=$2
  "${READELF}" -d "${path}" 2>/dev/null \
    | sed -n "s/.*(${tag}).*\\[\\([^]]*\\)\\].*/\\1/p"
}

elf_build_id() {
  local path=$1
  "${READELF}" -n "${path}" 2>/dev/null \
    | sed -n 's/.*Build ID: \([0-9a-f][0-9a-f]*\).*/\1/p' \
    | sed -n '1p'
}

elf_soname() {
  local path=$1
  "${READELF}" -d "${path}" 2>/dev/null \
    | sed -n 's/.*(SONAME).*\[\([^]]*\)\].*/\1/p' \
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

patch_set_sha256() {
  local patch_path patch_sha256

  while IFS= read -r patch_path; do
    patch_sha256=$(sha256sum "${ENGINE_DIR}/${patch_path}" | awk '{print $1}')
    printf '%s  %s\n' "${patch_sha256}" "${patch_path}"
  done < <(jq -r '.patches[] | .[]' "${LOCK_FILE}") \
    | sha256sum | awk '{print $1}'
}

find_build_artifact() {
  local name=$1 candidate first= first_sha= candidate_sha

  while IFS= read -r candidate; do
    is_aarch64_elf "${candidate}" || continue
    candidate=$(readlink -f -- "${candidate}")
    candidate_sha=$(sha256sum "${candidate}" | awk '{print $1}')
    if [[ -z "${first}" ]]; then
      first=${candidate}
      first_sha=${candidate_sha}
    elif [[ "${candidate_sha}" != "${first_sha}" ]]; then
      die "ambiguous AArch64 build artifacts named ${name}: ${first} and ${candidate}"
    fi
  done < <(find "${BUILD_DIR}" \( -type f -o -type l \) -name "${name}" -print | sort)

  [[ -n "${first}" ]] || return 1
  printf '%s\n' "${first}"
}

find_aarch64_file() {
  local name=$1 root candidate

  for root in "${SEARCH_ROOTS[@]}"; do
    [[ -d "${root}" ]] || continue
    if [[ -e "${root}/${name}" ]] && is_aarch64_elf "${root}/${name}"; then
      readlink -f -- "${root}/${name}"
      return 0
    fi
    while IFS= read -r candidate; do
      if is_aarch64_elf "${candidate}"; then
        readlink -f -- "${candidate}"
        return 0
      fi
    done < <(find "${root}" \( -type f -o -type l \) -name "${name}" -print | sort)
  done
  return 1
}

copy_dependency_closure() {
  local current canonical needed resolved output index=0
  local -a queue=("${ELF_ROOTS[@]}")
  local -A processed_files=()
  local -A resolved_names=()

  while ((index < ${#queue[@]})); do
    current=${queue[index++]}
    canonical=$(readlink -f -- "${current}")
    [[ -z "${processed_files[${canonical}]+x}" ]] || continue
    processed_files[${canonical}]=1

    while IFS= read -r needed; do
      [[ -n "${needed}" ]] || continue
      [[ "${needed}" =~ ^[A-Za-z0-9._+-]+$ ]] \
        || die "unsafe DT_NEEDED entry ${needed} from ${current}"
      [[ -z "${resolved_names[${needed}]+x}" ]] || continue

      if [[ -f "${BUNDLE_DIR}/lib64/${needed}" ]]; then
        resolved=${BUNDLE_DIR}/lib64/${needed}
      elif [[ -f "${BUNDLE_DIR}/lib64/gles_swiftshader/${needed}" ]]; then
        resolved=${BUNDLE_DIR}/lib64/gles_swiftshader/${needed}
      elif [[ -f "${BUNDLE_DIR}/lib64/vulkan/${needed}" ]]; then
        resolved=${BUNDLE_DIR}/lib64/vulkan/${needed}
      else
        resolved=$(find_aarch64_file "${needed}") \
          || die "unresolved AArch64 DT_NEEDED entry ${needed} from ${current}"
        output=${BUNDLE_DIR}/lib64/${needed}
        cp --dereference --preserve=mode -- "${resolved}" "${output}"
        chmod 0644 "${output}"
        resolved=${output}
      fi

      is_aarch64_elf "${resolved}" \
        || die "resolved dependency is not AArch64: ${resolved}"
      resolved_names[${needed}]=1
      queue+=("${resolved}")
    done < <(needed_names "${current}")
  done
}

make_json_tree_file_list() {
  local directory=$1 relative_prefix=$2 path relative sha

  while IFS= read -r path; do
    relative=${relative_prefix}/${path#"${directory}/"}
    sha=$(sha256sum "${path}" | awk '{print $1}')
    jq -n --arg path "${relative}" --arg sha256 "${sha}" \
      '{path: $path, sha256: $sha256}'
  done < <(find "${directory}" -type f -print | sort)
}

copy_runtime_tree() {
  local source=$1 destination=$2 path relative

  [[ -d "${source}" ]] || die "locked runtime resource directory is missing: ${source}"
  while IFS= read -r path; do
    relative=${path#"${source}/"}
    mkdir -p "${destination}/$(dirname -- "${relative}")"
    cp --preserve=mode -- "${path}" "${destination}/${relative}"
  done < <(find "${source}" -type f ! -name BUILD.bazel -print | sort)
}

copy_runtime_tree_flat() {
  local source=$1 destination=$2 path output

  [[ -d "${source}" ]] || die "locked runtime resource directory is missing: ${source}"
  while IFS= read -r path; do
    output=${destination}/$(basename -- "${path}")
    if [[ -e "${output}" ]]; then
      cmp -s "${path}" "${output}" \
        || die "runtime resource basename collision: $(basename -- "${path}")"
    else
      cp --preserve=mode -- "${path}" "${output}"
    fi
  done < <(find "${source}" -type f ! -name BUILD.bazel -print | sort)
}

ENGINE_SOURCE=$(find_build_artifact qemu-system-aarch64-headless) \
  || die 'AArch64 qemu-system-aarch64-headless was not found'
GFXSTREAM_SOURCE=$(find_build_artifact libgfxstream_backend.so) \
  || die 'AArch64 libgfxstream_backend.so was not found'
CRASHPAD_SOURCE=$(find_build_artifact crashpad_handler) \
  || die 'AArch64 crashpad_handler was not found'
QEMU_IMG_SOURCE=$(find_build_artifact qemu-img) \
  || die 'AArch64 qemu-img was not found'
NIMBLE_BRIDGE_SOURCE=$(find_build_artifact nimble_bridge) \
  || die 'AArch64 nimble_bridge was not found'
VULKAN_LOADER_SOURCE=${VULKAN_BUILD_ROOT}/loader-install/lib/libvulkan.so.1.4.344
VULKAN_ICD_SOURCE=${VULKAN_BUILD_ROOT}/swiftshader-build/libvk_swiftshader.so
VULKAN_ICD_JSON_SOURCE=${VULKAN_BUILD_ROOT}/swiftshader-build/Linux/vk_swiftshader_icd.json
VULKAN_PROBE_SOURCE=${VULKAN_BUILD_ROOT}/vulkan-smoke
for vulkan_elf in "${VULKAN_LOADER_SOURCE}" "${VULKAN_ICD_SOURCE}" \
  "${VULKAN_PROBE_SOURCE}"; do
  [[ -f "${vulkan_elf}" ]] \
    || die "built AArch64 Vulkan artifact is missing: ${vulkan_elf}"
  is_aarch64_elf "${vulkan_elf}" \
    || die "built Vulkan artifact is not AArch64: ${vulkan_elf}"
done
[[ $(elf_soname "${VULKAN_LOADER_SOURCE}") == libvulkan.so.1 ]] \
  || die 'built Vulkan loader SONAME is not libvulkan.so.1'
[[ -f "${VULKAN_ICD_JSON_SOURCE}" ]] \
  || die 'generated SwiftShader Vulkan ICD manifest is missing'
jq -e '
  .file_format_version == "1.0.0" and
  .ICD.library_path == "./libvk_swiftshader.so" and
  .ICD.api_version == "1.0.5"
' "${VULKAN_ICD_JSON_SOURCE}" >/dev/null \
  || die 'generated SwiftShader Vulkan ICD manifest contract changed'
[[ $(elf_interpreter "${VULKAN_PROBE_SOURCE}") == /lib/ld-linux-aarch64.so.1 ]] \
  || die 'unexpected Vulkan probe ELF interpreter'
VULKAN_PROBE_RPATH=$(elf_search_path "${VULKAN_PROBE_SOURCE}" RPATH)
VULKAN_PROBE_RUNPATH=$(elf_search_path "${VULKAN_PROBE_SOURCE}" RUNPATH)
if ! search_path_contains "${VULKAN_PROBE_RPATH}" '$ORIGIN/lib64/vulkan' \
  && ! search_path_contains "${VULKAN_PROBE_RUNPATH}" '$ORIGIN/lib64/vulkan'; then
  die 'Vulkan probe ELF search path does not contain $ORIGIN/lib64/vulkan'
fi
validate_origin_search_path "${VULKAN_PROBE_RPATH}" RPATH
validate_origin_search_path "${VULKAN_PROBE_RUNPATH}" RUNPATH
NETSIMD_LOCK_JSON=$(jq -ce '
  [.sources[] | select(.id == "common-netsimd-linux-x86_64")] |
  if length == 1 then .[0] else error("netsimd source lock must be unique") end
' "${LOCK_FILE}") || die 'locked netsimd source metadata is missing or ambiguous'
[[ $(jq -r '.files | length' <<<"${NETSIMD_LOCK_JSON}") == 1 ]] \
  || die 'locked netsimd source must contain exactly one file'
NETSIMD_SOURCE_REPOSITORY=$(jq -r '.repository' <<<"${NETSIMD_LOCK_JSON}")
NETSIMD_SOURCE_COMMIT=$(jq -r '.commit' <<<"${NETSIMD_LOCK_JSON}")
NETSIMD_SOURCE_TREE=$(jq -r '.git_tree' <<<"${NETSIMD_LOCK_JSON}")
NETSIMD_SOURCE_PATH=$(jq -r '.files[0].path' <<<"${NETSIMD_LOCK_JSON}")
NETSIMD_SOURCE_BLOB_SHA1=$(jq -r '.files[0].sha1' <<<"${NETSIMD_LOCK_JSON}")
NETSIMD_SOURCE=${WORKSPACE}/$(jq -r '.destination + "/" + .files[0].destination' \
  <<<"${NETSIMD_LOCK_JSON}")
[[ -f "${NETSIMD_SOURCE}" ]] \
  || die 'locked official Google netsimd 0.3.112 helper was not found'
is_x86_64_elf "${NETSIMD_SOURCE}" \
  || die 'locked netsimd helper is not x86_64'
[[ $(git hash-object --no-filters "${NETSIMD_SOURCE}") == \
  "${NETSIMD_SOURCE_BLOB_SHA1}" ]] \
  || die 'locked netsimd helper does not match the approved Git blob'
NETSIMD_INTERPRETER=$(host_elf_interpreter "${NETSIMD_SOURCE}")
[[ "${NETSIMD_INTERPRETER}" == /lib64/ld-linux-x86-64.so.2 ]] \
  || die "unexpected netsimd ELF interpreter: ${NETSIMD_INTERPRETER}"
EXPECTED_NETSIMD_NEEDED=$'ld-linux-x86-64.so.2\nlibc.so.6\nlibdl.so.2\nlibm.so.6\nlibpthread.so.0\nlibrt.so.1'
[[ $(host_needed_names "${NETSIMD_SOURCE}") == "${EXPECTED_NETSIMD_NEEDED}" ]] \
  || die 'locked netsimd system-library dependency set changed'

for executable in "${ENGINE_SOURCE}" "${CRASHPAD_SOURCE}" \
  "${QEMU_IMG_SOURCE}" "${NIMBLE_BRIDGE_SOURCE}"; do
  [[ $(elf_interpreter "${executable}") == /lib/ld-linux-aarch64.so.1 ]] \
    || die "unexpected ELF interpreter for ${executable}"
done

INTERPRETER=$(elf_interpreter "${ENGINE_SOURCE}")
ENGINE_RPATH=$(elf_search_path "${ENGINE_SOURCE}" RPATH)
ENGINE_RUNPATH=$(elf_search_path "${ENGINE_SOURCE}" RUNPATH)
if ! search_path_contains "${ENGINE_RPATH}" '$ORIGIN/lib64' \
  && ! search_path_contains "${ENGINE_RUNPATH}" '$ORIGIN/lib64'; then
  die 'engine ELF search path does not contain $ORIGIN/lib64'
fi
validate_origin_search_path "${ENGINE_RPATH}" RPATH
validate_origin_search_path "${ENGINE_RUNPATH}" RUNPATH

rm -rf -- "${BUNDLE_DIR}"
mkdir -p \
  "${BUNDLE_DIR}/bin" \
  "${BUNDLE_DIR}/libexec/linux-x86_64" \
  "${BUNDLE_DIR}/qemu/linux-aarch64" \
  "${BUNDLE_DIR}/lib/pc-bios" \
  "${BUNDLE_DIR}/lib64/gles_swiftshader" \
  "${BUNDLE_DIR}/lib64/vulkan" \
  "${BUNDLE_DIR}/resources/skins/android-36" \
  "${BUNDLE_DIR}/share/provenance/patches" \
  "${BUNDLE_DIR}/share/licenses"

cp --preserve=mode -- "${ENGINE_SOURCE}" "${BUNDLE_DIR}/${ENGINE_RELATIVE}"
cp --preserve=mode -- "${ENGINE_DIR}/bin/run-qemu-system-aarch64-headless" \
  "${BUNDLE_DIR}/${RUNNER_RELATIVE}"
cp --preserve=mode -- "${ENGINE_DIR}/bin/netsimd" \
  "${BUNDLE_DIR}/${NETSIMD_LAUNCHER_RELATIVE}"
cp --preserve=mode -- "${NETSIMD_SOURCE}" \
  "${BUNDLE_DIR}/${NETSIMD_BINARY_RELATIVE}"
cp --preserve=mode -- "${GFXSTREAM_SOURCE}" "${BUNDLE_DIR}/${GFXSTREAM_RELATIVE}"
cp --preserve=mode -- "${CRASHPAD_SOURCE}" "${BUNDLE_DIR}/${CRASHPAD_RELATIVE}"
cp --preserve=mode -- "${QEMU_IMG_SOURCE}" "${BUNDLE_DIR}/${QEMU_IMG_RELATIVE}"
cp --preserve=mode -- "${NIMBLE_BRIDGE_SOURCE}" "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}"
cp --preserve=mode -- "${VULKAN_LOADER_SOURCE}" \
  "${BUNDLE_DIR}/${VULKAN_LOADER_REAL_RELATIVE}"
ln -s libvulkan.so.1.4.344 "${BUNDLE_DIR}/${VULKAN_LOADER_SONAME_RELATIVE}"
ln -s libvulkan.so.1 "${BUNDLE_DIR}/${VULKAN_LOADER_RELATIVE}"
cp --preserve=mode -- "${VULKAN_ICD_SOURCE}" \
  "${BUNDLE_DIR}/${VULKAN_ICD_RELATIVE}"
cp --preserve=mode -- "${VULKAN_ICD_JSON_SOURCE}" \
  "${BUNDLE_DIR}/${VULKAN_ICD_JSON_RELATIVE}"
cp --preserve=mode -- "${VULKAN_PROBE_SOURCE}" \
  "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}"
[[ $(readlink "${BUNDLE_DIR}/${VULKAN_LOADER_RELATIVE}") == libvulkan.so.1 ]] \
  || die 'Vulkan loader unversioned symlink changed'
[[ $(readlink "${BUNDLE_DIR}/${VULKAN_LOADER_SONAME_RELATIVE}") == \
  libvulkan.so.1.4.344 ]] || die 'Vulkan loader SONAME symlink changed'
ln -s ../../lib64 "${BUNDLE_DIR}/qemu/linux-aarch64/lib64"

PC_BIOS_SOURCE=${WORKSPACE}/external/qemu/pc-bios
[[ -d "${PC_BIOS_SOURCE}" ]] || die 'locked AEMU pc-bios directory is missing'
cp --archive --dereference -- "${PC_BIOS_SOURCE}/." "${BUNDLE_DIR}/lib/pc-bios/"
find "${BUNDLE_DIR}/lib/pc-bios" -type f -print -quit | grep -q . \
  || die 'locked AEMU pc-bios directory is empty'
find "${BUNDLE_DIR}/lib/pc-bios" -type l -print -quit | grep -q . \
  && die 'pc-bios must not contain untracked symbolic links'

while IFS=$'\t' read -r source_path destination_name; do
  [[ -f "${WORKSPACE}/external/qemu/${source_path}" ]] \
    || die "locked AEMU runtime data is missing: ${source_path}"
  cp --preserve=mode -- "${WORKSPACE}/external/qemu/${source_path}" \
    "${BUNDLE_DIR}/lib/${destination_name}"
done <<'EOF'
android/data/advancedFeatures.ini	advancedFeatures.ini
android/data/emu-original-feature-flags.protobuf	emu-original-feature-flags.protobuf
android/data/ca-bundle.pem	ca-bundle.pem
android/data/hostapd.conf	hostapd.conf
android/android-grpc/security/src/android/emulation/control/secure/emulator_access.json	emulator_access.json
EOF

VIRTUALSCENE_SOURCE=${WORKSPACE}/prebuilts/android-emulator-build/common/virtualscene
copy_runtime_tree_flat "${VIRTUALSCENE_SOURCE}/Toren1BD" "${BUNDLE_DIR}/resources"
copy_runtime_tree_flat "${VIRTUALSCENE_SOURCE}/default" "${BUNDLE_DIR}/resources"
SKIN_SOURCE=${WORKSPACE}/prebuilts/android-emulator-build/common/skins/x86_64/android-36
copy_runtime_tree "${SKIN_SOURCE}" "${BUNDLE_DIR}/resources/skins/android-36"
find "${BUNDLE_DIR}/resources" -type f -print -quit | grep -q . \
  || die 'locked AEMU runtime resources are empty'

SWIFTSHADER_SOURCE=${WORKSPACE}/prebuilts/android-emulator-build/common/swiftshader/linux-aarch64/lib
for library in libEGL.so libGLES_CM.so libGLESv2.so; do
  [[ -f "${SWIFTSHADER_SOURCE}/${library}" ]] \
    || die "locked AArch64 SwiftShader library is missing: ${library}"
  is_aarch64_elf "${SWIFTSHADER_SOURCE}/${library}" \
    || die "locked SwiftShader library is not AArch64: ${library}"
  cp --preserve=mode -- "${SWIFTSHADER_SOURCE}/${library}" \
    "${BUNDLE_DIR}/lib64/gles_swiftshader/${library}"
done

QT_X11_LIB_DIR=${WORKSPACE}/prebuilts/android-emulator-build/qt/linux-aarch64/lib
X11_XCB_SOURCE=${QT_X11_LIB_DIR}/libX11-xcb.so.1
[[ -f "${X11_XCB_SOURCE}" ]] \
  || die 'locked AArch64 libX11-xcb.so.1 is missing'
is_aarch64_elf "${X11_XCB_SOURCE}" \
  || die 'locked libX11-xcb.so.1 is not AArch64'
cp --preserve=mode -- "${X11_XCB_SOURCE}" "${BUNDLE_DIR}/${X11_XCB_RELATIVE}"

SEARCH_ROOTS=(
  "${BUILD_DIR}"
  "${WORKSPACE}/prebuilts/android-emulator-build/common"
  "${QT_X11_LIB_DIR}"
  "${WORKSPACE}/prebuilts/android-emulator-build/qemu-android-deps"
  "/usr/aarch64-linux-gnu/lib"
  "/lib/aarch64-linux-gnu"
  "/usr/lib/aarch64-linux-gnu"
  "/usr/lib/gcc-cross/aarch64-linux-gnu"
)

LOADER_SOURCE=$(find_aarch64_file "$(basename -- "${INTERPRETER}")") \
  || die "AArch64 loader was not found for ${INTERPRETER}"
cp --dereference --preserve=mode -- "${LOADER_SOURCE}" \
  "${BUNDLE_DIR}/${LOADER_RELATIVE}"

ELF_ROOTS=(
  "${BUNDLE_DIR}/${ENGINE_RELATIVE}"
  "${BUNDLE_DIR}/${GFXSTREAM_RELATIVE}"
  "${BUNDLE_DIR}/${X11_XCB_RELATIVE}"
  "${BUNDLE_DIR}/${CRASHPAD_RELATIVE}"
  "${BUNDLE_DIR}/${QEMU_IMG_RELATIVE}"
  "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}"
  "${BUNDLE_DIR}/${VULKAN_LOADER_REAL_RELATIVE}"
  "${BUNDLE_DIR}/${VULKAN_ICD_RELATIVE}"
  "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}"
  "${BUNDLE_DIR}/${LOADER_RELATIVE}"
  "${BUNDLE_DIR}/lib64/gles_swiftshader/libEGL.so"
  "${BUNDLE_DIR}/lib64/gles_swiftshader/libGLES_CM.so"
  "${BUNDLE_DIR}/lib64/gles_swiftshader/libGLESv2.so"
)
copy_dependency_closure

while IFS= read -r library; do
  if [[ "${library}" == "${BUNDLE_DIR}/${VULKAN_ICD_JSON_RELATIVE}" ]]; then
    continue
  fi
  is_aarch64_elf "${library}" || die "lib64 contains a non-AArch64 file: ${library}"
done < <(find "${BUNDLE_DIR}/lib64" -type f -print | sort)

while IFS= read -r elf_file; do
  validate_origin_search_path "$(elf_search_path "${elf_file}" RPATH)" RPATH
  validate_origin_search_path "$(elf_search_path "${elf_file}" RUNPATH)" RUNPATH
done < <(
  printf '%s\n' \
    "${BUNDLE_DIR}/${ENGINE_RELATIVE}" \
    "${BUNDLE_DIR}/${CRASHPAD_RELATIVE}" \
    "${BUNDLE_DIR}/${QEMU_IMG_RELATIVE}" \
    "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}" \
    "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}"
  find "${BUNDLE_DIR}/lib64" -type f ! -name '*.json' -print | sort
)

ENGINE_BUILD_ID_BEFORE=$(elf_build_id "${BUNDLE_DIR}/${ENGINE_RELATIVE}")
[[ -n "${ENGINE_BUILD_ID_BEFORE}" ]] || die 'engine has no GNU Build ID before stripping'
while IFS= read -r elf_file; do
  build_id_before=$(elf_build_id "${elf_file}")
  "${STRIP}" --strip-unneeded "${elf_file}"
  is_aarch64_elf "${elf_file}" || die "stripped artifact is not AArch64: ${elf_file}"
  build_id_after=$(elf_build_id "${elf_file}")
  [[ -z "${build_id_before}" || "${build_id_after}" == "${build_id_before}" ]] \
    || die "strip changed or removed the Build ID: ${elf_file}"
done < <(
  printf '%s\n' \
    "${BUNDLE_DIR}/${ENGINE_RELATIVE}" \
    "${BUNDLE_DIR}/${CRASHPAD_RELATIVE}" \
    "${BUNDLE_DIR}/${QEMU_IMG_RELATIVE}" \
    "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}" \
    "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}"
  find "${BUNDLE_DIR}/lib64" -type f ! -name '*.json' -print | sort
)
ENGINE_BUILD_ID=$(elf_build_id "${BUNDLE_DIR}/${ENGINE_RELATIVE}")
[[ "${ENGINE_BUILD_ID}" == "${ENGINE_BUILD_ID_BEFORE}" ]] \
  || die 'engine Build ID changed while stripping'

cp -- "${LOCK_FILE}" "${BUNDLE_DIR}/share/provenance/sources.lock.json"
while IFS= read -r patch_path; do
  cp -- "${ENGINE_DIR}/${patch_path}" \
    "${BUNDLE_DIR}/share/provenance/patches/$(basename -- "${patch_path}")"
done < <(jq -r '.patches[] | .[]' "${LOCK_FILE}")

while IFS= read -r license_file; do
  cp -- "${license_file}" "${BUNDLE_DIR}/share/licenses/$(basename -- "${license_file}")"
done < <(find "${WORKSPACE}/external/qemu" -maxdepth 1 -type f \
  \( -name 'LICENSE*' -o -name 'NOTICE*' \) -print | sort)
for licensed_source in \
  "${WORKSPACE}/external/vulkan-loader/LICENSE.txt:Vulkan-Loader-LICENSE.txt" \
  "${WORKSPACE}/external/vulkan-headers/LICENSE.md:Vulkan-Headers-LICENSE.md" \
  "${WORKSPACE}/external/swiftshader/LICENSE.txt:SwiftShader-LICENSE.txt"; do
  source_path=${licensed_source%%:*}
  destination_name=${licensed_source#*:}
  [[ -f "${source_path}" ]] || die "locked Vulkan license is missing: ${source_path}"
  cp -- "${source_path}" "${BUNDLE_DIR}/share/licenses/${destination_name}"
done

chmod 0755 \
  "${BUNDLE_DIR}/${ENGINE_RELATIVE}" \
  "${BUNDLE_DIR}/${RUNNER_RELATIVE}" \
  "${BUNDLE_DIR}/${NETSIMD_LAUNCHER_RELATIVE}" \
  "${BUNDLE_DIR}/${NETSIMD_BINARY_RELATIVE}" \
  "${BUNDLE_DIR}/${CRASHPAD_RELATIVE}" \
  "${BUNDLE_DIR}/${QEMU_IMG_RELATIVE}" \
  "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}" \
  "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}" \
  "${BUNDLE_DIR}/${LOADER_RELATIVE}"
find "${BUNDLE_DIR}/lib64" -type f ! -name ld-linux-aarch64.so.1 \
  -exec chmod 0644 {} +

sh -n "${BUNDLE_DIR}/${NETSIMD_LAUNCHER_RELATIVE}"
NETSIMD_VERSION_OUTPUT=$("${BUNDLE_DIR}/${NETSIMD_LAUNCHER_RELATIVE}" --version 2>&1) \
  || die 'locked netsimd helper did not execute on the amd64 build platform'
grep -Eq '(^|[^0-9])0\.3\.112([^0-9]|$)' <<<"${NETSIMD_VERSION_OUTPUT}" \
  || die "unexpected netsimd version output: ${NETSIMD_VERSION_OUTPUT}"

ENGINE_NEEDED_JSON=$(needed_names "${BUNDLE_DIR}/${ENGINE_RELATIVE}" \
  | jq -R . | jq -s .)
LIBRARIES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/lib64" lib64 | jq -s .)
PC_BIOS_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/lib/pc-bios" lib/pc-bios | jq -s .)
DATA_FILES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/lib" lib | jq -s .)
RESOURCE_FILES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/resources" resources | jq -s .)
PATCHES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/share/provenance/patches" \
  share/provenance/patches | jq -s .)
NETSIMD_SHA256=$(sha256sum "${BUNDLE_DIR}/${NETSIMD_BINARY_RELATIVE}" \
  | awk '{print $1}')
NETSIMD_NEEDED_JSON=$(host_needed_names "${BUNDLE_DIR}/${NETSIMD_BINARY_RELATIVE}" \
  | jq -R . | jq -s .)
VULKAN_LOADER_SHA256=$(sha256sum "${BUNDLE_DIR}/${VULKAN_LOADER_REAL_RELATIVE}" \
  | awk '{print $1}')
VULKAN_ICD_SHA256=$(sha256sum "${BUNDLE_DIR}/${VULKAN_ICD_RELATIVE}" \
  | awk '{print $1}')
VULKAN_ICD_JSON_SHA256=$(sha256sum "${BUNDLE_DIR}/${VULKAN_ICD_JSON_RELATIVE}" \
  | awk '{print $1}')
VULKAN_PROBE_SHA256=$(sha256sum "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}" \
  | awk '{print $1}')
VULKAN_LOADER_NEEDED_JSON=$(needed_names \
  "${BUNDLE_DIR}/${VULKAN_LOADER_REAL_RELATIVE}" | jq -R . | jq -s .)
VULKAN_ICD_NEEDED_JSON=$(needed_names "${BUNDLE_DIR}/${VULKAN_ICD_RELATIVE}" \
  | jq -R . | jq -s .)
VULKAN_PROBE_NEEDED_JSON=$(needed_names "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}" \
  | jq -R . | jq -s .)
VULKAN_PROBE_BUILD_ID=$(elf_build_id "${BUNDLE_DIR}/${VULKAN_PROBE_RELATIVE}")
[[ -n "${VULKAN_PROBE_BUILD_ID}" ]] || die 'Vulkan probe has no GNU Build ID'
VULKAN_LOADER_LOCK_JSON=$(jq -ce '.sources[] | select(.id == "vulkan-loader")' \
  "${LOCK_FILE}")
VULKAN_HEADERS_LOCK_JSON=$(jq -ce '.sources[] | select(.id == "vulkan-headers")' \
  "${LOCK_FILE}")
VULKAN_SWIFTSHADER_LOCK_JSON=$(jq -ce \
  '.sources[] | select(.id == "swiftshader-vulkan")' "${LOCK_FILE}")
SOURCE_LOCK_SHA256=$(sha256sum "${BUNDLE_DIR}/share/provenance/sources.lock.json" \
  | awk '{print $1}')
PATCH_SET_SHA256=$(patch_set_sha256)
REVISION=$(jq -r '.aemu_revision' "${LOCK_FILE}")

[[ -z "${NATIVE_AEMU_REVISION}" || "${REVISION}" == "${NATIVE_AEMU_REVISION}" ]] \
  || die "revision identity mismatch: expected ${NATIVE_AEMU_REVISION}, got ${REVISION}"
[[ -z "${NATIVE_AEMU_SOURCE_LOCK_SHA256}" \
  || "${SOURCE_LOCK_SHA256}" == "${NATIVE_AEMU_SOURCE_LOCK_SHA256}" ]] \
  || die 'source-lock identity digest mismatch'
[[ -z "${NATIVE_AEMU_PATCH_SET_SHA256}" \
  || "${PATCH_SET_SHA256}" == "${NATIVE_AEMU_PATCH_SET_SHA256}" ]] \
  || die 'patch-set identity digest mismatch'

printf '%s\n' \
  "revision=${REVISION}" \
  "source_lock_sha256=${SOURCE_LOCK_SHA256}" \
  "patch_set_sha256=${PATCH_SET_SHA256}" \
  > "${BUNDLE_DIR}/identity.properties"

jq -n \
  --arg product cloudandx-aemu-native-engine \
  --arg revision "${REVISION}" \
  --arg architecture arm64 \
  --arg binary "/opt/cloudandx/native-aemu/${ENGINE_RELATIVE}" \
  --arg runner "/opt/cloudandx/native-aemu/${RUNNER_RELATIVE}" \
  --arg loader "/opt/cloudandx/native-aemu/${LOADER_RELATIVE}" \
  --arg gfxstream_backend "/opt/cloudandx/native-aemu/${GFXSTREAM_RELATIVE}" \
  --arg x11_xcb "/opt/cloudandx/native-aemu/${X11_XCB_RELATIVE}" \
  --arg crashpad_handler "/opt/cloudandx/native-aemu/${CRASHPAD_RELATIVE}" \
  --arg qemu_img "/opt/cloudandx/native-aemu/${QEMU_IMG_RELATIVE}" \
  --arg nimble_bridge "/opt/cloudandx/native-aemu/${NIMBLE_BRIDGE_RELATIVE}" \
  --arg vulkan_probe "/opt/cloudandx/native-aemu/${VULKAN_PROBE_RELATIVE}" \
  --arg vulkan_loader "/opt/cloudandx/native-aemu/${VULKAN_LOADER_RELATIVE}" \
  --arg vulkan_loader_soname "/opt/cloudandx/native-aemu/${VULKAN_LOADER_SONAME_RELATIVE}" \
  --arg vulkan_loader_real "/opt/cloudandx/native-aemu/${VULKAN_LOADER_REAL_RELATIVE}" \
  --arg vulkan_icd "/opt/cloudandx/native-aemu/${VULKAN_ICD_RELATIVE}" \
  --arg vulkan_icd_json "/opt/cloudandx/native-aemu/${VULKAN_ICD_JSON_RELATIVE}" \
  --arg vulkan_loader_sha256 "${VULKAN_LOADER_SHA256}" \
  --arg vulkan_icd_sha256 "${VULKAN_ICD_SHA256}" \
  --arg vulkan_icd_json_sha256 "${VULKAN_ICD_JSON_SHA256}" \
  --arg vulkan_probe_sha256 "${VULKAN_PROBE_SHA256}" \
  --arg vulkan_probe_build_id "${VULKAN_PROBE_BUILD_ID}" \
  --arg netsimd_launcher "/opt/cloudandx/native-aemu/${NETSIMD_LAUNCHER_RELATIVE}" \
  --arg netsimd_binary "/opt/cloudandx/native-aemu/${NETSIMD_BINARY_RELATIVE}" \
  --arg netsimd_version "${NETSIMD_VERSION}" \
  --arg netsimd_interpreter "${NETSIMD_INTERPRETER}" \
  --arg netsimd_sha256 "${NETSIMD_SHA256}" \
  --arg netsimd_lock_id "common-netsimd-linux-x86_64" \
  --arg netsimd_repository "${NETSIMD_SOURCE_REPOSITORY}" \
  --arg netsimd_commit "${NETSIMD_SOURCE_COMMIT}" \
  --arg netsimd_tree "${NETSIMD_SOURCE_TREE}" \
  --arg netsimd_source_path "${NETSIMD_SOURCE_PATH}" \
  --arg netsimd_blob_sha1 "${NETSIMD_SOURCE_BLOB_SHA1}" \
  --arg pc_bios /opt/cloudandx/native-aemu/lib/pc-bios \
  --arg swiftshader /opt/cloudandx/native-aemu/lib64/gles_swiftshader \
  --arg swiftshader_egl /opt/cloudandx/native-aemu/lib64/gles_swiftshader/libEGL.so \
  --arg swiftshader_gles_cm /opt/cloudandx/native-aemu/lib64/gles_swiftshader/libGLES_CM.so \
  --arg swiftshader_gles_v2 /opt/cloudandx/native-aemu/lib64/gles_swiftshader/libGLESv2.so \
  --arg resources /opt/cloudandx/native-aemu/resources \
  --arg execution_model direct-engine \
  --arg interpreter "${INTERPRETER}" \
  --arg rpath "${ENGINE_RPATH}" \
  --arg runpath "${ENGINE_RUNPATH}" \
  --arg build_id "${ENGINE_BUILD_ID}" \
  --arg library_path "${LIBRARY_PATH}" \
  --arg source_lock_sha256 "${SOURCE_LOCK_SHA256}" \
  --arg patch_set_sha256 "${PATCH_SET_SHA256}" \
  --argjson engine_needed "${ENGINE_NEEDED_JSON}" \
  --argjson netsimd_needed "${NETSIMD_NEEDED_JSON}" \
  --argjson vulkan_loader_needed "${VULKAN_LOADER_NEEDED_JSON}" \
  --argjson vulkan_icd_needed "${VULKAN_ICD_NEEDED_JSON}" \
  --argjson vulkan_probe_needed "${VULKAN_PROBE_NEEDED_JSON}" \
  --argjson vulkan_loader_source "${VULKAN_LOADER_LOCK_JSON}" \
  --argjson vulkan_headers_source "${VULKAN_HEADERS_LOCK_JSON}" \
  --argjson vulkan_swiftshader_source "${VULKAN_SWIFTSHADER_LOCK_JSON}" \
  --argjson libraries "${LIBRARIES_JSON}" \
  --argjson pc_bios_files "${PC_BIOS_JSON}" \
  --argjson data_files "${DATA_FILES_JSON}" \
  --argjson resource_files "${RESOURCE_FILES_JSON}" \
  --argjson patches "${PATCHES_JSON}" \
  '{
    schema_version: 2,
    product: $product,
    revision: $revision,
    architecture: $architecture,
    binary: $binary,
    runner: $runner,
    loader: $loader,
    helpers: {
      gfxstream_backend: $gfxstream_backend,
      crashpad_handler: $crashpad_handler,
      qemu_img: $qemu_img,
      nimble_bridge: $nimble_bridge,
      netsimd: $netsimd_launcher,
      vulkan_smoke: $vulkan_probe
    },
    mixed_arch_helpers: {
      netsimd: {
        architecture: "x86_64",
        version: $netsimd_version,
        launcher: $netsimd_launcher,
        binary: $netsimd_binary,
        interpreter: $netsimd_interpreter,
        sha256: $netsimd_sha256,
        dt_needed: $netsimd_needed,
        included_in_aarch64_dt_needed_closure: false,
        source: {
          lock_id: $netsimd_lock_id,
          repository: $netsimd_repository,
          commit: $netsimd_commit,
          tree: $netsimd_tree,
          path: $netsimd_source_path,
          git_blob_sha1: $netsimd_blob_sha1
        }
      }
    },
    runtime_dlopen: {
      gfxstream_backend: $gfxstream_backend,
      x11_xcb: $x11_xcb,
      swiftshader_egl: $swiftshader_egl,
      swiftshader_gles_cm: $swiftshader_gles_cm,
      swiftshader_gles_v2: $swiftshader_gles_v2,
      vulkan_loader: $vulkan_loader,
      swiftshader_vulkan_icd: $vulkan_icd,
      swiftshader_vulkan_manifest: $vulkan_icd_json
    },
    vulkan: {
      loader: {
        path: $vulkan_loader,
        soname_path: $vulkan_loader_soname,
        real_path: $vulkan_loader_real,
        version: "1.4.344",
        soname: "libvulkan.so.1",
        sha256: $vulkan_loader_sha256,
        dt_needed: $vulkan_loader_needed,
        source: $vulkan_loader_source
      },
      headers_source: $vulkan_headers_source,
      swiftshader_icd: {
        path: $vulkan_icd,
        manifest: $vulkan_icd_json,
        manifest_file_format_version: "1.0.0",
        manifest_api_version: "1.0.5",
        manifest_library_path: "./libvk_swiftshader.so",
        sha256: $vulkan_icd_sha256,
        manifest_sha256: $vulkan_icd_json_sha256,
        dt_needed: $vulkan_icd_needed,
        source: $vulkan_swiftshader_source
      },
      smoke_probe: {
        path: $vulkan_probe,
        sha256: $vulkan_probe_sha256,
        build_id: $vulkan_probe_build_id,
        dt_needed: $vulkan_probe_needed,
        verifies: ["instance", "physical-device", "device", "queue", "submit", "fence"]
      }
    },
    data: {
      pc_bios: $pc_bios,
      pc_bios_files: $pc_bios_files,
      swiftshader: $swiftshader,
      resources: $resources,
      resource_files: $resource_files,
      files: $data_files
    },
    execution: {
      model: $execution_model,
      interpreter: $interpreter,
      rpath: $rpath,
      runpath: $runpath,
      build_id: $build_id,
      library_path: $library_path,
      audio_driver: "none"
    },
    engine_dt_needed: $engine_needed,
    libraries: $libraries,
    provenance: {
      source_lock: "share/provenance/sources.lock.json",
      source_lock_sha256: $source_lock_sha256,
      patch_set_sha256: $patch_set_sha256,
      patches: $patches
    }
  }' > "${BUNDLE_DIR}/manifest.json"

find "${BUNDLE_DIR}" -depth -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +

(
  cd "${BUNDLE_DIR}"
  find . -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | while IFS= read -r -d '' path; do
        sha256sum "${path#./}"
      done > SHA256SUMS
  touch -d "@${SOURCE_DATE_EPOCH}" SHA256SUMS
)
