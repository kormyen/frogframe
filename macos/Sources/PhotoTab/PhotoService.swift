import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct BucketConfiguration: Codable, Sendable {
    var endpoint: String
    var token: String

    func validatedURL() throws -> URL {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", !token.isEmpty else {
            throw BucketError.message("Enter an HTTPS server address and a management token.")
        }
        return url
    }
}

enum BucketError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

struct Photo: Codable, Hashable, Identifiable, Sendable {
    let key: String
    let url: URL
    let size: Int?
    var id: String { key }
    var name: String { key.split(separator: "/").last.map(String.init) ?? key }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor PhotoService {
    struct UploadResult: Sendable {
        let photo: Photo
        let added: Bool
        let contentHash: String?
        init(photo: Photo, added: Bool, contentHash: String? = nil) {
            self.photo = photo; self.added = added; self.contentHash = contentHash
        }
    }
    let configuration: BucketConfiguration
    private let session: URLSession
    private let base: URL
    private let images = NSCache<NSString, CGImage>()
    private let diskCache: PhotoDiskCache
    private var contentHashes: [URL: SHA256.Digest] = [:]

    init(configuration: BucketConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         cacheDirectory: URL? = nil) throws {
        self.configuration = configuration
        base = try configuration.validatedURL()
        let cacheRoot = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "nz.kor.frogframe.manager/images")
        let namespace = SHA256.hash(data: Data("\(base.absoluteString)\n\(configuration.token)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        diskCache = PhotoDiskCache(directory: cacheRoot.appendingPathComponent(namespace))
        let settings = sessionConfiguration
        settings.timeoutIntervalForRequest = 45
        settings.timeoutIntervalForResource = 180
        session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        images.totalCostLimit = 64 * 1024 * 1024
    }

    func imageURL(key: String) -> URL {
        key.split(separator: "/", omittingEmptySubsequences: false).reduce(base.appending(path: "image")) {
            $0.appendingPathComponent(String($1))
        }
    }

    private func request(_ url: URL, method: String = "GET") throws -> URLRequest {
        guard url.scheme == base.scheme, url.host == base.host, url.port == base.port else {
            throw BucketError.message("The server returned an image address outside this photo server.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw BucketError.message("No server response.") }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw BucketError.message("Access denied. Check the management token in Settings.")
        case 413: throw BucketError.message("The image is larger than 40 MiB.")
        default: throw BucketError.message("The photo server returned error \(http.statusCode).")
        }
    }

    func list() async throws -> [Photo] {
        struct Page: Decodable { let images: [Photo]; let cursor: String? }
        var cursor: String?
        var seen = Set<String>()
        var result = [Photo]()
        repeat {
            var parts = URLComponents(url: base.appending(path: "manifest"), resolvingAgainstBaseURL: false)!
            if let cursor { parts.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            let (data, response) = try await session.data(for: request(parts.url!))
            try check(response)
            let page = try JSONDecoder().decode(Page.self, from: data)
            result.append(contentsOf: page.images)
            cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 100 {
                throw BucketError.message("The server returned an invalid image list.")
            }
        } while cursor != nil
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func observeChanges(onChange: @escaping @Sendable () async -> Void) async throws {
        var req = try request(base.appending(path: "updates"))
        var address = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        address.scheme = "wss"
        req.url = address.url!
        let socket = session.webSocketTask(with: req)
        socket.resume()
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                socket.sendPing { error in
                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
        defer { heartbeat.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                // Grouped uploads need one refresh after completion, rather
                // than a full bucket fetch for every image in the group.
                if type == "connected" || type == "upload-finished" ||
                    (type == "changed" && event["uploadGroup"] == nil) {
                    await onChange()
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func thumbnail(_ photo: Photo, pixels: Int) async throws -> CGImage {
        let cacheKey = "\(photo.url.absoluteString)-\(pixels)" as NSString
        if let image = images.object(forKey: cacheKey) { return image }
        // The server's version changes when the image changes. Unversioned
        // addresses are not safe to reuse across launches.
        let versioned = URLComponents(url: photo.url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "v" && !($0.value ?? "").isEmpty } == true
        _ = try request(photo.url)
        if versioned, let data = diskCache.read(photo.url) {
            if let image = decodeThumbnail(data, pixels: pixels) {
                images.setObject(image, forKey: cacheKey, cost: image.width * image.height * 4)
                return image
            }
            diskCache.remove(photo.url)
        }
        let (data, response) = try await session.data(for: request(photo.url))
        try check(response)
        guard let image = decodeThumbnail(data, pixels: pixels) else {
            throw BucketError.message("Cannot display this image.")
        }
        if versioned { diskCache.write(data, for: photo.url) }
        images.setObject(image, forKey: cacheKey, cost: image.width * image.height * 4)
        return image
    }

    func download(_ photo: Photo) async throws -> Data {
        _ = try request(photo.url)
        if let data = diskCache.read(photo.url), data.count <= 40 * 1024 * 1024 { return data }
        let (data, response) = try await session.data(for: request(photo.url))
        try check(response)
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024 else {
            throw BucketError.message("The server image is empty or larger than 40 MiB.")
        }
        diskCache.write(data, for: photo.url)
        return data
    }

    private func decodeThumbnail(_ data: Data, pixels: Int) -> CGImage? {
        guard data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            return nil
        }
        return image
    }

    func startUploadGroup(_ id: UUID) async throws -> Bool {
        let url = base.appending(path: "upload-groups/\(id.uuidString.lowercased())/start")
        let (_, response) = try await session.data(for: request(url, method: "POST"))
        // Keep uploads available while an older server is being updated.
        if let http = response as? HTTPURLResponse, [404, 405].contains(http.statusCode) { return false }
        try check(response)
        return true
    }

    func finishUploadGroup(_ id: UUID, added: Int) async throws {
        let url = base.appending(path: "upload-groups/\(id.uuidString.lowercased())/finish")
        var req = try request(url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["added": added])
        let (_, response) = try await session.data(for: req)
        try check(response)
    }

    func upload(_ file: URL, existingPhotos: [Photo]? = nil, uploadGroup: UUID? = nil) async throws -> UploadResult {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard file.isFileURL, values.isRegularFile == true,
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"].contains(file.pathExtension.lowercased()) else {
            throw BucketError.message("\(file.lastPathComponent) is not a supported image file.")
        }
        guard let size = values.fileSize, size > 0, size <= 40 * 1024 * 1024 else {
            throw BucketError.message("\(file.lastPathComponent) must be between 1 byte and 40 MiB.")
        }
        // Hash and send the same bytes, even if the source file changes later.
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024 else {
            throw BucketError.message("\(file.lastPathComponent) must be between 1 byte and 40 MiB.")
        }
        let digest = SHA256.hash(data: data)
        let contentHash = digest.map { String(format: "%02x", $0) }.joined()
        let photos: [Photo]
        if let existingPhotos { photos = existingPhotos }
        else { photos = try await list() }
        for photo in photos where photo.size == nil || photo.size == data.count {
            let existingDigest: SHA256.Digest
            if let cached = contentHashes[photo.url] { existingDigest = cached }
            else {
                let (existingData, response) = try await session.data(for: request(photo.url))
                try check(response)
                existingDigest = SHA256.hash(data: existingData)
                contentHashes[photo.url] = existingDigest
            }
            if digest == existingDigest { return UploadResult(photo: photo, added: false, contentHash: contentHash) }
        }
        // A unique folder prevents two files with the same name from replacing each other.
        let key = UUID().uuidString.lowercased() + "/" + file.lastPathComponent
        var req = try request(imageURL(key: key), method: "PUT")
        req.setValue(type.preferredMIMEType ?? "image/\(file.pathExtension)", forHTTPHeaderField: "Content-Type")
        if let uploadGroup { req.setValue(uploadGroup.uuidString.lowercased(), forHTTPHeaderField: "X-PhotoTab-Upload-Group") }
        let (_, response) = try await session.upload(for: req, from: data)
        try check(response)
        let photo = Photo(key: key, url: imageURL(key: key), size: data.count)
        contentHashes[photo.url] = digest
        return UploadResult(photo: photo, added: true, contentHash: contentHash)
    }

    func delete(key: String) async throws {
        let (_, response) = try await session.data(for: request(imageURL(key: key), method: "DELETE"))
        try check(response)
    }
}
