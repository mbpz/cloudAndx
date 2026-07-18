#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

BUNDLE_DIR=${BUNDLE_DIR:-/out/bundle/opt/cloudandx/native-aemu}
READELF=${READELF:-aarch64-linux-gnu-readelf}
NATIVE_AEMU_REVISION=${NATIVE_AEMU_REVISION:-}
NATIVE_AEMU_SOURCE_LOCK_SHA256=${NATIVE_AEMU_SOURCE_LOCK_SHA256:-}
NATIVE_AEMU_PATCH_SET_SHA256=${NATIVE_AEMU_PATCH_SET_SHA256:-}

die() {
  printf 'smoke-test-bundle: %s\n' "$*" >&2
  exit 1
}

ENGINE=${BUNDLE_DIR}/bin/qemu-system-x86_64-headless
RUNNER=${BUNDLE_DIR}/bin/run-qemu-system-x86_64-headless
LOADER=${BUNDLE_DIR}/lib/ld-linux-aarch64.so.1
IDENTITY=${BUNDLE_DIR}/identity.properties

for required in "${ENGINE}" "${RUNNER}" "${LOADER}" \
  "${IDENTITY}" "${BUNDLE_DIR}/manifest.json" "${BUNDLE_DIR}/SHA256SUMS"; do
  [[ -f "${required}" ]] || die "required bundle file is missing: ${required}"
done

(
  cd "${BUNDLE_DIR}"
  sha256sum -c SHA256SUMS
)

sh -n "${RUNNER}"
grep -Fq 'ROOT=${NATIVE_AEMU_ROOT:-/opt/cloudandx/native-aemu}' "${RUNNER}" \
  || die 'runner does not default to the fixed bundle root'
grep -Fq 'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT' "${RUNNER}" \
  || die 'runner does not clear inherited dynamic-loader variables'
grep -Fq 'LD_LIBRARY_PATH=${LIBRARY_PATH}' "${RUNNER}" \
  || die 'runner does not replace the inherited library path with the bundle path'
grep -Fq 'exec "${ENGINE}" "$@"' "${RUNNER}" \
  || die 'runner does not directly exec the engine'
if grep -Fq 'exec "${LOADER}"' "${RUNNER}"; then
  die 'runner still executes the ELF loader as the process image'
fi
[[ -L "${BUNDLE_DIR}/bin/lib64" \
  && $(readlink "${BUNDLE_DIR}/bin/lib64") == ../lib ]] \
  || die 'engine $ORIGIN/lib64 link does not resolve to the bundle library directory'

INTERPRETER=$("${READELF}" -l "${ENGINE}" \
  | sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p')
RPATH=$("${READELF}" -d "${ENGINE}" 2>/dev/null \
  | sed -n 's/.*(RPATH).*\[\([^]]*\)\].*/\1/p')
RUNPATH=$("${READELF}" -d "${ENGINE}" 2>/dev/null \
  | sed -n 's/.*(RUNPATH).*\[\([^]]*\)\].*/\1/p')
[[ "${INTERPRETER}" == /lib/ld-linux-aarch64.so.1 ]] \
  || die "unexpected direct-exec ELF interpreter: ${INTERPRETER:-missing}"
[[ "${RPATH}:${RUNPATH}" == *'$ORIGIN/lib64'* ]] \
  || die 'engine ELF search path does not contain $ORIGIN/lib64'

while IFS= read -r elf_file; do
  "${READELF}" -h "${elf_file}" \
    | grep -Eq 'Machine:[[:space:]]+AArch64' \
    || die "ELF is not AArch64: ${elf_file}"
  while IFS= read -r needed; do
    [[ -f "${BUNDLE_DIR}/lib/${needed}" ]] \
      || die "unresolved bundled DT_NEEDED entry ${needed} from ${elf_file}"
  done < <("${READELF}" -d "${elf_file}" 2>/dev/null \
    | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' | sort -u)
done < <(printf '%s\n' "${ENGINE}" "${LOADER}"; find "${BUNDLE_DIR}/lib" \
  -maxdepth 1 -type f ! -name ld-linux-aarch64.so.1 -print | sort)

jq -e \
  --arg interpreter "${INTERPRETER}" \
  --arg rpath "${RPATH}" \
  --arg runpath "${RUNPATH}" '
  .schema_version == 1 and
  .product == "cloudandx-aemu-native-engine" and
  .revision == "37.1.7" and
  .architecture == "arm64" and
  .binary == "/opt/cloudandx/native-aemu/bin/qemu-system-x86_64-headless" and
  .runner == "/opt/cloudandx/native-aemu/bin/run-qemu-system-x86_64-headless" and
  .loader == "/opt/cloudandx/native-aemu/lib/ld-linux-aarch64.so.1" and
  .execution.model == "direct-engine" and
  .execution.interpreter == $interpreter and
  .execution.rpath == $rpath and
  .execution.runpath == $runpath and
  .execution.library_path == "/opt/cloudandx/native-aemu/lib"
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

printf 'smoke-test-bundle: direct AArch64 engine, identity, ELF closure, and checksums verified\n'
