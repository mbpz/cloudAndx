#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

BUNDLE_DIR=${BUNDLE_DIR:-/out/bundle/opt/cloudandx/native-aemu}
READELF=${READELF:-aarch64-linux-gnu-readelf}

die() {
  printf 'smoke-test-bundle: %s\n' "$*" >&2
  exit 1
}

ENGINE=${BUNDLE_DIR}/bin/qemu-system-x86_64-headless
RUNNER=${BUNDLE_DIR}/bin/run-qemu-system-x86_64-headless
LOADER=${BUNDLE_DIR}/lib/ld-linux-aarch64.so.1

for required in "${ENGINE}" "${RUNNER}" "${LOADER}" \
  "${BUNDLE_DIR}/manifest.json" "${BUNDLE_DIR}/SHA256SUMS"; do
  [[ -f "${required}" ]] || die "required bundle file is missing: ${required}"
done

(
  cd "${BUNDLE_DIR}"
  sha256sum -c SHA256SUMS
)

sh -n "${RUNNER}"
grep -Fq 'ROOT=/opt/cloudandx/native-aemu' "${RUNNER}" \
  || die 'runner does not use the fixed bundle root'
grep -Fq 'unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT' "${RUNNER}" \
  || die 'runner does not clear inherited dynamic-loader variables'

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

jq -e '
  .schema_version == 1 and
  .product == "cloudandx-aemu-native-engine" and
  .revision == "37.1.7" and
  .architecture == "arm64" and
  .binary == "/opt/cloudandx/native-aemu/bin/qemu-system-x86_64-headless" and
  .runner == "/opt/cloudandx/native-aemu/bin/run-qemu-system-x86_64-headless" and
  .loader == "/opt/cloudandx/native-aemu/lib/ld-linux-aarch64.so.1"
' "${BUNDLE_DIR}/manifest.json" >/dev/null \
  || die 'bundle manifest contract is invalid'

printf 'smoke-test-bundle: AArch64 ELF closure and checksums verified\n'
