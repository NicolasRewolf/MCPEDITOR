import Foundation
import XCTest
import MPCCore
@testable import KitStudio

/// The PART view: empty PARTs share one summary, the others show their free space.
final class PartOverviewTests: XCTestCase {
    private func part(_ letter: String, files: Int = 0, issues: [String] = [], available: Int64) -> LibraryPartition {
        LibraryPartition(url: URL(fileURLWithPath: "/Volumes/MPC-PART--\(letter)"), letter: letter, kits: [],
                         fileCount: files, folderCount: 0, audioCount: files, sequenceCount: 0, issues: issues,
                         availableBytes: available,
                         volumeSpace: ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: available))
    }

    @MainActor
    func testEmptyPartsAreSummarizedAndCapacityIsMeasuredOrRemembered() throws {
        let suite = "PartOverviewTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString)
        let model = StudioModel(defaults: defaults, localLibraryURL: library, volumeProvider: { [] })
        XCTAssertNil(model.emptyPartCapacityBytes)

        model.partitions = [
            part("A", files: 3, available: 1_984 * 1024),
            part("E", available: 7_952 * 1024),
            part("G", available: 7_900 * 1024),
            part("U", issues: ["PART U non proposée comme destination : .Trashes"], available: 7_912 * 1024)
        ]

        XCTAssertEqual(model.partsWithContent.map(\.letter), ["A", "U"], "A PART to check is never summarized as empty")
        XCTAssertEqual(model.emptyParts.map(\.letter), ["E", "G"])
        XCTAssertEqual(model.emptyPartCapacityBytes, 7_952 * 1024)

        model.rememberEmptyPartCapacity(model.partitions)
        model.partitions = []
        XCTAssertEqual(model.emptyPartCapacityBytes, 7_952 * 1024, "Remembered when the card is out")
    }
}
