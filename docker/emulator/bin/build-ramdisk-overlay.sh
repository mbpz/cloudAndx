#!/bin/sh
set -eu

if [ "$#" -ne 7 ]; then
  printf >&2 'Usage: %s INPUT_RAMDISK OUTPUT_DIR TIMEOUT_MULTIPLIER OFFICIAL_RAMDISK_SHA256 OFFICIAL_CPIO_SHA256 DERIVED_RAMDISK_SHA256 OVERLAY_PATH\n' "$0"
  exit 64
fi

input_ramdisk=$1
output_dir=$2
timeout_multiplier=$3
official_ramdisk_sha256=$4
official_cpio_sha256=$5
derived_ramdisk_sha256=$6
overlay_path=$7

case ${timeout_multiplier} in
  ''|*[!0-9]*)
    printf >&2 'Invalid timeout multiplier: %s\n' "${timeout_multiplier}"
    exit 64
    ;;
esac
[ "${timeout_multiplier}" -ge 1 ] || {
  printf >&2 'Timeout multiplier must be positive.\n'
  exit 64
}

case ${official_ramdisk_sha256}:${official_cpio_sha256} in
  *[!0-9a-f:]*|*::*|:*)
    printf >&2 'Official ramdisk identities must be lowercase SHA-256 values.\n'
    exit 64
    ;;
esac
[ "${#official_ramdisk_sha256}" -eq 64 ]
[ "${#official_cpio_sha256}" -eq 64 ]
if [ "${derived_ramdisk_sha256}" != - ]; then
  case ${derived_ramdisk_sha256} in
    *[!0-9a-f]*)
      printf >&2 'Derived ramdisk identity must be a lowercase SHA-256 value.\n'
      exit 64
      ;;
  esac
  [ "${#derived_ramdisk_sha256}" -eq 64 ]
fi
[ "${overlay_path}" = system/etc/ramdisk/build.prop ] || {
  printf >&2 'Unsupported Android second-stage property path: %s\n' "${overlay_path}"
  exit 64
}

for command_name in cpio dd lz4 sha256sum od stat; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf >&2 'Required build command is unavailable: %s\n' "${command_name}"
    exit 69
  }
done
[ -s "${input_ramdisk}" ] || {
  printf >&2 'Official ramdisk is missing: %s\n' "${input_ramdisk}"
  exit 66
}

umask 022
work_dir=$(mktemp -d)
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT INT TERM HUP

official_cpio=${work_dir}/official.cpio
overlay_cpio=${work_dir}/overlay.cpio
combined_cpio=${work_dir}/combined.cpio
verified_cpio=${work_dir}/verified.cpio
verified_overlay=${work_dir}/verified-overlay
property_value=ro.hw_timeout_multiplier=${timeout_multiplier}

printf '%s  %s\n' "${official_ramdisk_sha256}" "${input_ramdisk}" \
  | sha256sum --check --strict -
[ "$(od -An -tx1 -N4 "${input_ramdisk}" | tr -d ' \n')" = 02214c18 ] || {
  printf >&2 'Official ramdisk is not a legacy LZ4 stream.\n'
  exit 65
}
lz4 -d -q "${input_ramdisk}" "${official_cpio}"
printf '%s  %s\n' "${official_cpio_sha256}" "${official_cpio}" \
  | sha256sum --check --strict -

if cpio --quiet --list <"${official_cpio}" \
  | sed 's#^\./##' | grep -Fxq "${overlay_path}"; then
  printf >&2 'Official ramdisk unexpectedly already contains %s; refusing to truncate it.\n' \
    "${overlay_path}"
  exit 65
fi

property_file=${work_dir}/build.prop
printf '%s\n' "${property_value}" >"${property_file}"
: >"${overlay_cpio}"
newc_inode=1

append_zero_bytes() {
  zero_count=$1
  if [ "${zero_count}" -gt 0 ]; then
    dd if=/dev/zero bs=1 count="${zero_count}" status=none >>"${overlay_cpio}"
  fi
}

append_newc_entry() {
  newc_name=$1
  newc_mode=$2
  newc_source=${3-}
  newc_size=0
  if [ -n "${newc_source}" ]; then
    newc_size=$(wc -c <"${newc_source}" | tr -d ' ')
  fi
  newc_namesize=$((${#newc_name} + 1))
  printf '070701%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x' \
    "${newc_inode}" "${newc_mode}" 0 0 1 0 "${newc_size}" 0 0 0 0 \
    "${newc_namesize}" 0 >>"${overlay_cpio}"
  printf '%s\000' "${newc_name}" >>"${overlay_cpio}"
  append_zero_bytes "$(( (4 - ((110 + newc_namesize) % 4)) % 4 ))"
  if [ -n "${newc_source}" ]; then
    cat "${newc_source}" >>"${overlay_cpio}"
    append_zero_bytes "$(( (4 - (newc_size % 4)) % 4 ))"
  fi
  newc_inode=$((newc_inode + 1))
}

# Generate newc directly so inode and directory-link fields do not inherit
# overlayfs/tmpfs behavior from the builder's backing filesystem.
append_newc_entry system 16877
append_newc_entry system/etc 16877
append_newc_entry system/etc/ramdisk 16877
append_newc_entry "${overlay_path}" 33188 "${property_file}"
append_newc_entry TRAILER!!! 0
overlay_size=$(wc -c <"${overlay_cpio}" | tr -d ' ')
append_zero_bytes "$(( (512 - (overlay_size % 512)) % 512 ))"
cat "${official_cpio}" "${overlay_cpio}" >"${combined_cpio}"
lz4 -l -q -f "${combined_cpio}" "${work_dir}/derived-ramdisk.img"
lz4 -d -q "${work_dir}/derived-ramdisk.img" "${verified_cpio}"
cmp -s "${combined_cpio}" "${verified_cpio}" || {
  printf >&2 'Derived ramdisk failed its decompression round trip.\n'
  exit 65
}

official_cpio_size=$(wc -c <"${official_cpio}" | tr -d ' ')
head -c "${official_cpio_size}" "${verified_cpio}" \
  | sha256sum | grep -Fq "${official_cpio_sha256}  -" || {
  printf >&2 'Derived ramdisk does not preserve the official cpio as an exact prefix.\n'
  exit 65
}
tail -c "+$((official_cpio_size + 1))" "${verified_cpio}" >"${work_dir}/verified-overlay.cpio"
mkdir -p "${verified_overlay}"
(
  cd "${verified_overlay}"
  cpio --quiet --extract --make-directories --no-absolute-filenames \
    <"${work_dir}/verified-overlay.cpio"
)
[ "$(find "${verified_overlay}" -mindepth 1 -printf '%P\n' | LC_ALL=C sort)" = \
  "$(printf '%s\n' system system/etc system/etc/ramdisk "${overlay_path}")" ] || {
  printf >&2 'Derived ramdisk overlay contains an unexpected path.\n'
  exit 65
}
[ "$(stat -c '%a %u:%g' "${verified_overlay}/${overlay_path}")" = '644 0:0' ] || {
  printf >&2 'Derived property file has unexpected mode or ownership.\n'
  exit 65
}
property_sha256=$(printf '%s\n' "${property_value}" | sha256sum | cut -d' ' -f1)
[ "$(sha256sum "${verified_overlay}/${overlay_path}" | cut -d' ' -f1)" = \
  "${property_sha256}" ] || {
  printf >&2 'Derived property file content is not exact.\n'
  exit 65
}

actual_derived_sha256=$(sha256sum "${work_dir}/derived-ramdisk.img" | cut -d' ' -f1)
if [ "${derived_ramdisk_sha256}" != - ] \
  && [ "${actual_derived_sha256}" != "${derived_ramdisk_sha256}" ]; then
  printf >&2 'Derived ramdisk SHA-256 mismatch: expected %s, got %s\n' \
    "${derived_ramdisk_sha256}" "${actual_derived_sha256}"
  exit 65
fi

mkdir -p "${output_dir}"
[ ! -e "${output_dir}/official-ramdisk.img" ]
[ ! -e "${output_dir}/derived-ramdisk.img" ]
[ ! -e "${output_dir}/identity.properties" ]
install -m 0444 "${input_ramdisk}" "${output_dir}/official-ramdisk.img"
install -m 0444 "${work_dir}/derived-ramdisk.img" "${output_dir}/derived-ramdisk.img"
{
  printf 'official_ramdisk_sha256=%s\n' "${official_ramdisk_sha256}"
  printf 'official_cpio_sha256=%s\n' "${official_cpio_sha256}"
  printf 'overlay_cpio_sha256=%s\n' "$(sha256sum "${overlay_cpio}" | cut -d' ' -f1)"
  printf 'combined_cpio_sha256=%s\n' "$(sha256sum "${combined_cpio}" | cut -d' ' -f1)"
  printf 'derived_ramdisk_sha256=%s\n' "${actual_derived_sha256}"
  printf 'overlay_path=%s\n' "${overlay_path}"
  printf 'overlay_property=%s\n' "${property_value}"
} >"${work_dir}/identity.properties"
install -m 0444 "${work_dir}/identity.properties" "${output_dir}/identity.properties"

printf 'derived_ramdisk_sha256=%s\n' "${actual_derived_sha256}"
