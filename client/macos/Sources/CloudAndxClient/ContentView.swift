import CloudAndxClientCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RuntimeViewModel

    var body: some View {
        NavigationSplitView {
            List {
                Label("Android 17", systemImage: "iphone.gen3")
                Label("运行日志", systemImage: "doc.text.magnifyingglass")
                Label("能力边界", systemImage: "checkmark.shield")
            }
            .navigationTitle("CloudAndx")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    FixtureDisplayPanel()
                    runtimeCard
                    snapshotCard
                    logCard
                    boundaryCard
                }
                .padding(24)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var snapshotCard: some View {
        GroupBox("可信恢复点") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Label(model.snapshot.health.title, systemImage: snapshotSymbol)
                        .foregroundStyle(snapshotColor)
                    Spacer()
                    Button { model.perform(.snapshotSave) } label: {
                        Label("保存当前状态", systemImage: "camera.aperture")
                    }
                    .disabled(model.isCommandLocked || model.status.health != .ready)
                    Button { model.refreshSnapshotStatus() } label: {
                        Label("检查", systemImage: "checklist")
                    }
                    .disabled(model.isCommandLocked)
                    Button { model.confirmAndResumeSnapshot() } label: {
                        Label("恢复", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCommandLocked || model.snapshot.health != .ready)
                }
                Text("恢复会回到保存时的 Android 系统、应用和用户数据；保存后尚未写入恢复点的 guest 变更会丢失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Android Workbench")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("AEMU ARM64 · Hypervisor.Framework · host GPU")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.runtimeMode.displayName)
                    .font(.caption)
                    .foregroundStyle(model.runtimeMode == .developmentSDK ? .orange : (model.runtimeMode == .bundledRelease ? .green : .red))
            }
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        Label(model.status.health.title, systemImage: statusSymbol)
            .font(.headline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(statusColor.opacity(0.13), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var runtimeCard: some View {
        GroupBox("本机 Android") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    actionButton(.start, symbol: "play.fill", prominent: true)
                    actionButton(.stop, symbol: "stop.fill")
                    actionButton(.restart, symbol: "arrow.clockwise")
                    Button { model.refresh() } label: {
                        Label("刷新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isCommandLocked)
                    Spacer()
                    Button { model.perform(.scrcpy) } label: {
                        Label(model.isOpeningInteraction ? "交互窗口运行中" : "打开 Android", systemImage: "rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCommandLocked)
                }
                HStack(spacing: 10) {
                    Button { model.installAPK() } label: {
                        Label(RuntimeCommand.installAPK.title, systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCommandLocked || model.status.health != .ready)
                    Button { model.pushFile() } label: {
                        Label(RuntimeCommand.pushFile.title, systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCommandLocked || model.status.health != .ready)
                    Button { model.captureScreenshot() } label: {
                        Label(RuntimeCommand.captureScreenshot.title, systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCommandLocked || model.status.health != .ready)
                    Spacer()
                }
                Divider()
                LabeledContent("设备", value: model.status.serial ?? "—")
                LabeledContent("进程", value: model.status.pid.map(String.init) ?? "—")
                LabeledContent("项目", value: model.projectPath.isEmpty ? "未定位" : model.projectPath)
                Text(model.feedback)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(8)
        }
    }

    private var logCard: some View {
        GroupBox("运行日志 · 最后 64 KiB") {
            ScrollView([.horizontal, .vertical]) {
                Text(model.log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 180, maxHeight: 260)
        }
    }

    private var boundaryCard: some View {
        GroupBox("真机体验边界") {
            VStack(alignment: .leading, spacing: 10) {
                capability("本机可优化", "60 FPS、低延迟输入、可信快照恢复、APK/文件投递、截图、相机/麦克风/手柄")
                capability("需要物理 Pixel", "基带/eSIM、TEE/StrongBox、Widevine L1、硬件级 Play Integrity、真实 ISP")
                Text("客户端不会将虚拟能力冒充真实硬件证明，也不会开放任意 ADB 或 shell。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func actionButton(_ command: RuntimeCommand, symbol: String, prominent: Bool = false) -> some View {
        Group {
            if prominent {
                Button { model.perform(command) } label: { Label(command.title, systemImage: symbol) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { model.perform(command) } label: { Label(command.title, systemImage: symbol) }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(model.isCommandLocked)
    }

    private func capability(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: title == "本机可优化" ? "bolt.fill" : "iphone.gen3")
                .foregroundStyle(title == "本机可优化" ? .green : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch model.status.health {
        case .ready: .green
        case .booting: .orange
        case .stopped: .secondary
        case .unknown: .red
        }
    }

    private var statusSymbol: String {
        switch model.status.health {
        case .ready: "checkmark.circle.fill"
        case .booting: "clock.fill"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private var snapshotColor: Color {
        switch model.snapshot.health {
        case .ready: .green
        case .unavailable: .secondary
        case .incompatible: .orange
        case .unknown: .red
        }
    }

    private var snapshotSymbol: String {
        switch model.snapshot.health {
        case .ready: "checkmark.seal.fill"
        case .unavailable: "circle.dashed"
        case .incompatible: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}
