import Foundation
import CloudAndxClientCore

@main
enum RuntimeCoreTests {
    static func main() throws {
        try testRuntimeCommandsRemainAllowlisted()
        try testParsesReadyAndStoppedStatus()
        try testParsesSnapshotStatus()
        try testLocatesProjectFromChild()
        try testProcessRunnerCapturesOnlyBoundedOutput()
        try testProcessRunnerRejectsUnknownEnvironmentOverrides()
        try testRuntimeServiceCapabilityValidation()
        try testRuntimeLogSanitizer()
        print("PASS: CloudAndxClientCore tests")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }

    static func testRuntimeCommandsRemainAllowlisted() throws {
        try expect(
            RuntimeCommand.allCases.map(\.rawValue) == [
                "start",
                "stop",
                "restart",
                "status",
                "scrcpy",
                "snapshot-save",
                "snapshot-resume",
                "snapshot-status",
                "install-apk",
                "push-file",
                "capture-screenshot",
            ],
            "runtime command allowlist changed"
        )
    }

    static func testParsesReadyAndStoppedStatus() throws {
        let ready = RuntimeStatusParser.parse("cloudandx-native: running pid=418 serial=emulator-5556 boot_completed=1")
        try expect(ready.health == .ready, "ready status not parsed")
        try expect(ready.pid == 418, "pid not parsed")
        try expect(ready.serial == "emulator-5556", "serial not parsed")

        let stopped = RuntimeStatusParser.parse("cloudandx-native: stopped")
        try expect(stopped.health == .stopped, "stopped status not parsed")
    }

    static func testParsesSnapshotStatus() throws {
        try expect(
            SnapshotStatusParser.parse("snapshot_ready=1 snapshot_name=cloudandx-ready").health == .ready,
            "trusted snapshot readiness not parsed"
        )
        try expect(
            SnapshotStatusParser.parse("snapshot_ready=0 reason=no trusted snapshot").health == .unavailable,
            "missing snapshot not parsed"
        )
        try expect(
            SnapshotStatusParser.parse("snapshot_incompatible=1 reason=runtime identity changed").health == .incompatible,
            "incompatible snapshot not parsed"
        )
    }

    static func testLocatesProjectFromChild() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let scripts = temporary.appendingPathComponent("scripts", isDirectory: true)
        let child = temporary.appendingPathComponent("client/macos", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: temporary.appendingPathComponent("compose.yaml").path, contents: Data())
        let runner = scripts.appendingPathComponent("native-android17.sh")
        FileManager.default.createFile(atPath: runner.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)

        let discovered = try ProjectLocator.locate(startingAt: child)
        try expect(
            discovered == temporary.standardizedFileURL,
            "project was not found from a child directory"
        )
    }

    static func testProcessRunnerCapturesOnlyBoundedOutput() throws {
        let result = try FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["1234567890"],
            currentDirectory: URL(fileURLWithPath: "/"),
            environment: [:],
            outputLimit: 5
        )
        try expect(result.exitCode == 0, "process failed")
        try expect(result.output == "12345", "process output was not bounded")
        try expect(result.wasTruncated, "truncation was not reported")
    }

    static func testRuntimeServiceCapabilityValidation() throws {
        let service = RuntimeService(projectRoot: URL(fileURLWithPath: "/tmp/project"))
        do {
            _ = try service.installAPK(at: URL(fileURLWithPath: "/tmp/example.txt"))
            throw TestFailure(message: "non-apk install should fail")
        } catch let error as RuntimeCapabilityError {
            try expect(error == .invalidAPK("example.txt"), "unexpected apk validation error")
        }

        do {
            _ = try service.captureScreenshot(to: URL(fileURLWithPath: "/tmp/shot.jpg"))
            throw TestFailure(message: "non-png screenshot should fail")
        } catch let error as RuntimeCapabilityError {
            try expect(error == .invalidScreenshotPath("shot.jpg"), "unexpected screenshot validation error")
        }

        try expect(
            RuntimeService.defaultPushedFileTarget(for: URL(fileURLWithPath: "/tmp/demo.apk")) == "/sdcard/Download/demo.apk",
            "device push target drifted outside the allowlist"
        )
        try expect(
            RuntimeService.defaultPushedFileTarget(for: URL(fileURLWithPath: "/tmp/a b?.txt")) == "/sdcard/Download/a_b_.txt",
            "unsafe device filename characters were not normalized"
        )
    }

    static func testProcessRunnerRejectsUnknownEnvironmentOverrides() throws {
        do {
            _ = try FoundationProcessRunner().run(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                currentDirectory: URL(fileURLWithPath: "/"),
                environment: ["PATH": "/tmp/untrusted"],
                outputLimit: 16
            )
            throw TestFailure(message: "unknown environment override should fail")
        } catch let error as ProcessRunnerError {
            guard case .unsupportedEnvironmentOverride("PATH") = error else {
                throw TestFailure(message: "unexpected environment override error")
            }
        }
    }

    static func testRuntimeLogSanitizer() throws {
        let original = "Authorization: Bearer abc token=def adbkey=/secret \(NSHomeDirectory())/runtime"
        let redacted = RuntimeLogSanitizer.redact(original)
        try expect(!redacted.contains("abc"), "bearer token leaked")
        try expect(!redacted.contains("def"), "token leaked")
        try expect(!redacted.contains("/secret"), "adb key path leaked")
        try expect(!redacted.contains(NSHomeDirectory()), "home directory leaked")
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
