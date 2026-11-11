import XCTest
import CryptoKit
@testable import PhotoTab

private actor FolderBucket: FolderSyncRemote {
    private var objects: [String: (Data, Int)] = [:]
    private var revision = 0
    private var deletions: [String] = []
    private var summaries: [Int] = []
    private var listCalls = 0
    var failList = false
    var failUpload = false
    var beforeUpload: (@Sendable (URL) async throws -> Void)?
    var beforeRead: (@Sendable (URL) async throws -> Void)?

    func setFailures(list: Bool = false, upload: Bool = false) { failList = list; failUpload = upload }
    func setUploadHook(_ hook: @escaping @Sendable (URL) async throws -> Void) { beforeUpload = hook }
    func setReadHook(_ hook: @escaping @Sendable (URL) async throws -> Void) { beforeRead = hook }
    func put(_ key: String, _ text: String) { revision += 1; objects[key] = (Data(text.utf8), revision) }
    func remove(_ key: String) { objects.removeValue(forKey: key) }
    func values() -> Set<Data> { Set(objects.values.map { $0.0 }) }
    func deleted() -> [String] { deletions }
    func notices() -> [Int] { summaries }
    func listCount() -> Int { listCalls }
    private func photo(_ key: String) -> Photo {
        let object = objects[key]!
        return Photo(key: key, url: URL(string: "https://photos.example/image/\(key)?v=\(object.1)")!, size: object.0.count)
    }
    func list() throws -> [Photo] {
        listCalls += 1
        if failList { throw BucketError.message("Offline") }
        return objects.keys.sorted().map(photo)
    }
    func download(_ photo: Photo) throws -> Data { try XCTUnwrap(objects[photo.key]?.0) }
    func upload(_ file: URL, existingPhotos: [Photo]?, uploadGroup: UUID?) async throws -> PhotoService.UploadResult {
        if failUpload { throw BucketError.message("Upload failed") }
        if let hook = beforeRead { beforeRead = nil; try await hook(file) }
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let key = objects.first(where: { $0.value.0 == data })?.key { return .init(photo: photo(key), added: false, contentHash: digest) }
        if let beforeUpload { try await beforeUpload(file) }
        let key = UUID().uuidString + "/" + file.lastPathComponent
        revision += 1; objects[key] = (data, revision)
        return .init(photo: Photo(key: key, url: URL(string: "https://photos.example/image/\(key)")!, size: data.count), added: true, contentHash: digest)
    }
    func delete(key: String) { deletions.append(key); objects.removeValue(forKey: key) }
    func startUploadGroup(_ id: UUID) -> Bool { true }
    func finishUploadGroup(_ id: UUID, added: Int) { summaries.append(added) }
}

final class FolderSyncTests: XCTestCase {
    private let configuration = BucketConfiguration(endpoint: "https://photos.example", token: "fixture")
    private func setup() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (folder, root.appendingPathComponent("state"))
    }
    private func engine(_ folder: URL, _ state: URL) -> FolderSync {
        FolderSync(directory: folder, connection: configuration, stateDirectory: state,
                   trash: { try FileManager.default.removeItem(at: $0) })
    }
    private func write(_ text: String, _ folder: URL, _ name: String = "one.png") throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }
    private func files(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
    }
    private func contents(_ folder: URL) throws -> Set<Data> { try Set(files(folder).map { try Data(contentsOf: $0) }) }

    func testFinderLocationUsesTrackedNestedPathAfterRestart() async throws {
        let (folder, state) = try setup()
        let nested = folder.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("first image", nested, "same.png")
        try write("second image", folder, "same.png")
        let remote = FolderBucket()
        let result = try await engine(folder, state).synchronize(remote: remote)
        let restarted = engine(folder, state)
        var locations = Set<URL>()
        for photo in result.photos {
            let location = try await restarted.localFile(for: photo)
            locations.insert(try XCTUnwrap(location))
        }
        XCTAssertEqual(locations, Set([folder.appendingPathComponent("same.png"), nested.appendingPathComponent("same.png")]))
    }

    func testFinderLocationRejectsMissingFileAndStaleVersion() async throws {
        let (folder, state) = try setup()
        try write("image", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        let result = try await sync.synchronize(remote: remote)
        let photo = try XCTUnwrap(result.photos.first)
        let changed = Photo(key: photo.key, url: URL(string: "https://photos.example/changed")!, size: photo.size)
        let staleLocation = try await sync.localFile(for: changed)
        XCTAssertNil(staleLocation)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("one.png"))
        let missingLocation = try await sync.localFile(for: photo)
        XCTAssertNil(missingLocation)
    }

    func testIdleSyncDoesNoWritesHashesOrCloudFetchesFor115Images() async throws {
        let (folder, state) = try setup()
        let remote = FolderBucket()
        for index in 0..<115 { try write("image-\(index)", folder, "image-\(index).png") }
        let sync = engine(folder, state)
        _ = try await sync.synchronize(remote: remote)
        let before = await sync.statistics()
        let listCalls = await remote.listCount()
        let journal = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil).first)
        let modified = try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<50 { _ = try await sync.synchronize(remote: remote, refreshCloud: false) }
        let elapsed = start.duration(to: clock.now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let after = await sync.statistics()
        XCTAssertEqual(after.recordWrites, before.recordWrites)
        XCTAssertEqual(after.filesHashed, before.filesHashed)
        XCTAssertEqual(after.bytesHashed, before.bytesHashed)
        XCTAssertEqual(after.cloudLists, before.cloudLists)
        let idleListCalls = await remote.listCount()
        XCTAssertEqual(idleListCalls, listCalls)
        XCTAssertEqual(try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        print("Idle sync: 50 checks of 115 files in \(Int(milliseconds)) ms; 0 record writes, 0 image hashes, 0 cloud lists")

        // The periodic fallback or manual refresh needs only one cloud list.
        _ = try await sync.synchronize(remote: remote, refreshCloud: true)
        let refreshed = await sync.statistics()
        XCTAssertEqual(refreshed.cloudLists, after.cloudLists + 1)
        XCTAssertEqual(refreshed.recordWrites, after.recordWrites)
        XCTAssertEqual(refreshed.filesHashed, after.filesHashed)
    }

    func testSameSizeEditWithRestoredModificationTimeStillSyncs() async throws {
        let (folder, state) = try setup()
        try write("before", folder)
        try write("unchanged", folder, "two.png")
        let file = folder.appendingPathComponent("one.png")
        let oldDate = Date(timeIntervalSince1970: 1700000000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        _ = try await sync.synchronize(remote: remote)
        let before = await sync.statistics()
        try Data("after!".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        _ = try await sync.synchronize(remote: remote, refreshCloud: false)
        let after = await sync.statistics()
        XCTAssertEqual(after.filesHashed, before.filesHashed + 1)
        let values = await remote.values()
        XCTAssertEqual(values, Set([Data("after!".utf8), Data("unchanged".utf8)]))
    }

    func testLocalChangeRefreshesCloudBeforeResolvingAConflict() async throws {
        let (folder, state) = try setup()
        try write("original", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        let first = try await sync.synchronize(remote: remote)
        try write("local edit", folder)
        await remote.put(first.photos[0].key, "cloud edit")
        let result = try await sync.synchronize(remote: remote, refreshCloud: false)
        XCTAssertEqual(result.photos.count, 2)
        let values = await remote.values()
        XCTAssertEqual(values, Set([Data("local edit".utf8), Data("cloud edit".utf8)]))
    }

    func testFirstSyncMergesBothSidesAndDoesNotDuplicateMatchingFiles() async throws {
        let (folder, state) = try setup()
        try write("local", folder)
        let remote = FolderBucket()
        await remote.put("existing/one.png", "local")
        await remote.put("other/two.png", "cloud")
        let result = try await engine(folder, state).synchronize(remote: remote)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.photos.count, 2)
        XCTAssertEqual(try contents(folder), Set([Data("local".utf8), Data("cloud".utf8)]))
        let deleted = await remote.deleted()
        XCTAssertTrue(deleted.isEmpty)
    }

    func testLocalAndCloudDeletionsSurviveRestart() async throws {
        let (folder, state) = try setup()
        try write("one", folder)
        try write("two", folder, "two.png")
        let remote = FolderBucket()
        let first = try await engine(folder, state).synchronize(remote: remote)
        XCTAssertEqual(first.added, 2)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("one.png"))
        let second = try await engine(folder, state).synchronize(remote: remote)
        XCTAssertEqual(second.photos.count, 1)
        await remote.remove(second.photos[0].key)
        _ = try await engine(folder, state).synchronize(remote: remote)
        XCTAssertTrue(try files(folder).isEmpty)
    }

    func testSameNamesWithDifferentContentsKeepBothImages() async throws {
        let (folder, state) = try setup()
        try write("local", folder)
        let remote = FolderBucket()
        await remote.put("cloud/one.png", "server")
        let result = try await engine(folder, state).synchronize(remote: remote)
        XCTAssertEqual(result.photos.count, 2)
        XCTAssertEqual(try files(folder).count, 2)
        XCTAssertEqual(try contents(folder), Set([Data("local".utf8), Data("server".utf8)]))
    }

    func testDeletingOneCloudDuplicateKeepsTheOtherCopy() async throws {
        let (folder, state) = try setup()
        let remote = FolderBucket()
        await remote.put("first/one.png", "same")
        await remote.put("second/two.png", "same")
        let sync = engine(folder, state)
        _ = try await sync.synchronize(remote: remote)
        XCTAssertEqual(try files(folder).count, 1)
        await remote.remove("first/one.png")
        let remaining = try await sync.synchronize(remote: remote)
        XCTAssertEqual(remaining.photos.count, 1)
        XCTAssertEqual(try files(folder).count, 1)
        let deleted = await remote.deleted()
        XCTAssertTrue(deleted.isEmpty)
        await remote.remove("second/two.png")
        _ = try await sync.synchronize(remote: remote)
        XCTAssertTrue(try files(folder).isEmpty)
    }

    func testRenameKeepsTheSameCloudObject() async throws {
        let (folder, state) = try setup()
        try write("one", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        let first = try await sync.synchronize(remote: remote)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("one.png"), to: folder.appendingPathComponent("renamed.png"))
        let second = try await sync.synchronize(remote: remote)
        XCTAssertEqual(first.photos.map(\.key), second.photos.map(\.key))
        XCTAssertEqual(second.added, 0)
        await remote.remove(second.photos[0].key)
        _ = try await sync.synchronize(remote: remote)
        XCTAssertTrue(try files(folder).isEmpty)
    }

    func testLocalEditReplacesCloudObjectAfterSuccessfulUpload() async throws {
        let (folder, state) = try setup()
        try write("original", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        let first = try await sync.synchronize(remote: remote)
        try write("changed image", folder)
        let second = try await sync.synchronize(remote: remote)
        XCTAssertEqual(second.photos.count, 1)
        XCTAssertNotEqual(first.photos[0].key, second.photos[0].key)
        let values = await remote.values()
        XCTAssertEqual(values, Set([Data("changed image".utf8)]))
    }

    func testFileRevertingDuringUploadKeepsTheDeduplicatedCloudObject() async throws {
        let (folder, state) = try setup()
        try write("original", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        let first = try await sync.synchronize(remote: remote)
        try write("temporary edit", folder)
        await remote.setReadHook { file in try Data("original".utf8).write(to: file, options: .atomic) }
        let reverted = try await sync.synchronize(remote: remote)
        XCTAssertEqual(reverted.photos.map(\.key), first.photos.map(\.key))
        let deleted = await remote.deleted()
        XCTAssertTrue(deleted.isEmpty)
    }

    func testEditDuringTransferIsUploadedOnTheNextPass() async throws {
        let (folder, state) = try setup()
        try write("original", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        await remote.setUploadHook { file in try Data("edited during transfer".utf8).write(to: file, options: .atomic) }
        _ = try await sync.synchronize(remote: remote)
        let result = try await sync.synchronize(remote: remote)
        XCTAssertEqual(result.photos.count, 1)
        let values = await remote.values()
        XCTAssertEqual(values, Set([Data("edited during transfer".utf8)]))
    }

    func testCloudEditUpdatesLocalCopyAndConflictingEditsKeepBoth() async throws {
        let (folder, state) = try setup()
        let remote = FolderBucket()
        await remote.put("cloud/one.png", "original")
        let sync = engine(folder, state)
        _ = try await sync.synchronize(remote: remote)
        await remote.put("cloud/one.png", "cloud edit")
        _ = try await sync.synchronize(remote: remote)
        XCTAssertEqual(try contents(folder), Set([Data("cloud edit".utf8)]))
        try write("local edit different", folder)
        await remote.put("cloud/one.png", "second cloud edit")
        let result = try await sync.synchronize(remote: remote)
        XCTAssertEqual(result.photos.count, 2)
        XCTAssertEqual(try contents(folder), Set([Data("local edit different".utf8), Data("second cloud edit".utf8)]))
    }

    func testMissingAndReplacedFolderNeverDeletesCloudImages() async throws {
        let (folder, state) = try setup()
        try write("original", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        _ = try await sync.synchronize(remote: remote)
        let moved = folder.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        do { _ = try await sync.synchronize(remote: remote); XCTFail("Missing folder must pause sync") } catch {}
        var deleted = await remote.deleted()
        XCTAssertTrue(deleted.isEmpty)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try await sync.synchronize(remote: remote)
        XCTAssertEqual(result.photos.count, 1)
        XCTAssertEqual(try files(folder).count, 1)
        deleted = await remote.deleted()
        XCTAssertTrue(deleted.isEmpty)
    }

    func testNewCloudVersionWinsAgainstAnOlderLocalDeletion() async throws {
        let (folder, state) = try setup()
        let remote = FolderBucket()
        await remote.put("cloud/one.png", "original")
        let sync = engine(folder, state)
        _ = try await sync.synchronize(remote: remote)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("one.png"))
        await remote.put("cloud/one.png", "new cloud edit")
        let result = try await sync.synchronize(remote: remote)
        XCTAssertEqual(result.photos.count, 1)
        XCTAssertEqual(try contents(folder), Set([Data("new cloud edit".utf8)]))
    }

    func testOfflineServerAndIncompleteFilesPauseBeforeAnyDeletion() async throws {
        let (folder, state) = try setup()
        try write("original", folder)
        let remote = FolderBucket()
        let sync = engine(folder, state)
        _ = try await sync.synchronize(remote: remote)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("one.png"))
        await remote.setFailures(list: true)
        do { _ = try await sync.synchronize(remote: remote); XCTFail("Offline sync must fail") } catch {}
        await remote.setFailures()
        try write("", folder, "writing.png")
        do { _ = try await sync.synchronize(remote: remote); XCTFail("An incomplete file must pause sync") } catch {}
        let deleted = await remote.deleted()
        XCTAssertTrue(deleted.isEmpty)
    }

    func testImportCopiesAndDeduplicatesWithoutChangingSource() async throws {
        let (folder, state) = try setup()
        let source = folder.deletingLastPathComponent().appendingPathComponent("source.png")
        try Data("source".utf8).write(to: source)
        let sync = engine(folder, state)
        try await sync.importFiles([source, source])
        XCTAssertEqual(try files(folder).count, 1)
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        let remote = FolderBucket()
        let result = try await sync.synchronize(remote: remote)
        XCTAssertEqual(result.added, 1)
    }

    func testFailedUploadIsRetriedAndGroupIsFinished() async throws {
        let (folder, state) = try setup()
        try write("source", folder)
        let sync = engine(folder, state)
        let remote = FolderBucket()
        await remote.setFailures(upload: true)
        do { _ = try await sync.synchronize(remote: remote); XCTFail("The upload must fail") } catch {}
        let notices = await remote.notices()
        XCTAssertEqual(notices, [0])
        XCTAssertEqual(try files(folder).count, 1)
        await remote.setFailures()
        let result = try await sync.synchronize(remote: remote)
        XCTAssertEqual(result.added, 1)
    }

    func testCancelInFlightUploadRemovesOnlyItsNewCopyAndDoesNotRetry() async throws {
        let (folder, state) = try setup()
        try write("source", folder)
        let sync = engine(folder, state)
        let remote = FolderBucket()
        await remote.setUploadHook { file in try await sync.cancel([file]) }
        let result = try await sync.synchronize(remote: remote)
        XCTAssertEqual(result.cancelled, 1)
        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(result.photos.isEmpty)
        XCTAssertTrue(try files(folder).isEmpty)
        let second = try await sync.synchronize(remote: remote)
        XCTAssertTrue(second.photos.isEmpty)
    }

    func testCorruptSyncRecordCannotTriggerDeletions() async throws {
        let (folder, state) = try setup()
        try write("source", folder)
        let remote = FolderBucket()
        _ = try await engine(folder, state).synchronize(remote: remote)
        let journal = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: state, includingPropertiesForKeys: nil).first)
        try Data("invalid record".utf8).write(to: journal)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("one.png"))
        do { _ = try await engine(folder, state).synchronize(remote: remote); XCTFail("Corrupt records must pause sync") } catch {}
        let deleted = await remote.deleted()
        XCTAssertTrue(deleted.isEmpty)
    }
}

private actor LiveFolderBucket: FolderSyncRemote {
    let api: PhotoService
    let prefix: String
    init(api: PhotoService, prefix: String) { self.api = api; self.prefix = prefix }
    func list() async throws -> [Photo] { try await api.list().filter { $0.name.hasPrefix(prefix) } }
    func download(_ photo: Photo) async throws -> Data {
        guard photo.name.hasPrefix(prefix) else { throw BucketError.message("Outside the test group") }
        return try await api.download(photo)
    }
    func upload(_ file: URL, existingPhotos: [Photo]?, uploadGroup: UUID?) async throws -> PhotoService.UploadResult {
        guard file.lastPathComponent.hasPrefix(prefix) else { throw BucketError.message("Outside the test group") }
        return try await api.upload(file, existingPhotos: existingPhotos, uploadGroup: uploadGroup)
    }
    func delete(key: String) async throws {
        guard key.split(separator: "/").last?.hasPrefix(prefix) == true else { throw BucketError.message("Outside the test group") }
        try await api.delete(key: key)
    }
    func startUploadGroup(_ id: UUID) async throws -> Bool { try await api.startUploadGroup(id) }
    func finishUploadGroup(_ id: UUID, added: Int) async throws { try await api.finishUploadGroup(id, added: added) }
}

extension FolderSyncTests {
    func testLiveFolderSyncAddsDeletesDownloadsAndImports() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOTAB_LIVE_CONFIG"] else {
            throw XCTSkip("Set PHOTOTAB_LIVE_CONFIG for the live folder check.")
        }
        let config = try JSONDecoder().decode(BucketConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = try PhotoService(configuration: config)
        let prefix = "phototab-folder-test-\(UUID().uuidString)-"
        let remote = LiveFolderBucket(api: api, prefix: prefix)
        let (folder, state) = try setup()
        let sync = FolderSync(directory: folder, connection: config, stateDirectory: state,
                              trash: { try FileManager.default.removeItem(at: $0) })
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP0YAAAAASUVORK5CYII=")!
        let local = folder.appendingPathComponent(prefix + "local.png")
        let source = folder.deletingLastPathComponent().appendingPathComponent(prefix + "source.png")
        let cloudSource = folder.deletingLastPathComponent().appendingPathComponent(prefix + "cloud.png")
        do {
            try (png + Data(UUID().uuidString.utf8)).write(to: local)
            let first = try await sync.synchronize(remote: remote)
            XCTAssertEqual(first.added, 1)
            XCTAssertEqual(first.photos.count, 1)
            try FileManager.default.removeItem(at: local)
            let deleted = try await sync.synchronize(remote: remote)
            XCTAssertTrue(deleted.photos.isEmpty)
            let cloudData = png + Data(UUID().uuidString.utf8)
            try cloudData.write(to: cloudSource)
            let uploaded = try await remote.upload(cloudSource, existingPhotos: [], uploadGroup: nil)
            let downloaded = try await sync.synchronize(remote: remote)
            XCTAssertEqual(downloaded.photos.count, 1)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(cloudSource.lastPathComponent)), cloudData)
            try await remote.delete(key: uploaded.photo.key)
            _ = try await sync.synchronize(remote: remote)
            XCTAssertTrue(try files(folder).isEmpty)
            let sourceData = png + Data(UUID().uuidString.utf8)
            try sourceData.write(to: source)
            try await sync.importFiles([source])
            let imported = try await sync.synchronize(remote: remote)
            XCTAssertEqual(imported.added, 1)
            XCTAssertEqual(try Data(contentsOf: source), sourceData)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(source.lastPathComponent)), sourceData)
        } catch {
            for photo in (try? await remote.list()) ?? [] { try? await remote.delete(key: photo.key) }
            throw error
        }
        for photo in try await remote.list() { try await remote.delete(key: photo.key) }
    }
}
