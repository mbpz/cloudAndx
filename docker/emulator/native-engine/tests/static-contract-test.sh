#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)
LOCK_FILE=${ENGINE_DIR}/sources.lock.json

fail() {
  printf 'static-contract-test: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle=$1 file=$2
  grep -Fq -- "${needle}" "${file}" \
    || fail "${file} does not contain: ${needle}"
}

jq -e . "${LOCK_FILE}" >/dev/null || fail 'source lock is not valid JSON'

jq -e '
  .schema_version == 1 and
  .aemu_revision == "37.1.7" and
  (([.repository_roots[].id] | length) == ([.repository_roots[].id] | unique | length)) and
  all(.repository_roots[]; .commit | test("^[0-9a-f]{40}$")) and
  all(.repository_roots[]; .git_tree | test("^[0-9a-f]{40}$")) and
  all(.repository_roots[]; .repository | test("^https://android\\.googlesource\\.com/[A-Za-z0-9._/-]+$")) and
  (.sources | length > 0) and
  (([.sources[].id] | length) == ([.sources[].id] | unique | length)) and
  (([.sources[].destination] | length) == ([.sources[].destination] | unique | length)) and
  all(.sources[]; .commit | test("^[0-9a-f]{40}$")) and
  all(.sources[]; (.git_tree == null) or (.git_tree | test("^[0-9a-f]{40}$"))) and
  all(.sources[]; .repository | test("^https://android\\.googlesource\\.com/[A-Za-z0-9._/-]+$")) and
  all(.sources[]; all(.blob_checks[]?; .sha1 | test("^[0-9a-f]{40}$"))) and
  all(.sources[]; (has("archive_sha256") | not))
' "${LOCK_FILE}" >/dev/null || fail 'source lock invariants failed'

jq -e '
  (.repository_roots | INDEX(.id)) as $roots |
  $roots.aemu.commit == "98f7f6ffcc4e6ce513a8b978323c3b961dc58143" and
  $roots.aemu.git_tree == "aeeb57688c7eac123fd2c9728f721da45e60a39a" and
  $roots."qemu-android-deps".commit == "b06aee625002d0738c5576bbf437b9378229bef0" and
  $roots."qemu-android-deps".git_tree == "0e8ba908ca9f160db2e495511f59790241279c38" and
  $roots.common.commit == "f64c458fc47ac18f738f9c8bdecb64d265f530f4" and
  $roots.common.git_tree == "a528f26b6f42526e2d4f460aed5aaf5c5d706516" and
  $roots.webrtc.git_tree == "a699fadd6579a9df71b9150f14be8445629e6684" and
  $roots.cuttlefish.git_tree == "3c74a4b4e4770afc7b17e2eb0f9a9d8de750453d" and
  $roots.rootcanal.git_tree == "f9dc1acd3bd70478dcdd8c574b9ab20d36057b0a"
' "${LOCK_FILE}" >/dev/null || fail 'repository root pins do not match approved revisions'

jq -e '
  (.sources[] | select(.id == "aemu") |
    .commit == "98f7f6ffcc4e6ce513a8b978323c3b961dc58143" and
    .git_tree == "aeeb57688c7eac123fd2c9728f721da45e60a39a") and
  (.sources[] | select(.id == "qemu-android-deps") |
    .commit == "b06aee625002d0738c5576bbf437b9378229bef0" and
    .git_tree == "0e8ba908ca9f160db2e495511f59790241279c38") and
  (all(.sources[] | select(.id | startswith("common-"));
    .commit == "f64c458fc47ac18f738f9c8bdecb64d265f530f4"))
' "${LOCK_FILE}" >/dev/null || fail 'major source pins do not match the approved revisions'

EXPECTED_AEMU_PATCHES='["patches/0001-build-x86_64-headless-for-linux-aarch64.patch","patches/0002-build-headless-engine-only.patch","patches/0003-fix-gnss-proto-relative-path.patch","patches/0004-use-system-toolchain-for-build-host-tools.patch","patches/0005-build-host-protoc-from-upstream-source.patch"]'
[[ $(jq -c '.patches.aemu' "${LOCK_FILE}") == "${EXPECTED_AEMU_PATCHES}" ]] \
  || fail 'AEMU patch order changed'
[[ $(jq -c '.patches.protobuf' "${LOCK_FILE}") == \
  '["patches/protobuf-0001-allow-standalone-host-protoc.patch"]' ]] \
  || fail 'protobuf patch order changed'
[[ $(jq -c '.patches.crashpad' "${LOCK_FILE}") == \
  '["patches/crashpad-0001-gcc-packed-alignment.patch"]' ]] \
  || fail 'Crashpad patch order changed'

while IFS= read -r patch_path; do
  [[ -f "${ENGINE_DIR}/${patch_path}" ]] || fail "locked patch is missing: ${patch_path}"
done < <(jq -r '.patches[] | .[]' "${LOCK_FILE}")

bash -n "${ENGINE_DIR}"/scripts/*.sh
sh -n "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless"

for flag in \
  '-DCMAKE_BUILD_TYPE=Release' \
  '-DCMAKE_TOOLCHAIN_FILE=' \
  '-DPython_EXECUTABLE=/usr/bin/python3' \
  '-DOPTION_BAZEL=FALSE' \
  '-DOPTION_CRASHUPLOAD=NONE' \
  '-DOPTION_MINBUILD=TRUE' \
  '-DOPTION_HEADLESS_ENGINE_ONLY=TRUE' \
  '-DOPTION_SYSTEM_HOST_TOOLCHAIN=TRUE' \
  '-DOPTION_X86_64_GUEST_ON_AARCH64=TRUE' \
  '-DOPTION_SDK_TOOLS_BUILD_NUMBER=cloudandx-hybrid' \
  '-DOPTION_SDK_TOOLS_REVISION=37.1.7' \
  '-DQTWEBENGINE=FALSE' \
  '-DWEBRTC=FALSE'; do
  assert_contains "${flag}" "${ENGINE_DIR}/scripts/configure.sh"
done

assert_contains '--target qemu-system-x86_64-headless' "${ENGINE_DIR}/scripts/build.sh"
assert_contains 'FROM --platform=${BUNDLE_PLATFORM} scratch AS bundle' "${ENGINE_DIR}/Dockerfile"
assert_contains '/out/bundle/opt/cloudandx/native-aemu' "${ENGINE_DIR}/Dockerfile"
assert_contains '/opt/cloudandx/native-aemu/bin/qemu-system-x86_64-headless' \
  "${ENGINE_DIR}/scripts/package-bundle.sh"
assert_contains '/opt/cloudandx/native-aemu/bin/run-qemu-system-x86_64-headless' \
  "${ENGINE_DIR}/scripts/package-bundle.sh"
assert_contains '/opt/cloudandx/native-aemu/manifest.json' "${ENGINE_DIR}/README.md"
assert_contains '/opt/cloudandx/native-aemu/SHA256SUMS' "${ENGINE_DIR}/README.md"
assert_contains 'exec "${LOADER}" --library-path "${LIBRARY_PATH}" "${ENGINE}" "$@"' \
  "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless"

printf 'static-contract-test: source locks, patch order, scripts, and bundle contract verified\n'
