#!/bin/sh
set -eu

usage() {
  printf '%s\n' 'usage: build-app.sh --mode development-sdk|bundled-release [--output path] [--runtime-payload path] [--dry-run]'
  exit 64
}

PACKAGE_ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
MODE=
OUTPUT=
PAYLOAD=
DRY_RUN=no
while [ "$#" -gt 0 ]; do
  case $1 in
    --mode) [ "$#" -ge 2 ] || usage; MODE=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; OUTPUT=$2; shift 2 ;;
    --runtime-payload) [ "$#" -ge 2 ] || usage; PAYLOAD=$2; shift 2 ;;
    --dry-run) DRY_RUN=yes; shift ;;
    *) usage ;;
  esac
done
case ${MODE} in development-sdk|bundled-release) ;; *) usage ;; esac
[ -n "${OUTPUT}" ] || OUTPUT=${PACKAGE_ROOT}/.build/CloudAndx.app
case ${OUTPUT} in *.app) ;; *) printf '%s\n' 'output must end in .app' >&2; exit 1 ;; esac

fail() { printf '%s\n' "build-app: ERROR: $*" >&2; exit 1; }

if [ "${MODE}" = bundled-release ]; then
  # All release gates run before compilation or output deletion. This keeps a
  # missing payload/identity from mutating an existing product candidate.
  [ -n "${PAYLOAD}" ] && [ -d "${PAYLOAD}" ] || fail 'bundled-release requires --runtime-payload with a verified AndroidRuntime root'
  project_root=$(CDPATH= cd "${PACKAGE_ROOT}/../.." && pwd)
  pipeline=${project_root}/runtime/macos-arm64/runtime_pipeline.py
  production_policy=${project_root}/runtime/macos-arm64/production-trusted-builders.json
  [ -x "${pipeline}" ] || fail 'bundled-release Phase 2C runtime pipeline is unavailable'
  # The policy is repository-fixed and currently has zero trusted builders.
  # A release caller cannot replace it with a CLI or environment override.
  verifier_bin=$("${PACKAGE_ROOT}/scripts/swift-toolchain.sh" build -c release --product CloudAndxRuntimeVerifier >/dev/null && "${PACKAGE_ROOT}/scripts/swift-toolchain.sh" bin-path -c release)/CloudAndxRuntimeVerifier
  "${pipeline}" verify-payload --payload "${PAYLOAD}" --policy "${production_policy}" --swift-verifier "${verifier_bin}" \
    || fail 'runtime payload verification failed (no trusted production builder key or supply-chain gate rejection)'
  [ -n "${CLOUDANDX_CODESIGN_IDENTITY:-}" ] || fail 'bundled-release requires CLOUDANDX_CODESIGN_IDENTITY (ad-hoc signing is forbidden)'
  [ -n "${CLOUDANDX_EXPECTED_TEAM_ID:-}" ] || fail 'bundled-release requires CLOUDANDX_EXPECTED_TEAM_ID'
  [ -n "${CLOUDANDX_NOTARY_PROFILE:-}" ] || fail 'bundled-release requires CLOUDANDX_NOTARY_PROFILE'
  case ${CLOUDANDX_CODESIGN_IDENTITY} in *'Developer ID Application:'*) ;; *) fail 'CLOUDANDX_CODESIGN_IDENTITY must be a Developer ID Application identity' ;; esac
  "${verifier_bin}" "${PAYLOAD}" >/dev/null || fail 'runtime payload manifest verification failed'
  identity_listing=$(security find-identity -v -p codesigning)
  printf '%s\n' "${identity_listing}" | grep -Fq "${CLOUDANDX_CODESIGN_IDENTITY}" \
    || fail 'CLOUDANDX_CODESIGN_IDENTITY is not an installed code-signing identity'
  printf '%s\n' "${identity_listing}" | grep -Fq "${CLOUDANDX_EXPECTED_TEAM_ID}" \
    || fail 'installed signing identity does not expose the expected Team ID'
  [ "${DRY_RUN}" = yes ] && { printf '%s\n' 'release preflight passed; dry-run produced no app'; exit 0; }
  fail 'bundled-release artifact emission is deferred until the signed launcher embeds the verified runner and bundle-relative service locator'
else
  [ -z "${PAYLOAD}" ] || fail 'development-sdk must not copy a runtime payload; it is not a product runtime'
fi

"${PACKAGE_ROOT}/scripts/swift-toolchain.sh" build -c release
BIN_DIR=$("${PACKAGE_ROOT}/scripts/swift-toolchain.sh" bin-path -c release)

rm -rf "${OUTPUT}"
install -d "${OUTPUT}/Contents/MacOS" "${OUTPUT}/Contents/Resources"
install -m 0755 "${BIN_DIR}/CloudAndxClient" "${OUTPUT}/Contents/MacOS/CloudAndxClient"
install -m 0644 "${PACKAGE_ROOT}/Resources/Info.plist" "${OUTPUT}/Contents/Info.plist"
install -d "${OUTPUT}/Contents/XPCServices/CloudAndxCapabilityAgent.xpc/Contents/MacOS"
install -m 0755 "${BIN_DIR}/CloudAndxCapabilityAgent" "${OUTPUT}/Contents/XPCServices/CloudAndxCapabilityAgent.xpc/Contents/MacOS/CloudAndxCapabilityAgent"
install -m 0644 "${PACKAGE_ROOT}/Resources/CloudAndxCapabilityAgent-Info.plist" "${OUTPUT}/Contents/XPCServices/CloudAndxCapabilityAgent.xpc/Contents/Info.plist"
# The App-Sandboxed agent intentionally has no development checkout authority.
# Do not package project paths or an executable runner until a bundle-owned
# runtime or separately audited lifecycle helper exists.
printf '%s\n' 'CLOUDANDX_RUNTIME_MODE=development-sdk' >"${OUTPUT}/Contents/Resources/runtime-mode.env"
# Development output is intentionally ad-hoc signed so users can inspect it.
# Sign the nested XPC bundle before the sandboxed outer app; release never uses this identity.
codesign --force --sign - --entitlements "${PACKAGE_ROOT}/Resources/CloudAndxCapabilityAgent.entitlements" "${OUTPUT}/Contents/XPCServices/CloudAndxCapabilityAgent.xpc"
codesign --force --sign - --entitlements "${PACKAGE_ROOT}/Resources/CloudAndxClient.entitlements" "${OUTPUT}"
printf '%s\n' "built ${OUTPUT} mode=${MODE}"
