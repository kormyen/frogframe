import XCTest
@testable import PhotoTab

private final class UploadResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, Data)] = [:]
    private var calls: [String] = []

    func reset(_ responses: [String: (Int, Data)]) {
        lock.lock(); defer { lock.unlock() }
        self.responses = responses
        calls = []
    }
    func response(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        calls.append("\(method) \(path)")
        if method == "PUT" { return (201, Data()) }
        return responses[path] ?? (404, Data())
    }
    func count(_ prefix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.hasPrefix(prefix) }.count
    }
}

private final class UploadProtocol: URLProtocol, @unchecked Sendable {
    static let responses = UploadResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.responses.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DuplicateUploadTests: XCTestCase {
    private func service(cacheDirectory: URL? = nil, token: String = "test") throws -> PhotoService {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [UploadProtocol.self]
        return try PhotoService(configuration: BucketConfiguration(endpoint: "https://photos.example", token: token),
                                sessionConfiguration: settings, cacheDirectory: cacheDirectory)
    }

    func testCachedImagesSurviveRestartAndChangedVersionsFetchNewData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP0YAAAAASUVORK5CYII=")!
        UploadProtocol.responses.reset(["/image/old/photo.png": (200, png)])
        _ = try await service(cacheDirectory: folder).thumbnail(existing(), pixels: 500)
        XCTAssertEqual(UploadProtocol.responses.count("GET"), 1)
        UploadProtocol.responses.reset([:])
        let saved = try await service(cacheDirectory: folder).thumbnail(existing(), pixels: 500)
        XCTAssertEqual(saved.width, 1)
        XCTAssertEqual(UploadProtocol.responses.count("GET"), 0)
        do {
            _ = try await service(cacheDirectory: folder).thumbnail(existing(version: "2"), pixels: 500)
            XCTFail("A changed version must fetch new bytes")
        } catch {}
        XCTAssertEqual(UploadProtocol.responses.count("GET"), 1)

        UploadProtocol.responses.reset([:])
        do {
            _ = try await service(cacheDirectory: folder, token: "different-account").thumbnail(existing(), pixels: 500)
            XCTFail("A different connection must not reuse the previous connection's images")
        } catch {}
        XCTAssertEqual(UploadProtocol.responses.count("GET"), 1)

        let namespace = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let cachedFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: namespace, includingPropertiesForKeys: nil).first)
        try Data("damaged cache".utf8).write(to: cachedFile)
        UploadProtocol.responses.reset(["/image/old/photo.png": (200, png)])
        _ = try await service(cacheDirectory: folder).thumbnail(existing(), pixels: 500)
        XCTAssertEqual(UploadProtocol.responses.count("GET"), 1)
        XCTAssertEqual(try Data(contentsOf: cachedFile), png)
    }

    func testDiskCacheEvictsTheLeastRecentlyUsedImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = PhotoDiskCache(directory: folder, maximumBytes: 8)
        let urls = (0..<3).map { URL(string: "https://photos.example/\($0)?v=1")! }
        let data = Data("test".utf8)
        cache.write(data, for: urls[0])
        cache.write(data, for: urls[1])
        for (index, url) in urls.prefix(2).enumerated() {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: cache.file(for: url).path)
        }
        XCTAssertEqual(cache.read(urls[0]), data)
        cache.write(data, for: urls[2])
        XCTAssertNil(cache.read(urls[1]))
        XCTAssertEqual(cache.read(urls[0]), data)
        XCTAssertEqual(cache.read(urls[2]), data)
    }
    private func file(_ body: String, name: String = "renamed.png") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try Data(body.utf8).write(to: file)
        return file
    }
    private func existing(size: Int? = 4, version: String = "1") -> Photo {
        Photo(key: "old/photo.png", url: URL(string: "https://photos.example/image/old/photo.png?v=\(version)")!, size: size)
    }

    func testExistingRenamedImageIsSkippedAfterManifestLookup() async throws {
        let photo = existing()
        let manifest = try JSONSerialization.data(withJSONObject: ["images": [["key": photo.key,
            "url": photo.url.absoluteString, "size": 4]], "cursor": NSNull()])
        UploadProtocol.responses.reset(["/manifest": (200, manifest), "/image/old/photo.png": (200, Data("same".utf8))])
        let result = try await service().upload(file("same"))
        XCTAssertFalse(result.added)
        XCTAssertEqual(result.photo.key, photo.key)
        XCTAssertEqual(UploadProtocol.responses.count("PUT"), 0)
    }

    func testSameSizeDifferentBytesAreAddedAndRepeatedDropIsSkipped() async throws {
        UploadProtocol.responses.reset(["/image/old/photo.png": (200, Data("old!".utf8))])
        let api = try service()
        let first = try await api.upload(file("new!", name: "photo.png"), existingPhotos: [existing()])
        XCTAssertTrue(first.added)
        let second = try await api.upload(file("new!"), existingPhotos: [existing(), first.photo])
        XCTAssertFalse(second.added)
        XCTAssertEqual(second.photo.key, first.photo.key)
        XCTAssertEqual(UploadProtocol.responses.count("PUT"), 1)
        XCTAssertEqual(UploadProtocol.responses.count("GET /image/old/photo.png"), 1)
    }

    func testDifferentSizeDoesNotDownloadExistingImage() async throws {
        UploadProtocol.responses.reset([:])
        let result = try await service().upload(file("larger"), existingPhotos: [existing()])
        XCTAssertTrue(result.added)
        XCTAssertEqual(UploadProtocol.responses.count("GET"), 0)
        XCTAssertEqual(UploadProtocol.responses.count("PUT"), 1)
    }

    func testMissingSizeStillChecksHashAndReadFailureDoesNotUpload() async throws {
        UploadProtocol.responses.reset(["/image/old/photo.png": (200, Data("same".utf8))])
        let result = try await service().upload(file("same"), existingPhotos: [existing(size: nil)])
        XCTAssertFalse(result.added)
        UploadProtocol.responses.reset(["/image/old/photo.png": (503, Data())])
        do {
            _ = try await service().upload(file("same"), existingPhotos: [existing()])
            XCTFail("A failed comparison must not upload a possible duplicate")
        } catch {}
        XCTAssertEqual(UploadProtocol.responses.count("PUT"), 0)
    }

    func testChangedImageVersionDoesNotUseOldHash() async throws {
        let api = try service()
        UploadProtocol.responses.reset(["/image/old/photo.png": (200, Data("same".utf8))])
        let first = try await api.upload(file("same"), existingPhotos: [existing()])
        XCTAssertFalse(first.added)
        UploadProtocol.responses.reset(["/image/old/photo.png": (200, Data("else".utf8))])
        let changed = try await api.upload(file("same"), existingPhotos: [existing(version: "2")])
        XCTAssertTrue(changed.added)
        XCTAssertEqual(UploadProtocol.responses.count("GET"), 1)
        XCTAssertEqual(UploadProtocol.responses.count("PUT"), 1)
    }
}
