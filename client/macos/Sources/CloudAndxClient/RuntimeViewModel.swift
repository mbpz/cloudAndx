import CloudAndxClientCore
import Foundation

@MainActor
final class RuntimeViewModel: ObservableObject {
    @Published private(set) var status = RuntimeStatus(health: .unknown, pid: nil, serial: nil, rawOutput: "")
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
                feedback = result.output.isEmpty ? "\(command.title)完成" : result.output
                await reload(using: service)
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

    private func reload(using service: RuntimeService) async {
        do {
            status = try await Task.detached(priority: .utility) { try service.status() }.value
            if !status.rawOutput.isEmpty { feedback = status.rawOutput }
        } catch {
            status = RuntimeStatus(health: .unknown, pid: nil, serial: nil, rawOutput: "")
            feedback = error.localizedDescription
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
}
