import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String
    public let wasTruncated: Bool

    public init(exitCode: Int32, output: String, wasTruncated: Bool) {
        self.exitCode = exitCode
        self.output = output
        self.wasTruncated = wasTruncated
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String],
        outputLimit: Int
    ) throws -> ProcessResult
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case invalidOutputLimit
    case unsupportedEnvironmentOverride(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOutputLimit:
            "子进程输出上限必须大于零"
        case let .unsupportedEnvironmentOverride(key):
            "不允许覆盖子进程环境变量：\(key)"
        }
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        if remaining > 0 { bytes.append(data.prefix(remaining)) }
        if data.count > remaining { truncated = true }
    }

    func result() -> (String, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: bytes, as: UTF8.self), truncated)
    }
}

public struct FoundationProcessRunner: ProcessRunning, Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL,
        environment overrides: [String: String] = [:],
        outputLimit: Int = 65_536
    ) throws -> ProcessResult {
        guard outputLimit > 0 else { throw ProcessRunnerError.invalidOutputLimit }

        let process = Process()
        let pipe = Pipe()
        let collector = BoundedOutput(limit: outputLimit)
        let drain = DispatchGroup()

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName(),
        ]
        let allowedOverrides = [
            "CLOUDANDX_ANDROID_SDK_ROOT",
            "CLOUDANDX_JAVA_HOME",
            "CLOUDANDX_LSOF_BIN",
            "CLOUDANDX_NATIVE_AVD_NAME",
            "CLOUDANDX_NATIVE_CONSOLE_PORT",
            "CLOUDANDX_NATIVE_GRPC_PORT",
            "CLOUDANDX_NATIVE_RUNTIME_ROOT",
            "CLOUDANDX_RUNTIME_MODE",
            "CLOUDANDX_BUNDLED_RUNTIME_ROOT",
            // Deliberately not inherited from the app/process environment.
            "CLOUDANDX_SCRCPY_BIN",
        ]
        for key in allowedOverrides {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        let allowedActionInputs = [
            "CLOUDANDX_NATIVE_APK_PATH",
            "CLOUDANDX_NATIVE_HOST_FILE_PATH",
            "CLOUDANDX_NATIVE_SCREENSHOT_PATH",
            // RuntimeService supplies the fixed trusted value; it is never
            // inherited from the app/process environment above.
            "CLOUDANDX_NATIVE_BOOT_TIMEOUT_SECONDS",
            "CLOUDANDX_RUNTIME_MODE",
            "CLOUDANDX_BUNDLED_RUNTIME_ROOT",
            "CLOUDANDX_DEVELOPMENT_PROJECT_ROOT",
        ]
        for (key, value) in overrides {
            guard allowedActionInputs.contains(key) else {
                throw ProcessRunnerError.unsupportedEnvironmentOverride(key)
            }
            environment[key] = value
        }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        drain.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                collector.append(data)
            }
            drain.leave()
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            drain.wait()
            throw error
        }
        process.waitUntilExit()
        pipe.fileHandleForWriting.closeFile()
        drain.wait()

        let (output, wasTruncated) = collector.result()
        return ProcessResult(exitCode: process.terminationStatus, output: output, wasTruncated: wasTruncated)
    }
}
