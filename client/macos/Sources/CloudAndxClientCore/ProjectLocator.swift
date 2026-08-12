import Foundation

public enum ProjectLocatorError: Error, Equatable, LocalizedError, Sendable {
    case projectNotFound(String)
    case insecureProjectRoot(String)

    public var errorDescription: String? {
        switch self {
        case let .projectNotFound(path):
            "无法从 \(path) 定位 CloudAndx 项目；请从项目内构建并运行客户端"
        case let .insecureProjectRoot(path):
            "CloudAndx 项目目录的所有权或写权限不安全：\(path)"
        }
    }
}

public enum ProjectLocator {
    public static func locate(
        startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> URL {
        var candidate = start.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue {
            candidate.deleteLastPathComponent()
        }
        while true {
            if isProjectRoot(candidate) {
                guard hasSecureOwnershipAndPermissions(candidate) else {
                    throw ProjectLocatorError.insecureProjectRoot(candidate.path)
                }
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        throw ProjectLocatorError.projectNotFound(start.path)
    }

    public static func isProjectRoot(_ url: URL) -> Bool {
        let runner = url.appendingPathComponent("scripts/native-android17.sh")
        let compose = url.appendingPathComponent("compose.yaml")
        return FileManager.default.isExecutableFile(atPath: runner.path)
            && FileManager.default.fileExists(atPath: compose.path)
    }

    private static func hasSecureOwnershipAndPermissions(_ root: URL) -> Bool {
        let paths = [
            root,
            root.appendingPathComponent("scripts", isDirectory: true),
            root.appendingPathComponent("scripts/native-android17.sh"),
            root.appendingPathComponent("compose.yaml"),
        ]
        let expectedOwner = getuid()
        return paths.allSatisfy { url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  let permissions = attributes[.posixPermissions] as? NSNumber else {
                return false
            }
            return owner.uint32Value == expectedOwner && (permissions.uint16Value & 0o022) == 0
        }
    }
}
