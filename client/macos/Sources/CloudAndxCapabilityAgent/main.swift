import CloudAndxClientCore
import Darwin
import Foundation
import OSLog

final class Agent: NSObject, CloudAndxCapabilityXPCProtocol, NSXPCListenerDelegate {
    private let listener = NSXPCListener.service()
    // Lifecycle, descriptor, and read-only actions serialize to preserve the
    // single Android instance. scrcpy is a user interaction that lasts until
    // its window closes, so it must never occupy this queue.
    private let serialQueue = DispatchQueue(label: "dev.cloudandx.capability-agent.serial")
    private let interactionQueue = DispatchQueue(label: "dev.cloudandx.capability-agent.interaction")
    private let logger = Logger(subsystem: "dev.cloudandx.android-client", category: "capability-agent")
    private lazy var service: RuntimeService? = try? makeService()
    func run() { listener.delegate = self; listener.resume() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Development-only boundary: same-euid transport plus exact client bundle
        // identifier requirement. It is intentionally not a production identity.
        guard connection.effectiveUserIdentifier == geteuid(), connection.processIdentifier > 1,
              clientPath(connection.processIdentifier) == containingApp().appendingPathComponent("Contents/MacOS/CloudAndxClient").path else { return false }
        connection.exportedInterface = NSXPCInterface(with: CloudAndxCapabilityXPCProtocol.self)
        connection.exportedObject = self
        guard let requirement = try? appPeerRequirement() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        return true
    }
    private func appPeerRequirement() throws -> String {
        let resources = containingApp().appendingPathComponent("Contents/Resources")
        let config = try RuntimeBundleConfiguration.load(resources: resources)
        return try CapabilityPeerRequirement.app(mode: config.mode, teamID: config.teamID)
    }
    private func containingApp() -> URL { Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func clientPath(_ pid: pid_t) -> String? { var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN)); return proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 ? String(cString: bytes) : nil }
    func executeCommand(_ rawValue: String, withReply reply: @escaping (String?, NSError?) -> Void) {
        guard let command = RuntimeCommand(rawValue: rawValue), ![.installAPK, .pushFile, .captureScreenshot].contains(command) else { reply(nil, CapabilityAgentError.invalidCommand as NSError); return }
        let executionQueue = command == .scrcpy ? interactionQueue : serialQueue
        executionQueue.async { self.reply(action: command.rawValue, reply) { try self.requiredService().execute(command).output } }
    }
    func readLog(withReply reply: @escaping (String?, NSError?) -> Void) { serialQueue.async { self.reply(action: "readLog", reply) { try self.requiredService().readLog() } } }
    func installAPK(_ source: FileHandle, displayName: String, withReply reply: @escaping (String?, NSError?) -> Void) {
        serialQueue.async { self.reply(action: "installAPK", reply) { let staged = try self.stage(source, displayName, true); defer { try? FileManager.default.removeItem(at: staged) }; return try self.requiredService().installAPK(at: staged).output } }
    }
    func pushFile(_ source: FileHandle, displayName: String, withReply reply: @escaping (String?, NSError?) -> Void) {
        serialQueue.async { self.reply(action: "pushFile", reply) { let staged = try self.stage(source, displayName, false); defer { try? FileManager.default.removeItem(at: staged) }; return try self.requiredService().pushFile(at: staged).output } }
    }
    func captureScreenshot(to destination: FileHandle, withReply reply: @escaping (String?, NSError?) -> Void) {
        serialQueue.async { self.reply(action: "captureScreenshot", reply) { let directory = try self.stageDirectory(); let staged = directory.appendingPathComponent("screenshot-\(UUID().uuidString).png"); let fd = open(staged.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, 0o600); guard fd >= 0 else { throw CapabilityAgentError.xpcUnavailable }; close(fd); defer { try? FileManager.default.removeItem(at: staged) }; _ = try self.requiredService().captureScreenshot(to: staged); let data = try CapabilityPNGValidator.validatedData(at: staged); try destination.truncate(atOffset: 0); try destination.seek(toOffset: 0); try destination.write(contentsOf: data); try destination.synchronize(); return "screenshot_saved=1" } }
    }

    private func reply(action: String, _ reply: @escaping (String?, NSError?) -> Void, _ body: () throws -> String) {
        do {
            let output = try body()
            logger.info("capability action=\(action, privacy: .public) success=true")
            reply(output, nil)
        } catch {
            logger.info("capability action=\(action, privacy: .public) success=false")
            reply(nil, error as NSError)
        }
    }
    private func requiredService() throws -> RuntimeService { guard let service else { throw CapabilityAgentError.xpcUnavailable }; return service }
    private func makeService() throws -> RuntimeService {
        // A sandboxed XPC service cannot safely run the development checkout's
        // project-root script or mutate its .runtime state. Keep this agent
        // descriptor/FD-only and fail closed until authority moves into a
        // bundle-owned runtime or a separately reviewed helper.
        throw CapabilityAgentError.xpcUnavailable
    }
    private func stageDirectory() throws -> URL { let directory = try requiredService().runtimeRoot.appendingPathComponent("ipc", isDirectory: true); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return directory }
    private func stage(_ handle: FileHandle, _ name: String, _ apk: Bool) throws -> URL { try handle.seek(toOffset: 0); return try CapabilityFileStager.stage(handle, displayName: name, requireAPK: apk, in: try stageDirectory()) }
}
let agent = Agent()
agent.run()
RunLoop.current.run()
