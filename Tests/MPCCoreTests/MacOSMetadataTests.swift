import Foundation
import XCTest
@testable import MPCCore

final class MacOSMetadataTests: XCTestCase {
    private func part() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSMetadataTests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("MPC-PART--S", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testAppleDoubleFilesAndSystemFoldersAreCountedInClusters() throws {
        let root = try part()
        try Data(count: 4096).write(to: root.appendingPathComponent("._A01KICK.SND"))
        try Data(count: 900).write(to: root.appendingPathComponent("A01KICK.SND"))
        let sub = root.appendingPathComponent("NEWPROG", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data(count: 9000).write(to: sub.appendingPathComponent("._CLAP.SND"))
        for folder in [".fseventsd", ".Trashes"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        try Data(count: 10).write(to: root.appendingPathComponent(".Trashes/._HIDDEN"))

        let metadata = try XCTUnwrap(MacOSMetadata.inspect(root, allocationUnit: 8192))

        XCTAssertEqual(metadata.appleDoubleCount, 2, "Files inside system folders are not counted")
        XCTAssertEqual(metadata.appleDoubleBytes, 8192 + 16384)
        XCTAssertEqual(metadata.systemFolders, [".Trashes", ".fseventsd"])
        XCTAssertTrue(metadata.isComplete)
        XCTAssertFalse(metadata.isEmpty)
    }

    func testPartitionScanCarriesTheMetadataReport() throws {
        let root = try part()
        try Data(count: 4096).write(to: root.appendingPathComponent("._KIT.PGM"))
        let scanned = LibraryIndex.scanPartition(root, fatVolumeProbe: { _ in nil })
        XCTAssertEqual(scanned.macOSMetadata?.appleDoubleCount, 1)
        XCTAssertNil(MacOSMetadata.inspect(root.appendingPathComponent("absent"), allocationUnit: 8192))
    }
}
