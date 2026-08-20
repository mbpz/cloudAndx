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
    @Published private(set) var runtimeMode = RuntimeMode.unavailable
    @Published private(set) var isCapabilityAvailable: Bool

    var isCommandLocked: Bool { !isCapabilityAvailable || isBusy || isOpeningInteraction }

    private let service: any CapabilityServing

    init(service: (any CapabilityServing)? = nil, mode: RuntimeMode? = nil) {
        let configuration = try? RuntimeBundleConfiguration.load(resources: Bundle.main.resourceURL ?? URL(fileURLWithPath: "/nonexistent"))
        isCapabilityAvailable = service != nil
        self.service = service ?? UnavailableCapabilityService()
        runtimeMode = mode ?? configuration?.mode ?? .unavailable
        switch runtimeMode {
        case .developmentSDK: feedback = "沙盒 Capability Agent 当前无生命周期权限；功能已禁用并失败关闭"
        case .bundledRelease: feedback = "签名发布 runtime 尚不可用；功能已禁用并失败关闭"
        case .unavailable: feedback = "Runtime 配置不可用"
        }
        if isCapabilityAvailable { refresh() }
    }

    func perform(_ command: RuntimeCommand) {
        guard !isCommandLocked else { return }
        if command == .scrcpy {
            openInteraction(using: service)
            return
        }
        isBusy = true
        feedback = "\(command.title)中…"
        Task {
            do {
                let result = try await service.execute(command)
                await reload(using: service)
                if command == .snapshotSave || command == .snapshotResume { refreshSnapshotStatus() }
                feedback = result.output.isEmpty ? "\(command.title)完成" : result.output
            } catch {
                feedback = error.localizedDescription
                await reloadLog(using: service)
            }
            isBusy = false
        }
    }

    func refresh() {
        guard !isCommandLocked else { return }
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
        guard !isCommandLocked else { return }
        let panel = NSOpenPanel()
        if let apk = UTType(filenameExtension: "apk") {
            panel.allowedContentTypes = [apk]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要安装到当前 Android 实例的 APK"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runFileAction(title: RuntimeCommand.installAPK.title, url: url, install: true)
    }

    func pushFile() {
        guard !isCommandLocked else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要投递到 /sdcard/Download 的文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runFileAction(title: RuntimeCommand.pushFile.title, url: url, install: false)
    }

    func captureScreenshot() {
        guard !isCommandLocked else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "cloudandx-\(Self.timestamp()).png"
        panel.message = "导出当前 Android 画面为 PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        Task { defer { isBusy = false }; do { feedback = try await SecurityScopedFileAccess.withWritableHandle(at: url) { try await service.captureScreenshot(to: $0) } } catch { feedback = error.localizedDescription } }
    }

    private func reload(using service: any CapabilityServing) async {
        do {
            status = RuntimeStatusParser.parse(try await service.execute(.status).output)
            if !status.rawOutput.isEmpty { feedback = status.rawOutput }
        } catch {
            status = RuntimeStatus(health: .unknown, pid: nil, serial: nil, rawOutput: "")
            feedback = error.localizedDescription
        }
        await reloadLog(using: service)
    }

    func refreshSnapshotStatus() {
        Task { do { snapshot = SnapshotStatusParser.parse(try await service.execute(.snapshotStatus).output) } catch { snapshot = SnapshotStatus(health: .unknown, rawOutput: error.localizedDescription) } }
    }

    private func reloadLog(using service: any CapabilityServing) async {
        do {
            log = try await service.readLog()
        } catch {
            log = "日志读取失败：\(error.localizedDescription)"
        }
    }

    private func openInteraction(using service: any CapabilityServing) {
        guard !isCommandLocked else { return }
        isOpeningInteraction = true
        feedback = "正在打开连接同一 Android 实例的 scrcpy…"
        Task {
            do {
                _ = try await service.execute(.scrcpy)
                feedback = "Android 交互窗口已关闭"
            } catch {
                feedback = error.localizedDescription
            }
            isOpeningInteraction = false
        }
    }

    private func runFileAction(title: String, url: URL, install: Bool) {
        isBusy = true
        feedback = "\(title)中…"
        Task {
            defer { isBusy = false }
            do { let output = try await SecurityScopedFileAccess.withReadableHandle(at: url) { handle in
                try await (install ? service.installAPK(handle, name: url.lastPathComponent) : service.pushFile(handle, name: url.lastPathComponent)) }
                await reload(using: service)
                feedback = output.isEmpty ? "\(title)完成" : output
            } catch {
                feedback = error.localizedDescription
                await reloadLog(using: service)
            }
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

private struct UnavailableCapabilityService: CapabilityServing {
    func execute(_ command: RuntimeCommand) async throws -> ProcessResult { throw CapabilityAgentError.xpcUnavailable }
    func readLog() async throws -> String { throw CapabilityAgentError.xpcUnavailable }
    func installAPK(_ handle: FileHandle, name: String) async throws -> String { throw CapabilityAgentError.xpcUnavailable }
    func pushFile(_ handle: FileHandle, name: String) async throws -> String { throw CapabilityAgentError.xpcUnavailable }
    func captureScreenshot(to handle: FileHandle) async throws -> String { throw CapabilityAgentError.xpcUnavailable }
}
