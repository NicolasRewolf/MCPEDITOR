import Combine
import Foundation
import XCTest
import MPCCore
@testable import KitStudio

/// Building a bank: PART capacity, shared samples, keyboard sample browsing, .PGM summaries.
final class BankBuildingTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("BankBuildingTests-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder
    }

    @MainActor
    private func model(kitFolders: [URL] = []) throws -> (StudioModel, UserDefaults) {
        let suiteName = "BankBuildingTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(kitFolders.map(\.path), forKey: "library.kitFolders")
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString)
        return (StudioModel(defaults: defaults, localLibraryURL: library, volumeProvider: { [] }), defaults)
    }

    private func sound(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".SND")
        try MPCSound(name: name, channels: [Array(repeating: 0.25, count: 441)]).encoded().write(to: url)
        return url
    }

    /// One 441-frame mono sample on pad A01.
    private func program(in folder: URL) throws -> URL {
        _ = try sound("KICK", in: folder)
        var program = MPCProgram.blank(name: "BANK")
        program.setSound(slot: 0, name: "KICK", wordCount: 441)
        program.assign(slot: 0, toNote: program.midiNote(forPad: 0))
        let url = folder.appendingPathComponent("BANK.PGM")
        try program.bytes.write(to: url)
        return url
    }

    @MainActor
    private func open(_ url: URL, in model: StudioModel) async throws {
        let finished = expectation(description: "Program opened")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }
        model.openProgram(url)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(model.errorMessage)
    }

    private func emptyPart(_ letter: String, available: Int64) -> LibraryPartition {
        LibraryPartition(url: URL(fileURLWithPath: "/Volumes/MPC-PART--\(letter)"), letter: letter, kits: [],
                         fileCount: 0, folderCount: 0, audioCount: 0, sequenceCount: 0, issues: [],
                         availableBytes: available,
                         volumeSpace: ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: available))
    }

    @MainActor
    func testCapacityGaugeUsesTheCopyEstimateAgainstTheLargestEmptyPart() async throws {
        let (model, defaults) = try model()
        XCTAssertNil(model.partCapacity)
        try await open(try program(in: try directory("Source")), in: model)

        // SND and PGM: one 8 KiB cluster each, AppleDouble reserve for each, 64 KiB margin.
        model.partitions = [emptyPart("E", available: 200_000), emptyPart("F", available: 150_000)]
        let fits = try XCTUnwrap(model.partCapacity)
        XCTAssertEqual(fits.requiredBytes, 98_304)
        XCTAssertEqual(fits.capacityBytes, 200_000)
        XCTAssertEqual(fits.measuredLetter, "E")
        XCTAssertTrue(fits.fits)
        XCTAssertEqual(fits.requiredBytes, model.requiredExportFreeBytes(in: model.partitions[0]))

        model.partitions = [emptyPart("E", available: 90_000)]
        XCTAssertEqual(model.partCapacity?.fits, false)

        model.rememberEmptyPartCapacity([emptyPart("G", available: 7_952 * 1024)])
        XCTAssertEqual(defaults.integer(forKey: "library.emptyPartAvailableBytes"), 7_952 * 1024)
        model.partitions = []
        let remembered = try XCTUnwrap(model.partCapacity)
        XCTAssertNil(remembered.measuredLetter)
        XCTAssertEqual(remembered.capacityBytes, 7_952 * 1024)
        XCTAssertTrue(remembered.fits)
    }

    @MainActor
    func testCopiedAssignmentIsReportedAsASharedSample() async throws {
        let (model, _) = try model()
        try await open(try program(in: try directory("Source")), in: model)
        XCTAssertTrue(model.padsSharingSample(with: 0).isEmpty)

        model.padTransfer(from: 0, to: 1, copy: true)

        XCTAssertEqual(model.padsSharingSample(with: 0), [1])
        XCTAssertEqual(model.padsSharingSample(with: 1), [0])
        XCTAssertEqual(StudioModel.padLabel(1), "A02")
        XCTAssertEqual(StudioModel.padLabel(63), "D16")
        XCTAssertTrue(model.padsSharingSample(with: 2).isEmpty)
    }

    @MainActor
    func testArrowKeysWalkSamplesAndAutoPreviewFollowsTheSelection() async throws {
        let root = try directory("Samples")
        let names = ["A_KICK", "B_SNARE", "C_HAT"]
        let urls = try names.map { try sound($0, in: root) }
        let (model, defaults) = try model()
        model.selectSampleRoot(root)
        await model.browseSamplesFolder(root)?.value
        XCTAssertEqual(model.filteredSamples, urls.map(\.standardizedFileURL))

        model.moveSampleSelection(by: 1)
        XCTAssertEqual(model.selectedSampleURL, urls[0].standardizedFileURL)
        XCTAssertFalse(model.samplePreviewBusy)
        model.moveSampleSelection(by: 1)
        model.moveSampleSelection(by: 5)
        XCTAssertEqual(model.selectedSampleURL, urls[2].standardizedFileURL)
        model.moveSampleSelection(by: -1)
        XCTAssertEqual(model.selectedSampleURL, urls[1].standardizedFileURL)

        model.autoPreviewSamples = true
        XCTAssertTrue(defaults.bool(forKey: "library.autoPreviewSamples"))
        model.moveSampleSelection(by: 1)
        XCTAssertEqual(model.selectedSampleURL, urls[2].standardizedFileURL)
        XCTAssertTrue(model.samplePreviewBusy)
        model.stop()
        XCTAssertFalse(model.samplePreviewBusy)
    }

    @MainActor
    func testProgramRowsSummarizeTheirResolvedSamples() async throws {
        let folder = try directory("Kits")
        let url = try program(in: folder)
        let (model, _) = try model(kitFolders: [folder])
        await model.refreshLocations().value
        let kit = try XCTUnwrap(model.libraryKits.first { $0.url == url.standardizedFileURL })

        XCTAssertEqual(model.kitContentSummary(for: kit), "1 sample")
        XCTAssertNil(model.kitTitleOnMPC(for: kit))
    }
}
