import Foundation
import XCTest
import MPCCore
@testable import KitStudio

/// Remembered folders across remounts, and the .PGM list grouped by location.
final class FolderMemoryAndGroupingTests: XCTestCase {
    private func container() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderMemoryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func defaults() throws -> UserDefaults {
        let name = "FolderMemoryTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    func testRemountedVolumeNameIsRepairedOnlyWhenUnambiguous() throws {
        let volumes = try container()
        let current = try makeDirectory(volumes.appendingPathComponent("T9/User Library/Samples/Soul"))
        let stale = volumes.appendingPathComponent("T9 1/User Library/Samples/Soul")
        let store = try defaults()

        XCTAssertEqual(FolderMemory.resolve([stale], defaults: store, volumes: volumes), [current])

        _ = try makeDirectory(volumes.appendingPathComponent("T9 2/User Library/Samples/Soul"))
        XCTAssertEqual(FolderMemory.resolve([stale], defaults: store, volumes: volumes), [stale],
                       "Two candidate volumes keep the stored path")

        let missing = volumes.appendingPathComponent("Other/Folder")
        XCTAssertEqual(FolderMemory.resolve([missing], defaults: store, volumes: volumes), [missing])
        XCTAssertEqual(FolderMemory.baseVolumeName("T9 1"), "T9")
        XCTAssertEqual(FolderMemory.baseVolumeName("Samples 2024"), "Samples 2024")
        XCTAssertEqual(FolderMemory.baseVolumeName("T9"), "T9")
    }

    func testBookmarkFollowsAVolumeNameButNeverAMovedFolder() throws {
        let volumes = try container()
        let original = try makeDirectory(volumes.appendingPathComponent("T9/Banks"))
        let store = try defaults()
        FolderMemory.remember([original], defaults: store)

        let moved = volumes.appendingPathComponent("T9/Banks renamed")
        try FileManager.default.moveItem(at: original, to: moved)
        XCTAssertEqual(FolderMemory.resolve([original], defaults: store, volumes: volumes), [original],
                       "A moved folder stays unavailable")

        let remount = URL(fileURLWithPath: "/Volumes/T9 1/Banks")
        let rename = URL(fileURLWithPath: "/Volumes/T9/Banks renamed")
        let stored = URL(fileURLWithPath: "/Volumes/T9/Banks")
        let system = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        XCTAssertTrue(FolderMemory.isSameFolderOnRemountedVolume(stored, remount, volumes: system))
        XCTAssertFalse(FolderMemory.isSameFolderOnRemountedVolume(stored, rename, volumes: system))
        XCTAssertFalse(FolderMemory.isSameFolderOnRemountedVolume(URL(fileURLWithPath: "/Users/me/Banks"),
                                                                  URL(fileURLWithPath: "/Users/me/Moved"), volumes: system))
    }

    @MainActor
    func testProgramsAreGroupedByMacLibraryPartsThenFolders() throws {
        let store = try defaults()
        let library = try container().appendingPathComponent("Library", isDirectory: true)
        let model = StudioModel(defaults: store, localLibraryURL: library, volumeProvider: { [] })
        let folder = URL(fileURLWithPath: "/tmp/Banks", isDirectory: true)
        func kit(_ name: String, root: URL, part: String?, folder sub: String = "") -> LibraryKit {
            LibraryKit(url: root.appendingPathComponent(sub).appendingPathComponent(name + ".PGM"),
                       rootURL: root, partitionLetter: part, relativeFolder: sub)
        }
        let partB = URL(fileURLWithPath: "/Volumes/MPC-PART--B")
        let partA = URL(fileURLWithPath: "/Volumes/MPC-PART--A")
        model.libraryKits = [
            kit("ZED", root: folder, part: nil, folder: "Old"),
            kit("PROGRAM_", root: partB, part: "B"),
            kit("PROGRAM_", root: partA, part: "A"),
            kit("SOULS", root: library, part: nil),
            kit("KIT", root: partA, part: "A")
        ]

        let groups = model.groupedFilteredKits
        XCTAssertEqual(groups.map(\.title), ["Bibliothèque sur le Mac", "PART A", "PART B", "Banks"])
        XCTAssertEqual(groups[1].kits.map(\.title), ["PROGRAM_", "KIT"], "Order inside a group is kept")
        XCTAssertEqual(model.kitRowSubtitle(for: groups[3].kits[0]), "Old · ZED.PGM")
    }
}
