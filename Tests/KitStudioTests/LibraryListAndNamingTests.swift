import Foundation
import XCTest
import MPCCore
@testable import KitStudio

/// Library list management, SD trash refusal and DOS name previews.
final class LibraryListAndNamingTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryListAndNamingTests-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder
    }

    @MainActor
    private func model(kitFolders: [URL] = [], sampleRoots: [URL] = [],
                       trash: @escaping KitTrash.Operation = { _ in XCTFail("No trash expected"); return nil })
        throws -> (StudioModel, UserDefaults) {
        let suiteName = "LibraryListAndNamingTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(kitFolders.map(\.path), forKey: "library.kitFolders")
        defaults.set(sampleRoots.map(\.path), forKey: "library.sampleRoots")
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString)
        return (StudioModel(defaults: defaults, localLibraryURL: library, trashOperation: trash,
                            volumeProvider: { [] }), defaults)
    }

    private func program(named name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".PGM")
        try MPCProgram.blank(name: name).bytes.write(to: url)
        return url
    }

    @MainActor
    func testProgramOnSDPartIsNeverTrashedAndExplainsWhy() throws {
        let part = try directory("MPC-PART--A")
        let url = try program(named: "KIT", in: part)
        let (model, _) = try model()
        let kit = LibraryKit(url: url, rootURL: part, partitionLetter: "A", relativeFolder: "")

        XCTAssertNil(model.requestTrashKit(kit))
        XCTAssertTrue(model.errorMessage?.contains(".Trashes") == true)
        XCTAssertTrue(model.errorMessage?.contains("PART A") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let local = LibraryKit(url: url, rootURL: part, partitionLetter: nil, relativeFolder: "")
        XCTAssertNil(model.trashRefusal(for: local))
    }

    @MainActor
    func testRemovingAKitFolderForgetsItWithoutTouchingFiles() async throws {
        let kept = try directory("Kept")
        let removed = try directory("Removed")
        let keptProgram = try program(named: "KEPT", in: kept)
        let removedProgram = try program(named: "GONE", in: removed)
        let (model, defaults) = try model(kitFolders: [kept, removed])
        await model.refreshLocations().value
        XCTAssertEqual(Set(model.libraryKits.map(\.title)), ["KEPT", "GONE"])
        model.filterPrograms(to: removed)

        model.removeKitFolder(removed)
        await model.refreshLocations().value

        XCTAssertEqual(defaults.stringArray(forKey: "library.kitFolders"), [kept.path])
        XCTAssertEqual(model.addedKitFolders.map(\.path), [kept.path])
        XCTAssertNil(model.selectedLocation)
        XCTAssertEqual(model.libraryKits.map(\.title), ["KEPT"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: removedProgram.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptProgram.path))
    }

    @MainActor
    func testRemovingTheBrowsedSampleSourceReturnsToTheLibraryView() async throws {
        let root = try directory("Samples")
        let sample = root.appendingPathComponent("KICK.SND")
        try MPCSound(name: "KICK", channels: [Array(repeating: 0.25, count: 441)]).encoded().write(to: sample)
        let (model, defaults) = try model(sampleRoots: [root])
        model.selectSampleRoot(root)
        XCTAssertEqual(model.sampleScope, .folder)

        model.removeSampleRoot(root)

        XCTAssertTrue(model.sampleRoots.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "library.sampleRoots"), [])
        XCTAssertEqual(model.sampleScope, .library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))
    }

    @MainActor
    func testNamePreviewsShowTheDOSNamesUsedBySaveAndCopy() throws {
        let (model, _) = try model()
        model.newKit()
        XCTAssertNil(model.programFileNamePreview)
        model.setKitName("My deep kit")
        XCTAssertEqual(model.programFileNamePreview, "MY_DEEP_.PGM")
        XCTAssertEqual(KitExport.dosStem("KICK_DEEP_808", fallback: "SOUND"), "KICK_DEE")
        XCTAssertEqual(KitExport.dosStem("Caisse claire é", fallback: "SOUND"), "CAISSE_C")
        XCTAssertEqual(KitExport.dosStem("…", fallback: "SOUND"), "SOUND")
    }
}
