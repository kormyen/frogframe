import XCTest
@testable import PhotoTab

@MainActor
final class SyncFolderAccessTests: XCTestCase {
    private func withPreferences(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "Frogframe.SyncFolderAccessTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try body(preferences, folder.resolvingSymlinksInPath())
    }

    func testRepairsUnreadableBookmarkFromSavedPath() throws {
        try withPreferences { preferences, folder in
            let broken = Data("unusable bookmark from an earlier app".utf8)
            preferences.set(broken, forKey: "SyncFolderBookmark")
            preferences.set(folder.path, forKey: "SyncFolderPath")
            XCTAssertEqual(try SyncFolderAccess.savedURL(preferences: preferences)?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
            let repaired = try XCTUnwrap(preferences.data(forKey: "SyncFolderBookmark"))
            XCTAssertNotEqual(repaired, broken)
            var stale = false
            XCTAssertEqual(try URL(resolvingBookmarkData: repaired, options: [.withSecurityScope, .withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale).resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
            XCTAssertEqual(try SyncFolderAccess.savedURL(preferences: preferences)?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
            XCTAssertEqual(preferences.data(forKey: "SyncFolderBookmark"), repaired)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
    }

    func testMissingFolderGivesSpecificErrorAndPreservesReference() throws {
        try withPreferences { preferences, folder in
            let missing = folder.appendingPathComponent("missing")
            let broken = Data("unusable bookmark".utf8)
            preferences.set(broken, forKey: "SyncFolderBookmark")
            preferences.set(missing.path, forKey: "SyncFolderPath")
            XCTAssertThrowsError(try SyncFolderAccess.savedURL(preferences: preferences)) { error in
                XCTAssertTrue(error.localizedDescription.contains(missing.path))
                XCTAssertTrue(error.localizedDescription.contains("Sync Folder"))
                XCTAssertFalse(error.localizedDescription.contains("correct format"))
            }
            XCTAssertEqual(preferences.data(forKey: "SyncFolderBookmark"), broken)
            XCTAssertEqual(preferences.string(forKey: "SyncFolderPath"), missing.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    func testLegacyPathGetsBookmark() throws {
        try withPreferences { preferences, folder in
            preferences.set(folder.path, forKey: "SyncFolderPath")
            XCTAssertEqual(try SyncFolderAccess.savedURL(preferences: preferences)?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
            XCTAssertNotNil(preferences.data(forKey: "SyncFolderBookmark"))
        }
    }

    func testNoSavedFolderDoesNotEnableSync() throws {
        try withPreferences { preferences, _ in
            XCTAssertNil(try SyncFolderAccess.savedURL(preferences: preferences))
        }
    }

    func testUnreadableBookmarkWithoutPathGivesSpecificError() throws {
        try withPreferences { preferences, _ in
            preferences.set(Data("unusable bookmark".utf8), forKey: "SyncFolderBookmark")
            XCTAssertThrowsError(try SyncFolderAccess.savedURL(preferences: preferences)) { error in
                XCTAssertTrue(error.localizedDescription.contains("saved sync folder"))
                XCTAssertTrue(error.localizedDescription.contains("Sync Folder"))
            }
        }
    }

    func testRecoveryRejectsFileInsteadOfFolder() throws {
        try withPreferences { preferences, folder in
            let file = folder.appendingPathComponent("photo.png")
            let bytes = Data("unchanged".utf8)
            try bytes.write(to: file)
            preferences.set(file.path, forKey: "SyncFolderPath")
            XCTAssertThrowsError(try SyncFolderAccess.savedURL(preferences: preferences)) { error in
                XCTAssertTrue(error.localizedDescription.contains(file.path))
            }
            XCTAssertNil(preferences.data(forKey: "SyncFolderBookmark"))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
}
