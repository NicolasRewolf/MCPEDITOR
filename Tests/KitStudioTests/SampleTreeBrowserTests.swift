import Foundation
import XCTest
import MPCCore
@testable import KitStudio

/// The SSD browsed like a DAW browser: places, folders opened in place, a search
/// across the whole source, samples dragged from any depth.
final class SampleTreeBrowserTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleTreeBrowserTests-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder.standardizedFileURL
    }

    private func folder(_ name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    private func sound(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".SND")
        try MPCSound(name: String(name.prefix(16)), channels: [Array(repeating: 0.25, count: 441)]).encoded().write(to: url)
        return url.standardizedFileURL
    }

    @MainActor
    private func model() throws -> StudioModel {
        let suite = "SampleTreeBrowserTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString)
        return StudioModel(defaults: defaults, localLibraryURL: library, volumeProvider: { [] })
    }

    /// Soul/ ── SONG003/ ── LOOPS/ ── DRUMS 22.SND
    ///                   └─ ONE SHOTS/ ── KICK.SND
    ///       └─ TOP.SND
    private struct Tree {
        let root: URL
        let song: URL
        let loops: URL
        let oneShots: URL
        let drums: URL
        let kick: URL
        let top: URL
    }

    private func tree() throws -> Tree {
        let root = try directory("Soul")
        let song = try folder("SONG003 - Sloppy Drums", in: root)
        let loops = try folder("LOOPS", in: song)
        let oneShots = try folder("ONE SHOTS", in: song)
        return Tree(root: root, song: song, loops: loops, oneShots: oneShots,
                    drums: try sound("DRUMS 22", in: loops), kick: try sound("KICK", in: oneShots),
                    top: try sound("TOP", in: root))
    }

    @MainActor
    private func open(_ tree: Tree, in model: StudioModel) async {
        model.sampleRoots = [tree.root]
        await model.selectSampleRoot(tree.root)?.value
    }

    @MainActor
    func testASourceBeingReadIsNotCalledEmpty() async throws {
        let tree = try tree()
        let model = try model()
        model.sampleRoots = [tree.root]
        let pending = model.selectSampleRoot(tree.root)
        XCTAssertTrue(model.sampleFolderReading)
        XCTAssertTrue(model.sampleTreeRows.isEmpty)
        await pending?.value
        XCTAssertFalse(model.sampleFolderReading)
        XCTAssertNil(model.sampleBrowserIssue, "The SD inventory does not speak for an SSD folder")

        model.selectSampleRoot(tree.root)
        model.showAllLibrarySamples()
        XCTAssertFalse(model.sampleFolderReading, "Leaving a source stops waiting for it")
    }

    @MainActor
    func testFoldersOpenInPlaceOneLevelAtATime() async throws {
        let tree = try tree()
        let model = try model()
        await open(tree, in: model)

        XCTAssertEqual(model.sampleTreeRows.map(\.name), ["SONG003 - Sloppy Drums", "TOP.SND"])
        XCTAssertEqual(model.filteredSamples, [tree.top])

        await model.toggleSampleFolder(tree.song)?.value
        XCTAssertEqual(model.sampleTreeRows.map(\.name), ["SONG003 - Sloppy Drums", "LOOPS", "ONE SHOTS", "TOP.SND"])
        XCTAssertEqual(model.sampleTreeRows.map(\.depth), [0, 1, 1, 0])
        XCTAssertNil(model.sampleTreeListings[tree.loops], "A folder is read only when it is opened")

        await model.toggleSampleFolder(tree.loops)?.value
        let drumsRow = try XCTUnwrap(model.sampleTreeRows.first { $0.url == tree.drums })
        XCTAssertEqual(drumsRow.depth, 2)
        XCTAssertEqual(drumsRow.kind, .sample)
        XCTAssertEqual(model.filteredSamples, [tree.drums, tree.top], "Arrow keys walk the samples in view")

        XCTAssertNil(model.toggleSampleFolder(tree.song))
        XCTAssertEqual(model.sampleTreeRows.map(\.name), ["SONG003 - Sloppy Drums", "TOP.SND"])
        await model.toggleSampleFolder(tree.song)?.value
        XCTAssertTrue(model.sampleTreeRows.contains { $0.url == tree.drums }, "Reopening a folder keeps what was open inside")
    }

    @MainActor
    func testOnlyFoldersShownInsideTheSourceCanOpen() async throws {
        let tree = try tree()
        let elsewhere = try directory("Elsewhere")
        _ = try sound("OUTSIDE", in: elsewhere)
        let model = try model()
        await open(tree, in: model)

        XCTAssertNil(model.toggleSampleFolder(elsewhere))
        XCTAssertNil(model.toggleSampleFolder(tree.loops), "A folder inside a closed one is not in view yet")
        XCTAssertTrue(model.expandedSampleFolders.isEmpty)
        XCTAssertFalse(model.filteredSamples.contains { $0.lastPathComponent == "OUTSIDE.SND" })
    }

    @MainActor
    func testRefreshReadsOpenFoldersAgainAndDropsVanishedSelection() async throws {
        let tree = try tree()
        let model = try model()
        await open(tree, in: model)
        await model.toggleSampleFolder(tree.song)?.value
        await model.toggleSampleFolder(tree.oneShots)?.value
        model.selectSample(tree.kick)

        let snare = try sound("SNARE", in: tree.oneShots)
        await model.refreshLocations().value

        XCTAssertEqual(model.selectedSampleURL, tree.kick)
        XCTAssertTrue(model.sampleTreeRows.contains { $0.url == snare }, "An open folder shows a new file after refresh")

        try FileManager.default.removeItem(at: tree.kick)
        await model.refreshLocations().value
        XCTAssertNil(model.selectedSampleURL)
        XCTAssertFalse(model.sampleTreeRows.contains { $0.url == tree.kick })
    }

    @MainActor
    func testEmptyAndUnreadableFoldersSayWhyInPlace() async throws {
        let tree = try tree()
        let empty = try folder("EMPTY", in: tree.root)
        let model = try model()
        await open(tree, in: model)

        await model.toggleSampleFolder(empty)?.value
        let notice = try XCTUnwrap(model.sampleTreeRows.first { $0.isNotice })
        XCTAssertEqual(notice.kind, .notice("Aucun sample ici"))
        XCTAssertEqual(notice.depth, 1)
    }

    @MainActor
    func testSearchFindsEveryWordAcrossClosedFoldersAndNamesTheirFolder() async throws {
        let tree = try tree()
        let model = try model()
        await open(tree, in: model)

        model.sampleQuery = "sloppy loops"
        XCTAssertTrue(model.isSampleTreeSearch)
        XCTAssertTrue(model.sampleSearchInProgress)
        await model.pendingSampleSearch?.value

        XCTAssertFalse(model.sampleSearchInProgress)
        XCTAssertEqual(model.filteredSamples, [tree.drums])
        XCTAssertEqual(model.groupedFilteredSamples.map(\.title), ["SONG003 - Sloppy Drums / LOOPS"])
        XCTAssertTrue(model.expandedSampleFolders.isEmpty, "Searching opens no folder")

        model.sampleQuery = "kick loops"
        await model.pendingSampleSearch?.value
        XCTAssertTrue(model.filteredSamples.isEmpty)

        model.sampleQuery = ""
        XCTAssertNil(model.sampleSearch)
        XCTAssertEqual(model.filteredSamples, [tree.top])
    }

    @MainActor
    func testSearchStaysInsideTheBrowsedSourceAndEndsWithIt() async throws {
        let tree = try tree()
        let model = try model()
        await open(tree, in: model)
        model.sampleQuery = "kick"
        await model.pendingSampleSearch?.value
        XCTAssertEqual(model.filteredSamples, [tree.kick])

        model.showAllLibrarySamples()
        XCTAssertEqual(model.sampleQuery, "")
        XCTAssertNil(model.sampleSearch)
        XCTAssertFalse(model.isSampleTreeSearch)
    }

    @MainActor
    func testPlacesFollowTheBrowsedSource() async throws {
        let tree = try tree()
        let model = try model()
        XCTAssertEqual(model.selectedSamplePlace, .library)
        await open(tree, in: model)
        XCTAssertEqual(model.selectedSamplePlace, .root(tree.root))
        model.showAllLibrarySamples()
        XCTAssertEqual(model.selectedSamplePlace, .library)

        let unlisted = try directory("Kits")
        model.selectSampleRoot(unlisted)
        XCTAssertNil(model.selectedSamplePlace, "A folder that is not in the places list is not one of the places")
    }

    func testVolumeNameOfASource() {
        XCTAssertEqual(LibraryFormat.volumeName(of: URL(fileURLWithPath: "/Volumes/T9/User Library/Samples/Soul")), "T9")
        XCTAssertNil(LibraryFormat.volumeName(of: URL(fileURLWithPath: "/Users/nicolas/Music/Samples")))
        XCTAssertNil(LibraryFormat.volumeName(of: URL(fileURLWithPath: "/Volumes")))
    }
}
