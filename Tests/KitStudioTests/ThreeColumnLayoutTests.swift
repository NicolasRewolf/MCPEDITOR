import Foundation
import XCTest
import MPCCore
@testable import KitStudio

/// Samples on the left (computer above, SD below), .PGM on the right with a PART filter.
final class ThreeColumnLayoutTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreeColumnLayoutTests-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder.standardizedFileURL
    }

    private func sound(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".SND")
        try MPCSound(name: name, channels: [Array(repeating: 0.25, count: 441)]).encoded().write(to: url)
        return url.standardizedFileURL
    }

    private func program(_ name: String, sounds: [String], in folder: URL) throws -> URL {
        var program = MPCProgram.blank(name: name)
        for (slot, sound) in sounds.enumerated() {
            program.setSound(slot: slot, name: sound, wordCount: 512)
            program.assign(slot: slot, toNote: program.midiNote(forPad: slot))
        }
        let url = folder.appendingPathComponent(name + ".PGM")
        try program.bytes.write(to: url)
        return url.standardizedFileURL
    }

    @MainActor
    private func model(defaults: UserDefaults? = nil, volumes: @escaping () -> [URL] = { [] }) throws -> (StudioModel, UserDefaults) {
        let suite = "ThreeColumnLayoutTests-" + UUID().uuidString
        let store = try defaults ?? XCTUnwrap(UserDefaults(suiteName: suite))
        if defaults == nil { addTeardownBlock { store.removePersistentDomain(forName: suite) } }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString)
        return (StudioModel(defaults: store, localLibraryURL: library, volumeProvider: volumes), store)
    }

    @MainActor
    func testSDPaneListsMountedPartsClosedThenOpensOneInPlace() async throws {
        let partA = try directory("MPC-PART--A")
        let partB = try directory("MPC-PART--B")
        let clap = try sound("CLAP", in: partA)
        let kick = try sound("KICK", in: partA)
        let snare = try sound("SNARE", in: partB)
        let (model, _) = try model(volumes: { [partA, partB] })
        await model.refreshLocations().value

        XCTAssertTrue(model.sdIsMounted)
        XCTAssertEqual(model.sdSampleCount, 3)
        XCTAssertEqual(summary(model.sdSampleRows), ["A 2 fermée", "B 1 fermée"])
        model.toggleSDPart(partA)
        XCTAssertEqual(model.visibleSDSamples, [clap, kick])

        model.sdSampleQuery = "snare"
        XCTAssertEqual(summary(model.sdSampleRows), ["B 1 ouverte", "SNARE.SND"], "A search opens the matching PARTs only")
        XCTAssertEqual(model.visibleSDSamples, [snare])
        XCTAssertEqual(model.sampleScope, .library, "Searching the SD leaves the computer pane alone")
    }

    @MainActor
    func testOneSampleIsChosenAcrossBothPanesAndAssignUsesIt() async throws {
        let part = try directory("MPC-PART--A")
        let sdKick = try sound("KICK", in: part)
        let ssd = try directory("Samples")
        let ssdSnare = try sound("SNARE", in: ssd)
        let (model, _) = try model(volumes: { [part] })
        await model.refreshLocations().value
        model.sampleRoots = [ssd]
        model.selectSampleRoot(ssd)
        await model.browseSamplesFolder(ssd)?.value

        model.selectSample(ssdSnare)
        XCTAssertEqual(model.chosenSampleURL, ssdSnare)
        model.selectSDSample(sdKick)
        XCTAssertNil(model.selectedSampleURL, "Choosing on the SD releases the computer pane's sample")
        XCTAssertEqual(model.chosenSampleURL, sdKick)
        model.selectSample(ssdSnare)
        XCTAssertNil(model.selectedSDSampleURL)

        model.newKit()
        model.selectSDSample(sdKick)
        model.assignChosenSample()
        await waitUntil { model.padHasSound(index: model.selectedPad) }
        XCTAssertEqual(model.padName(model.selectedPad), "KICK")
    }

    @MainActor
    func testUnmountDropsTheSDSampleAndEmptiesThePane() async throws {
        let part = try directory("MPC-PART--A")
        let kick = try sound("KICK", in: part)
        var mounted = [part]
        let (model, _) = try model(volumes: { mounted })
        await model.refreshLocations().value
        model.selectSDSample(kick)

        mounted = []
        await model.refreshLocations().value

        XCTAssertNil(model.selectedSDSampleURL)
        XCTAssertFalse(model.sdIsMounted)
        XCTAssertTrue(model.sdSampleRows.isEmpty)
    }

    @MainActor
    func testArrowKeysWalkTheOpenSDSamples() async throws {
        let part = try directory("MPC-PART--A")
        let clap = try sound("CLAP", in: part)
        let kick = try sound("KICK", in: part)
        let (model, _) = try model(volumes: { [part] })
        await model.refreshLocations().value
        model.toggleSDPart(part)

        model.moveSDSampleSelection(by: 1)
        XCTAssertEqual(model.selectedSDSampleURL, clap)
        model.moveSDSampleSelection(by: 1)
        XCTAssertEqual(model.selectedSDSampleURL, kick)
        model.moveSDSampleSelection(by: 1)
        XCTAssertEqual(model.selectedSDSampleURL, kick)
    }

    @MainActor
    func testPartFilterNarrowsProgramsWithoutTouchingTheSamplePanes() async throws {
        let partA = try directory("MPC-PART--A")
        let partB = try directory("MPC-PART--B")
        _ = try sound("KICK", in: partA)
        _ = try sound("SNARE", in: partB)
        let soulA = try program("SOUL", sounds: ["KICK"], in: partA)
        _ = try program("FUNK", sounds: ["SNARE"], in: partB)
        let (model, _) = try model(volumes: { [partA, partB] })
        await model.refreshLocations().value
        let before = model.sampleScope

        model.filterPrograms(to: partA)
        XCTAssertEqual(model.filteredKits.map(\.url), [soulA])
        XCTAssertEqual(model.sampleScope, before)
        XCTAssertNil(model.selectedSampleRoot)

        model.filterPrograms(to: nil)
        XCTAssertEqual(model.filteredKits.count, 2)
    }

    @MainActor
    func testMacPlaceShowsOnlyTheMacCollection() async throws {
        let part = try directory("MPC-PART--A")
        _ = try sound("KICK", in: part)
        _ = try program("SOUL", sounds: ["KICK"], in: part)
        let (model, _) = try model(volumes: { [part] })
        await model.refreshLocations().value

        model.showAllLibrarySamples()
        XCTAssertEqual(model.selectedSamplePlace, .library)
        XCTAssertEqual(model.sampleScopeTitle, "Bibliothèque sur le Mac")
        XCTAssertTrue(model.filteredSamples.isEmpty, "SD samples belong to the SD pane")
    }

    @MainActor
    func testComputerPaneReopensOnTheLastSourceWithItsOpenFolders() async throws {
        let root = try directory("Samples")
        let soul = URL(fileURLWithPath: root.appendingPathComponent("Soul").path, isDirectory: true)
        try FileManager.default.createDirectory(at: soul, withIntermediateDirectories: true)
        let kick = try sound("KICK", in: soul)
        let (first, defaults) = try model()
        first.sampleRoots = [root]
        first.selectSampleRoot(root)
        await first.browseSamplesFolder(root)?.value
        await first.toggleSampleFolder(soul)?.value
        defaults.set([root.path], forKey: "library.sampleRoots")

        let (second, _) = try model(defaults: defaults)
        XCTAssertEqual(second.selectedSampleRoot, root)
        XCTAssertFalse(second.canGoBackInSamples, "Reopening is not a navigation step")
        await waitUntil { second.sampleTreeRows.contains { $0.url == kick } }
        XCTAssertTrue(second.expandedSampleFolders.contains(soul))

        second.showAllLibrarySamples()
        let (third, _) = try model(defaults: defaults)
        XCTAssertEqual(third.sampleScope, .library, "Choosing the Mac place is remembered too")
    }

    /// Temporary folders are not FAT volumes, so their PARTs carry a destination caveat; the
    /// pane's structure is what these tests check.
    private func summary(_ rows: [StudioModel.SDSampleRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .part(let letter, let count, let expanded, _): return "\(letter) \(count) \(expanded ? "ouverte" : "fermée")"
            case .sample: return row.url.lastPathComponent
            }
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Condition not met within \(timeout) s")
    }
}
