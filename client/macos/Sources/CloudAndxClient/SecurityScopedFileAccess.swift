import Foundation
import CloudAndxClientCore
import Darwin

/// Main-app only PowerBox bridge. Bookmark bytes are intentionally ephemeral:
/// created, resolved and discarded before the descriptor crosses XPC.
enum SecurityScopedFileAccess {
    static func withReadableHandle<T>(at url: URL, _ body: (FileHandle) async throws -> T) async throws -> T {
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, resolved.startAccessingSecurityScopedResource() else { throw CapabilityAgentError.xpcUnavailable }
        defer { resolved.stopAccessingSecurityScopedResource() }
        let handle = try FileHandle(forReadingFrom: resolved); defer { try? handle.close() }
        return try await body(handle)
    }

    static func withWritableHandle<T>(at url: URL, _ body: (FileHandle) async throws -> T) async throws -> T {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let bookmarkURL = exists ? url : url.deletingLastPathComponent()
        let bookmark = try bookmarkURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, resolved.startAccessingSecurityScopedResource() else { throw CapabilityAgentError.xpcUnavailable }
        defer { resolved.stopAccessingSecurityScopedResource() }
        let target = exists ? resolved : resolved.appendingPathComponent(url.lastPathComponent)
        guard exists || (!url.lastPathComponent.isEmpty && url.lastPathComponent != "." && url.lastPathComponent != ".." && !url.lastPathComponent.contains("/")) else { throw CapabilityAgentError.xpcUnavailable }
        guard target.deletingLastPathComponent().path == resolved.path || exists else { throw CapabilityAgentError.xpcUnavailable }
        var created = false
        let flags = exists ? (O_WRONLY | O_NOFOLLOW) : (O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY)
        let fd = open(target.path, flags, 0o600)
        guard fd >= 0 else { throw CapabilityAgentError.xpcUnavailable }
        created = !exists
        var info = stat(); guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, !created || (info.st_mode & 0o777) == 0o600 else { close(fd); if created { try? FileManager.default.removeItem(at: target) }; throw CapabilityAgentError.xpcUnavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { let value = try await body(handle); try? handle.close(); return value }
        catch { try? handle.close(); if created { try? FileManager.default.removeItem(at: target) }; throw error }
    }
}
