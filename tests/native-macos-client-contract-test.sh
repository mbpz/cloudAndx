#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
CLIENT=${ROOT}/client/macos
CORE=${CLIENT}/Sources/CloudAndxClientCore
APP=${CLIENT}/Sources/CloudAndxClient

test -f "${CLIENT}/Package.swift"
test -x "${CLIENT}/scripts/swift-toolchain.sh"
test -x "${CLIENT}/scripts/build-app.sh"
plutil -lint "${CLIENT}/Resources/Info.plist" >/dev/null

grep -Fq 'case start' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case stop' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case restart' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case status' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case scrcpy' "${CORE}/RuntimeCommand.swift"
grep -Fq 'executable: runner' "${CORE}/RuntimeService.swift"
grep -Fq 'arguments: [command.rawValue]' "${CORE}/RuntimeService.swift"
grep -Fq 'outputLimit = 65_536' "${CORE}/RuntimeService.swift"
grep -Fq 'scripts/native-android17.sh' "${CORE}/ProjectLocator.swift"
grep -Fq 'hasSecureOwnershipAndPermissions' "${CORE}/ProjectLocator.swift"
if grep -Rq 'CLOUDANDX_PROJECT_ROOT' "${CORE}" "${APP}"; then
  echo 'FAIL: GUI must not trust an environment-selected project root' >&2
  exit 1
fi
grep -Fq 'process.environment = environment' "${CORE}/ProcessRunner.swift"
grep -Fq 'RuntimeLogSanitizer.redact' "${CORE}/RuntimeService.swift"
grep -Fq 'isCommandLocked: Bool { isBusy || isOpeningInteraction }' "${APP}/RuntimeViewModel.swift"
grep -Fq 'guard !isCommandLocked else { return }' "${APP}/RuntimeViewModel.swift"

if rg -n '/bin/(ba)?sh|-c[" ]' "${CORE}" "${APP}" >/dev/null; then
  echo 'FAIL: macOS client must not execute a shell command string' >&2
  exit 1
fi
if rg -n 'ProcessInfo.*arguments|CommandLine\.arguments' "${CORE}" "${APP}" >/dev/null; then
  echo 'FAIL: macOS client must not accept arbitrary runtime commands' >&2
  exit 1
fi

grep -Fq 'Hypervisor.Framework' "${APP}/ContentView.swift"
grep -Fq 'StrongBox' "${APP}/ContentView.swift"
grep -Fq 'Widevine L1' "${APP}/ContentView.swift"
grep -Fq 'client/macos/.build/' "${ROOT}/.gitignore"

printf '%s\n' 'PASS: native macOS client security and packaging contracts'
