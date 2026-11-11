import Foundation
import CryptoKit
import Darwin

protocol FolderSyncRemote: Sendable {
    func list() async throws -> [Photo]
    func download(_ photo: Photo) async throws -> Data
    func upload(_ file: URL, existingPhotos: [Photo]?, uploadGroup: UUID?) async throws -> PhotoService.UploadResult
    func delete(key: String) async throws
    func startUploadGroup(_ id: UUID) async throws -> Bool
    func finishUploadGroup(_ id: UUID, added: Int) async throws
}

extension PhotoService: FolderSyncRemote {}

enum FolderSyncProgress: Sendable {
    case message(String)
    case photos([Photo])
    case uploads([URL])
    case uploaded(URL)
    case removed(URL)
}

actor FolderSync {
    struct Entry: Codable, Sendable, Equatable {
        var paths: [String]
        var version: String
        var hash: String
    }
    private struct State: Codable, Equatable {
        var format = 1
        var folderIdentity: String
        var entries: [String: Entry] = [:]
        var pendingDeletes: [String: String] = [:]
    }
    struct Result: Sendable {
        let photos: [Photo]
        let added: Int
        let skipped: Int
        let cancelled: Int
    }
    private struct FileSignature: Equatable {
        let size: Int
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let inode: UInt64
    }
    private struct LocalImage: Equatable {
        let hash: String
        let signature: FileSignature
    }
    struct Statistics: Sendable {
        var recordWrites = 0
        var filesHashed = 0
        var bytesHashed = 0
        var cloudLists = 0
    }
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"]
    let directory: URL
    private let stateURL: URL
    private let trash: @Sendable (URL) throws -> Void
    private var state: State?
    private var persistedState: State?
    private var hashes: [String: LocalImage] = [:]
    private var cachedCloud: [String: Photo]?
    private var reconciled = false
    private var counters = Statistics()
    private var cancelled = Set<String>()
    private var running = false

    init(directory: URL, connection: BucketConfiguration, stateDirectory: URL? = nil,
         trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.directory = directory.standardizedFileURL
        self.trash = trash
        let root = stateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "nz.kor.frogframe.manager/FolderSync")
        let namespace = Self.hash(Data("\(directory.standardizedFileURL.path)\n\(connection.endpoint)\n\(connection.token)".utf8))
        stateURL = root.appendingPathComponent(namespace + ".json")
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func identity() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber], let inode = attributes[.systemFileNumber] else {
            throw BucketError.message("The sync folder is not available.")
        }
        return "\(device):\(inode)"
    }

    private func load() throws {
        let folderID = try identity()
        if state == nil {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
                guard saved.format == 1 else { throw BucketError.message("The folder sync record has an unsupported format.") }
                state = saved
                persistedState = saved
            } else { state = State(folderIdentity: folderID) }
        }
        // A replaced or re-created directory needs a fresh, non-destructive merge.
        if state?.folderIdentity != folderID {
            state = State(folderIdentity: folderID); hashes = [:]; cachedCloud = nil; reconciled = false
        }
    }

    private func save() throws {
        guard let state, state != persistedState else { return }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        persistedState = state
        counters.recordWrites += 1
    }

    func statistics() -> Statistics { counters }

    func localFile(for photo: Photo) throws -> URL? {
        try load()
        guard let entry = state?.entries[photo.key], entry.version == photo.url.absoluteString else { return nil }
        for path in entry.paths.sorted() {
            let file = try localURL(path)
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true {
                return file
            }
        }
        return nil
    }

    private func signature(_ url: URL) throws -> FileSignature {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return FileSignature(size: Int(info.st_size), modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec, changedSeconds: info.st_ctimespec.tv_sec,
            changedNanoseconds: info.st_ctimespec.tv_nsec, inode: UInt64(info.st_ino))
    }

    private func cloudList(_ remote: any FolderSyncRemote) async throws -> [Photo] {
        counters.cloudLists += 1
        return try await remote.list()
    }

    private func localURL(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw BucketError.message("The folder sync record contains an invalid file path.")
        }
        let url = directory.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
            throw BucketError.message("A sync file points outside the chosen folder.")
        }
        return url
    }

    private func scan() throws -> [String: LocalImage] {
        _ = try identity() // An unavailable folder is never an empty folder.
        var result: [String: LocalImage] = [:]
        func visit(_ folder: URL, prefix: String) throws {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                if values.isSymbolicLink == true { continue }
                let path = prefix + file.lastPathComponent
                if values.isDirectory == true { try visit(file, prefix: path + "/"); continue }
                guard values.isRegularFile == true, Self.extensions.contains(file.pathExtension.lowercased()) else { continue }
                let current = try signature(file)
                let size = current.size
                if let cached = hashes[path], cached.signature == current {
                    result[path] = cached; continue
                }
                guard size > 0, size <= 40 * 1024 * 1024 else {
                    throw BucketError.message("\(file.lastPathComponent) must be between 1 byte and 40 MiB. Folder sync will try again.")
                }
                let data = try Data(contentsOf: file)
                guard data.count == size, try signature(file) == current else {
                    throw BucketError.message("A file is still being written. Folder sync will try again.")
                }
                result[path] = LocalImage(hash: Self.hash(data), signature: current)
                counters.filesHashed += 1
                counters.bytesHashed += data.count
            }
        }
        try visit(directory, prefix: "")
        hashes = result
        return result
    }

    private func unusedURL(name: String) -> URL {
        let name = name.hasPrefix(".") ? "image-" + name : name
        var candidate = directory.appendingPathComponent(name)
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).\(ext)")
        }
        return candidate
    }

    func importFiles(_ files: [URL]) throws {
        _ = try identity()
        let local = try scan()
        var knownHashes = Set(local.values.map(\.hash))
        for file in files {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Self.extensions.contains(file.pathExtension.lowercased()),
                  let size = values.fileSize, size > 0, size <= 40 * 1024 * 1024 else {
                throw BucketError.message("\(file.lastPathComponent) is not a supported image between 1 byte and 40 MiB.")
            }
            let data = try Data(contentsOf: file)
            guard data.count == size else { throw BucketError.message("The source image changed while it was being copied.") }
            let digest = Self.hash(data)
            if knownHashes.contains(digest) { continue }
            try data.write(to: unusedURL(name: file.lastPathComponent), options: .atomic)
            knownHashes.insert(digest)
        }
    }

    func cancel(_ files: [URL]) throws {
        for file in files {
            let path = String(file.standardizedFileURL.path.dropFirst(directory.path.count + 1))
            guard try localURL(path) == file.standardizedFileURL else { continue }
            cancelled.insert(path)
            // Only untracked upload cards can be cancelled. Keep established copies.
            if state?.entries.values.contains(where: { $0.paths.contains(path) }) != true,
               FileManager.default.fileExists(atPath: file.path) {
                try trash(file)
            }
        }
    }

    func synchronize(remote: any FolderSyncRemote, refreshCloud: Bool = true,
                     progress: @Sendable (FolderSyncProgress) async -> Void = { _ in }) async throws -> Result {
        guard !running else { throw BucketError.message("Folder sync is already running.") }
        running = true; cancelled = []
        defer { running = false }
        try load()
        let previousLocal = hashes
        var local = try scan()
        let needsCloud = refreshCloud || cachedCloud == nil || previousLocal != local
        if !needsCloud, reconciled, let cachedCloud {
            return Result(photos: cachedCloud.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                          added: 0, skipped: 0, cancelled: 0)
        }
        reconciled = false
        var cloud: [String: Photo]
        if needsCloud {
            cloud = Dictionary(uniqueKeysWithValues: try await cloudList(remote).map { ($0.key, $0) })
            cachedCloud = cloud
        } else { cloud = cachedCloud ?? [:] }
        guard try identity() == state!.folderIdentity else { throw BucketError.message("The sync folder changed. Sync will try again.") }
        if needsCloud { local = try scan() }
        var pathsByHash = Dictionary(grouping: local.keys, by: { local[$0]!.hash })
        var cloudMutated = false
        await progress(.photos(Array(cloud.values)))
        // Ensure that a writable, durable record exists before any deletions.
        try save()
        for (key, version) in state!.pendingDeletes {
            if let photo = cloud[key], photo.url.absoluteString == version {
                cachedCloud = nil
                try await remote.delete(key: key); cloud.removeValue(forKey: key); cloudMutated = true
            }
            state!.pendingDeletes.removeValue(forKey: key)
            try save()
        }
        var replacePaths: [String: [String]] = [:]
        var obsolete: [String: Entry] = [:]
        for (key, entry) in state!.entries {
            if entry.paths.isEmpty { state!.entries.removeValue(forKey: key); try save(); continue }
            let present = Array(Set(entry.paths.filter { local[$0] != nil })
                .union(pathsByHash[entry.hash] ?? [])).sorted()
            let unchanged = present.filter { local[$0]?.hash == entry.hash }
            let changed = present.filter { local[$0]?.hash != entry.hash }
            guard let photo = cloud[key] else {
                for path in unchanged {
                    let shared = state!.entries.contains { otherKey, other in
                        otherKey != key && cloud[otherKey] != nil && other.paths.contains(path)
                    }
                    if shared { continue }
                    let url = try localURL(path)
                    if Self.hash(try Data(contentsOf: url)) == entry.hash {
                        try trash(url)
                        local.removeValue(forKey: path)
                        pathsByHash[entry.hash]?.removeAll { $0 == path }
                    }
                }
                state!.entries.removeValue(forKey: key); try save(); continue
            }
            let remoteChanged = photo.url.absoluteString != entry.version
            if present.isEmpty && !remoteChanged {
                cachedCloud = nil
                try await remote.delete(key: key)
                cloudMutated = true
                cloud.removeValue(forKey: key); state!.entries.removeValue(forKey: key); try save(); continue
            }
            if remoteChanged {
                replacePaths[key] = unchanged
                state!.entries.removeValue(forKey: key)
            } else if unchanged.isEmpty && !changed.isEmpty {
                obsolete[key] = Entry(paths: changed, version: entry.version, hash: entry.hash)
                state!.entries.removeValue(forKey: key)
            } else {
                if entry.paths == unchanged { continue }
                state!.entries[key]?.paths = unchanged
            }
            try save()
        }
        for photo in cloud.values.sorted(by: { $0.key < $1.key }) where state!.entries[photo.key] == nil && obsolete[photo.key] == nil {
            await progress(.message("Syncing \(photo.name)…"))
            let data = try await remote.download(photo)
            let digest = Self.hash(data)
            var paths = (pathsByHash[digest] ?? []).sorted()
            if let replacements = replacePaths[photo.key], !replacements.isEmpty {
                for path in replacements {
                    let url = try localURL(path)
                    if let scanned = local[path], Self.hash(try Data(contentsOf: url)) == scanned.hash {
                        try data.write(to: url, options: .atomic)
                        pathsByHash[scanned.hash]?.removeAll { $0 == path }
                        pathsByHash[digest, default: []].append(path)
                        local[path] = LocalImage(hash: digest, signature: try signature(url))
                        if !paths.contains(path) { paths.append(path) }
                    }
                }
            }
            if paths.isEmpty {
                let url = unusedURL(name: photo.name)
                try data.write(to: url, options: .atomic)
                let path = url.lastPathComponent
                local[path] = LocalImage(hash: digest, signature: try signature(url))
                pathsByHash[digest, default: []].append(path)
                paths = [path]
            }
            state!.entries[photo.key] = Entry(paths: paths, version: photo.url.absoluteString, hash: digest)
            try save()
        }
        let tracked = Set(state!.entries.values.flatMap(\.paths))
        let newPaths = local.keys.filter { !tracked.contains($0) }.sorted()
        await progress(.uploads(try newPaths.map { try localURL($0) }))
        var added = 0, skipped = 0
        let proposed = UUID()
        let group: UUID?
        if !newPaths.isEmpty { group = try await remote.startUploadGroup(proposed) ? proposed : nil }
        else { group = nil }
        var uploadFailure: Error?
        for path in newPaths {
            let file = try localURL(path)
            if cancelled.contains(path) { await progress(.removed(file)); continue }
            do {
                let digest = local[path]!.hash
                if let key = state!.entries.first(where: { $0.value.hash == digest })?.key {
                    state!.entries[key]!.paths.append(path); skipped += 1
                    try save(); await progress(.removed(file)); continue
                }
                await progress(.message("Uploading \(file.lastPathComponent)…"))
                let snapshotHash = Self.hash(try Data(contentsOf: file))
                cachedCloud = nil // A failed request can still have reached the server.
                let result = try await remote.upload(file, existingPhotos: Array(cloud.values), uploadGroup: group)
                if result.added { cloudMutated = true }
                if cancelled.contains(path) {
                    if result.added { try await remote.delete(key: result.photo.key) }
                    await progress(.removed(file)); continue
                }
                if result.added { added += 1 } else { skipped += 1 }
                cloud[result.photo.key] = result.photo
                if state!.entries[result.photo.key] == nil {
                    state!.entries[result.photo.key] = Entry(paths: [], version: result.photo.url.absoluteString,
                                                           hash: result.contentHash ?? snapshotHash)
                }
                state!.entries[result.photo.key]!.paths.append(path)
                try save()
                await progress(result.added ? .uploaded(file) : .removed(file))
            } catch {
                uploadFailure = error; await progress(.removed(file)); break
            }
        }
        // Replacement files must be safely stored before the old cloud object is removed.
        let nowTracked = Set(state!.entries.values.flatMap(\.paths))
        do {
            for (key, entry) in obsolete {
                // The file can change back to its old contents before upload.
                // Deduplication then returns the original key; keep that object.
                if state!.entries[key] != nil { continue }
                if entry.paths.allSatisfy({ nowTracked.contains($0) }) {
                    state!.pendingDeletes[key] = entry.version; try save()
                    cachedCloud = nil
                    try await remote.delete(key: key)
                    cloudMutated = true
                    cloud.removeValue(forKey: key); state!.pendingDeletes.removeValue(forKey: key); try save()
                } else {
                    // A failed or cancelled replacement keeps the previous server copy.
                    state!.entries[key] = Entry(paths: [], version: entry.version, hash: entry.hash)
                    try save()
                }
            }
        } catch { uploadFailure = uploadFailure ?? error }
        if let group { try await remote.finishUploadGroup(group, added: added) }
        if let uploadFailure { throw uploadFailure }
        let photos: [Photo]
        if cloudMutated { photos = try await cloudList(remote) }
        else { photos = cloud.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        for photo in photos where state!.entries[photo.key] != nil {
            if state!.entries[photo.key]?.version.contains("?v=") == false {
                state!.entries[photo.key]?.version = photo.url.absoluteString
            }
        }
        // Empty entries preserve a server copy after an interrupted replacement.
        for key in state!.entries.keys where state!.entries[key]?.paths.isEmpty == true { state!.entries.removeValue(forKey: key) }
        try save()
        cachedCloud = Dictionary(uniqueKeysWithValues: photos.map { ($0.key, $0) })
        hashes = local
        reconciled = true
        return Result(photos: photos, added: added, skipped: skipped, cancelled: cancelled.count)
    }
}
