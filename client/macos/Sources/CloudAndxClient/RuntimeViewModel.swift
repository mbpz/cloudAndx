import CloudAndxClientCore
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class RuntimeViewModel: ObservableObject {
    @Published private(set) var status = RuntimeStatus(health: .unknown, pid: nil, serial: nil, rawOutput: "")
    @Published private(set) var snapshot = SnapshotStatus(health: .unknown, rawOutput: "")
    @Published private(set) var feedback = "正在定位 CloudAndx runtime…"
    @Published private(set) var log = "尚无运行日志。"
    @Published private(set) var isBusy = false
    @Published private(set) var isOpeningInteraction = false
    @Published private(set) var projectPath = ""

    var isCommandLocked: Bool { isBusy || isOpeningInteraction }

    private var service: RuntimeService?

    init() {
        do {
            let root = try ProjectLocator.locate(startingAt: Bundle.main.bundleURL)
            service = RuntimeService(projectRoot: root)
            projectPath = root.path
            feedback = "已连接本机 runtime"
            refresh()
        } catch {
            feedback = error.localizedDescription
        }
    }

    func perform(_ command: RuntimeCommand) {
        guard let service else { return }
        if command == .scrcpy {
            openInteraction(using: service)
            return
        }
        guard !isCommandLocked else { return }
        isBusy = true
        feedback = "\(command.title)中…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try service.execute(command)
                }.value
                await reload(using: service)
                feedback = result.output.isEmpty ? "\(command.title)完成" : result.output
            } catch {
                feedback = error.localizedDescription
                await reloadLog(using: service)
            }
            isBusy = false
        }
    }

    func refresh() {
        guard let service, !isCommandLocked else { return }
        isBusy = true
        Task {
            await reload(using: service)
            isBusy = false
        }
    }

    func confirmAndResumeSnapshot() {
        guard !isCommandLocked, snapshot.health == .ready else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "恢复到可信恢复点？"
        alert.informativeText = "该操作会覆盖恢复点保存后产生的 Android guest 状态，宿主文件不会受影响。"
        alert.addButton(withTitle: "恢复并覆盖当前状态")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(.snapshotResume)
    }

    func installAPK() {
        guard let service, !isCommandLocked else { return }
        let panel = NSOpenPanel()
        if let apk = UTType(filenameExtension: "apk") {
            panel.allowedContentTypes = [apk]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要安装到当前 Android 实例的 APK"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runForegroundAction(title: RuntimeCommand.installAPK.title) {
            try service.installAPK(at: url)
        }
    }

    func pushFile() {
        guard let service, !isCommandLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要投递到 /sdcard/Download 的文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runForegroundAction(title: RuntimeCommand.pushFile.title) {
            try service.pushFile(at: url)
        }
    }

    func captureScreenshot() {
        guard let service, !isCommandLocked else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "cloudandx-\(Self.timestamp()).png"
        panel.message = "导出当前 Android 画面为 PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runForegroundAction(title: RuntimeCommand.captureScreenshot.title) {
            try service.captureScreenshot(to: url)
        }
    }

    private func reload(using service: RuntimeService) async {
        do {
            status = try await Task.detached(priority: .utility) { try service.status() }.value
            if !status.rawOutput.isEmpty { feedback = status.rawOutput }
        } catch {
            status = RuntimeStatus(health: .unknown, pid: nil, serial: nil, rawOutput: "")
            feedback = error.localizedDescription
        }
        do {
            snapshot = try await Task.detached(priority: .utility) {
                try service.snapshotStatus()
            }.value
        } catch {
            snapshot = SnapshotStatus(health: .unknown, rawOutput: error.localizedDescription)
        }
        await reloadLog(using: service)
    }

    private func reloadLog(using service: RuntimeService) async {
        do {
            log = try await Task.detached(priority: .utility) { try service.readLog() }.value
        } catch {
            log = "日志读取失败：\(error.localizedDescription)"
        }
    }

    private func openInteraction(using service: RuntimeService) {
        guard !isCommandLocked else { return }
        isOpeningInteraction = true
        feedback = "正在打开连接同一 Android 实例的 scrcpy…"
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try service.execute(.scrcpy)
                }.value
                feedback = "Android 交互窗口已关闭"
            } catch {
                feedback = error.localizedDescription
            }
            isOpeningInteraction = false
        }
    }

    private func runForegroundAction(
        title: String,
        action: @escaping @Sendable () throws -> ProcessResult
    ) {
        guard let service else { return }
        isBusy = true
        feedback = "\(title)中…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated, operation: action).value
                await reload(using: service)
                feedback = result.output.isEmpty ? "\(title)完成" : result.output
            } catch {
                feedback = error.localizedDescription
                await reloadLog(using: service)
            }
            isBusy = false
        }
    }

    private static func timestamp(now: Date = .init()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now)
    }
}
