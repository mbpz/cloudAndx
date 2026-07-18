#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
LOCK_FILE=${LOCK_FILE:-${ENGINE_DIR}/sources.lock.json}
WORKSPACE=${WORKSPACE:-/workspace}
BUILD_DIR=${BUILD_DIR:-/out/build}
BUNDLE_DIR=${BUNDLE_DIR:-/out/bundle/opt/cloudandx/native-aemu}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(jq -r '.source_date_epoch' "${LOCK_FILE}")}
READELF=${READELF:-aarch64-linux-gnu-readelf}
STRIP=${STRIP:-aarch64-linux-gnu-strip}
NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION:-}
NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256:-}
NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256:-}

ENGINE_RELATIVE=qemu/linux-aarch64/qemu-system-x86_64-headless
RUNNER_RELATIVE=bin/run-qemu-system-x86_64-headless
LOADER_RELATIVE=lib64/ld-linux-aarch64.so.1
GFXSTREAM_RELATIVE=lib64/libgfxstream_backend.so
X11_XCB_RELATIVE=lib64/libX11-xcb.so.1
CRASHPAD_RELATIVE=crashpad_handler
QEMU_IMG_RELATIVE=qemu-img
NIMBLE_BRIDGE_RELATIVE=nimble_bridge
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

needed_names() {
  local path=$1
  "${READELF}" -d "${path}" 2>/dev/null \
    | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' \
    | sort -u
}

elf_interpreter() {
  local path=$1
  "${READELF}" -l "${path}" 2>/dev/null \
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

ENGINE_SOURCE=$(find_build_artifact qemu-system-x86_64-headless) \
  || die 'AArch64 qemu-system-x86_64-headless was not found'
GFXSTREAM_SOURCE=$(find_build_artifact libgfxstream_backend.so) \
  || die 'AArch64 libgfxstream_backend.so was not found'
CRASHPAD_SOURCE=$(find_build_artifact crashpad_handler) \
  || die 'AArch64 crashpad_handler was not found'
QEMU_IMG_SOURCE=$(find_build_artifact qemu-img) \
  || die 'AArch64 qemu-img was not found'
NIMBLE_BRIDGE_SOURCE=$(find_build_artifact nimble_bridge) \
  || die 'AArch64 nimble_bridge was not found'

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
  "${BUNDLE_DIR}/qemu/linux-aarch64" \
  "${BUNDLE_DIR}/lib/pc-bios" \
  "${BUNDLE_DIR}/lib64/gles_swiftshader" \
  "${BUNDLE_DIR}/resources/skins/android-36" \
  "${BUNDLE_DIR}/share/provenance/patches" \
  "${BUNDLE_DIR}/share/licenses"

cp --preserve=mode -- "${ENGINE_SOURCE}" "${BUNDLE_DIR}/${ENGINE_RELATIVE}"
cp --preserve=mode -- "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless" \
  "${BUNDLE_DIR}/${RUNNER_RELATIVE}"
cp --preserve=mode -- "${GFXSTREAM_SOURCE}" "${BUNDLE_DIR}/${GFXSTREAM_RELATIVE}"
cp --preserve=mode -- "${CRASHPAD_SOURCE}" "${BUNDLE_DIR}/${CRASHPAD_RELATIVE}"
cp --preserve=mode -- "${QEMU_IMG_SOURCE}" "${BUNDLE_DIR}/${QEMU_IMG_RELATIVE}"
cp --preserve=mode -- "${NIMBLE_BRIDGE_SOURCE}" "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}"
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
  "${BUNDLE_DIR}/${LOADER_RELATIVE}"
  "${BUNDLE_DIR}/lib64/gles_swiftshader/libEGL.so"
  "${BUNDLE_DIR}/lib64/gles_swiftshader/libGLES_CM.so"
  "${BUNDLE_DIR}/lib64/gles_swiftshader/libGLESv2.so"
)
copy_dependency_closure

while IFS= read -r library; do
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
    "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}"
  find "${BUNDLE_DIR}/lib64" -type f -print | sort
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
    "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}"
  find "${BUNDLE_DIR}/lib64" -type f -print | sort
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

chmod 0755 \
  "${BUNDLE_DIR}/${ENGINE_RELATIVE}" \
  "${BUNDLE_DIR}/${RUNNER_RELATIVE}" \
  "${BUNDLE_DIR}/${CRASHPAD_RELATIVE}" \
  "${BUNDLE_DIR}/${QEMU_IMG_RELATIVE}" \
  "${BUNDLE_DIR}/${NIMBLE_BRIDGE_RELATIVE}" \
  "${BUNDLE_DIR}/${LOADER_RELATIVE}"
find "${BUNDLE_DIR}/lib64" -type f ! -name ld-linux-aarch64.so.1 \
  -exec chmod 0644 {} +

ENGINE_NEEDED_JSON=$(needed_names "${BUNDLE_DIR}/${ENGINE_RELATIVE}" \
  | jq -R . | jq -s .)
LIBRARIES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/lib64" lib64 | jq -s .)
PC_BIOS_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/lib/pc-bios" lib/pc-bios | jq -s .)
DATA_FILES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/lib" lib | jq -s .)
RESOURCE_FILES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/resources" resources | jq -s .)
PATCHES_JSON=$(make_json_tree_file_list "${BUNDLE_DIR}/share/provenance/patches" \
  share/provenance/patches | jq -s .)
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
      nimble_bridge: $nimble_bridge
    },
    runtime_dlopen: {
      gfxstream_backend: $gfxstream_backend,
      x11_xcb: $x11_xcb,
      swiftshader_egl: $swiftshader_egl,
      swiftshader_gles_cm: $swiftshader_gles_cm,
      swiftshader_gles_v2: $swiftshader_gles_v2
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
      library_path: $library_path
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
