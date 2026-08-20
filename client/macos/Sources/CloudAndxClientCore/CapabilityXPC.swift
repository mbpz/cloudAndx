import Foundation
import Darwin

/// The only IPC surface between the UI and the embedded capability agent.
/// File descriptors cross XPC; paths, bookmarks, environments and shell text do not.
@objc public protocol CloudAndxCapabilityXPCProtocol {
    func executeCommand(_ rawValue: String, withReply reply: @escaping (String?, NSError?) -> Void)
    func readLog(withReply reply: @escaping (String?, NSError?) -> Void)
    func installAPK(_ source: FileHandle, displayName: String, withReply reply: @escaping (String?, NSError?) -> Void)
    func pushFile(_ source: FileHandle, displayName: String, withReply reply: @escaping (String?, NSError?) -> Void)
    func captureScreenshot(to destination: FileHandle, withReply reply: @escaping (String?, NSError?) -> Void)
}

public enum CapabilityAgentError: Error, LocalizedError, Sendable {
    case invalidCommand
    case fileTooLarge
    case invalidFilename
    case xpcUnavailable
    case xpcInterrupted
    case invalidReleaseIdentity

    public var errorDescription: String? {
        switch self {
        case .invalidCommand: "Capability agent rejected this command"
        case .fileTooLarge: "Selected file exceeds the capability-agent limit"
        case .invalidFilename: "Selected filename is not allowed"
        case .xpcUnavailable: "CloudAndx capability agent is unavailable"
        case .xpcInterrupted: "CloudAndx capability agent connection was interrupted"
        case .invalidReleaseIdentity: "Release XPC identity configuration is invalid"
        }
    }
}

public enum CapabilityPeerRequirement {
    public static let appIdentifier = "dev.cloudandx.android-client"
    public static let agentIdentifier = "dev.cloudandx.android-client.CloudAndxCapabilityAgent"
    public static func agent(mode: RuntimeMode, teamID: String? = nil) throws -> String {
        try requirement(identifier: agentIdentifier, mode: mode, teamID: teamID)
    }
    public static func app(mode: RuntimeMode, teamID: String? = nil) throws -> String {
        try requirement(identifier: appIdentifier, mode: mode, teamID: teamID)
    }
    private static func requirement(identifier: String, mode: RuntimeMode, teamID: String?) throws -> String {
        if mode == .developmentSDK { return "identifier \"\(identifier)\"" }
        guard let teamID, teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { throw CapabilityAgentError.invalidReleaseIdentity }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

public enum CapabilityFileStager {
    public static let apkLimit: UInt64 = 2 * 1024 * 1024 * 1024
    public static let fileLimit: UInt64 = 512 * 1024 * 1024

    public static func sanitizedFilename(_ displayName: String, requireAPK: Bool) throws -> String {
        let safe = displayName.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains(scalar) ? Character(String(scalar)) : "_"
        }
        let result = String(safe.prefix(120))
        guard !result.isEmpty, result != ".", result != "..", (!requireAPK || result.lowercased().hasSuffix(".apk")) else {
            throw CapabilityAgentError.invalidFilename
        }
        return result
    }

    /// The agent calls this with a descriptor received from the main app. The
    /// created file is private, exclusive and never named by a UI supplied path.
    public static func stage(_ source: FileHandle, displayName: String, requireAPK: Bool, in directory: URL, limitOverride: UInt64? = nil) throws -> URL {
        let name = try sanitizedFilename(displayName, requireAPK: requireAPK)
        let limit = limitOverride ?? (requireAPK ? apkLimit : fileLimit)
        var sourceInfo = stat()
        let sourceFlags = fcntl(source.fileDescriptor, F_GETFL)
        guard fstat(source.fileDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG,
              sourceInfo.st_uid == geteuid(),
              sourceFlags >= 0,
              (sourceFlags & O_ACCMODE) != O_WRONLY else { throw CapabilityAgentError.xpcUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              (info.st_mode & 0o777) == 0o700, info.st_uid == geteuid(), access(directory.path, W_OK) == 0 else { throw CapabilityAgentError.xpcUnavailable }
        let target = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        let fd = open(target.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, 0o600)
        guard fd >= 0 else { throw CapabilityAgentError.xpcUnavailable }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var complete = false
        defer { try? output.close() }
        defer { if !complete { try? FileManager.default.removeItem(at: target) } }
        try source.seek(toOffset: 0)
        var copied: UInt64 = 0
        while true {
            let data = try source.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            copied += UInt64(data.count)
            guard copied <= limit else { try? FileManager.default.removeItem(at: target); throw CapabilityAgentError.fileTooLarge }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        complete = true
        return target
    }
}

public enum CapabilityPNGValidator {
    public static let limit: UInt64 = 64 * 1024 * 1024
    public static func validatedData(at url: URL) throws -> Data {
        var info = stat(); guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o777) == 0o600, UInt64(info.st_size) >= 8, UInt64(info.st_size) <= limit else { throw CapabilityAgentError.invalidFilename }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        guard data.count == Int(info.st_size), data.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) else { throw CapabilityAgentError.invalidFilename }
        return data
    }
}

public final class OutstandingRequestRegistry: @unchecked Sendable {
    private let lock = NSLock(); private var gates = [UUID: RequestGate]()
    public init() {}
    public func register(_ gate: RequestGate) -> UUID { lock.lock(); defer { lock.unlock() }; let id = UUID(); gates[id] = gate; return id }
    public func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; gates.removeValue(forKey: id) }
    public func failAll(_ error: Error) { lock.lock(); let values = Array(gates.values); gates.removeAll(); lock.unlock(); values.forEach { $0.fail(error) } }
}

public protocol CapabilityServing: Sendable {
    func execute(_ command: RuntimeCommand) async throws -> ProcessResult
    func readLog() async throws -> String
    func installAPK(_ handle: FileHandle, name: String) async throws -> String
    func pushFile(_ handle: FileHandle, name: String) async throws -> String
    func captureScreenshot(to handle: FileHandle) async throws -> String
}

/// Only read-only requests time out. XPC cannot cancel an authority operation,
/// so releasing UI state while a lifecycle, file, or interaction request is
/// still executing would permit conflicting commands against the one Android.
public enum CapabilityRequestTimeout {
    public static let short: TimeInterval = 15

    public static func command(_ command: RuntimeCommand) -> TimeInterval? {
        switch command {
        case .status, .snapshotStatus:
            short
        case .start, .stop, .restart, .scrcpy, .snapshotSave, .snapshotResume,
                .installAPK, .pushFile, .captureScreenshot:
            // start/resume may consume the trusted 120s boot gate; every
            // mutating action remains pending until reply or connection loss.
            nil
        }
    }
}

public final class CapabilityXPCClient: @unchecked Sendable, CapabilityServing {
    private let connection: NSXPCConnection
    private let outstanding = OutstandingRequestRegistry()

    public init(mode: RuntimeMode = .developmentSDK, teamID: String? = nil, serviceName: String = CapabilityPeerRequirement.agentIdentifier, shortTimeout: TimeInterval = CapabilityRequestTimeout.short) throws {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: CloudAndxCapabilityXPCProtocol.self)
        connection.interruptionHandler = { [outstanding] in outstanding.failAll(CapabilityAgentError.xpcInterrupted) }
        connection.invalidationHandler = { [outstanding] in outstanding.failAll(CapabilityAgentError.xpcInterrupted) }
        // Development uses a same-user/path check inside the agent. Release will
        // set an anchor-apple/team requirement before activation.
        self.shortTimeout = shortTimeout
        connection.setCodeSigningRequirement(try CapabilityPeerRequirement.agent(mode: mode, teamID: teamID))
        connection.resume()
    }
    private let shortTimeout: TimeInterval

    public func execute(_ command: RuntimeCommand) async throws -> ProcessResult {
        guard ![.installAPK, .pushFile, .captureScreenshot].contains(command) else { throw CapabilityAgentError.invalidCommand }
        let output = try await request(timeout: timeout(for: command)) { proxy, reply in proxy.executeCommand(command.rawValue, withReply: reply) }
        return ProcessResult(exitCode: 0, output: output, wasTruncated: false)
    }

    public func readLog() async throws -> String { try await request(timeout: shortTimeout) { $0.readLog(withReply: $1) } }
    public func installAPK(_ handle: FileHandle, name: String) async throws -> String { try await request(timeout: nil) { $0.installAPK(handle, displayName: name, withReply: $1) } }
    public func pushFile(_ handle: FileHandle, name: String) async throws -> String { try await request(timeout: nil) { $0.pushFile(handle, displayName: name, withReply: $1) } }
    public func captureScreenshot(to handle: FileHandle) async throws -> String { try await request(timeout: nil) { $0.captureScreenshot(to: handle, withReply: $1) } }

    private func timeout(for command: RuntimeCommand) -> TimeInterval? {
        switch command {
        case .status, .snapshotStatus:
            shortTimeout
        default:
            CapabilityRequestTimeout.command(command)
        }
    }

    private func request(timeout: TimeInterval?, _ body: @escaping (CloudAndxCapabilityXPCProtocol, @escaping (String?, NSError?) -> Void) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let gate = RequestGate(continuation)
            let id = outstanding.register(gate)
            let timeoutWorkItem = timeout.map { interval in
                DispatchWorkItem { [outstanding] in
                    outstanding.remove(id)
                    gate.fail(CapabilityAgentError.xpcInterrupted)
                }
            }
            if let timeoutWorkItem, let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                self.outstanding.remove(id)
                gate.fail(error)
            }) as? CloudAndxCapabilityXPCProtocol else {
                timeoutWorkItem?.cancel(); self.outstanding.remove(id); gate.fail(CapabilityAgentError.xpcUnavailable); return
            }
            body(proxy) { value, error in
                timeoutWorkItem?.cancel()
                self.outstanding.remove(id)
                if let error { gate.fail(error) } else { gate.succeed(value ?? "") }
            }
        }
    }
}

public final class RequestGate: @unchecked Sendable {
    private let lock = NSLock(); private var complete = false
    private let continuation: CheckedContinuation<String, Error>?
    private let observer: ((Result<String, Error>) -> Void)?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation; observer = nil }
    public init(observer: @escaping (Result<String, Error>) -> Void) { continuation = nil; self.observer = observer }
    public func succeed(_ value: String) { lock.lock(); guard !complete else { lock.unlock(); return }; complete = true; let c = continuation; let o = observer; lock.unlock(); c?.resume(returning: value); o?(.success(value)) }
    public func fail(_ error: Error) { lock.lock(); guard !complete else { lock.unlock(); return }; complete = true; let c = continuation; let o = observer; lock.unlock(); c?.resume(throwing: error); o?(.failure(error)) }
    public func scheduleTimeout(after interval: TimeInterval) { DispatchQueue.global().asyncAfter(deadline: .now() + interval) { self.fail(CapabilityAgentError.xpcInterrupted) } }
}

public struct RuntimeBundleConfiguration: Sendable {
    public let mode: RuntimeMode; public let teamID: String?
    public static func load(resources: URL) throws -> Self {
        let mode = try String(contentsOf: resources.appendingPathComponent("runtime-mode.env"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case "CLOUDANDX_RUNTIME_MODE=development-sdk": return Self(mode: .developmentSDK, teamID: nil)
        case "CLOUDANDX_RUNTIME_MODE=bundled-release":
            let team = try String(contentsOf: resources.appendingPathComponent("expected-team-id.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try CapabilityPeerRequirement.app(mode: .bundledRelease, teamID: team)
            return Self(mode: .bundledRelease, teamID: team)
        default: throw CapabilityAgentError.xpcUnavailable
        }
    }
}
