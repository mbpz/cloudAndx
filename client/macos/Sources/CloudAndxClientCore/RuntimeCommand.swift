import Foundation

public enum RuntimeCommand: String, CaseIterable, Sendable {
    case start
    case stop
    case restart
    case status
    case scrcpy
    case snapshotSave = "snapshot-save"
    case snapshotResume = "snapshot-resume"
    case snapshotStatus = "snapshot-status"
    case installAPK = "install-apk"
    case pushFile = "push-file"
    case captureScreenshot = "capture-screenshot"

    public var title: String {
        switch self {
        case .start: "启动"
        case .stop: "停止"
        case .restart: "重启"
        case .status: "刷新状态"
        case .scrcpy: "打开 Android"
        case .snapshotSave: "保存恢复点"
        case .snapshotResume: "恢复到保存点"
        case .snapshotStatus: "检查恢复点"
        case .installAPK: "安装 APK"
        case .pushFile: "投递文件"
        case .captureScreenshot: "导出截图"
        }
    }
}

public enum SnapshotHealth: Equatable, Sendable {
    case unavailable
    case ready
    case incompatible
    case unknown

    public var title: String {
        switch self {
        case .unavailable: "尚未保存"
        case .ready: "可恢复"
        case .incompatible: "已失效"
        case .unknown: "状态未知"
        }
    }
}

public struct SnapshotStatus: Equatable, Sendable {
    public let health: SnapshotHealth
    public let rawOutput: String

    public init(health: SnapshotHealth, rawOutput: String) {
        self.health = health
        self.rawOutput = rawOutput
    }
}

public enum SnapshotStatusParser {
    public static func parse(_ output: String) -> SnapshotStatus {
        let normalized = output.lowercased()
        if normalized.contains("snapshot_ready=1") || normalized.contains("snapshot ready") {
            return SnapshotStatus(health: .ready, rawOutput: output)
        }
        if normalized.contains("snapshot_incompatible=1") || normalized.contains("snapshot incompatible") {
            return SnapshotStatus(health: .incompatible, rawOutput: output)
        }
        if normalized.contains("snapshot_ready=0") || normalized.contains("no trusted snapshot") {
            return SnapshotStatus(health: .unavailable, rawOutput: output)
        }
        return SnapshotStatus(health: .unknown, rawOutput: output)
    }
}

public enum RuntimeHealth: Equatable, Sendable {
    case stopped
    case booting
    case ready
    case unknown

    public var title: String {
        switch self {
        case .stopped: "已停止"
        case .booting: "启动中"
        case .ready: "已就绪"
        case .unknown: "状态未知"
        }
    }
}

public struct RuntimeStatus: Equatable, Sendable {
    public let health: RuntimeHealth
    public let pid: Int?
    public let serial: String?
    public let rawOutput: String

    public init(health: RuntimeHealth, pid: Int?, serial: String?, rawOutput: String) {
        self.health = health
        self.pid = pid
        self.serial = serial
        self.rawOutput = rawOutput
    }
}

public enum RuntimeStatusParser {
    public static func parse(_ output: String) -> RuntimeStatus {
        if output.contains("not running") || output.contains("stopped") {
            return RuntimeStatus(health: .stopped, pid: nil, serial: nil, rawOutput: output)
        }

        let pid = captureInteger(named: "pid", in: output)
        let serial = captureValue(named: "serial", in: output)
        if output.contains("boot_completed=1") || output.contains("ready:") {
            return RuntimeStatus(health: .ready, pid: pid, serial: serial, rawOutput: output)
        }
        if pid != nil || output.contains("boot_completed=0") {
            return RuntimeStatus(health: .booting, pid: pid, serial: serial, rawOutput: output)
        }
        return RuntimeStatus(health: .unknown, pid: nil, serial: nil, rawOutput: output)
    }

    private static func captureValue(named name: String, in output: String) -> String? {
        let prefix = "\(name)="
        return output.split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .punctuationCharacters) }
    }

    private static func captureInteger(named name: String, in output: String) -> Int? {
        captureValue(named: name, in: output).flatMap(Int.init)
    }
}
