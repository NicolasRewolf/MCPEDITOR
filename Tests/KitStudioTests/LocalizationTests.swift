import XCTest
@testable import KitStudio

/// French is the source language: its texts must read right without the catalog,
/// which only the packaged app loads.
final class LocalizationTests: XCTestCase {
    func testFrenchCountsAreSingularForZeroAndOne() {
        XCTAssertEqual(LibraryFormat.samples(0), "0 sample")
        XCTAssertEqual(LibraryFormat.samples(1), "1 sample")
        XCTAssertEqual(LibraryFormat.samples(2), "2 samples")
        XCTAssertEqual(LibraryFormat.results(1), "1 résultat")
        XCTAssertEqual(LibraryFormat.results(40), "40 résultats")
        XCTAssertEqual(LibraryFormat.importedSamples(1), "1 sample importé.")
        XCTAssertEqual(LibraryFormat.importedSamples(3), "3 samples importés.")
        XCTAssertEqual(LibraryFormat.emptyParts(1), "+ 1 PART vide")
        XCTAssertEqual(LibraryFormat.emptyParts(11), "+ 11 PART vides")
        XCTAssertEqual(LibraryFormat.programs(25), "25 .PGM")
    }

    @MainActor
    func testUndoMenuItemReadsAnnulerInFrench() throws {
        let suite = "LocalizationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString)
        let model = StudioModel(defaults: defaults, localLibraryURL: library, volumeProvider: { [] })
        XCTAssertEqual(model.undoTitle, "Annuler", "Its own key in the catalog, French by default")
    }
}
