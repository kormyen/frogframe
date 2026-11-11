import SwiftUI
import Observation

struct PendingUpload: Identifiable {
    let id = UUID()
    let file: URL
    var completed = false
    var selectionID: String { "upload:\(id.uuidString)" }
}

@MainActor @Observable
final class LibraryModel {
    var photos: [Photo] = []
    var pendingUploads: [PendingUpload] = []
    private var cancelledUploads = Set<UUID>()
    private var currentUpload: UUID?
    var selection = Set<String>()
    private var selectionAnchor: String?
    var service: PhotoService?
    var configuration: BucketConfiguration?
    var busy = false
    var status = ""
    var uploadSummary = ""
    var error: String?
    var preview: Photo?
    var syncFolder: URL?
    var folderStatus = ""
    private var folderAccess: SyncFolderAccess?
    private var folderEngine: FolderSync?
    private var folderDebounce: Task<Void, Never>?
    private var folderCloudWatch: Task<Void, Never>?
    private var folderCloudDirty = true
    private var lastFolderCloudCheck = Date.distantPast

    init(service: PhotoService? = nil, loadSavedConfiguration: Bool = true) {
        if let service {
            self.service = service
            return
        }
        guard loadSavedConfiguration else { return }
        do {
            if let path = ProcessInfo.processInfo.environment["PHOTOTAB_CONFIGURATION"] {
                let loaded = try JSONDecoder().decode(BucketConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                try Credentials.save(loaded)
            }
            if let saved = Credentials.load() {
                configuration = saved
                self.service = try PhotoService(configuration: saved)
                if let folder = try SyncFolderAccess.savedURL() { try startFolder(folder, connection: saved) }
            }
        } catch { self.error = error.localizedDescription }
    }

    func configure(_ newValue: BucketConfiguration) async {
        do {
            try Credentials.save(newValue)
            let api = try PhotoService(configuration: newValue)
            configuration = newValue; service = api
            folderAccess?.stop()
            folderEngine = nil
            if let folder = syncFolder { try startFolder(folder, connection: newValue) }
            else if let folder = try SyncFolderAccess.savedURL() { try startFolder(folder, connection: newValue) }
            photos = []; selection = []
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !busy, let service else { return }
        busy = true; status = "Loading images…"
        defer { busy = false; status = "" }
        do {
            if folderEngine != nil { try await synchronizeFolder() }
            else { photos = try await service.list() }
            selection.formIntersection(Set(photos.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }

    func add(_ files: [URL]) async {
        guard !busy, let service, !files.isEmpty else { return }
        if let folderEngine {
            busy = true
            defer { busy = false; status = ""; pendingUploads = [] }
            do {
                try await folderEngine.importFiles(files)
                try await synchronizeFolder()
            } catch { self.error = error.localizedDescription }
            return
        }
        busy = true
        uploadSummary = ""
        pendingUploads = files.map { PendingUpload(file: $0) }
        cancelledUploads = []
        let uploads = pendingUploads
        defer {
            selection.subtract(uploads.map(\.selectionID))
            busy = false; status = ""; pendingUploads = []; currentUpload = nil; cancelledUploads = []
        }
        var failures = [String]()
        var added = Set<String>()
        var uploadedPhotos = [Photo]()
        var skipped = 0
        var existing: [Photo]
        do { existing = try await service.list() }
        catch { self.error = error.localizedDescription; return }
        let proposedGroup = UUID()
        let group: UUID?
        do { group = try await service.startUploadGroup(proposedGroup) ? proposedGroup : nil }
        catch { self.error = error.localizedDescription; return }
        for (index, upload) in uploads.enumerated() {
            guard !cancelledUploads.contains(upload.id) else { continue }
            let file = upload.file
            currentUpload = upload.id
            status = "Uploading \(index + 1) of \(files.count)…"
            do {
                let result = try await service.upload(file, existingPhotos: existing, uploadGroup: group)
                if cancelledUploads.contains(upload.id) {
                    // Wait for the PUT to settle before deleting. This prevents
                    // a late server write from restoring a cancelled image.
                    if result.added {
                        do { try await service.delete(key: result.photo.key) }
                        catch {
                            uploadedPhotos.append(result.photo)
                            existing.append(result.photo)
                            added.insert(result.photo.id)
                            failures.append("Cannot remove cancelled upload \(file.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    continue
                }
                if result.added {
                    added.insert(result.photo.id)
                    existing.append(result.photo)
                    uploadedPhotos.append(result.photo)
                    if let card = pendingUploads.firstIndex(where: { $0.id == upload.id }) {
                        pendingUploads[card].completed = true
                    }
                } else {
                    skipped += 1
                    pendingUploads.removeAll { $0.id == upload.id }
                }
            }
            catch {
                pendingUploads.removeAll { $0.id == upload.id }
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
            selection.remove(upload.selectionID)
        }
        // Keep successful uploads visible even if the final refresh fails.
        photos.append(contentsOf: uploadedPhotos)
        pendingUploads = []
        if let group {
            do { try await service.finishUploadGroup(group, added: added.count) }
            catch { failures.append("Cannot send the upload summary to the tablet: \(error.localizedDescription)") }
        }
        do { photos = try await service.list(); selection = added }
        catch { failures.append(error.localizedDescription) }
        uploadSummary = "\(added.count) added · \(skipped) skipped"
        if !cancelledUploads.isEmpty { uploadSummary += " · \(cancelledUploads.count) cancelled" }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    func deleteSelection() async {
        guard !busy, let service else { return }
        let keys = selection
        busy = true
        defer { busy = false; status = "" }
        var failures = [String]()
        for (index, key) in keys.sorted().enumerated() {
            status = "Deleting \(index + 1) of \(keys.count)…"
            do { try await service.delete(key: key); photos.removeAll { $0.key == key }; selection.remove(key) }
            catch { failures.append(error.localizedDescription) }
        }
        if folderEngine != nil {
            do { try await synchronizeFolder() }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    func openInFinder(_ photo: Photo) async {
        guard let folderEngine else { return }
        do {
            guard let file = try await folderEngine.localFile(for: photo) else {
                throw BucketError.message("This image has no local file. Wait for folder sync to finish, then try again.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch { self.error = error.localizedDescription }
    }

    func deselectAll() {
        selection = []
        selectionAnchor = nil
    }

    var selectableIDs: [String] {
        photos.map(\.id) + pendingUploads.filter { !$0.completed }.map(\.selectionID)
    }

    var hasSelectedUploads: Bool {
        pendingUploads.contains { !$0.completed && selection.contains($0.selectionID) }
    }

    func cancelSelectedUploads() {
        let cancelled = pendingUploads.filter { !$0.completed && selection.contains($0.selectionID) }
        cancelledUploads.formUnion(cancelled.map(\.id))
        let ids = Set(cancelled.map(\.selectionID))
        if let folderEngine {
            status = "Cancelling uploads…"
            Task {
                do { try await folderEngine.cancel(cancelled.map(\.file)) }
                catch { self.error = error.localizedDescription }
            }
        }
        pendingUploads.removeAll { ids.contains($0.selectionID) }
        selection.subtract(ids)
        if let currentUpload, cancelledUploads.contains(currentUpload) { status = "Cancelling upload…" }
        if let selectionAnchor, ids.contains(selectionAnchor) { self.selectionAnchor = nil }
    }

    private func startFolder(_ folder: URL, connection: BucketConfiguration) throws {
        folderAccess?.stop()
        folderCloudWatch?.cancel()
        let access = try SyncFolderAccess(url: folder) { [weak self] in self?.scheduleFolderSync() }
        folderAccess = access
        syncFolder = folder
        folderEngine = FolderSync(directory: folder, connection: connection)
        folderCloudDirty = true
        lastFolderCloudCheck = .distantPast
        if let service {
            folderCloudWatch = Task { [weak self] in
                var retrySeconds = 2
                while !Task.isCancelled {
                    do {
                        try await service.observeChanges { [weak self] in
                            await self?.folderCloudChanged()
                        }
                    } catch {
                        if Task.isCancelled { return }
                    }
                    do { try await Task.sleep(for: .seconds(retrySeconds)) } catch { return }
                    retrySeconds = min(30, retrySeconds * 2)
                }
            }
        }
        folderStatus = "Ready to sync"
    }

    func chooseSyncFolder(_ folder: URL) async {
        guard !busy, let configuration else { return }
        do {
            try SyncFolderAccess.save(folder)
            try startFolder(folder, connection: configuration)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func stopFolderSync() {
        guard !busy else { return }
        folderDebounce?.cancel()
        folderCloudWatch?.cancel(); folderCloudWatch = nil
        folderAccess?.stop(); folderAccess = nil
        folderEngine = nil; syncFolder = nil; folderStatus = ""
        SyncFolderAccess.clear()
    }

    private func scheduleFolderSync() {
        // Writes made by the current sync also raise folder events. Do not
        // cancel an active transfer when one of those events arrives.
        guard !busy, folderEngine != nil else { return }
        folderDebounce?.cancel()
        folderDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !self.busy, self.folderEngine != nil else { return }
            self.busy = true
            defer { self.busy = false; self.status = ""; self.pendingUploads = [] }
            do { try await self.synchronizeFolder(forceCloudRefresh: false) }
            catch { self.folderStatus = "Sync paused: \(error.localizedDescription)" }
        }
    }

    private func folderCloudChanged() {
        folderCloudDirty = true
        scheduleFolderSync()
    }

    private func synchronizeFolder(forceCloudRefresh: Bool = true) async throws {
        guard let folderEngine, let service else { return }
        let refreshCloud = forceCloudRefresh || folderCloudDirty || Date().timeIntervalSince(lastFolderCloudCheck) >= 60
        if refreshCloud {
            folderCloudDirty = false
            lastFolderCloudCheck = Date()
        }
        folderStatus = "Syncing…"
        let result = try await folderEngine.synchronize(remote: service, refreshCloud: refreshCloud) { [weak self] event in
            await self?.receiveFolderProgress(event)
        }
        photos = result.photos
        selection.formIntersection(Set(photos.map(\.id)))
        pendingUploads = []
        folderStatus = "Up to date"
        if result.added > 0 || result.skipped > 0 || result.cancelled > 0 {
            uploadSummary = "\(result.added) added · \(result.skipped) skipped"
            if result.cancelled > 0 { uploadSummary += " · \(result.cancelled) cancelled" }
        }
    }

    private func receiveFolderProgress(_ progress: FolderSyncProgress) {
        switch progress {
        case .message(let text): status = text
        case .photos(let photos): self.photos = photos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .uploads(let files): pendingUploads = files.map { PendingUpload(file: $0) }
        case .uploaded(let file):
            if let index = pendingUploads.firstIndex(where: { $0.file == file }) {
                selection.remove(pendingUploads[index].selectionID)
                pendingUploads[index].completed = true
            }
        case .removed(let file):
            selection.subtract(pendingUploads.filter { $0.file == file }.map(\.selectionID))
            pendingUploads.removeAll { $0.file == file }
        }
    }

    func selectUpload(_ upload: PendingUpload, extending: Bool, range: Bool = false) {
        guard !upload.completed else { return }
        select(id: upload.selectionID, extending: extending, range: range)
    }

    func select(_ photo: Photo, extending: Bool, range: Bool = false) {
        select(id: photo.id, extending: extending, range: range)
    }

    private func select(id: String, extending: Bool, range: Bool) {
        let ids = selectableIDs
        if range, let anchor = selectionAnchor,
           let start = ids.firstIndex(of: anchor),
           let end = ids.firstIndex(of: id) {
            let rangeIDs = Set(ids[min(start, end)...max(start, end)])
            selection = extending ? selection.union(rangeIDs) : rangeIDs
            return
        }
        selectionAnchor = id
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else { selection = [id] }
    }
}
