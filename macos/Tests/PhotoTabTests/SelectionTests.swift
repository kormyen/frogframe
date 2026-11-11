import XCTest
@testable import PhotoTab

@MainActor
final class SelectionTests: XCTestCase {
    private func library() -> LibraryModel {
        let library = LibraryModel(loadSavedConfiguration: false)
        library.photos = (0..<5).map {
            Photo(key: "\($0).png", url: URL(string: "https://photos.example/image/\($0).png")!, size: nil)
        }
        return library
    }

    func testShiftSelectionKeepsAnchorAndWorksInBothDirections() {
        let library = library()
        library.select(library.photos[2], extending: false)
        library.select(library.photos[4], extending: false, range: true)
        XCTAssertEqual(library.selection, ["2.png", "3.png", "4.png"])
        library.select(library.photos[0], extending: false, range: true)
        XCTAssertEqual(library.selection, ["0.png", "1.png", "2.png"])
    }

    func testCommandTogglesAndCommandShiftAddsRange() {
        let library = library()
        library.select(library.photos[0], extending: false)
        library.select(library.photos[2], extending: true)
        library.select(library.photos[4], extending: true, range: true)
        XCTAssertEqual(library.selection, ["0.png", "2.png", "3.png", "4.png"])
        library.select(library.photos[2], extending: true)
        XCTAssertEqual(library.selection, ["0.png", "3.png", "4.png"])
    }

    func testShiftWithoutAnchorSelectsOneImage() {
        let library = library()
        library.select(library.photos[3], extending: false, range: true)
        XCTAssertEqual(library.selection, ["3.png"])
    }

    func testDeselectClearsTheRangeAnchor() {
        let library = library()
        library.select(library.photos[0], extending: false)
        library.select(library.photos[2], extending: true)
        library.deselectAll()
        XCTAssertTrue(library.selection.isEmpty)
        library.select(library.photos[4], extending: false, range: true)
        XCTAssertEqual(library.selection, ["4.png"])
    }
}
