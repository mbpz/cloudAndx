import CryptoKit
import Darwin
import Foundation
import Security
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
        try testRuntimeManifestVerifier()
        try testScrcpyDisplayFixtureSeam()
        try testCapabilityContracts()
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
        let recorder = EnvironmentRecorder()
        let service = RuntimeService(projectRoot: URL(fileURLWithPath: "/tmp/project"), processRunner: recorder)
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
        _ = try service.execute(.status)
        try expect(recorder.environment?["CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS"] == "120", "runtime service did not pin the trusted boot timeout")
    }

    static func testProcessRunnerRejectsUnknownEnvironmentOverrides() throws {
        let explicitBootTimeout = try FoundationProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            currentDirectory: URL(fileURLWithPath: "/"),
            environment: ["CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS": "120"],
            outputLimit: 4096
        )
        try expect(explicitBootTimeout.output.contains("CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS=120"), "trusted boot timeout override was not passed")
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

    static func testRuntimeManifestVerifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("templates"), withIntermediateDirectories: true)
        let template = root.appendingPathComponent("templates/clean.img")
        let data = Data("source-built-template".utf8)
        FileManager.default.createFile(atPath: template.path, contents: data)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: template.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let references = ["provenance/aosp.json", "licenses/AOSP-NOTICE", "licenses/NOTICE", "provenance/build.json", "provenance/toolchain.json", "provenance/sbom.spdx.json"]
        for reference in references {
            let url = root.appendingPathComponent(reference)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(reference.utf8))
        }
        var referenceArtifacts = [RuntimeArtifact]()
        for reference in references {
            let bytes = Data(reference.utf8)
            referenceArtifacts.append(RuntimeArtifact(path: reference, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), size: UInt64(bytes.count), role: "provenance", executable: false, requiredArchitecture: nil, sourceReference: "provenance/aosp.json", licenseReference: "licenses/AOSP-NOTICE", noticeReference: "licenses/NOTICE"))
        }
        let artifact = RuntimeArtifact(path: "templates/clean.img", sha256: digest, size: UInt64(data.count), role: "aosp-template", executable: false, requiredArchitecture: nil, sourceReference: "provenance/aosp.json", licenseReference: "licenses/AOSP-NOTICE", noticeReference: "licenses/NOTICE")
        let manifest = RuntimeManifest(schemaVersion: 1, runtimeID: "aosp17-arm64-test", targetPlatform: "macos", targetArchitecture: "arm64", sourceBuilt: true, immutableRoot: "AndroidRuntime", artifacts: [artifact] + referenceArtifacts, defaultTemplateArtifact: artifact.path, defaultTemplateDigest: digest, aemuRevision: "aemu-source-revision", aospRevision: "aosp-source-revision", adbRevision: "adb-source-revision", scrcpyRevision: "scrcpy-source-revision", buildAttestationReference: "provenance/build.json", toolchainAttestationReference: "provenance/toolchain.json", sbomReference: "provenance/sbom.spdx.json", licensesReference: "licenses/AOSP-NOTICE", noticeReference: "licenses/NOTICE")
        try RuntimeManifestVerifier.verify(manifest: manifest, at: root)

        let tampered = Data("tampered".utf8)
        try tampered.write(to: template)
        try expectManifestFailure(manifest, root, "tampered hash")
        try data.write(to: template)
        FileManager.default.createFile(atPath: root.appendingPathComponent("extra.bin").path, contents: Data())
        try expectManifestFailure(manifest, root, "extra file")
        try FileManager.default.removeItem(at: root.appendingPathComponent("extra.bin"))
        let forbidden = RuntimeArtifact(path: artifact.path, sha256: digest, size: artifact.size, role: "Google Play image", executable: false, requiredArchitecture: nil, sourceReference: artifact.sourceReference, licenseReference: artifact.licenseReference, noticeReference: artifact.noticeReference)
        let forbiddenManifest = RuntimeManifest(schemaVersion: 1, runtimeID: manifest.runtimeID, targetPlatform: manifest.targetPlatform, targetArchitecture: manifest.targetArchitecture, sourceBuilt: manifest.sourceBuilt, immutableRoot: manifest.immutableRoot, artifacts: [forbidden], defaultTemplateArtifact: manifest.defaultTemplateArtifact, defaultTemplateDigest: manifest.defaultTemplateDigest, aemuRevision: manifest.aemuRevision, aospRevision: manifest.aospRevision, adbRevision: manifest.adbRevision, scrcpyRevision: manifest.scrcpyRevision, buildAttestationReference: manifest.buildAttestationReference, toolchainAttestationReference: manifest.toolchainAttestationReference, sbomReference: manifest.sbomReference, licensesReference: manifest.licensesReference, noticeReference: manifest.noticeReference)
        try expectManifestFailure(forbiddenManifest, root, "forbidden Google Play classification")
        let traversal = RuntimeArtifact(path: "../escape", sha256: digest, size: artifact.size, role: artifact.role, executable: false, requiredArchitecture: nil, sourceReference: artifact.sourceReference, licenseReference: artifact.licenseReference, noticeReference: artifact.noticeReference)
        try expectManifestFailure(replacingArtifacts(manifest, [traversal]), root, "path traversal")
        let caseCollision = RuntimeArtifact(path: "Templates/CLEAN.IMG", sha256: digest, size: artifact.size, role: artifact.role, executable: false, requiredArchitecture: nil, sourceReference: artifact.sourceReference, licenseReference: artifact.licenseReference, noticeReference: artifact.noticeReference)
        try expectManifestFailure(replacingArtifacts(manifest, [artifact, caseCollision]), root, "case collision")
        let executable = RuntimeArtifact(path: artifact.path, sha256: digest, size: artifact.size, role: artifact.role, executable: true, requiredArchitecture: "arm64", sourceReference: artifact.sourceReference, licenseReference: artifact.licenseReference, noticeReference: artifact.noticeReference)
        try expectManifestFailure(replacingArtifacts(manifest, [executable]), root, "executable mode or architecture drift")
        let missingSBOM = RuntimeManifest(schemaVersion: manifest.schemaVersion, runtimeID: manifest.runtimeID, targetPlatform: manifest.targetPlatform, targetArchitecture: manifest.targetArchitecture, sourceBuilt: manifest.sourceBuilt, immutableRoot: manifest.immutableRoot, artifacts: manifest.artifacts, defaultTemplateArtifact: manifest.defaultTemplateArtifact, defaultTemplateDigest: manifest.defaultTemplateDigest, aemuRevision: manifest.aemuRevision, aospRevision: manifest.aospRevision, adbRevision: manifest.adbRevision, scrcpyRevision: manifest.scrcpyRevision, buildAttestationReference: manifest.buildAttestationReference, toolchainAttestationReference: manifest.toolchainAttestationReference, sbomReference: "", licensesReference: manifest.licensesReference, noticeReference: manifest.noticeReference)
        try expectManifestFailure(missingSBOM, root, "missing SBOM")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("untrusted-link").path, withDestinationPath: template.path)
        try expectManifestFailure(manifest, root, "symlink")
        try FileManager.default.removeItem(at: root.appendingPathComponent("untrusted-link"))
        let linkedRoot = root.deletingLastPathComponent().appendingPathComponent("linked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        try FileManager.default.createSymbolicLink(atPath: linkedRoot.path, withDestinationPath: root.path)
        do { _ = try RuntimeManifestVerifier.loadAndVerify(at: linkedRoot); throw TestFailure(message: "manifest verifier accepted symlink root") } catch is RuntimeManifestError {}
        let unsafeID = RuntimeManifest(schemaVersion: manifest.schemaVersion, runtimeID: "unsafe/path", targetPlatform: manifest.targetPlatform, targetArchitecture: manifest.targetArchitecture, sourceBuilt: manifest.sourceBuilt, immutableRoot: manifest.immutableRoot, artifacts: manifest.artifacts, defaultTemplateArtifact: manifest.defaultTemplateArtifact, defaultTemplateDigest: manifest.defaultTemplateDigest, aemuRevision: manifest.aemuRevision, aospRevision: manifest.aospRevision, adbRevision: manifest.adbRevision, scrcpyRevision: manifest.scrcpyRevision, buildAttestationReference: manifest.buildAttestationReference, toolchainAttestationReference: manifest.toolchainAttestationReference, sbomReference: manifest.sbomReference, licensesReference: manifest.licensesReference, noticeReference: manifest.noticeReference)
        try expectManifestFailure(unsafeID, root, "unsafe runtime ID")
        let nonSource = RuntimeManifest(schemaVersion: manifest.schemaVersion, runtimeID: manifest.runtimeID, targetPlatform: manifest.targetPlatform, targetArchitecture: manifest.targetArchitecture, sourceBuilt: false, immutableRoot: manifest.immutableRoot, artifacts: manifest.artifacts, defaultTemplateArtifact: manifest.defaultTemplateArtifact, defaultTemplateDigest: manifest.defaultTemplateDigest, aemuRevision: manifest.aemuRevision, aospRevision: manifest.aospRevision, adbRevision: manifest.adbRevision, scrcpyRevision: manifest.scrcpyRevision, buildAttestationReference: manifest.buildAttestationReference, toolchainAttestationReference: manifest.toolchainAttestationReference, sbomReference: manifest.sbomReference, licensesReference: manifest.licensesReference, noticeReference: manifest.noticeReference)
        try expectManifestFailure(nonSource, root, "unaudited source marker")
        let badTemplateDigest = RuntimeManifest(schemaVersion: manifest.schemaVersion, runtimeID: manifest.runtimeID, targetPlatform: manifest.targetPlatform, targetArchitecture: manifest.targetArchitecture, sourceBuilt: manifest.sourceBuilt, immutableRoot: manifest.immutableRoot, artifacts: manifest.artifacts, defaultTemplateArtifact: manifest.defaultTemplateArtifact, defaultTemplateDigest: String(repeating: "0", count: 64), aemuRevision: manifest.aemuRevision, aospRevision: manifest.aospRevision, adbRevision: manifest.adbRevision, scrcpyRevision: manifest.scrcpyRevision, buildAttestationReference: manifest.buildAttestationReference, toolchainAttestationReference: manifest.toolchainAttestationReference, sbomReference: manifest.sbomReference, licensesReference: manifest.licensesReference, noticeReference: manifest.noticeReference)
        try expectManifestFailure(badTemplateDigest, root, "template digest mismatch")
        let backslash = RuntimeArtifact(path: "templates\\bad", sha256: digest, size: artifact.size, role: artifact.role, executable: false, requiredArchitecture: nil, sourceReference: artifact.sourceReference, licenseReference: artifact.licenseReference, noticeReference: artifact.noticeReference)
        try expectManifestFailure(replacingArtifacts(manifest, [backslash]), root, "backslash path")
        let rawMachO = root.appendingPathComponent("templates/unlabelled-macho")
        let rawMachOBytes = Data([0xce, 0xfa, 0xed, 0xfe]) // 32-bit Mach-O magic; it must not evade the arm64 gate.
        try rawMachOBytes.write(to: rawMachO)
        let rawMachODigest = SHA256.hash(data: rawMachOBytes).map { String(format: "%02x", $0) }.joined()
        let unlabelledMachO = RuntimeArtifact(path: "templates/unlabelled-macho", sha256: rawMachODigest, size: UInt64(rawMachOBytes.count), role: "data", executable: false, requiredArchitecture: nil, sourceReference: artifact.sourceReference, licenseReference: artifact.licenseReference, noticeReference: artifact.noticeReference)
        let rawMachOManifest = RuntimeManifest(schemaVersion: manifest.schemaVersion, runtimeID: manifest.runtimeID, targetPlatform: manifest.targetPlatform, targetArchitecture: manifest.targetArchitecture, sourceBuilt: manifest.sourceBuilt, immutableRoot: manifest.immutableRoot, artifacts: [unlabelledMachO] + referenceArtifacts, defaultTemplateArtifact: unlabelledMachO.path, defaultTemplateDigest: rawMachODigest, aemuRevision: manifest.aemuRevision, aospRevision: manifest.aospRevision, adbRevision: manifest.adbRevision, scrcpyRevision: manifest.scrcpyRevision, buildAttestationReference: manifest.buildAttestationReference, toolchainAttestationReference: manifest.toolchainAttestationReference, sbomReference: manifest.sbomReference, licensesReference: manifest.licensesReference, noticeReference: manifest.noticeReference)
        try expectManifestFailure(rawMachOManifest, root, "unlabelled non-arm64 Mach-O")
        try FileManager.default.removeItem(at: rawMachO)
        let validJSON = try JSONEncoder().encode(manifest)
        try validJSON.write(to: root.appendingPathComponent("manifest.json"))
        _ = try RuntimeManifestVerifier.loadAndVerify(at: root)
        let duplicate = String(data: validJSON, encoding: .utf8)!.replacingOccurrences(of: "{", with: "{\"runtimeID\":\"duplicate\",", options: [], range: String(data: validJSON, encoding: .utf8)!.startIndex ..< String(data: validJSON, encoding: .utf8)!.index(after: String(data: validJSON, encoding: .utf8)!.startIndex))
        try Data(duplicate.utf8).write(to: root.appendingPathComponent("manifest.json"))
        do { _ = try RuntimeManifestVerifier.loadAndVerify(at: root); throw TestFailure(message: "duplicate root JSON key accepted") } catch is RuntimeManifestError {}
        let unknown = String(data: validJSON, encoding: .utf8)!.replacingOccurrences(of: "{", with: "{\"unknown\":true,", options: [], range: String(data: validJSON, encoding: .utf8)!.startIndex ..< String(data: validJSON, encoding: .utf8)!.index(after: String(data: validJSON, encoding: .utf8)!.startIndex))
        try Data(unknown.utf8).write(to: root.appendingPathComponent("manifest.json"))
        do { _ = try RuntimeManifestVerifier.loadAndVerify(at: root); throw TestFailure(message: "unknown root JSON key accepted") } catch is RuntimeManifestError {}
        let artifactUnknown = String(data: validJSON, encoding: .utf8)!.replacingOccurrences(of: "\"artifacts\":[{", with: "\"artifacts\":[{\"unknownArtifact\":true,")
        try Data(artifactUnknown.utf8).write(to: root.appendingPathComponent("manifest.json"))
        do { _ = try RuntimeManifestVerifier.loadAndVerify(at: root); throw TestFailure(message: "unknown artifact JSON key accepted") } catch is RuntimeManifestError {}
        try validJSON.write(to: root.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("manifest-link.json").path, withDestinationPath: root.appendingPathComponent("manifest.json").path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("manifest-link.json"), to: root.appendingPathComponent("manifest.json"))
        do { _ = try RuntimeManifestVerifier.loadAndVerify(at: root); throw TestFailure(message: "symlink manifest accepted") } catch is RuntimeManifestError {}
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
        let sparseManifest = root.appendingPathComponent("manifest.json")
        FileManager.default.createFile(atPath: sparseManifest.path, contents: Data([0x20]))
        let sparseHandle = try FileHandle(forWritingTo: sparseManifest)
        try sparseHandle.truncate(atOffset: UInt64(4 * 1024 * 1024 + 1))
        try sparseHandle.close()
        do { _ = try RuntimeManifestVerifier.loadAndVerify(at: root); throw TestFailure(message: "oversized sparse manifest accepted") } catch is RuntimeManifestError {}
    }

    static func testCapabilityContracts() throws {
        try expect(CapabilityRequestTimeout.command(.status) == CapabilityRequestTimeout.short, "status timeout drift")
        try expect(CapabilityRequestTimeout.command(.start) == nil, "start must remain pending through the 120s runner boot gate")
        try expect(CapabilityRequestTimeout.command(.snapshotResume) == nil, "snapshot resume must remain pending through the 120s runner boot gate")
        try expect(CapabilityRequestTimeout.command(.restart) == nil && CapabilityRequestTimeout.command(.stop) == nil, "lifecycle operations must not unlock while still running")
        try expect(CapabilityRequestTimeout.command(.snapshotSave) == nil && CapabilityRequestTimeout.command(.installAPK) == nil, "mutating requests must not receive a fixed XPC timeout")
        try expect(CapabilityRequestTimeout.command(.scrcpy) == nil, "scrcpy must not receive a fixed XPC timeout")
        let devRequirement = try CapabilityPeerRequirement.agent(mode: .developmentSDK)
        try expect(devRequirement == "identifier \"dev.cloudandx.android-client.CloudAndxCapabilityAgent\"", "dev agent requirement drift")
        let release = try CapabilityPeerRequirement.app(mode: .bundledRelease, teamID: "ABCDE12345")
        try expect(release.contains("anchor apple generic") && release.contains("ABCDE12345") && release.contains(CapabilityPeerRequirement.appIdentifier), "release requirement is incomplete")
        for requirement in [
            devRequirement,
            try CapabilityPeerRequirement.app(mode: .developmentSDK),
            release,
            try CapabilityPeerRequirement.agent(mode: .bundledRelease, teamID: "ABCDE12345"),
        ] {
            var parsed: SecRequirement?
            let status = SecRequirementCreateWithString(requirement as CFString, [], &parsed)
            try expect(status == errSecSuccess && parsed != nil, "NSXPC code-signing requirement did not parse: \(requirement)")
        }
        do { _ = try CapabilityPeerRequirement.app(mode: .bundledRelease); throw TestFailure(message: "missing team ID accepted") } catch CapabilityAgentError.invalidReleaseIdentity {}
        do { _ = try CapabilityPeerRequirement.app(mode: .bundledRelease, teamID: "bad"); throw TestFailure(message: "bad team ID accepted") } catch CapabilityAgentError.invalidReleaseIdentity {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("source.apk"); let bytes = Data("full content".utf8); try bytes.write(to: source)
        let input = try FileHandle(forReadingFrom: source); try input.seekToEnd()
        let staged = try CapabilityFileStager.stage(input, displayName: "unsafe name.apk", requireAPK: true, in: root)
        defer { try? input.close(); try? FileManager.default.removeItem(at: staged) }
        let stagedBytes = try Data(contentsOf: staged)
        try expect(stagedBytes == bytes, "stager did not reset input offset")
        let mode = try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber
        try expect((mode?.intValue ?? 0) & 0o777 == 0o600, "staged mode is not 0600")
        do { _ = try CapabilityFileStager.sanitizedFilename("not-apk", requireAPK: true); throw TestFailure(message: "invalid APK filename accepted") } catch CapabilityAgentError.invalidFilename {}
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do { _ = try CapabilityFileStager.stage(try FileHandle(forReadingFrom: source), displayName: "too-big.apk", requireAPK: true, in: root, limitOverride: 2); throw TestFailure(message: "size limit accepted") } catch CapabilityAgentError.fileTooLarge {}
        let after = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        try expect(after == before, "oversize staging left a file")
        let unsafe = root.appendingPathComponent("unsafe"); try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        do { _ = try CapabilityFileStager.stage(try FileHandle(forReadingFrom: source), displayName: "x.apk", requireAPK: true, in: unsafe); throw TestFailure(message: "unsafe staging directory accepted") } catch CapabilityAgentError.xpcUnavailable {}
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)
        do { _ = try CapabilityFileStager.stage(try FileHandle(forReadingFrom: source), displayName: "x.apk", requireAPK: true, in: link); throw TestFailure(message: "symlink directory accepted") } catch CapabilityAgentError.xpcUnavailable {}
        let directoryFD = open(root.path, O_RDONLY)
        try expect(directoryFD >= 0, "failed to open directory descriptor")
        let directoryHandle = FileHandle(fileDescriptor: directoryFD, closeOnDealloc: true)
        defer { try? directoryHandle.close() }
        do { _ = try CapabilityFileStager.stage(directoryHandle, displayName: "directory.apk", requireAPK: true, in: root); throw TestFailure(message: "directory descriptor accepted") } catch CapabilityAgentError.xpcUnavailable {}
        var pipeDescriptors = [Int32](repeating: -1, count: 2)
        try expect(pipe(&pipeDescriptors) == 0, "failed to create descriptor test pipe")
        let pipeRead = FileHandle(fileDescriptor: pipeDescriptors[0], closeOnDealloc: true)
        close(pipeDescriptors[1])
        defer { try? pipeRead.close() }
        do { _ = try CapabilityFileStager.stage(pipeRead, displayName: "pipe.apk", requireAPK: true, in: root); throw TestFailure(message: "pipe descriptor accepted") } catch CapabilityAgentError.xpcUnavailable {}
        let writeOnlyFD = open(source.path, O_WRONLY)
        try expect(writeOnlyFD >= 0, "failed to open write-only source")
        let writeOnly = FileHandle(fileDescriptor: writeOnlyFD, closeOnDealloc: true)
        defer { try? writeOnly.close() }
        do { _ = try CapabilityFileStager.stage(writeOnly, displayName: "write-only.apk", requireAPK: true, in: root); throw TestFailure(message: "write-only descriptor accepted") } catch CapabilityAgentError.xpcUnavailable {}
        let png = root.appendingPathComponent("image.png"); try Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]).write(to: png)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: png.path)
        let validPNG = try CapabilityPNGValidator.validatedData(at: png)
        try expect(validPNG.count == 8, "PNG signature not accepted")
        try Data("bad-data".utf8).write(to: png); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: png.path)
        do { _ = try CapabilityPNGValidator.validatedData(at: png); throw TestFailure(message: "bad PNG accepted") } catch CapabilityAgentError.invalidFilename {}
        try Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]).write(to: png); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: png.path)
        do { _ = try CapabilityPNGValidator.validatedData(at: png); throw TestFailure(message: "wrong PNG mode accepted") } catch CapabilityAgentError.invalidFilename {}
        var callbacks = 0; let semaphore = DispatchSemaphore(value: 0); let gate = RequestGate { _ in callbacks += 1; semaphore.signal() }; gate.scheduleTimeout(after: 0.01); _ = semaphore.wait(timeout: .now() + 0.1); gate.succeed("late")
        try expect(callbacks == 1, "request gate resumed more than once")
        var registryCallbacks = 0; let registry = OutstandingRequestRegistry(); let first = RequestGate { _ in registryCallbacks += 1 }; let second = RequestGate { _ in registryCallbacks += 1 }; _ = registry.register(first); _ = registry.register(second); registry.failAll(CapabilityAgentError.xpcInterrupted); first.succeed("late"); second.fail(CapabilityAgentError.xpcInterrupted)
        try expect(registryCallbacks == 2, "registry did not fail each gate once")
        let env = try FoundationProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], currentDirectory: URL(fileURLWithPath: "/"), environment: ["CLOUDANDX_DEVELOPMENT_PROJECT_ROOT": "/tmp/example"], outputLimit: 4096)
        try expect(env.output.contains("CLOUDANDX_DEVELOPMENT_PROJECT_ROOT=/tmp/example"), "explicit development root override was not passed")
    }

    static func testScrcpyDisplayFixtureSeam() throws {
        func be32(_ n: UInt32) -> Data { Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]) }
        func be64(_ n: UInt64) -> Data { be32(UInt32(truncatingIfNeeded: n >> 32)) + be32(UInt32(truncatingIfNeeded: n)) }
        var stream = Data("h264".utf8) + be32(0x8000_0000) + be32(1080) + be32(2400)
        stream += be64((1 << 62) | (1 << 61) | 42) + be32(3) + Data([1, 2, 3])
        let parser = ScrcpyVideoParser()
        let initialPackets = try parser.feed(stream.prefix(7))
        try expect(initialPackets.isEmpty, "fragmented display header emitted early")
        let packets = try parser.feed(Data(stream.dropFirst(7)))
        try expect(parser.videoConfiguration == .init(deviceName: "endpoint", codec: "h264", width: 1080, height: 2400), "scrcpy 4.1 configuration drift")
        try expect(packets == [.init(timestamp: 42, isConfiguration: true, isKeyFrame: true, payload: Data([1,2,3]))], "video packet flags or timestamp drift")
        try parser.finish()
        let malformed = ScrcpyVideoParser()
        do { _ = try malformed.feed(Data("vp09".utf8) + be32(0) + be32(1) + be32(1)); throw TestFailure(message: "unsupported codec accepted") } catch ScrcpyDisplayError.unsupportedCodec("vp09") {}
        let oversized = ScrcpyVideoParser(); _ = try oversized.feed(Data("h264".utf8) + be32(0x8000_0000) + be32(1) + be32(1))
        do { _ = try oversized.feed(be64(0) + be32(UInt32(ScrcpyVideoParser.maxPacketBytes + 1))); throw TestFailure(message: "oversized packet accepted") } catch ScrcpyDisplayError.oversizedPacket {}
        let truncated = ScrcpyVideoParser(); _ = try truncated.feed(Data("h264".utf8) + be32(0x8000_0000) + be32(1) + be32(1) + be64(0))
        do { try truncated.finish(); throw TestFailure(message: "truncated stream accepted") } catch ScrcpyDisplayError.truncated {}
        let queue = ScrcpyPacketQueue(limit: 1); try queue.push(.init(timestamp: 0, isConfiguration: false, isKeyFrame: false, payload: Data()))
        do { try queue.push(.init(timestamp: 1, isConfiguration: false, isKeyFrame: false, payload: Data())); throw TestFailure(message: "display queue exceeded bound") } catch ScrcpyDisplayError.queueFull {}
        try expect(ScrcpyControl.key(action: .down, keyCode: 3).encoded.map { String(format: "%02x", $0) }.joined() == "0000000000030000000000000000", "key control golden bytes drift")
        let clampedTouch = try ScrcpyControl.touch(.down, x: -1, y: 5000, width: 100, height: 200)
        let clampedScroll = try ScrcpyControl.scroll(x: 5, y: 6, width: 100, height: 200, horizontal: -16, vertical: 32)
        try expect(clampedTouch.encoded.count == 32, "touch control size drift")
        try expect(clampedScroll.encoded.count == 21, "scroll control size drift")
        let zero = ScrcpyCoordinateMapper(source: .init(width: 100, height: 200), view: .init(width: 200, height: 200)).map(.init(x: 0, y: 0))
        try expect(zero.x == 0 && zero.y == 0, "letterbox mapping drift")
        let rotated = ScrcpyCoordinateMapper(source: .init(width: 100, height: 200), view: .init(width: 200, height: 100), rotation: .degrees90).map(.init(x: 50, y: 50))
        try expect(rotated.x >= 0 && rotated.x < 100 && rotated.y >= 0 && rotated.y < 200, "rotation mapping escaped source")
        try expect(ScrcpyCoordinateMapper(source: .zero, view: .zero).map(.init(x: 5, y: 5)) == .zero, "invalid display geometry did not fail closed")
    }

    static func expectManifestFailure(_ manifest: RuntimeManifest, _ root: URL, _ message: String) throws {
        do {
            try RuntimeManifestVerifier.verify(manifest: manifest, at: root)
            throw TestFailure(message: "manifest verifier accepted \(message)")
        } catch is RuntimeManifestError {}
    }

    static func replacingArtifacts(_ manifest: RuntimeManifest, _ artifacts: [RuntimeArtifact]) -> RuntimeManifest {
        RuntimeManifest(schemaVersion: manifest.schemaVersion, runtimeID: manifest.runtimeID, targetPlatform: manifest.targetPlatform, targetArchitecture: manifest.targetArchitecture, sourceBuilt: manifest.sourceBuilt, immutableRoot: manifest.immutableRoot, artifacts: artifacts, defaultTemplateArtifact: manifest.defaultTemplateArtifact, defaultTemplateDigest: manifest.defaultTemplateDigest, aemuRevision: manifest.aemuRevision, aospRevision: manifest.aospRevision, adbRevision: manifest.adbRevision, scrcpyRevision: manifest.scrcpyRevision, buildAttestationReference: manifest.buildAttestationReference, toolchainAttestationReference: manifest.toolchainAttestationReference, sbomReference: manifest.sbomReference, licensesReference: manifest.licensesReference, noticeReference: manifest.noticeReference)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class EnvironmentRecorder: ProcessRunning, @unchecked Sendable {
    private(set) var environment: [String: String]?
    func run(executable: URL, arguments: [String], currentDirectory: URL, environment: [String: String], outputLimit: Int) throws -> ProcessResult {
        self.environment = environment
        return ProcessResult(exitCode: 0, output: "cloudandx-native: stopped", wasTruncated: false)
    }
}
