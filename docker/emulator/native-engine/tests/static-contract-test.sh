#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "${TEST_DIR}/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "${ENGINE_DIR}/../../.." && pwd)
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
  all(.sources[];
    all(.files[]?;
      (.path | test("^[A-Za-z0-9._/-]+$")) and
      (.destination | test("^[A-Za-z0-9._/-]+$")) and
      (.sha1 | test("^[0-9a-f]{40}$")))) and
  all(.sources[];
    (([.files[]?.destination] | length) ==
     ([.files[]?.destination] | unique | length))) and
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
  $roots.qt.commit == "f2d41b8d15c2a628e95c2e755ed92186d03b763c" and
  $roots.qt.git_tree == "e24037912caff0d1333503aec24faafdde8f7921" and
  $roots.webrtc.git_tree == "a699fadd6579a9df71b9150f14be8445629e6684" and
  $roots.cuttlefish.git_tree == "3c74a4b4e4770afc7b17e2eb0f9a9d8de750453d" and
  $roots.rootcanal.git_tree == "f9dc1acd3bd70478dcdd8c574b9ab20d36057b0a"
' "${LOCK_FILE}" >/dev/null || fail 'repository root pins do not match approved revisions'

jq -e '
  (.repository_roots | INDEX(.id)) as $roots |
  (.sources[] | select(.id == "aemu") |
    .commit == "98f7f6ffcc4e6ce513a8b978323c3b961dc58143" and
    .git_tree == "aeeb57688c7eac123fd2c9728f721da45e60a39a") and
  (.sources[] | select(.id == "qemu-android-deps") |
    .commit == "b06aee625002d0738c5576bbf437b9378229bef0" and
    .git_tree == "0e8ba908ca9f160db2e495511f59790241279c38") and
  ((.sources[] | select(.id == "qt-linux-aarch64-x11")) as $qt_x11 |
    ($qt_x11.files | INDEX(.destination)) as $files |
    $qt_x11.repository == "https://android.googlesource.com/platform/prebuilts/android-emulator-build/qt" and
    $qt_x11.commit == $roots.qt.commit and
    $qt_x11.destination == "prebuilts/android-emulator-build/qt/linux-aarch64/lib" and
    $qt_x11.git_tree == "ce55fd91d181e57515f3833e80a4d1fcc7f732da" and
    $qt_x11.verify_tree == false and
    ($files | keys | sort) == [
      "libX11.so", "libX11.so.6", "libXau.so", "libXau.so.6",
      "libXdmcp.so.6", "libbsd.so.0", "libxcb.so.1"
    ] and
    all($qt_x11.files[];
      .path == ("linux-aarch64/lib/" + .destination)) and
    $files["libX11.so"].sha1 == "c6a6bf0eb60353d00ec60df437dab1e16134ed45" and
    $files["libX11.so.6"].sha1 == "c6a6bf0eb60353d00ec60df437dab1e16134ed45" and
    $files["libXau.so"].sha1 == "338d63b32fedd3fb45f057bec3ab888c27f5f5ed" and
    $files["libXau.so.6"].sha1 == "338d63b32fedd3fb45f057bec3ab888c27f5f5ed" and
    $files["libxcb.so.1"].sha1 == "e8aa539274979031543d77902b9a5ea874ef3aad" and
    $files["libXdmcp.so.6"].sha1 == "2c935ce03cc1f358aabb9d00be3bd61538377678" and
    $files["libbsd.so.0"].sha1 == "ec5288fd6b365b24ea1de3650a4ef2d61d3319b4") and
  (.sources[] | select(.id == "cuttlefish-common-libs-fs") |
    .repository == "https://android.googlesource.com/device/google/cuttlefish" and
    .commit == "7544e817764397f8ed818ea1cd36dde6ab90adf1" and
    .subtree == "common/libs/fs" and
    .destination == "device/google/cuttlefish/common/libs/fs" and
    .git_tree == "eac7967fe51482a31b82b1d506efc41238c9fed4" and
    .verify_tree == true and
    .blob_checks == [{
      "path": "shared_buf.h",
      "sha1": "a4ad2dfe2f00365c4c0ac2cd475a0e67aefa6054"
    }]) and
  (all(.sources[] |
    select(.repository == "https://android.googlesource.com/device/google/cuttlefish");
    .commit == $roots.cuttlefish.commit)) and
  (all(.sources[] | select(.id | startswith("common-"));
    .commit == "f64c458fc47ac18f738f9c8bdecb64d265f530f4"))
' "${LOCK_FILE}" >/dev/null || fail 'major source pins do not match the approved revisions'

EXPECTED_AEMU_PATCHES='["patches/0001-build-x86_64-headless-for-linux-aarch64.patch","patches/0002-build-headless-engine-only.patch","patches/0003-fix-gnss-proto-relative-path.patch","patches/0004-use-system-toolchain-for-build-host-tools.patch","patches/0005-build-host-protoc-from-upstream-source.patch","patches/0006-propagate-host-cmake-context.patch","patches/0007-disable-x86-kvm-on-non-x86-linux.patch","patches/0008-use-tcg-translation-without-kvm.patch"]'
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

assert_contains '#if defined(__linux__) && (defined(__i386__) || defined(__x86_64__))' \
  "${ENGINE_DIR}/patches/0007-disable-x86-kvm-on-non-x86-linux.patch"
assert_contains '#ifdef CONFIG_KVM' \
  "${ENGINE_DIR}/patches/0008-use-tcg-translation-without-kvm.patch"
assert_contains 'set_address_translation_funcs(0, tcg_gpa2hva);' \
  "${ENGINE_DIR}/patches/0008-use-tcg-translation-without-kvm.patch"

bash -n "${ENGINE_DIR}"/scripts/*.sh
sh -n "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless"

for flag in \
  '-DCMAKE_BUILD_TYPE=Release' \
  '-DCMAKE_TOOLCHAIN_FILE=' \
  '-DPython_EXECUTABLE=/usr/bin/python3' \
  '-DQT5_LINK_PATH:STRING=' \
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

assert_contains '?format=TEXT' "${ENGINE_DIR}/scripts/fetch-sources.sh"
assert_contains 'base64 --decode' "${ENGINE_DIR}/scripts/fetch-sources.sh"
assert_contains 'git hash-object --no-filters' "${ENGINE_DIR}/scripts/fetch-sources.sh"

assert_contains '--target qemu-system-x86_64-headless' "${ENGINE_DIR}/scripts/build.sh"
assert_contains 'FROM --platform=${BUNDLE_PLATFORM} scratch AS bundle' "${ENGINE_DIR}/Dockerfile"
assert_contains '/out/bundle/opt/cloudandx/native-aemu' "${ENGINE_DIR}/Dockerfile"
assert_contains '/opt/cloudandx/native-aemu/bin/qemu-system-x86_64-headless' \
  "${ENGINE_DIR}/scripts/package-bundle.sh"
assert_contains '/opt/cloudandx/native-aemu/bin/run-qemu-system-x86_64-headless' \
  "${ENGINE_DIR}/scripts/package-bundle.sh"
assert_contains '/opt/cloudandx/native-aemu/manifest.json' "${ENGINE_DIR}/README.md"
assert_contains '/opt/cloudandx/native-aemu/SHA256SUMS' "${ENGINE_DIR}/README.md"
assert_contains 'ROOT=${NATIVE_AEMU_ROOT:-/opt/cloudandx/native-aemu}' \
  "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless"
assert_contains 'LD_LIBRARY_PATH=${LIBRARY_PATH}' \
  "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless"
assert_contains 'exec "${ENGINE}" "$@"' \
  "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless"
if grep -Fq 'exec "${LOADER}"' "${ENGINE_DIR}/bin/run-qemu-system-x86_64-headless"; then
  fail 'runner must not make the ELF loader the process image'
fi

assert_contains 'ARG NATIVE_AEMU_SOURCE_LOCK_SHA256' \
  "${ENGINE_DIR}/Dockerfile"
assert_contains 'ARG NATIVE_AEMU_PATCH_SET_SHA256' \
  "${ENGINE_DIR}/Dockerfile"
assert_contains 'NATIVE_AEMU_SOURCE_LOCK_SHA256=$(sha256_file "${NATIVE_AEMU_LOCK}")' \
  "${REPO_ROOT}/androidctl"
assert_contains 'NATIVE_AEMU_PATCH_SET_SHA256=$(' \
  "${REPO_ROOT}/androidctl"
assert_contains 'source_lock_sha256=${NATIVE_AEMU_SOURCE_LOCK_SHA256}' \
  "${REPO_ROOT}/docker/emulator/bin/runtime-lib.sh"
assert_contains 'patch_set_sha256=${NATIVE_AEMU_PATCH_SET_SHA256}' \
  "${REPO_ROOT}/docker/emulator/bin/runtime-lib.sh"
assert_contains 'ARG NATIVE_AEMU_SOURCE_LOCK_SHA256' \
  "${REPO_ROOT}/docker/emulator/Dockerfile"
assert_contains 'ARG NATIVE_AEMU_PATCH_SET_SHA256' \
  "${REPO_ROOT}/docker/emulator/Dockerfile"
assert_contains 'io.cloudandx.native-aemu.source-lock-sha256=' "${ENGINE_DIR}/Dockerfile"
assert_contains 'io.cloudandx.native-aemu.patch-set-sha256=' "${ENGINE_DIR}/Dockerfile"
assert_contains 'execution_model direct-engine' "${ENGINE_DIR}/scripts/package-bundle.sh"
assert_contains 'identity.properties' "${ENGINE_DIR}/scripts/package-bundle.sh"
assert_contains '/lib/ld-linux-aarch64.so.1' "${REPO_ROOT}/docker/emulator/Dockerfile"

printf 'static-contract-test: source locks, patch order, scripts, and bundle contract verified\n'
