import Foundation
import Darwin

@MainActor
final class SyncFolderAccess {
    static let preferences = UserDefaults.standard
    let url: URL
    private var scoped: Bool
    private var source: (any DispatchSourceFileSystemObject)?
    private var poll: Task<Void, Never>?

    static func savedURL(preferences: UserDefaults = SyncFolderAccess.preferences) throws -> URL? {
        let savedPath = preferences.string(forKey: "SyncFolderPath")
        var recoveryURL = savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let bookmark = preferences.data(forKey: "SyncFolderBookmark") {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale { try save(url, preferences: preferences) }
                return url
            } catch {
                // A bookmark from a previous app identity can still locate the
                // folder even when its security scope is no longer usable.
                // Resolve it without that scope first, so moved folders work too.
                if let located = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) {
                    recoveryURL = located
                }
            }
            guard recoveryURL != nil else {
                throw BucketError.message("Cannot restore access to the saved sync folder. Choose Sync Folder to select it again.")
            }
        }
        guard let url = recoveryURL else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  FileManager.default.isReadableFile(atPath: url.path),
                  FileManager.default.isWritableFile(atPath: url.path) else {
                throw CocoaError(.fileReadNoPermission)
            }
            try save(url, preferences: preferences)
            return url
        } catch {
            // Keep the old reference for a later retry. Never create a missing
            // directory: sync could treat an empty replacement as deletions.
            throw BucketError.message("Cannot restore access to the sync folder at \(url.path). Connect the drive or choose Sync Folder to select it again. Your saved sync record has been kept.")
        }
    }

    static func save(_ url: URL, preferences: UserDefaults = SyncFolderAccess.preferences) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        _ = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
        preferences.set(data, forKey: "SyncFolderBookmark")
        preferences.set(url.path, forKey: "SyncFolderPath")
    }

    static func clear() {
        preferences.removeObject(forKey: "SyncFolderBookmark")
        preferences.removeObject(forKey: "SyncFolderPath")
    }

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw BucketError.message("Cannot open the sync folder at \(url.path). Connect the drive or choose Sync Folder to select it again.")
        }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib], queue: .main)
        watch.setEventHandler { Task { @MainActor in onChange() } }
        watch.setCancelHandler { close(descriptor) }
        source = watch
        watch.resume()
        // A light metadata check also detects edits inside subfolders. Cloud
        // messages trigger cloud refreshes; a slower cloud check is a fallback.
        poll = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if !Task.isCancelled { onChange() }
            }
        }
    }

    func stop() {
        source?.cancel(); source = nil
        poll?.cancel(); poll = nil
        if scoped { url.stopAccessingSecurityScopedResource(); scoped = false }
    }
}
