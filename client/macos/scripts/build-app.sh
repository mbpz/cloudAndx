#!/bin/sh
set -eu

PACKAGE_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
OUTPUT=${1:-${PACKAGE_ROOT}/.build/CloudAndx.app}
case ${OUTPUT} in *.app) ;; *) printf '%s\n' 'output must end in .app' >&2; exit 1 ;; esac

"${PACKAGE_ROOT}/scripts/swift-toolchain.sh" build -c release
BIN_DIR=$("${PACKAGE_ROOT}/scripts/swift-toolchain.sh" bin-path -c release)

rm -rf "${OUTPUT}"
install -d "${OUTPUT}/Contents/MacOS"
install -m 0755 "${BIN_DIR}/CloudAndxClient" "${OUTPUT}/Contents/MacOS/CloudAndxClient"
install -m 0644 "${PACKAGE_ROOT}/Resources/Info.plist" "${OUTPUT}/Contents/Info.plist"
printf '%s\n' "built ${OUTPUT}"
