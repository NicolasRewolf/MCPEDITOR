import Foundation
@testable import MPCCore
import XCTest
@testable import KitStudio

final class LibraryAssociationModelTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryAssociationModelTests-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder
    }

    private func sound(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".SND")
        try MPCSound(name: name, channels: [Array(repeating: 0.25, count: 512)]).encoded().write(to: url)
        return url
    }

    private func program(_ name: String, sounds: [String], in folder: URL) throws -> URL {
        var program = MPCProgram.blank(name: name)
        for (slot, name) in sounds.enumerated() {
            program.setSound(slot: slot, name: name, wordCount: 512)
            program.assign(slot: slot, toNote: program.midiNote(forPad: slot))
        }
        let url = folder.appendingPathComponent(name + ".PGM")
        try program.bytes.write(to: url)
        return url
    }

    @MainActor
    private func model(folders: [URL] = [], volumes: @escaping () -> [URL] = { [] },
                       loader: @escaping @Sendable (URL) -> LibraryFolderListing = { LibraryIndex.listSamples(in: $0) }) throws -> StudioModel {
        let suiteName = "LibraryAssociationModelTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(folders.map(\.path), forKey: "library.kitFolders")
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return StudioModel(defaults: defaults, volumeProvider: volumes, sampleFolderLoader: loader)
    }

    @MainActor
    func testSamplesDefaultToAllPartsAndResolveOnlyExactFileAssociations() async throws {
        let partA = try directory("MPC-PART--A")
        let partB = try directory("MPC-PART--B")
        let kickA = try sound("KICK", in: partA)
        let kickB = try sound("KICK", in: partB)
        let orphan = try sound("OTHER", in: partA)
        let soulA = try program("SOUL", sounds: ["KICK"], in: partA)
        let funkA = try program("FUNK", sounds: ["KICK"], in: partA)
        let soulB = try program("SOUL", sounds: ["KICK"], in: partB)
        let model = try model(volumes: { [partA, partB] })

        await model.refreshLocations().value

        XCTAssertEqual(model.sampleScope, .sd)
        XCTAssertEqual(Set(model.filteredSamples), Set([kickA, kickB, orphan]))
        XCTAssertEqual(Set(model.programsUsingSample(kickA).map(\.url)), Set([soulA, funkA]))
        XCTAssertEqual(model.programsUsingSample(kickB).map(\.url), [soulB])
        XCTAssertEqual(model.sampleAssociationSummary(for: kickA), "2 .PGM associés")
        XCTAssertEqual(model.sampleAssociationSummary(for: orphan), "Aucun lien .PGM trouvé")
        XCTAssertEqual(model.sampleLocationLabel(for: kickA), "PART A")
        XCTAssertEqual(model.sampleLocationLabel(for: kickB), "PART B")
        XCTAssertFalse(model.canGoUpSamples)
        model.sampleQuery = "PART B"
        XCTAssertEqual(model.filteredSamples, [kickB])
    }

    @MainActor
    func testLocalBackupNamedLikePartDoesNotClaimPresenceOnSD() async throws {
        let backup = try directory("MPC-PART--S")
        let kick = try sound("KICK", in: backup)
        _ = try program("SOUL", sounds: ["KICK"], in: backup)
        let model = try model(folders: [backup])

        await model.refreshLocations().value

        XCTAssertTrue(model.partitions.isEmpty)
        XCTAssertTrue(model.filteredSamples.isEmpty)
        XCTAssertNil(model.libraryKits.first?.partitionLetter)
        XCTAssertEqual(model.sampleLocationLabel(for: kick), "MPC-PART--S")
        XCTAssertEqual(model.libraryKits.first?.locationLabel, "MPC-PART--S")
        model.programURL = model.libraryKits.first?.url
        XCTAssertTrue(model.kitLocationLabel.contains("MPC-PART--S"))
        XCTAssertFalse(model.kitLocationLabel.contains("PART S"))
    }

    @MainActor
    func testPartSampleNavigationIncludesNestedSamplesAndMatchesInventoryCount() async throws {
        let part = try directory("MPC-PART--S")
        let nested = part.appendingPathComponent("Soul", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let kick = try sound("KICK", in: part)
        let roll = try sound("ROLL", in: nested)
        let model = try model(volumes: { [part] })
        await model.refreshLocations().value
        let snapshot = try XCTUnwrap(model.partitions.first)

        model.showSamples(in: snapshot)

        XCTAssertEqual(model.sampleScope, .partition(part))
        XCTAssertEqual(Set(model.filteredSamples), Set([kick, roll]))
        XCTAssertEqual(model.filteredSamples.count, snapshot.audioCount)
        XCTAssertTrue(model.filteredSampleFolders.isEmpty)
        XCTAssertEqual(model.sampleScopeTitle, "Samples · PART S")
        XCTAssertEqual(model.sampleLocationLabel(for: roll), "PART S · Soul")
        XCTAssertFalse(model.canGoUpSamples)
        model.selectSample(roll)
        model.sampleQuery = "roll"
        await model.refreshLocations().value
        XCTAssertEqual(model.filteredSamples, [roll])
        XCTAssertEqual(model.selectedSampleURL, roll)
        XCTAssertEqual(model.sampleQuery, "roll")
    }

    @MainActor
    func testProgramSamplesShowResolvedFilesAndWarnAboutMissingReferences() async throws {
        let part = try directory("MPC-PART--S")
        let kick = try sound("KICK", in: part)
        _ = try sound("OTHER", in: part)
        let pgm = try program("SOUL", sounds: ["KICK", "MISSING"], in: part)
        let model = try model(volumes: { [part] })
        await model.refreshLocations().value
        let saved = try XCTUnwrap(model.libraryKits.first { $0.url == pgm })

        model.showSamples(in: saved)

        XCTAssertEqual(model.libraryMode, .samples)
        XCTAssertEqual(model.sampleScope, .program(saved))
        XCTAssertEqual(model.filteredSamples, [kick])
        XCTAssertTrue(model.filteredSampleFolders.isEmpty)
        XCTAssertTrue(model.sampleScopeTitle.contains("SOUL.PGM"))
        XCTAssertTrue(model.sampleScopeTitle.contains("PART S"))
        XCTAssertNotNil(model.libraryContentIssue)
        XCTAssertTrue(model.libraryContentIssue?.contains("MISSING") == true)
        XCTAssertNil(model.sampleFolder)
        XCTAssertFalse(model.canGoUpSamples)
    }

    @MainActor
    func testLibraryNavigationPreservesDirtyDocumentAndUsesSavedAssociations() async throws {
        let part = try directory("MPC-PART--S")
        let kick = try sound("KICK", in: part)
        let pgm = try program("SOUL", sounds: ["KICK"], in: part)
        let model = try model(volumes: { [part] })
        await model.refreshLocations().value
        await model.importURLs([kick], atPad: 20)?.value
        model.setKitName("EDITED")
        let beforeProgram = model.program?.bytes
        let beforeSound = model.sound?.channels
        let beforeStatus = model.status
        let beforeMemory = model.memoryBytes
        let saved = try XCTUnwrap(model.libraryKits.first { $0.url == pgm })
        let partition = try XCTUnwrap(model.partitions.first)

        model.showSamples(in: saved)
        model.selectSample(kick)
        XCTAssertEqual(model.programsUsingSample(kick).map(\.url), [pgm])
        XCTAssertTrue(model.selectedSampleAssociationNotice?.contains("modifications en mémoire ne sont pas incluses") == true)
        model.kitSearch = "NO MATCH"
        model.showPrograms(in: partition)
        XCTAssertEqual(model.kitSearch, "")
        XCTAssertEqual(model.libraryMode, .kits)
        XCTAssertEqual(model.filteredKits.map(\.url), [pgm])
        model.showSamples(in: partition)
        await model.browseSamplesFolder(part)?.value
        XCTAssertEqual(model.filteredSamples, [kick])
        model.showAllSDSamples()

        XCTAssertEqual(model.program?.bytes, beforeProgram)
        XCTAssertEqual(model.sound?.channels, beforeSound)
        XCTAssertEqual(model.selectedPad, 20)
        XCTAssertEqual(model.bank, 1)
        XCTAssertEqual(model.kitName, "EDITED")
        XCTAssertEqual(model.memoryBytes, beforeMemory)
        XCTAssertEqual(model.status, beforeStatus)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
    }

    @MainActor
    func testProgramRefreshKeepsQueryAndSelectionThenRemovesDeletedLinks() async throws {
        let folder = try directory("Programs")
        let kick = try sound("KICK", in: folder)
        let pgm = try program("SOUL", sounds: ["KICK"], in: folder)
        let model = try model(folders: [folder])
        await model.refreshLocations().value
        let saved = try XCTUnwrap(model.libraryKits.first)
        model.showSamples(in: saved)
        model.selectSample(kick)
        model.sampleQuery = "kick"
        let preview = model.samplePreviewStatus

        await model.refreshLocations().value

        XCTAssertEqual(model.selectedSampleURL, kick)
        XCTAssertEqual(model.sampleQuery, "kick")
        XCTAssertEqual(model.samplePreviewStatus, preview)
        try FileManager.default.removeItem(at: pgm)
        await model.refreshLocations().value

        XCTAssertTrue(model.filteredSamples.isEmpty)
        XCTAssertTrue(model.programsUsingSample(kick).isEmpty)
        XCTAssertNil(model.selectedSampleURL)
        XCTAssertEqual(model.sampleQuery, "kick")
        XCTAssertTrue(model.libraryContentIssue?.contains("plus disponible") == true)
    }

    @MainActor
    func testUnmountClearsPartSamplesAndAssociationsWithoutDiscardingDirtyDocument() async throws {
        let part = try directory("MPC-PART--M")
        let kick = try sound("KICK", in: part)
        _ = try program("SOUL", sounds: ["KICK"], in: part)
        var mounted = [part]
        let model = try model(volumes: { mounted })
        await model.refreshLocations().value
        await model.importURLs([kick], atPad: 0)?.value
        let before = model.program?.bytes
        model.showAllSDSamples()
        model.selectSample(kick)
        model.sampleQuery = "kick"
        model.samplePreviewBusy = true
        mounted = []

        await model.refreshLocations().value

        XCTAssertTrue(model.libraryKits.isEmpty)
        XCTAssertTrue(model.filteredSamples.isEmpty)
        XCTAssertTrue(model.programsUsingSample(kick).isEmpty)
        XCTAssertNil(model.selectedSampleURL)
        XCTAssertFalse(model.samplePreviewBusy)
        XCTAssertEqual(model.sampleQuery, "kick")
        XCTAssertTrue(model.libraryContentIssue?.contains("plus montée") == true)
        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(try XCTUnwrap(model.partitions.first).isEmpty)
    }

    @MainActor
    func testProgramScopeRetainsPartInventoryWarning() async throws {
        let part = try directory("MPC-PART--M")
        let kick = try sound("KICK", in: part)
        _ = try program("SOUL", sounds: ["KICK"], in: part)
        let model = try model(volumes: { [part] })
        await model.refreshLocations().value
        let saved = try XCTUnwrap(model.libraryKits.first)
        let reason = "L’espace FAT occupé ne correspond pas aux fichiers visibles."
        model.partitions = [LibraryPartition(url: part, letter: "M", kits: [saved], fileCount: 2,
            folderCount: 0, audioCount: 1, sequenceCount: 0, issues: [reason], availableBytes: nil, samples: [kick])]

        model.showSamples(in: saved)

        XCTAssertEqual(model.filteredSamples, [kick])
        XCTAssertEqual(model.libraryContentIssue, reason)
        XCTAssertEqual(model.libraryInventoryWarningTitle, "Inventaire incomplet · PART M")
    }

    @MainActor
    func testLateFolderReadCannotReplaceProgramOrAllSDScope() async throws {
        let folder = try directory("Programs")
        let kick = try sound("KICK", in: folder)
        _ = try program("SOUL", sounds: ["KICK"], in: folder)
        for useProgram in [false, true] {
            let requested = expectation(description: "Folder loader started")
            let gate = AssociationFolderGate()
            defer { gate.release() }
            let model = try model(folders: [folder], loader: { _ in
                requested.fulfill()
                gate.wait()
                return LibraryFolderListing(folders: [], samples: [kick], issue: nil)
            })
            await model.refreshLocations().value
            let saved = try XCTUnwrap(model.libraryKits.first)
            model.selectedSampleRoot = folder
            let pending = try XCTUnwrap(model.browseSamplesFolder(folder))
            await fulfillment(of: [requested], timeout: 3)
            if useProgram { model.showSamples(in: saved) }
            else { model.showAllSDSamples() }
            model.sampleQuery = "kick"
            gate.release()
            await pending.value

            XCTAssertEqual(model.sampleScope, useProgram ? .program(saved) : .sd)
            XCTAssertEqual(model.filteredSamples, useProgram ? [kick] : [])
            XCTAssertNil(model.sampleFolder)
            XCTAssertTrue(model.sampleListing.samples.isEmpty)
            XCTAssertEqual(model.sampleQuery, "kick")
        }
    }
}

private final class AssociationFolderGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        defer { condition.unlock() }
        while !released { condition.wait() }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
