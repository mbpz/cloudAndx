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

find_engine() {
  local candidate
  local -a preferred=(
    "${BUILD_DIR}/qemu-system-x86_64-headless"
    "${BUILD_DIR}/qemu/linux-aarch64/qemu-system-x86_64-headless"
    "${BUILD_DIR}/build/linux-aarch64/qemu-system-x86_64-headless"
    "${BUILD_DIR}/distribution/emulator/lib64/qemu/linux-aarch64/qemu-system-x86_64-headless"
  )

  for candidate in "${preferred[@]}"; do
    if [[ -f "${candidate}" ]] && is_aarch64_elf "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  while IFS= read -r candidate; do
    if is_aarch64_elf "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(find "${BUILD_DIR}" -type f -name qemu-system-x86_64-headless -print | sort)
  return 1
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
  local current needed resolved output copied_name already_copied index=0
  local -a queue=("${BUNDLE_DIR}/bin/qemu-system-x86_64-headless" "${BUNDLE_DIR}/lib/ld-linux-aarch64.so.1")
  local -a copied=()

  while ((index < ${#queue[@]})); do
    current=${queue[index++]}
    while IFS= read -r needed; do
      [[ -n "${needed}" ]] || continue
      already_copied=false
      for copied_name in "${copied[@]}"; do
        if [[ "${copied_name}" == "${needed}" ]]; then
          already_copied=true
          break
        fi
      done
      [[ "${already_copied}" == false ]] || continue
      resolved=$(find_aarch64_file "${needed}") \
        || die "unresolved AArch64 DT_NEEDED entry ${needed} from ${current}"
      output=${BUNDLE_DIR}/lib/${needed}
      cp --dereference --preserve=mode -- "${resolved}" "${output}"
      is_aarch64_elf "${output}" || die "resolved dependency is not AArch64: ${resolved}"
      copied+=("${needed}")
      queue+=("${output}")
    done < <(needed_names "${current}")
  done
}

make_json_file_list() {
  local directory=$1 relative_prefix=$2 path relative sha

  while IFS= read -r path; do
    relative=${relative_prefix}/$(basename -- "${path}")
    sha=$(sha256sum "${path}" | awk '{print $1}')
    jq -n --arg path "${relative}" --arg sha256 "${sha}" \
      '{path: $path, sha256: $sha256}'
  done < <(find "${directory}" -maxdepth 1 -type f -print | sort)
}

ENGINE_SOURCE=$(find_engine) || die 'AArch64 qemu-system-x86_64-headless was not found'
is_aarch64_elf "${ENGINE_SOURCE}" || die "engine is not AArch64: ${ENGINE_SOURCE}"

rm -rf -- "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/bin" "${BUNDLE_DIR}/lib" \
  "${BUNDLE_DIR}/share/provenance/patches" "${BUNDLE_DIR}/share/licenses"
cp --preserve=mode -- "${ENGINE_SOURCE}" \
  "${BUNDLE_DIR}/bin/qemu-system-x86_64-headless"
cp --preserve=mode -- "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless" \
  "${BUNDLE_DIR}/bin/run-qemu-system-x86_64-headless"

INTERPRETER=$("${READELF}" -l "${ENGINE_SOURCE}" \
  | sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p')
[[ -n "${INTERPRETER}" ]] || die 'engine has no ELF program interpreter'

SEARCH_ROOTS=(
  "${BUILD_DIR}"
  "${WORKSPACE}/prebuilts/android-emulator-build/common"
  "${WORKSPACE}/prebuilts/android-emulator-build/qemu-android-deps"
  "/usr/aarch64-linux-gnu/lib"
  "/lib/aarch64-linux-gnu"
  "/usr/lib/aarch64-linux-gnu"
  "/usr/lib/gcc-cross/aarch64-linux-gnu"
)

LOADER_SOURCE=$(find_aarch64_file "$(basename -- "${INTERPRETER}")") \
  || die "AArch64 loader was not found for ${INTERPRETER}"
cp --dereference --preserve=mode -- "${LOADER_SOURCE}" \
  "${BUNDLE_DIR}/lib/ld-linux-aarch64.so.1"

copy_dependency_closure

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
  "${BUNDLE_DIR}/bin/qemu-system-x86_64-headless" \
  "${BUNDLE_DIR}/bin/run-qemu-system-x86_64-headless" \
  "${BUNDLE_DIR}/lib/ld-linux-aarch64.so.1"
find "${BUNDLE_DIR}/lib" -maxdepth 1 -type f ! -name ld-linux-aarch64.so.1 \
  -exec chmod 0644 {} +

ENGINE_NEEDED_JSON=$(needed_names "${BUNDLE_DIR}/bin/qemu-system-x86_64-headless" \
  | jq -R . | jq -s .)
LIBRARIES_JSON=$(make_json_file_list "${BUNDLE_DIR}/lib" lib | jq -s .)
PATCHES_JSON=$(make_json_file_list "${BUNDLE_DIR}/share/provenance/patches" \
  share/provenance/patches | jq -s .)
SOURCE_LOCK_SHA256=$(sha256sum "${BUNDLE_DIR}/share/provenance/sources.lock.json" \
  | awk '{print $1}')

jq -n \
  --arg product cloudandx-aemu-native-engine \
  --arg revision 37.1.7 \
  --arg architecture arm64 \
  --arg binary /opt/cloudandx/native-aemu/bin/qemu-system-x86_64-headless \
  --arg runner /opt/cloudandx/native-aemu/bin/run-qemu-system-x86_64-headless \
  --arg loader /opt/cloudandx/native-aemu/lib/ld-linux-aarch64.so.1 \
  --arg source_lock_sha256 "${SOURCE_LOCK_SHA256}" \
  --argjson engine_needed "${ENGINE_NEEDED_JSON}" \
  --argjson libraries "${LIBRARIES_JSON}" \
  --argjson patches "${PATCHES_JSON}" \
  '{
    schema_version: 1,
    product: $product,
    revision: $revision,
    architecture: $architecture,
    binary: $binary,
    runner: $runner,
    loader: $loader,
    engine_dt_needed: $engine_needed,
    libraries: $libraries,
    provenance: {
      source_lock: "share/provenance/sources.lock.json",
      source_lock_sha256: $source_lock_sha256,
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
