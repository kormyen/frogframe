import XCTest
@testable import PhotoTab

private struct PausedUploadRequest: Sendable {
    let request: URLRequest
    let reply: @Sendable (Int, Data) -> Void
}

private actor UploadRequestQueue {
    private var requests: [PausedUploadRequest] = []
    private var waiter: CheckedContinuation<PausedUploadRequest, Never>?

    func response(for request: URLRequest) async -> (Int, Data) {
        await withCheckedContinuation { continuation in
            let paused = PausedUploadRequest(request: request) { status, data in
                continuation.resume(returning: (status, data))
            }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: paused)
            } else { requests.append(paused) }
        }
    }
    func next() async -> PausedUploadRequest {
        if !requests.isEmpty { return requests.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private final class PausedUploadProtocol: URLProtocol, @unchecked Sendable {
    static let queue = UploadRequestQueue()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            let (status, data) = await Self.queue.response(for: request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class UploadProgressTests: XCTestCase {
    func testCancelQueuedAndCurrentUploadsWithoutDeletingAnExistingDuplicate() async throws {
        for duplicate in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let files = [folder.appendingPathComponent("one.png"), folder.appendingPathComponent("two.png")]
            try Data("first".utf8).write(to: files[0])
            try Data("second".utf8).write(to: files[1])
            let settings = URLSessionConfiguration.ephemeral
            settings.protocolClasses = [PausedUploadProtocol.self]
            let api = try PhotoService(configuration: BucketConfiguration(endpoint: "https://photos.example", token: "test"), sessionConfiguration: settings)
            let model = LibraryModel(service: api)
            let operation = Task { await model.add(files) }
            let manifest = await PausedUploadProtocol.queue.next()
            let listing = duplicate
                ? "{\"images\":[{\"key\":\"saved.png\",\"url\":\"https://photos.example/image/saved.png?v=1\",\"size\":5}],\"cursor\":null}"
                : "{\"images\":[],\"cursor\":null}"
            manifest.reply(200, Data(listing.utf8))
            let start = await PausedUploadProtocol.queue.next()
            start.reply(204, Data())
            let current = await PausedUploadProtocol.queue.next()
            XCTAssertEqual(current.request.httpMethod, duplicate ? "GET" : "PUT")
            model.selectUpload(model.pendingUploads[0], extending: false)
            model.selectUpload(model.pendingUploads[1], extending: true)
            XCTAssertTrue(model.hasSelectedUploads)
            model.cancelSelectedUploads()
            XCTAssertTrue(model.pendingUploads.isEmpty)
            XCTAssertTrue(model.selection.isEmpty)
            current.reply(duplicate ? 200 : 201, duplicate ? Data("first".utf8) : Data())
            if !duplicate {
                let removal = await PausedUploadProtocol.queue.next()
                XCTAssertEqual(removal.request.httpMethod, "DELETE")
                XCTAssertEqual(removal.request.url, current.request.url)
                removal.reply(204, Data())
            }
            let finish = await PausedUploadProtocol.queue.next()
            XCTAssertTrue(finish.request.url!.path.hasSuffix("/finish"))
            finish.reply(204, Data())
            let refresh = await PausedUploadProtocol.queue.next()
            XCTAssertEqual(refresh.request.url?.path, "/manifest")
            refresh.reply(200, Data(listing.utf8))
            await operation.value
            XCTAssertNil(model.error)
            XCTAssertFalse(model.busy)
            XCTAssertEqual(model.photos.count, duplicate ? 1 : 0)
            XCTAssertEqual(model.uploadSummary, "0 added · 0 skipped · 2 cancelled")
        }
    }

    func testLiveGroupCountsNewImagesAndSkipsDuplicate() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOTAB_LIVE_CONFIG"] else {
            throw XCTSkip("Set PHOTOTAB_LIVE_CONFIG for the live group check.")
        }
        let config = try JSONDecoder().decode(BucketConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = try PhotoService(configuration: config)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let prefix = "phototab-progress-fixture-\(UUID().uuidString)"
        let files = ["one", "two", "duplicate"].map { folder.appendingPathComponent("\(prefix)-\($0).png") }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP0YAAAAASUVORK5CYII=")!
        let first = png + Data(UUID().uuidString.utf8)
        try first.write(to: files[0])
        try (png + Data(UUID().uuidString.utf8)).write(to: files[1])
        try first.write(to: files[2])
        let model = LibraryModel(service: api)
        await model.add(files)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.uploadSummary, "2 added · 1 skipped")
        XCTAssertTrue(model.pendingUploads.isEmpty)
        let fixtures = try await api.list().filter { $0.name.hasPrefix(prefix) }
        XCTAssertEqual(fixtures.count, 2)
        for photo in fixtures { try await api.delete(key: photo.key) }
        let after = try await api.list()
        XCTAssertFalse(after.contains { $0.name.hasPrefix(prefix) })
    }

    func testCardsAppearBeforeRequestsAndCompleteIndividuallyWithOneSummary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [folder.appendingPathComponent("first.png"), folder.appendingPathComponent("second.png")]
        try Data("first".utf8).write(to: files[0])
        try Data("second".utf8).write(to: files[1])
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [PausedUploadProtocol.self]
        let api = try PhotoService(configuration: BucketConfiguration(endpoint: "https://photos.example", token: "test"), sessionConfiguration: settings)
        let model = LibraryModel(service: api)
        let operation = Task { await model.add(files) }
        let manifest = await PausedUploadProtocol.queue.next()
        XCTAssertEqual(manifest.request.url?.path, "/manifest")
        XCTAssertEqual(model.pendingUploads.map(\.file), files)
        XCTAssertTrue(model.pendingUploads.allSatisfy { !$0.completed })
        manifest.reply(200, Data("{\"images\":[],\"cursor\":null}".utf8))
        let start = await PausedUploadProtocol.queue.next()
        XCTAssertTrue(start.request.url!.path.hasSuffix("/start"))
        start.reply(204, Data())
        let first = await PausedUploadProtocol.queue.next()
        XCTAssertEqual(first.request.httpMethod, "PUT")
        XCTAssertNotNil(first.request.value(forHTTPHeaderField: "X-PhotoTab-Upload-Group"))
        XCTAssertEqual(model.pendingUploads.filter(\.completed).count, 0)
        first.reply(201, Data())
        let second = await PausedUploadProtocol.queue.next()
        XCTAssertEqual(second.request.httpMethod, "PUT")
        XCTAssertEqual(model.pendingUploads.map(\.completed), [true, false])
        second.reply(500, Data())
        let finish = await PausedUploadProtocol.queue.next()
        XCTAssertTrue(finish.request.url!.path.hasSuffix("/finish"))
        let body: Data
        if let data = finish.request.httpBody { body = data }
        else if let stream = finish.request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = stream.read(&buffer, maxLength: buffer.count)
            body = Data(buffer.prefix(max(0, count)))
        } else { body = Data() }
        let summary = try JSONDecoder().decode([String: Int].self, from: body)
        XCTAssertEqual(summary["added"], 1)
        XCTAssertTrue(model.pendingUploads.isEmpty)
        XCTAssertEqual(model.photos.count, 1)
        finish.reply(204, Data())
        let refresh = await PausedUploadProtocol.queue.next()
        XCTAssertEqual(refresh.request.url?.path, "/manifest")
        refresh.reply(503, Data())
        await operation.value
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.pendingUploads.isEmpty)
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertEqual(model.uploadSummary, "1 added · 0 skipped")
        XCTAssertNotNil(model.error)
    }
}
