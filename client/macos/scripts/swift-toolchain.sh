#!/bin/sh
set -eu

PACKAGE_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
SDK_ROOT=${CLOUDANDX_MACOS_SDK_ROOT:-$(xcrun --sdk macosx --show-sdk-path)}
MODULE_CACHE=${TMPDIR:-/tmp}/cloudandx-swift-module-cache
SPM_CACHE=${TMPDIR:-/tmp}/cloudandx-swiftpm-cache
mkdir -p "${MODULE_CACHE}" "${SPM_CACHE}"

interface_version=$(sed -n 's/^\/\/ swift-compiler-version: Apple Swift version \([^ ]*\).*/\1/p' \
  "${SDK_ROOT}/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface" | head -n 1)
[ -n "${interface_version}" ] || { printf '%s\n' 'cannot determine SDK Swift interface version' >&2; exit 1; }

action=${1:-}
shift || true
case ${action} in
  build)
    exec env SDKROOT="${SDK_ROOT}" CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
      SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" swift build \
      --package-path "${PACKAGE_ROOT}" --disable-sandbox --build-system native \
      --cache-path "${SPM_CACHE}" --manifest-cache local \
      -Xswiftc -interface-compiler-version -Xswiftc "${interface_version}" "$@"
    ;;
  run)
    target=${1:?usage: swift-toolchain.sh run TARGET}
    shift
    exec env SDKROOT="${SDK_ROOT}" CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
      SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" swift run \
      --package-path "${PACKAGE_ROOT}" --disable-sandbox --build-system native \
      --cache-path "${SPM_CACHE}" --manifest-cache local \
      -Xswiftc -interface-compiler-version -Xswiftc "${interface_version}" "${target}" "$@"
    ;;
  bin-path)
    exec env SDKROOT="${SDK_ROOT}" CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
      SWIFTPM_MODULECACHE_OVERRIDE="${MODULE_CACHE}" swift build \
      --package-path "${PACKAGE_ROOT}" --disable-sandbox --build-system native \
      --cache-path "${SPM_CACHE}" --manifest-cache local \
      -Xswiftc -interface-compiler-version -Xswiftc "${interface_version}" --show-bin-path "$@"
    ;;
  *) printf '%s\n' 'usage: swift-toolchain.sh {build|run TARGET|bin-path}' >&2; exit 1 ;;
esac
