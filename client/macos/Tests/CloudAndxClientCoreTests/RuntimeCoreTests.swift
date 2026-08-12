import Foundation
import CloudAndxClientCore

@main
enum RuntimeCoreTests {
    static func main() throws {
        try testRuntimeCommandsRemainAllowlisted()
        try testParsesReadyAndStoppedStatus()
        try testLocatesProjectFromChild()
        try testProcessRunnerCapturesOnlyBoundedOutput()
        try testRuntimeLogSanitizer()
        print("PASS: CloudAndxClientCore tests")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
    }

    static func testRuntimeCommandsRemainAllowlisted() throws {
        try expect(
            RuntimeCommand.allCases.map(\.rawValue) == ["start", "stop", "restart", "status", "scrcpy"],
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
            outputLimit: 5
        )
        try expect(result.exitCode == 0, "process failed")
        try expect(result.output == "12345", "process output was not bounded")
        try expect(result.wasTruncated, "truncation was not reported")
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
