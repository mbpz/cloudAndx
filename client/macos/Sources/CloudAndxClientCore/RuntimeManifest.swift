import CryptoKit
import Darwin
import Foundation

/// Signed-app runtime inventory.  Every entry describes one immutable byte in
/// `Contents/Resources/AndroidRuntime`; writable AVD and snapshot state is never
/// part of this manifest.
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let runtimeID: String
    public let targetPlatform: String
    public let targetArchitecture: String
    public let sourceBuilt: Bool
    public let immutableRoot: String
    public let artifacts: [RuntimeArtifact]
    public let defaultTemplateArtifact: String
    public let defaultTemplateDigest: String
    public let aemuRevision: String
    public let aospRevision: String
    public let adbRevision: String
    public let scrcpyRevision: String
    public let buildAttestationReference: String
    public let toolchainAttestationReference: String
    public let sbomReference: String
    public let licensesReference: String
    public let noticeReference: String

    public init(schemaVersion: Int, runtimeID: String, targetPlatform: String, targetArchitecture: String, sourceBuilt: Bool, immutableRoot: String, artifacts: [RuntimeArtifact], defaultTemplateArtifact: String, defaultTemplateDigest: String, aemuRevision: String, aospRevision: String, adbRevision: String, scrcpyRevision: String, buildAttestationReference: String, toolchainAttestationReference: String, sbomReference: String, licensesReference: String, noticeReference: String) {
        self.schemaVersion = schemaVersion
        self.runtimeID = runtimeID
        self.targetPlatform = targetPlatform
        self.targetArchitecture = targetArchitecture
        self.sourceBuilt = sourceBuilt
        self.immutableRoot = immutableRoot
        self.artifacts = artifacts
        self.defaultTemplateArtifact = defaultTemplateArtifact
        self.defaultTemplateDigest = defaultTemplateDigest
        self.aemuRevision = aemuRevision
        self.aospRevision = aospRevision
        self.adbRevision = adbRevision
        self.scrcpyRevision = scrcpyRevision
        self.buildAttestationReference = buildAttestationReference
        self.toolchainAttestationReference = toolchainAttestationReference
        self.sbomReference = sbomReference
        self.licensesReference = licensesReference
        self.noticeReference = noticeReference
    }
}

public struct RuntimeArtifact: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let size: UInt64
    public let role: String
    public let executable: Bool
    public let requiredArchitecture: String?
    public let sourceReference: String
    public let licenseReference: String
    public let noticeReference: String

    public init(path: String, sha256: String, size: UInt64, role: String, executable: Bool, requiredArchitecture: String?, sourceReference: String, licenseReference: String, noticeReference: String) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.role = role
        self.executable = executable
        self.requiredArchitecture = requiredArchitecture
        self.sourceReference = sourceReference
        self.licenseReference = licenseReference
        self.noticeReference = noticeReference
    }
}

public enum RuntimeMode: String, Codable, Sendable, Equatable {
    case developmentSDK = "development-sdk"
    case bundledRelease = "bundled-release"
    case unavailable

    public var displayName: String {
        switch self {
        case .developmentSDK: "Development SDK compatibility (not a product runtime)"
        case .bundledRelease: "Bundled release runtime"
        case .unavailable: "Runtime configuration unavailable"
        }
    }
}

public struct RuntimeIdentity: Sendable, Equatable {
    public let mode: RuntimeMode
    public let runtimeID: String
    public let manifestDigest: String
    public let templateDigest: String
}

public enum RuntimeManifestError: Error, LocalizedError, Equatable, Sendable {
    case invalidManifest(String)
    case invalidArtifact(String)
    case missingFile(String)
    case extraFile(String)
    case symlink(String)
    case hashMismatch(String)
    case sizeMismatch(String)
    case executableModeMismatch(String)
    case architectureMismatch(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidManifest(reason): "Invalid Android runtime manifest: \(reason)"
        case let .invalidArtifact(path): "Invalid Android runtime artifact: \(path)"
        case let .missingFile(path): "Missing immutable runtime artifact: \(path)"
        case let .extraFile(path): "Unexpected immutable runtime artifact: \(path)"
        case let .symlink(path): "Symlinks are not allowed in the immutable runtime: \(path)"
        case let .hashMismatch(path): "Runtime artifact hash drift: \(path)"
        case let .sizeMismatch(path): "Runtime artifact size drift: \(path)"
        case let .executableModeMismatch(path): "Runtime artifact executable mode drift: \(path)"
        case let .architectureMismatch(path): "Runtime artifact architecture is not ARM64: \(path)"
        }
    }
}

public enum RuntimeManifestVerifier {
    public static let supportedSchemaVersion = 1
    public static let manifestFilename = "manifest.json"
    private static let maximumManifestBytes = 4 * 1024 * 1024

    public static func loadAndVerify(at root: URL) throws -> RuntimeIdentity {
        let root = root.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true else { throw RuntimeManifestError.invalidManifest("immutable root is not a directory") }
        guard rootValues.isSymbolicLink != true else { throw RuntimeManifestError.symlink(".") }
        let manifestURL = root.appendingPathComponent(manifestFilename)
        let data = try readManifest(manifestURL)
        try StrictRuntimeManifestJSON.validate(data)
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        try verify(manifest: manifest, at: root)
        return RuntimeIdentity(
            mode: .bundledRelease,
            runtimeID: manifest.runtimeID,
            manifestDigest: sha256(data),
            templateDigest: manifest.defaultTemplateDigest.lowercased()
        )
    }

    private static func readManifest(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RuntimeManifestError.missingFile(manifestFilename) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw RuntimeManifestError.invalidManifest("manifest is not a regular file")
        }
        guard info.st_size >= 1, info.st_size <= maximumManifestBytes else {
            throw RuntimeManifestError.invalidManifest("manifest JSON exceeds byte limit")
        }
        var data = Data(); data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < Int(info.st_size) {
            let count = read(fd, &buffer, min(buffer.count, Int(info.st_size) - data.count))
            guard count > 0 else { throw RuntimeManifestError.invalidManifest("manifest changed while reading") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var finalInfo = stat()
        guard fstat(fd, &finalInfo) == 0, finalInfo.st_size == info.st_size else {
            throw RuntimeManifestError.invalidManifest("manifest changed while reading")
        }
        return data
    }

    public static func verify(manifest: RuntimeManifest, at root: URL) throws {
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw RuntimeManifestError.invalidManifest("unsupported schemaVersion")
        }
        guard manifest.targetPlatform == "macos", manifest.targetArchitecture == "arm64", manifest.sourceBuilt else {
            throw RuntimeManifestError.invalidManifest("runtime must be source-built for macos/arm64")
        }
        guard manifest.immutableRoot == "AndroidRuntime", isSafeRuntimeID(manifest.runtimeID) else {
            throw RuntimeManifestError.invalidManifest("immutable root or runtime ID is missing")
        }
        try requireReferences([
            manifest.defaultTemplateArtifact, manifest.defaultTemplateDigest, manifest.aemuRevision,
            manifest.aospRevision, manifest.adbRevision, manifest.scrcpyRevision,
            manifest.buildAttestationReference, manifest.toolchainAttestationReference,
            manifest.sbomReference, manifest.licensesReference, manifest.noticeReference,
        ])
        try requireRelativePath(manifest.defaultTemplateArtifact)
        guard isSHA256(manifest.defaultTemplateDigest) else {
            throw RuntimeManifestError.invalidManifest("template digest is not SHA-256")
        }

        var paths = Set<String>()
        var foldedPaths = Set<String>()
        var expected = Set<String>()
        for artifact in manifest.artifacts {
            try requireRelativePath(artifact.path)
            let normalized = artifact.path.precomposedStringWithCanonicalMapping
            guard paths.insert(normalized).inserted,
                  foldedPaths.insert(normalized.lowercased()).inserted else {
                throw RuntimeManifestError.invalidManifest("duplicate or case-colliding artifact path")
            }
            guard isSHA256(artifact.sha256), !artifact.role.isEmpty,
                  !artifact.sourceReference.isEmpty, !artifact.licenseReference.isEmpty,
                  !artifact.noticeReference.isEmpty else {
                throw RuntimeManifestError.invalidArtifact(artifact.path)
            }
            let classification = ([manifest.runtimeID, manifest.immutableRoot, manifest.aemuRevision, manifest.aospRevision, manifest.adbRevision, manifest.scrcpyRevision, manifest.buildAttestationReference, manifest.toolchainAttestationReference, manifest.sbomReference, manifest.licensesReference, manifest.noticeReference, artifact.path, artifact.role, artifact.sourceReference, artifact.licenseReference, artifact.noticeReference].joined(separator: " ")).lowercased()
            guard !classification.contains("google play"), !classification.contains("google_apis"),
                  !classification.contains("google apis"), !classification.contains("android sdk") else {
                throw RuntimeManifestError.invalidArtifact(artifact.path)
            }
            if let requiredArchitecture = artifact.requiredArchitecture, requiredArchitecture != "arm64" {
                throw RuntimeManifestError.invalidArtifact(artifact.path)
            }
            expected.insert(normalized)
        }
        guard expected.contains(manifest.defaultTemplateArtifact) else {
            throw RuntimeManifestError.invalidManifest("default template is not an artifact")
        }
        guard manifest.artifacts.first(where: { $0.path == manifest.defaultTemplateArtifact })?.sha256.lowercased() == manifest.defaultTemplateDigest.lowercased() else {
            throw RuntimeManifestError.invalidManifest("template digest does not match template artifact")
        }
        try verifyReferences(manifest: manifest, declaredArtifacts: expected)

        let actual = try regularFiles(under: root)
        let allowedActual = actual.subtracting([manifestFilename])
        for path in expected where !allowedActual.contains(path) { throw RuntimeManifestError.missingFile(path) }
        for path in allowedActual where !expected.contains(path) { throw RuntimeManifestError.extraFile(path) }

        for artifact in manifest.artifacts {
            let url = root.appendingPathComponent(artifact.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true else { throw RuntimeManifestError.missingFile(artifact.path) }
            guard values.isSymbolicLink != true else { throw RuntimeManifestError.symlink(artifact.path) }
            guard UInt64(values.fileSize ?? -1) == artifact.size else { throw RuntimeManifestError.sizeMismatch(artifact.path) }
            guard try sha256File(url) == artifact.sha256.lowercased() else {
                throw RuntimeManifestError.hashMismatch(artifact.path)
            }
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            let isExecutable = ((mode?.intValue ?? 0) & 0o111) != 0
            guard isExecutable == artifact.executable else { throw RuntimeManifestError.executableModeMismatch(artifact.path) }
            if (artifact.executable || artifact.requiredArchitecture == "arm64" || MachOInspector.isMachO(at: url)), !MachOInspector.supportsARM64(at: url) {
                throw RuntimeManifestError.architectureMismatch(artifact.path)
            }
        }
    }

    private static func regularFiles(under root: URL) throws -> Set<String> {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            throw RuntimeManifestError.invalidManifest("immutable root cannot be read")
        }
        var files = Set<String>()
        for case let url as URL in enumerator {
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { throw RuntimeManifestError.symlink(relative) }
            if values.isRegularFile == true { files.insert(relative) }
            else if values.isDirectory != true { throw RuntimeManifestError.invalidManifest("special filesystem node: \(relative)") }
        }
        return files
    }

    private static func requireRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              path == path.precomposedStringWithCanonicalMapping else {
            throw RuntimeManifestError.invalidArtifact(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimeManifestError.invalidArtifact(path)
        }
    }

    private static func isSafeRuntimeID(_ runtimeID: String) -> Bool {
        runtimeID.count > 0 && runtimeID.count <= 96 && runtimeID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    private static func requireReferences(_ references: [String]) throws {
        guard references.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RuntimeManifestError.invalidManifest("required provenance, SBOM, license, or attestation reference missing")
        }
    }

    private static func verifyReferences(manifest: RuntimeManifest, declaredArtifacts: Set<String>) throws {
        let references = [manifest.defaultTemplateArtifact, manifest.buildAttestationReference, manifest.toolchainAttestationReference, manifest.sbomReference, manifest.licensesReference, manifest.noticeReference] + manifest.artifacts.flatMap { [$0.sourceReference, $0.licenseReference, $0.noticeReference] }
        for reference in references {
            try requireRelativePath(reference)
            guard declaredArtifacts.contains(reference) else {
                throw RuntimeManifestError.invalidManifest("reference is not a declared immutable artifact: \(reference)")
            }
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// JSONDecoder accepts duplicate object keys and ignores unknown keys. Runtime
/// manifests are an immutable security boundary, so reject both before decode.
private enum StrictRuntimeManifestJSON {
    private static let maximumBytes = 4 * 1024 * 1024
    private static let rootKeys: Set<String> = ["schemaVersion", "runtimeID", "targetPlatform", "targetArchitecture", "sourceBuilt", "immutableRoot", "artifacts", "defaultTemplateArtifact", "defaultTemplateDigest", "aemuRevision", "aospRevision", "adbRevision", "scrcpyRevision", "buildAttestationReference", "toolchainAttestationReference", "sbomReference", "licensesReference", "noticeReference"]
    private static let artifactKeys: Set<String> = ["path", "sha256", "size", "role", "executable", "requiredArchitecture", "sourceReference", "licenseReference", "noticeReference"]

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw RuntimeManifestError.invalidManifest("manifest JSON exceeds byte limit") }
        var scanner = Scanner(bytes: Array(data))
        try scanner.object(allowed: rootKeys, root: true)
        scanner.whitespace()
        guard scanner.atEnd else { throw RuntimeManifestError.invalidManifest("trailing JSON data") }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var atEnd: Bool { index == bytes.count }
        mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws { whitespace(); guard index < bytes.count, bytes[index] == byte else { throw RuntimeManifestError.invalidManifest("malformed JSON") }; index += 1 }
        mutating func object(allowed: Set<String>, root: Bool) throws {
            try take(123); whitespace(); var seen = Set<String>()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            while true {
                let key = try string(); guard allowed.contains(key), seen.insert(key).inserted else { throw RuntimeManifestError.invalidManifest("unknown or duplicate JSON key: \(key)") }
                try take(58)
                if root && key == "artifacts" { try artifacts() } else { try value() }
                whitespace(); guard index < bytes.count else { throw RuntimeManifestError.invalidManifest("unterminated JSON object") }
                if bytes[index] == 125 { index += 1; return }; guard bytes[index] == 44 else { throw RuntimeManifestError.invalidManifest("malformed JSON object") }; index += 1
            }
        }
        mutating func artifacts() throws {
            try take(91); whitespace(); if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true { try object(allowed: artifactKeys, root: false); whitespace(); guard index < bytes.count else { throw RuntimeManifestError.invalidManifest("unterminated artifacts") }; if bytes[index] == 93 { index += 1; return }; guard bytes[index] == 44 else { throw RuntimeManifestError.invalidManifest("malformed artifacts") }; index += 1 }
        }
        mutating func value() throws {
            whitespace(); guard index < bytes.count else { throw RuntimeManifestError.invalidManifest("truncated JSON") }
            switch bytes[index] { case 34: _ = try string(); case 123: try object(allowed: [], root: false); case 91: try array(); default: while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 } }
        }
        mutating func array() throws { try take(91); whitespace(); if index < bytes.count, bytes[index] == 93 { index += 1; return }; while true { try value(); whitespace(); guard index < bytes.count else { throw RuntimeManifestError.invalidManifest("unterminated JSON array") }; if bytes[index] == 93 { index += 1; return }; guard bytes[index] == 44 else { throw RuntimeManifestError.invalidManifest("malformed JSON array") }; index += 1 } }
        mutating func string() throws -> String {
            try take(34); let start = index; var escaped = false
            while index < bytes.count { let byte = bytes[index]; index += 1; if escaped { escaped = false; continue }; if byte == 92 { escaped = true; continue }; if byte == 34 { let token = Data([34] + Array(bytes[start ..< index])); guard let list = try? JSONSerialization.jsonObject(with: Data("[".utf8) + token + Data("]".utf8)) as? [String], let value = list.first else { throw RuntimeManifestError.invalidManifest("invalid JSON string") }; return value }; if byte < 32 { throw RuntimeManifestError.invalidManifest("invalid JSON control character") } }
            throw RuntimeManifestError.invalidManifest("unterminated JSON string")
        }
    }
}

private enum MachOInspector {
    // Mach-O magic values are read little-endian.  FAT headers use big-endian.
    private static let machO64LE: UInt32 = 0xfeedfacf
    private static let fat32BE: UInt32 = 0xcafebabe
    private static let fat64BE: UInt32 = 0xcafebabf
    private static let cpuTypeARM64: UInt32 = 0x0100000c

    static func supportsARM64(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = (try? handle.read(upToCount: 8)) ?? nil, prefix.count == 8 else { return false }
        let data = prefix
        let magic = le32(data, 0)
        if magic == machO64LE { return le32(data, 4) == cpuTypeARM64 }
        let bigMagic = be32(data, 0)
        guard bigMagic == fat32BE || bigMagic == fat64BE else { return false }
        let count = Int(be32(data, 4))
        let entrySize = bigMagic == fat64BE ? 32 : 20
        guard count >= 1, count <= 4_096 else { return false }
        guard let architectures = (try? handle.read(upToCount: count * entrySize)) ?? nil, architectures.count == count * entrySize else { return false }
        return (0 ..< count).contains { be32(architectures, $0 * entrySize) == cpuTypeARM64 }
    }

    static func isMachO(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: 4)) ?? nil, data.count == 4 else { return false }
        switch Array(data) {
        case [0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], // 64-bit Mach-O, both endian encodings
             [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xce], // 32-bit Mach-O, both endian encodings
             [0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf], // fat/fat64 big endian
             [0xbe, 0xba, 0xfe, 0xca], [0xbf, 0xba, 0xfe, 0xca]: // fat/fat64 little endian
            return true
        default:
            return false
        }
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset ..< offset + 4].enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset ..< offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
