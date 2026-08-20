#!/bin/sh
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
CLIENT=${ROOT}/client/macos
CORE=${CLIENT}/Sources/CloudAndxClientCore
APP=${CLIENT}/Sources/CloudAndxClient
AGENT=${CLIENT}/Sources/CloudAndxCapabilityAgent/main.swift
AGENT_ENTITLEMENTS=${CLIENT}/Resources/CloudAndxCapabilityAgent.entitlements

test -f "${CLIENT}/Package.swift"
test -x "${CLIENT}/scripts/swift-toolchain.sh"
test -x "${CLIENT}/scripts/build-app.sh"
plutil -lint "${CLIENT}/Resources/Info.plist" >/dev/null
plutil -lint "${CLIENT}/Resources/CloudAndxCapabilityAgent-Info.plist" >/dev/null
plutil -lint "${AGENT_ENTITLEMENTS}" >/dev/null
grep -Fq '<key>com.apple.security.app-sandbox</key>' "${AGENT_ENTITLEMENTS}"
grep -Fq '<true/>' "${AGENT_ENTITLEMENTS}"
! rg -n 'network|temporary-exception|get-task-allow|files\.(user-selected|downloads|pictures|movies|music)' "${AGENT_ENTITLEMENTS}"
grep -Fq 'com.apple.security.app-sandbox' "${CLIENT}/Resources/CloudAndxClient.entitlements"
grep -Fq 'FileHandle' "${CORE}/CapabilityXPC.swift"
! sed -n '/@objc public protocol/,/^}/p' "${CORE}/CapabilityXPC.swift" | rg 'bookmark|URL|path:|environment:'
grep -Fq 'OutstandingRequestRegistry' "${CORE}/CapabilityXPC.swift"
grep -Fq 'public enum CapabilityRequestTimeout' "${CORE}/CapabilityXPC.swift"
grep -Fq 'case .start, .stop, .restart, .scrcpy, .snapshotSave, .snapshotResume,' "${CORE}/CapabilityXPC.swift"
grep -Fq 'Only read-only requests time out.' "${CORE}/CapabilityXPC.swift"
grep -Fq 'start/resume may consume the trusted 120s boot gate' "${CORE}/CapabilityXPC.swift"
grep -Fq 'public static let trustedBootTimeoutSeconds = 120' "${CORE}/RuntimeService.swift"
grep -Fq '"CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS": String(Self.trustedBootTimeoutSeconds)' "${CORE}/RuntimeService.swift"
! sed -n '/let allowedOverrides = \[/,/\]/p' "${CORE}/ProcessRunner.swift" | grep -Fq 'CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS'
grep -Fq '"CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS",' "${CORE}/ProcessRunner.swift"
grep -Fq 'fstat(source.fileDescriptor, &sourceInfo)' "${CORE}/CapabilityXPC.swift"
grep -Fq '(sourceInfo.st_mode & S_IFMT) == S_IFREG' "${CORE}/CapabilityXPC.swift"
grep -Fq '(sourceFlags & O_ACCMODE) != O_WRONLY' "${CORE}/CapabilityXPC.swift"
grep -Fq 'Logger(subsystem: "dev.cloudandx.android-client", category: "capability-agent")' "${AGENT}"
grep -Fq 'success=true' "${AGENT}"
grep -Fq 'success=false' "${AGENT}"
grep -Fq 'action: "readLog"' "${AGENT}"
grep -Fq 'action: command.rawValue' "${AGENT}"
grep -Fq 'private let serialQueue = DispatchQueue(label: "dev.cloudandx.capability-agent.serial")' "${AGENT}"
grep -Fq 'private let interactionQueue = DispatchQueue(label: "dev.cloudandx.capability-agent.interaction")' "${AGENT}"
grep -Fq 'let executionQueue = command == .scrcpy ? interactionQueue : serialQueue' "${AGENT}"
! rg -n 'logger\.(info|error|debug).*output|logger\.(info|error|debug).*error|logger\.(info|error|debug).*displayName|logger\.(info|error|debug).*path' "${AGENT}"
grep -Fq 'CapabilityServing' "${APP}/RuntimeViewModel.swift"
grep -Fq 'SecurityScopedFileAccess' "${APP}/RuntimeViewModel.swift"
grep -Fq 'O_NOFOLLOW' "${APP}/SecurityScopedFileAccess.swift"
grep -Fq 'deletingLastPathComponent' "${APP}/SecurityScopedFileAccess.swift"
grep -Fq 'created' "${APP}/SecurityScopedFileAccess.swift"
grep -Fq 'O_EXCL' "${APP}/SecurityScopedFileAccess.swift"
grep -Fq 'RuntimeBundleConfiguration' "${CORE}/CapabilityXPC.swift"
grep -Fq 'case unavailable' "${CORE}/RuntimeManifest.swift"
grep -Fq 'O_NOFOLLOW' "${CORE}/RuntimeManifest.swift"
grep -Fq 'maximumManifestBytes' "${CORE}/RuntimeManifest.swift"
grep -Fq 'isCapabilityAvailable = service != nil' "${APP}/RuntimeViewModel.swift"
grep -Fq 'var isCommandLocked: Bool { !isCapabilityAvailable' "${APP}/RuntimeViewModel.swift"
reload=$(sed -n '/private func reload(using/,/private func reloadLog/p' "${APP}/RuntimeViewModel.swift")
! printf '%s\n' "${reload}" | grep -Fq '.snapshotStatus'
grep -Fq 'CloudAndxCapabilityAgent.xpc' "${CLIENT}/scripts/build-app.sh"
! rg -n 'RuntimeAuthority/native-android17.sh|development-project-root.txt' "${CLIENT}/scripts/build-app.sh"
grep -Fq 'CloudAndxCapabilityAgent.entitlements' "${CLIENT}/scripts/build-app.sh"
agent_sign_line=$(rg -n 'CloudAndxCapabilityAgent\.entitlements.*CloudAndxCapabilityAgent\.xpc' "${CLIENT}/scripts/build-app.sh" | cut -d: -f1)
app_sign_line=$(rg -n 'CloudAndxClient\.entitlements.*"\$\{OUTPUT\}"' "${CLIENT}/scripts/build-app.sh" | cut -d: -f1)
test -n "${agent_sign_line}" && test -n "${app_sign_line}" && test "${agent_sign_line}" -lt "${app_sign_line}"
! rg -n 'codesign .*--deep' "${CLIENT}/scripts/build-app.sh"

grep -Fq 'case start' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case stop' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case restart' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case status' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case scrcpy' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case snapshotSave = "snapshot-save"' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case snapshotResume = "snapshot-resume"' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case snapshotStatus = "snapshot-status"' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case installAPK = "install-apk"' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case pushFile = "push-file"' "${CORE}/RuntimeCommand.swift"
grep -Fq 'case captureScreenshot = "capture-screenshot"' "${CORE}/RuntimeCommand.swift"
grep -Fq 'executable: runner' "${CORE}/RuntimeService.swift"
grep -Fq 'arguments: [command.rawValue]' "${CORE}/RuntimeService.swift"
grep -Fq 'environment: environment' "${CORE}/RuntimeService.swift"
grep -Fq 'CLOUDANDX_NATIVE_APK_PATH' "${CORE}/RuntimeService.swift"
grep -Fq 'CLOUDANDX_NATIVE_HOST_FILE_PATH' "${CORE}/RuntimeService.swift"
grep -Fq 'CLOUDANDX_NATIVE_SCREENSHOT_PATH' "${CORE}/RuntimeService.swift"
grep -Fq 'outputLimit = 65_536' "${CORE}/RuntimeService.swift"
grep -Fq 'scripts/native-android17.sh' "${CORE}/ProjectLocator.swift"
grep -Fq 'hasSecureOwnershipAndPermissions' "${CORE}/ProjectLocator.swift"
if grep -Rq 'CLOUDANDX_PROJECT_ROOT' "${CORE}" "${APP}"; then
  echo 'FAIL: GUI must not trust an environment-selected project root' >&2
  exit 1
fi
grep -Fq 'process.environment = environment' "${CORE}/ProcessRunner.swift"
grep -Fq 'RuntimeLogSanitizer.redact' "${CORE}/RuntimeService.swift"
grep -Fq 'isCommandLocked: Bool { !isCapabilityAvailable || isBusy || isOpeningInteraction }' "${APP}/RuntimeViewModel.swift"
grep -Fq 'guard !isCommandLocked else { return }' "${APP}/RuntimeViewModel.swift"
grep -Fq 'confirmAndResumeSnapshot' "${APP}/RuntimeViewModel.swift"
grep -Fq 'installAPK()' "${APP}/RuntimeViewModel.swift"
grep -Fq 'pushFile()' "${APP}/RuntimeViewModel.swift"
grep -Fq 'captureScreenshot()' "${APP}/RuntimeViewModel.swift"
grep -Fq 'scrcpy requires an explicitly started, ready Android runtime' "${ROOT}/scripts/native-android17.sh"
! sed -n '/scrcpy_runtime()/,/^}/p' "${ROOT}/scripts/native-android17.sh" | grep -Eq '(^|[;[:space:]])start($|[[:space:];])'

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
grep -Fq '不会开放任意 ADB 或 shell' "${APP}/ContentView.swift"
grep -Fq 'client/macos/.build/' "${ROOT}/.gitignore"

printf '%s\n' 'PASS: native macOS client security and packaging contracts'
