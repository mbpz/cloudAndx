import Foundation

public enum RuntimeServiceError: Error, LocalizedError, Sendable {
    case commandFailed(RuntimeCommand, Int32, String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, code, output):
            "\(command.title)失败（退出码 \(code)）：\(output)"
        }
    }
}

public struct RuntimeService: Sendable {
    public static let outputLimit = 65_536
    /// XPC long-operation budgets are deliberately greater than this trusted
    /// runner gate; never inherit an unbounded host environment value here.
    public static let trustedBootTimeoutSeconds = 120
    private static let downloadTargetDirectory = "/sdcard/Download"
    public let projectRoot: URL
    public let runtimeMode: RuntimeMode
    public let bundledRuntimeRoot: URL?
    public let runnerURL: URL
    private let processRunner: any ProcessRunning

    public init(
        projectRoot: URL,
        runtimeMode: RuntimeMode = .developmentSDK,
        bundledRuntimeRoot: URL? = nil,
        runnerURL: URL? = nil,
        processRunner: any ProcessRunning = FoundationProcessRunner()
    ) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.runtimeMode = runtimeMode
        self.bundledRuntimeRoot = bundledRuntimeRoot?.standardizedFileURL
        self.runnerURL = (runnerURL ?? projectRoot.appendingPathComponent("scripts/native-android17.sh")).standardizedFileURL
        self.processRunner = processRunner
    }

    public var runtimeRoot: URL {
        projectRoot.appendingPathComponent(".runtime/native-android17", isDirectory: true)
    }

    public var logURL: URL { runtimeRoot.appendingPathComponent("emulator.log") }

    public func execute(_ command: RuntimeCommand) throws -> ProcessResult {
        try execute(command, environment: runtimeEnvironment)
    }

    private func execute(
        _ command: RuntimeCommand,
        environment: [String: String]
    ) throws -> ProcessResult {
        let result = try processRunner.run(
            executable: runnerURL,
            arguments: [command.rawValue],
            currentDirectory: projectRoot,
            environment: environment,
            outputLimit: Self.outputLimit
        )
        // A stopped runtime is the normal result of `status`, whose shell exit code is 1.
        if result.exitCode != 0,
           !(command == .status && RuntimeStatusParser.parse(result.output).health == .stopped),
           !(command == .snapshotStatus
                && SnapshotStatusParser.parse(result.output).health != .unknown) {
            throw RuntimeServiceError.commandFailed(command, result.exitCode, result.output)
        }
        return result
    }

    private var runtimeEnvironment: [String: String] {
        var environment = [
            "CLOUDANDX_RUNTIME_MODE": runtimeMode.rawValue,
            "CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS": String(Self.trustedBootTimeoutSeconds),
        ]
        if runtimeMode == .developmentSDK { environment["CLOUDANDX_DEVELOPMENT_PROJECT_ROOT"] = projectRoot.path }
        if runtimeMode == .bundledRelease, let bundledRuntimeRoot {
            environment["CLOUDANDX_BUNDLED_RUNTIME_ROOT"] = bundledRuntimeRoot.path
        }
        return environment
    }

    public func installAPK(at url: URL) throws -> ProcessResult {
        guard url.pathExtension.lowercased() == "apk" else {
            throw RuntimeCapabilityError.invalidAPK(url.lastPathComponent)
        }
        try validateReadableRegularFile(url)
        return try execute(.installAPK, environment: runtimeEnvironment.merging([
            "CLOUDANDX_NATIVE_APK_PATH": url.path,
        ]) { _, replacement in replacement })
    }

    public func pushFile(at url: URL) throws -> ProcessResult {
        guard !url.hasDirectoryPath else {
            throw RuntimeCapabilityError.directoryNotSupported(url.lastPathComponent)
        }
        try validateReadableRegularFile(url)
        return try execute(.pushFile, environment: runtimeEnvironment.merging([
            "CLOUDANDX_NATIVE_HOST_FILE_PATH": url.path,
        ]) { _, replacement in replacement })
    }

    public func captureScreenshot(to url: URL) throws -> ProcessResult {
        guard url.pathExtension.lowercased() == "png" else {
            throw RuntimeCapabilityError.invalidScreenshotPath(url.lastPathComponent)
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: parent.path) else {
            throw RuntimeCapabilityError.invalidDestination(parent.lastPathComponent)
        }
        return try execute(.captureScreenshot, environment: runtimeEnvironment.merging([
            "CLOUDANDX_NATIVE_SCREENSHOT_PATH": url.path,
        ]) { _, replacement in replacement })
    }

    public static func defaultPushedFileTarget(for url: URL) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = url.lastPathComponent.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let filename = String(scalars.prefix(120))
        return "\(downloadTargetDirectory)/\(filename)"
    }

    private func validateReadableRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isReadableKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isReadable == true,
              values.isSymbolicLink != true else {
            throw RuntimeCapabilityError.invalidHostFile(url.lastPathComponent)
        }
    }

    public func status() throws -> RuntimeStatus {
        RuntimeStatusParser.parse(try execute(.status).output)
    }

    public func snapshotStatus() throws -> SnapshotStatus {
        SnapshotStatusParser.parse(try execute(.snapshotStatus).output)
    }

    public func readLog(maxBytes: Int = 65_536) throws -> String {
        guard maxBytes > 0 else { throw ProcessRunnerError.invalidOutputLimit }
        guard FileManager.default.fileExists(atPath: logURL.path) else { return "尚无运行日志。" }
        let handle = try FileHandle(forReadingFrom: logURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        let prefix = start > 0 ? "… 仅显示最后 \(maxBytes) 字节 …\n" : ""
        return RuntimeLogSanitizer.redact(prefix + String(decoding: data, as: UTF8.self))
    }
}

public enum RuntimeCapabilityError: Error, LocalizedError, Equatable, Sendable {
    case invalidAPK(String)
    case invalidScreenshotPath(String)
    case directoryNotSupported(String)
    case invalidHostFile(String)
    case invalidDestination(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidAPK(name):
            "仅支持 .apk 安装包：\(name)"
        case let .invalidScreenshotPath(name):
            "截图必须保存为 .png：\(name)"
        case let .directoryNotSupported(name):
            "仅支持投递单个文件，不能直接投递目录：\(name)"
        case let .invalidHostFile(name):
            "宿主文件必须是可读的常规文件且不能是符号链接：\(name)"
        case let .invalidDestination(name):
            "截图目标目录不存在或不可写：\(name)"
        }
    }
}

public enum RuntimeLogSanitizer {
    public static func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let rules = [
            (#"(?i)(authorization:[[:space:]]*bearer[[:space:]]+)[^[:space:]]+"#, "$1<redacted>"),
            (#"(?i)((?:token|password|secret|adbkey)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+"#, "$1<redacted>"),
        ]
        for (pattern, replacement) in rules {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }
}
