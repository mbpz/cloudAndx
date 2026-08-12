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
    public let projectRoot: URL
    private let processRunner: any ProcessRunning

    public init(projectRoot: URL, processRunner: any ProcessRunning = FoundationProcessRunner()) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.processRunner = processRunner
    }

    public var runtimeRoot: URL {
        projectRoot.appendingPathComponent(".runtime/native-android17", isDirectory: true)
    }

    public var logURL: URL { runtimeRoot.appendingPathComponent("emulator.log") }

    public func execute(_ command: RuntimeCommand) throws -> ProcessResult {
        let runner = projectRoot.appendingPathComponent("scripts/native-android17.sh")
        let result = try processRunner.run(
            executable: runner,
            arguments: [command.rawValue],
            currentDirectory: projectRoot,
            outputLimit: Self.outputLimit
        )
        // A stopped runtime is the normal result of `status`, whose shell exit code is 1.
        if result.exitCode != 0,
           !(command == .status && RuntimeStatusParser.parse(result.output).health == .stopped) {
            throw RuntimeServiceError.commandFailed(command, result.exitCode, result.output)
        }
        return result
    }

    public func status() throws -> RuntimeStatus {
        RuntimeStatusParser.parse(try execute(.status).output)
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
