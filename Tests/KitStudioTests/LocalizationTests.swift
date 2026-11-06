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
        XCTAssertEqual(LibraryFormat.assignedPads(0), "0 pad affecté")
        XCTAssertEqual(LibraryFormat.assignedPads(36), "36 pads affectés")
        XCTAssertEqual(LibraryFormat.programs(25), "25 .PGM")
    }

    /// Durations and peaks once used String(format:), a dot even next to "Sélection : 1,099 s".
    func testDecimalsFollowTheRegion() {
        XCTAssertEqual(LibraryFormat.decimal(1.1, digits: 3, locale: Locale(identifier: "fr_FR")), "1,100")
        XCTAssertEqual(LibraryFormat.decimal(1.1, digits: 3, locale: Locale(identifier: "en_US")), "1.100")
        XCTAssertEqual(LibraryFormat.decimal(1.0049, digits: 2, locale: Locale(identifier: "en_US")), "1.00")
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
