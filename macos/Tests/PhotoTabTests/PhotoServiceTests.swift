import XCTest
@testable import PhotoTab

private actor CloudChangeRecorder {
    let connected: XCTestExpectation
    let changed: XCTestExpectation
    private var count = 0
    init(connected: XCTestExpectation, changed: XCTestExpectation) {
        self.connected = connected; self.changed = changed
    }
    func receive() {
        count += 1
        if count == 1 { connected.fulfill() }
        else if count == 2 { changed.fulfill() }
    }
}

final class PhotoServiceTests: XCTestCase {
    func testLiveCloudNotificationsRemainConnectedAfterHeartbeat() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOTAB_LIVE_CONFIG"] else {
            throw XCTSkip("Set PHOTOTAB_LIVE_CONFIG for the live notification check.")
        }
        let configuration = try JSONDecoder().decode(BucketConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = try PhotoService(configuration: configuration)
        let connected = expectation(description: "Cloud notification connection")
        let changed = expectation(description: "Cloud change notification")
        let recorder = CloudChangeRecorder(connected: connected, changed: changed)
        let observer = Task { try await api.observeChanges { await recorder.receive() } }
        defer { observer.cancel() }
        await fulfillment(of: [connected], timeout: 10)
        // Exercise one heartbeat before the change, so a rejected ping or an
        // idle connection failure cannot hide behind a quick handshake test.
        try await Task.sleep(for: .seconds(21))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("phototab-notification-\(UUID().uuidString).png")
        var data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP0YAAAAASUVORK5CYII=")!
        data.append(Data(UUID().uuidString.utf8))
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let uploaded = try await api.upload(file, existingPhotos: [])
        await fulfillment(of: [changed], timeout: 10)
        observer.cancel()
        _ = await observer.result
        if uploaded.added { try await api.delete(key: uploaded.photo.key) }
    }

    func testRejectsUnsafeServerAddresses() {
        for endpoint in ["http://photos.example", "https://user:pass@photos.example", "https://photos.example/path", "https://photos.example?token=abc", "https://photos.example#token"] {
            XCTAssertThrowsError(try BucketConfiguration(endpoint: endpoint, token: "token").validatedURL())
        }
        XCTAssertNoThrow(try BucketConfiguration(endpoint: "https://photos.example", token: "token").validatedURL())
        XCTAssertThrowsError(try BucketConfiguration(endpoint: "https://photos.example", token: "").validatedURL())
    }

    func testImageKeysAreEncodedWithoutChangingOrigin() async throws {
        let api = try PhotoService(configuration: BucketConfiguration(endpoint: "https://photos.example", token: "token"))
        let url = await api.imageURL(key: "folder/été #1.png")
        XCTAssertEqual(url.host, "photos.example")
        XCTAssertEqual(url.path, "/image/folder/été #1.png")
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.query)
    }

    func testLiveUploadThumbnailAndDelete() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOTAB_LIVE_CONFIG"] else {
            throw XCTSkip("Set PHOTOTAB_LIVE_CONFIG for the live bucket check.")
        }
        let configuration = try JSONDecoder().decode(BucketConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = try PhotoService(configuration: configuration)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("phototab-test-\(UUID().uuidString).png")
        var imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP0YAAAAASUVORK5CYII=")!
        // Unique trailing bytes keep the fixture separate from user images.
        imageData.append(Data(UUID().uuidString.utf8))
        try imageData.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await api.upload(file)
        guard result.added else { throw XCTSkip("The live bucket already contains the test image.") }
        let key = result.photo.key
        do {
            let photos = try await api.list()
            let photo = try XCTUnwrap(photos.first { $0.key == key })
            let image = try await api.thumbnail(photo, pixels: 300)
            XCTAssertLessThanOrEqual(max(image.width, image.height), 300)
            let duplicate = try await api.upload(file)
            XCTAssertFalse(duplicate.added)
            XCTAssertEqual(duplicate.photo.key, key)
        } catch {
            try? await api.delete(key: key)
            throw error
        }
        try await api.delete(key: key)
        let after = try await api.list()
        XCTAssertFalse(after.contains { $0.key == key })
    }
}
