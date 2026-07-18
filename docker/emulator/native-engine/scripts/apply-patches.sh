#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
LOCK_FILE=${LOCK_FILE:-${ENGINE_DIR}/sources.lock.json}
WORKSPACE=${WORKSPACE:-/workspace}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(jq -r '.source_date_epoch' "${LOCK_FILE}")}

die() {
  printf 'apply-patches: %s\n' "$*" >&2
  exit 1
}

apply_series() {
  local lock_key=$1 source_dir=$2 patch_file

  [[ -d "${source_dir}" ]] || die "source directory not found: ${source_dir}"
  while IFS= read -r patch_file; do
    [[ -f "${ENGINE_DIR}/${patch_file}" ]] || die "patch not found: ${patch_file}"
    printf 'apply-patches: %s -> %s\n' "${patch_file}" "${lock_key}"
    patch --directory="${source_dir}" --strip=1 --fuzz=0 --batch --dry-run \
      < "${ENGINE_DIR}/${patch_file}"
    patch --directory="${source_dir}" --strip=1 --fuzz=0 --batch \
      < "${ENGINE_DIR}/${patch_file}"
  done < <(jq -r --arg key "${lock_key}" '.patches[$key][]' "${LOCK_FILE}")
}

[[ $(jq -r '.aemu_revision' "${LOCK_FILE}") == 37.1.7 ]] \
  || die 'unexpected AEMU revision in source lock'

apply_series aemu "${WORKSPACE}/external/qemu"
apply_series protobuf "${WORKSPACE}/external/protobuf"
apply_series crashpad "${WORKSPACE}/external/crashpad"

rm -rf -- "${WORKSPACE}/prebuilts/clang"
mkdir -p "${WORKSPACE}/prebuilts/clang"

find "${WORKSPACE}" -depth -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
