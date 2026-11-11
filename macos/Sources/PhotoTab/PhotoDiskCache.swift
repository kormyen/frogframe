import Foundation
import CryptoKit

struct PhotoDiskCache: Sendable {
    let directory: URL
    var maximumBytes = 512 * 1024 * 1024

    func file(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash)
    }

    func read(_ url: URL) -> Data? {
        let path = file(for: url)
        guard let data = try? Data(contentsOf: path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return data
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: file(for: url))
    }

    func write(_ data: Data, for url: URL) {
        guard data.count <= maximumBytes else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let path = file(for: url)
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            trim()
        } catch {
            // A full or unavailable cache must not prevent images from loading.
        }
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { file -> (url: URL, size: Int, date: Date)? in
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.date < $1.date }
        var size = entries.reduce(0) { $0 + $1.size }
        for entry in entries where size > maximumBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { size -= entry.size }
        }
    }
}
