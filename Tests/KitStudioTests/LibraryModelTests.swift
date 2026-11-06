import AppKit
import Combine
import Foundation
import Darwin
@testable import MPCCore
import UniformTypeIdentifiers
import XCTest
@testable import KitStudio

final class LibraryModelTests: XCTestCase {
    private func directory(_ name: String = "Library") throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryModelTests-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder
    }

    @MainActor
    private func testModel(
        discardPresenter: StudioModel.DiscardPresenter? = nil,
        kitFolders: [URL] = [],
        mountedVolumes: [URL] = [],
        sampleFolderLoader: @escaping @Sendable (URL) -> LibraryFolderListing = { LibraryIndex.listSamples(in: $0) }
    ) throws -> StudioModel {
        let suiteName = "LibraryModelTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(kitFolders.map(\.path), forKey: "library.kitFolders")
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return StudioModel(defaults: defaults, localLibraryURL: FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString), discardPresenter: discardPresenter,
                           volumeProvider: { mountedVolumes }, sampleFolderLoader: sampleFolderLoader)
    }

    private func nativeSound(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".SND")
        let sound = MPCSound(name: name, channels: [Array(repeating: 0.25, count: 441)])
        try sound.encoded().write(to: url)
        return url
    }

    private func kit(in folder: URL, pad: Int = 20) throws -> URL {
        _ = try nativeSound("ORIGINAL", in: folder)
        var program = MPCProgram.blank(name: "SOURCE")
        program.setSound(slot: 0, name: "ORIGINAL", wordCount: 441)
        program.assign(slot: 0, toNote: program.midiNote(forPad: pad))
        let url = folder.appendingPathComponent("SOURCE.PGM")
        try program.bytes.write(to: url)
        return url
    }

    @MainActor
    private func open(_ url: URL, in model: StudioModel) async throws {
        let finished = expectation(description: "Kit load finishes")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }
        model.openProgram(url)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.programURL, url)
    }

    @MainActor
    func testBrowsingAnotherPartPreservesDirtyLoadedDocumentAndSelectedSample() async throws {
        let source = try directory("Source")
        let part = try directory("MPC-PART--S")
        let sourceURL = try kit(in: source)
        let sampleURL = try nativeSound("SNARE", in: part)
        let model = try testModel()
        try await open(sourceURL, in: model)
        model.selectPad(20)
        model.setKitName("EDITED")
        let beforeProgram = try XCTUnwrap(model.program?.bytes)
        let beforeSound = try XCTUnwrap(model.sound)
        let beforeStatus = model.status
        let beforeMemory = model.memoryBytes

        model.filterPrograms(to: part)
        await model.selectSampleRoot(part)?.value

        XCTAssertEqual(model.selectedLocation, part.standardizedFileURL)
        XCTAssertEqual(model.sampleListing.samples, [sampleURL.standardizedFileURL])
        XCTAssertEqual(model.program?.bytes, beforeProgram)
        XCTAssertEqual(model.programURL, sourceURL)
        XCTAssertEqual(model.sound?.channels, beforeSound.channels)
        XCTAssertEqual(model.sound?.name, beforeSound.name)
        XCTAssertEqual(model.selectedPad, 20)
        XCTAssertEqual(model.bank, 1)
        XCTAssertEqual(model.kitName, "EDITED")
        XCTAssertEqual(model.memoryBytes, beforeMemory)
        XCTAssertEqual(model.status, beforeStatus)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
    }

    @MainActor
    func testPartBrowsingDoesNotInvalidateAnImportWaitingForItsProvider() async throws {
        let source = try directory("Source")
        let part = try directory("MPC-PART--S")
        let original = try nativeSound("ORIGINAL", in: source)
        let replacement = try nativeSound("NEW", in: source)
        let model = try testModel()
        await model.importURLs([original], atPad: 20)?.value
        model.setKitName("KEEP")
        let beforeProgram = try XCTUnwrap(model.program?.bytes)
        let beforeChannels = try XCTUnwrap(model.sound?.channels)
        let requested = expectation(description: "Provider is waiting")
        let gate = LibraryDeferredProvider()
        gate.provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            gate.store(completion)
            requested.fulfill()
            return nil
        }
        let finished = expectation(description: "Import survives browsing")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }

        XCTAssertTrue(model.dropFiles([gate.provider], onPad: 21))
        await fulfillment(of: [requested], timeout: 3)
        let operationStatus = model.status
        model.filterPrograms(to: part)
        await model.selectSampleRoot(part)?.value

        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.program?.bytes, beforeProgram)
        XCTAssertEqual(model.sound?.channels, beforeChannels)
        XCTAssertEqual(model.selectedPad, 20)
        XCTAssertEqual(model.bank, 1)
        XCTAssertEqual(model.status, operationStatus)
        gate.complete(replacement.dataRepresentation)
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertEqual(model.padName(20), "ORIGINAL")
        XCTAssertEqual(model.padName(21), "NEW")
        XCTAssertEqual(model.kitName, "KEEP")
        XCTAssertEqual(model.selectedLocation, part.standardizedFileURL)
        XCTAssertEqual(model.selectedPad, 21)
        XCTAssertEqual(model.bank, 1)
        XCTAssertEqual(model.memoryBytes, 1_764)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testSamplesAlreadyOnAPartAreListedWithoutAnyProgram() async throws {
        let part = try directory("MPC-PART--S")
        let kick = try nativeSound("KICK", in: part)
        let snare = try nativeSound("SNARE", in: part)
        try Data([1, 2, 3]).write(to: part.appendingPathComponent("TAKE.SEQ"))
        let model = try testModel()

        model.filterPrograms(to: part)
        await model.selectSampleRoot(part)?.value

        XCTAssertEqual(model.sampleListing.samples, [kick, snare].map(\.standardizedFileURL))
        XCTAssertNil(model.sampleListing.issue)
        XCTAssertTrue(model.filteredKits.isEmpty)
        XCTAssertNil(model.program)
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func testApparentlyEmptySamplesRetainSelectedPartInventoryWarning() async throws {
        let part = try directory("MPC-PART--M")
        let reason = "L’espace FAT occupé ne correspond pas aux fichiers visibles."
        let model = try testModel(mountedVolumes: [part], sampleFolderLoader: { _ in
            LibraryFolderListing(folders: [], samples: [], issue: nil)
        })
        model.partitions = [LibraryPartition(
            url: part, letter: "M", kits: [], fileCount: 0, folderCount: 0,
            audioCount: 0, sequenceCount: 0, issues: [reason], availableBytes: 1_000_000)]

        model.filterPrograms(to: part)
        await model.selectSampleRoot(part)?.value

        XCTAssertTrue(model.filteredSamples.isEmpty)
        XCTAssertEqual(model.emptySampleTreeTitle, "Aucun sample visible", "An incomplete inventory is never called empty")
        XCTAssertTrue(model.emptySampleTreeDetail.contains("ne permettent pas de conclure"))
        XCTAssertEqual(model.sampleBrowserIssue, reason)
        XCTAssertTrue(model.filteredKits.isEmpty)
        XCTAssertEqual(model.programListIssue, reason)
    }

    @MainActor
    func testPartWarningSurvivesFilteringDeduplicatesReasonsAndClearsOnSelectionChange() async throws {
        let suspect = try directory("MPC-PART--M")
        let healthy = try directory("MPC-PART--S")
        let reason = "Lecture de .Trashes impossible : autorisation refusée."
        let visible = suspect.appendingPathComponent("KICK.SND")
        let visibleKit = LibraryKit(url: suspect.appendingPathComponent("DRUMS.PGM"), rootURL: suspect,
                                    partitionLetter: "M", relativeFolder: "")
        let model = try testModel(mountedVolumes: [suspect, healthy], sampleFolderLoader: { folder in
            LibraryFolderListing(folders: [], samples: folder == suspect ? [visible] : [],
                                 issue: folder == suspect ? reason : nil)
        })
        model.partitions = [
            LibraryPartition(url: suspect, letter: "M", kits: [visibleKit], fileCount: 2, folderCount: 0,
                             audioCount: 1, sequenceCount: 0, issues: [reason], availableBytes: nil),
            LibraryPartition(url: healthy, letter: "S", kits: [], fileCount: 0, folderCount: 0,
                             audioCount: 0, sequenceCount: 0, issues: [], availableBytes: 8_000_000)
        ]
        model.libraryKits = [visibleKit]
        model.libraryIssue = reason
        model.filterPrograms(to: suspect)
        await model.selectSampleRoot(suspect)?.value
        XCTAssertEqual(model.filteredSamples, [visible])
        XCTAssertEqual(model.sampleBrowserIssue, reason, "The PART's and the listing's identical reasons are said once")

        model.sampleQuery = "NO MATCH"
        XCTAssertTrue(model.filteredSamples.isEmpty)
        XCTAssertEqual(model.sampleBrowserIssue, reason)
        XCTAssertEqual(model.filteredKits, [visibleKit])
        XCTAssertEqual(model.programListIssue, reason)

        model.filterPrograms(to: healthy)
        await model.selectSampleRoot(healthy)?.value
        XCTAssertNil(model.sampleBrowserIssue)
        XCTAssertNil(model.programListIssue)
        XCTAssertEqual(model.emptySampleTreeTitle, "Dossier vide")
        XCTAssertEqual(model.libraryIssue, reason, "The separate issue on M must not disappear globally.")

        model.filterPrograms(to: nil)
        XCTAssertEqual(model.programListIssue, reason)
    }

    @MainActor
    func testNewHealthyPartitionSnapshotClearsSelectedInventoryWarning() async throws {
        let part = try directory("MPC-PART--M")
        let model = try testModel(mountedVolumes: [part], sampleFolderLoader: { _ in
            LibraryFolderListing(folders: [], samples: [], issue: nil)
        })
        model.partitions = [LibraryPartition(
            url: part, letter: "M", kits: [], fileCount: 0, folderCount: 0,
            audioCount: 0, sequenceCount: 0, issues: ["Deux fichiers portent le même nom."], availableBytes: nil)]
        model.filterPrograms(to: part)
        await model.selectSampleRoot(part)?.value
        XCTAssertNotNil(model.sampleBrowserIssue)

        model.partitions = [LibraryPartition(
            url: part, letter: "M", kits: [], fileCount: 0, folderCount: 0,
            audioCount: 0, sequenceCount: 0, issues: [], availableBytes: 8_000_000)]

        XCTAssertNil(model.sampleBrowserIssue)
        XCTAssertEqual(model.emptySampleTreeTitle, "Dossier vide")
        XCTAssertNil(model.programListIssue)
    }

    @MainActor
    func testUnavailableKitFolderClearsStaleLibraryAndRecoveryClearsItsIssueWithoutChangingDocument() async throws {
        let folder = try directory("SavedKits")
        let source = try kit(in: folder, pad: 0)
        let model = try testModel(kitFolders: [folder])
        try await open(source, in: model)
        let originalProgram = try XCTUnwrap(model.program?.bytes)
        let originalSample = try XCTUnwrap(model.sound)
        await model.refreshLocations().value
        XCTAssertEqual(model.libraryKits.map(\.url), [source.standardizedFileURL])
        XCTAssertNil(model.libraryIssue)

        let moved = folder.deletingLastPathComponent().appendingPathComponent("DisconnectedKits")
        try FileManager.default.moveItem(at: folder, to: moved)
        await model.refreshLocations().value
        XCTAssertTrue(model.libraryKits.isEmpty)
        XCTAssertTrue(model.filteredKits.isEmpty)
        XCTAssertNotNil(model.libraryIssue)
        XCTAssertEqual(model.program?.bytes, originalProgram)
        XCTAssertEqual(model.sound?.channels, originalSample.channels)
        XCTAssertFalse(model.isDirty)

        try FileManager.default.moveItem(at: moved, to: folder)
        await model.refreshLocations().value
        XCTAssertEqual(model.libraryKits.map(\.url), [source.standardizedFileURL])
        XCTAssertNil(model.libraryIssue)
        XCTAssertEqual(model.program?.bytes, originalProgram)
        XCTAssertEqual(model.programURL, source)
        XCTAssertEqual(try Data(contentsOf: source), originalProgram)
    }

    @MainActor
    func testOverlappingKitRootsFilterByProgramLocationWithoutDuplicatingKits() async throws {
        let parent = try directory("Kits")
        let soul = parent.appendingPathComponent("Soul", isDirectory: true)
        let sibling = parent.appendingPathComponent("Soulful", isDirectory: true)
        try FileManager.default.createDirectory(at: soul, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let soulKit = try kit(in: soul)
        let siblingKit = try kit(in: sibling)

        for roots in [[parent, soul], [soul, parent]] {
            let model = try testModel(kitFolders: roots)
            await model.refreshLocations().value
            XCTAssertEqual(Set(model.libraryKits.map(\.url)), Set([soulKit, siblingKit]))
            XCTAssertEqual(model.libraryKits.count, 2)
            model.selectedLocation = soul
            XCTAssertEqual(model.filteredKits.map(\.url), [soulKit], "A first-scanned parent must not hide a child kit or include a similarly named sibling.")
            model.selectedLocation = parent
            XCTAssertEqual(Set(model.filteredKits.map(\.url)), Set([soulKit, siblingKit]))
            XCTAssertEqual(model.filteredKits.count, 2)
        }
    }

    @MainActor
    func testKitFolderInsideAPartRetainsItsDeduplicatedProgram() async throws {
        let part = try directory("MPC-PART--S")
        let soul = part.appendingPathComponent("Soul", isDirectory: true)
        try FileManager.default.createDirectory(at: soul, withIntermediateDirectories: false)
        let source = try kit(in: soul)
        let model = try testModel(kitFolders: [soul], mountedVolumes: [part])

        await model.refreshLocations().value
        XCTAssertEqual(model.libraryKits.map(\.url), [source])
        XCTAssertEqual(model.libraryKits.first?.rootURL, part)
        model.selectedLocation = soul
        XCTAssertEqual(model.filteredKits.map(\.url), [source])
        model.selectedLocation = part
        XCTAssertEqual(model.filteredKits.map(\.url), [source])
    }

    @MainActor
    func testRefreshPreservesSampleQuerySelectionAndPreviewState() async throws {
        let folder = try directory("Samples")
        let kick = try nativeSound("KICK", in: folder)
        _ = try nativeSound("SNARE", in: folder)
        let model = try testModel()
        await model.selectSampleRoot(folder)?.value
        model.sampleQuery = "kick"
        model.selectSample(kick)

        await model.refreshLocations().value

        XCTAssertEqual(model.sampleQuery, "kick")
        XCTAssertEqual(model.filteredSamples, [kick])
        XCTAssertEqual(model.selectedSampleURL, kick)
        XCTAssertNil(model.sampleProblem)
        XCTAssertFalse(model.samplePreviewBusy)
        XCTAssertEqual(model.sampleFolder, folder)
    }

    @MainActor
    func testRefreshInvalidatesMissingOrUnreadableSampleWithoutClearingSearch() async throws {
        let folder = try directory("Samples")
        let kick = try nativeSound("KICK", in: folder)
        let snare = try nativeSound("SNARE", in: folder)
        let model = try testModel()
        await model.selectSampleRoot(folder)?.value
        model.sampleQuery = "kick"
        model.selectSample(kick)
        try FileManager.default.removeItem(at: kick)

        await model.refreshLocations().value

        XCTAssertEqual(model.sampleQuery, "kick")
        XCTAssertNil(model.selectedSampleURL)
        XCTAssertFalse(model.samplePreviewBusy)
        XCTAssertEqual(model.sampleListing.samples, [snare])
        model.selectSample(snare)
        model.samplePreviewBusy = true
        try FileManager.default.removeItem(at: folder)

        await model.refreshLocations().value

        XCTAssertEqual(model.sampleQuery, "kick")
        XCTAssertNil(model.selectedSampleURL)
        XCTAssertFalse(model.samplePreviewBusy)
        XCTAssertTrue(model.sampleListing.samples.isEmpty)
        XCTAssertNotNil(model.sampleListing.issue)
        XCTAssertTrue(model.sampleProblem?.contains("indisponible") == true)
    }

    @MainActor
    func testRefreshDisconnectedPartInvalidatesCachedSampleAndPendingPreview() async throws {
        let part = try directory("MPC-PART--S")
        let sample = try nativeSound("KICK", in: part)
        let model = try testModel()
        await model.selectSampleRoot(part)?.value
        model.selectSample(sample)
        model.sampleQuery = "kick"
        model.samplePreviewBusy = true
        model.partitions = [LibraryPartition(url: part, letter: "S", kits: [], fileCount: 1, folderCount: 0,
                                             audioCount: 1, sequenceCount: 0, issues: [], availableBytes: nil)]

        await model.refreshLocations().value

        XCTAssertNil(model.selectedSampleURL)
        XCTAssertFalse(model.samplePreviewBusy)
        XCTAssertEqual(model.sampleQuery, "kick")
        XCTAssertTrue(model.sampleListing.samples.isEmpty)
        XCTAssertTrue(model.sampleListing.issue?.contains("plus montée") == true)
        XCTAssertEqual(model.sampleProblem, "PART indisponible.")
    }

    @MainActor
    func testLateRefreshCannotReplaceNewerFolderNavigation() async throws {
        let root = try directory("Samples")
        let old = root.appendingPathComponent("Old", isDirectory: true)
        let next = root.appendingPathComponent("Next", isDirectory: true)
        let oldSample = old.appendingPathComponent("KICK.SND")
        let nextSample = next.appendingPathComponent("SNARE.SND")
        let requested = expectation(description: "Refresh is waiting")
        let gate = LibraryListingGate()
        let oldListing = LibraryFolderListing(folders: [], samples: [oldSample], issue: nil)
        defer { gate.release(oldListing) }
        let model = try testModel(sampleFolderLoader: { folder in
            if folder == old {
                requested.fulfill()
                return gate.wait()
            }
            return LibraryFolderListing(folders: [], samples: [nextSample], issue: nil)
        })
        model.selectedSampleRoot = old
        model.sampleFolder = old
        model.sampleListing = oldListing
        model.selectSample(oldSample)
        model.sampleQuery = "kick"
        let refresh = model.refreshLocations()
        await fulfillment(of: [requested], timeout: 3)

        await model.selectSampleRoot(next)?.value
        XCTAssertEqual(model.sampleQuery, "", "Choosing another source still resets the previous source's query.")
        XCTAssertNil(model.selectedSampleURL)
        model.selectSample(nextSample)
        model.sampleQuery = "snare"
        gate.release(oldListing)
        await refresh.value

        XCTAssertEqual(model.sampleFolder, next)
        XCTAssertEqual(model.sampleListing.samples, [nextSample])
        XCTAssertEqual(model.selectedSampleURL, nextSample)
        XCTAssertEqual(model.sampleQuery, "snare")
        XCTAssertNil(model.sampleProblem)
    }

    @MainActor
    func testRefreshValidatesTheLatestSampleSelectionInsteadOfRestoringItsOldSelection() async throws {
        let root = try directory("Samples")
        let kick = root.appendingPathComponent("KICK.SND")
        let snare = root.appendingPathComponent("SNARE.SND")
        let listing = LibraryFolderListing(folders: [], samples: [kick, snare], issue: nil)
        let requested = expectation(description: "Refresh is waiting")
        let gate = LibraryListingGate()
        defer { gate.release(listing) }
        let model = try testModel(sampleFolderLoader: { _ in
            requested.fulfill()
            return gate.wait()
        })
        model.selectedSampleRoot = root
        model.sampleFolder = root
        model.sampleListing = listing
        model.selectSample(kick)
        model.sampleQuery = "kick"
        let refresh = model.refreshLocations()
        await fulfillment(of: [requested], timeout: 3)

        model.selectSample(snare)
        model.sampleQuery = "snare"
        gate.release(listing)
        await refresh.value

        XCTAssertEqual(model.selectedSampleURL, snare)
        XCTAssertEqual(model.sampleQuery, "snare")
        XCTAssertNil(model.sampleProblem)
        XCTAssertEqual(model.filteredSamples, [snare])
    }

    @MainActor
    func testOlderFolderResultCannotReplaceTheLatestUnavailableFolder() async throws {
        let root = try directory("Samples")
        let old = root.appendingPathComponent("Old", isDirectory: true)
        let missing = root.appendingPathComponent("Disconnected", isDirectory: true)
        let oldListing = LibraryFolderListing(folders: [], samples: [old.appendingPathComponent("OLD.SND")], issue: nil)
        let requested = expectation(description: "Old scan is blocked before returning")
        let gate = LibraryListingGate()
        defer { gate.release(oldListing) }
        let model = try testModel(sampleFolderLoader: { folder in
            if folder == old.standardizedFileURL {
                requested.fulfill()
                return gate.wait()
            }
            return LibraryFolderListing(folders: [], samples: [], issue: "Disconnected source")
        })
        let previous = try XCTUnwrap(model.selectSampleRoot(old))
        await fulfillment(of: [requested], timeout: 3)
        let latest = try XCTUnwrap(model.selectSampleRoot(missing))
        await latest.value
        XCTAssertEqual(model.sampleListing.issue, "Disconnected source")
        gate.release(oldListing)
        await previous.value

        XCTAssertEqual(model.sampleFolder, missing.standardizedFileURL)
        XCTAssertTrue(model.sampleListing.samples.isEmpty)
        XCTAssertTrue(model.sampleListing.folders.isEmpty)
        XCTAssertEqual(model.sampleListing.issue, "Disconnected source")
        XCTAssertTrue(model.sampleProblem?.contains("indisponible") == true)
        XCTAssertEqual(model.sampleBrowserIssue, "Disconnected source")
    }

    @MainActor
    func testDisconnectedSourceClearsCachedListingAndKeepsTheKit() async throws {
        let folder = try directory("ExternalSource")
        let sample = try nativeSound("KICK", in: folder)
        let model = try testModel()
        await model.importURLs([sample], atPad: 0)?.value
        let before = try XCTUnwrap(model.program?.bytes)
        await model.selectSampleRoot(folder)?.value
        XCTAssertEqual(model.sampleListing.samples, [sample.standardizedFileURL])
        try FileManager.default.removeItem(at: folder)

        await model.refreshLocations().value

        XCTAssertTrue(model.sampleListing.samples.isEmpty)
        XCTAssertTrue(model.sampleListing.folders.isEmpty)
        XCTAssertNotNil(model.sampleListing.issue)
        XCTAssertNil(model.selectedSampleURL)
        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertEqual(model.padName(0), "KICK")
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testExportCollisionReportsActualCopyWhilePreservingLoadedOrigin() async throws {
        let source = try directory("Origin")
        let destination = try directory("LocalDestination")
        let sourceURL = try kit(in: source)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let originalSoundURL = source.appendingPathComponent("ORIGINAL.SND")
        let soundBytes = try Data(contentsOf: originalSoundURL)
        let collisionURL = destination.appendingPathComponent("SOULKIT.PGM")
        let collisionBytes = Data("existing file must survive".utf8)
        try collisionBytes.write(to: collisionURL)
        let model = try testModel()
        try await open(sourceURL, in: model)
        model.setKitName("SOULKIT")

        let task = try XCTUnwrap(model.exportKit(to: destination))
        await task.value

        let output = try XCTUnwrap(model.lastExportURL)
        XCTAssertEqual(output.lastPathComponent, "SOULKIT1.PGM")
        XCTAssertEqual(output.deletingLastPathComponent().resolvingSymlinksInPath(), destination.resolvingSymlinksInPath())
        XCTAssertEqual(model.programURL, sourceURL)
        XCTAssertEqual(model.kitName, "SOULKIT")
        XCTAssertTrue(model.isDirty, "A transport copy does not save the document in the local collection.")
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.status.contains("LocalDestination"))
        XCTAssertTrue(model.status.contains("SOULKIT1.PGM"))
        XCTAssertEqual(try Data(contentsOf: collisionURL), collisionBytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: originalSoundURL), soundBytes)
        XCTAssertEqual(try KitLoader.load(programURL: output).sounds.count, 1)
    }

    @MainActor
    func testFailedExportPreservesDirtyDocumentAndLastSuccessfulLocation() async throws {
        let folder = try directory("Source")
        let destination = try directory("LocalDestination")
        let sample = try nativeSound("KICK", in: folder)
        let model = try testModel()
        await model.importURLs([sample], atPad: 0)?.value
        model.setKitName("SAVED")
        await model.exportKit(to: destination)?.value
        let saved = try XCTUnwrap(model.lastExportURL)
        model.setKitName("EDITED")
        model.selectPad(32)
        let before = try XCTUnwrap(model.program?.bytes)
        let missing = destination.appendingPathComponent("ABSENT", isDirectory: true)

        let task = try XCTUnwrap(model.exportKit(to: missing))
        await task.value

        XCTAssertEqual(model.lastExportURL, saved)
        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertEqual(model.kitName, "EDITED")
        XCTAssertEqual(model.selectedPad, 32)
        XCTAssertEqual(model.bank, 2)
        XCTAssertEqual(model.padName(0), "KICK")
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.kitLocationPath.hasSuffix("SAVED.PGM"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    @MainActor
    func testFreshLocalExportIsIndexedUsingItsActualCollisionResolvedURL() async throws {
        let source = try directory("Source")
        let destination = try directory("LocalExports")
        let sample = try nativeSound("KICK", in: source)
        let existing = destination.appendingPathComponent("SOUL.PGM")
        try Data("keep this existing file".utf8).write(to: existing)
        let model = try testModel()
        await model.importURLs([sample], atPad: 0)?.value
        model.setKitName("SOUL")
        model.filterPrograms(to: source)
        XCTAssertTrue(model.libraryKits.isEmpty)

        await model.exportKit(to: destination)?.value
        await model.refreshLocations().value

        let output = try XCTUnwrap(model.lastExportURL)
        XCTAssertEqual(output.lastPathComponent, "SOUL1.PGM")
        XCTAssertTrue(model.libraryKits.contains { $0.url == output.standardizedFileURL })
        XCTAssertTrue(model.filteredKits.contains { $0.url == output.standardizedFileURL })
        XCTAssertNil(model.selectedLocation, "After a copy the whole list is shown, so the copy is visible")
        XCTAssertTrue(model.addedKitFolders.contains { $0.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() })
        XCTAssertTrue(model.isDirty, "A transport copy does not save the document in the local collection.")
        XCTAssertTrue(model.libraryIssue?.contains("SOUL.PGM") == true, "The pre-existing invalid PGM must remain visible as an unresolved association.")
        XCTAssertEqual(model.associations.association(for: existing)?.isComplete, false)
        XCTAssertEqual(model.associations.association(for: output)?.isComplete, true)
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep this existing file".utf8))
    }

    @MainActor
    func testSoundRenameUpdatesEverySharedPadWithoutChangingPCMAndRespectsBusyOrSameName() async throws {
        let source = try directory("Source")
        let sampleURL = try nativeSound("KICK", in: source)
        let sourceBytes = try Data(contentsOf: sampleURL)
        let model = try testModel()
        await model.importURLs([sampleURL], atPad: 0)?.value
        var shared = try XCTUnwrap(model.program)
        let slot = try XCTUnwrap(shared.slot(forNote: shared.midiNote(forPad: 0)))
        shared.assign(slot: slot, toNote: shared.midiNote(forPad: 16))
        model.program = shared
        model.selectPad(16)
        let beforeSample = try XCTUnwrap(model.sound)
        let beforeMemory = model.memoryBytes
        model.isDirty = false

        model.setSoundName("KICK")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.program?.bytes, shared.bytes)
        model.setSoundName("SOULKICK")

        var expected = shared
        expected.setSound(slot: slot, name: "SOULKICK", wordCount: beforeSample.frameCount * beforeSample.channels.count)
        XCTAssertEqual(model.program?.bytes, expected.bytes)
        XCTAssertEqual(model.program?.soundName(slot: slot), "SOULKICK")
        XCTAssertEqual(model.padName(0), "SOULKICK")
        XCTAssertEqual(model.padName(16), "SOULKICK")
        XCTAssertEqual(model.sound?.name, "SOULKICK")
        XCTAssertEqual(model.sound?.channels, beforeSample.channels)
        XCTAssertEqual(model.sound?.start, beforeSample.start)
        XCTAssertEqual(model.sound?.end, beforeSample.end)
        XCTAssertEqual(model.sound?.frameCount, beforeSample.frameCount)
        XCTAssertEqual(model.memoryBytes, beforeMemory)
        XCTAssertEqual(model.program?.referencedSlots, [slot])
        XCTAssertEqual(model.assignedPadCount, 2)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.selectedPad, 16)
        XCTAssertEqual(model.bank, 1)
        XCTAssertEqual(try Data(contentsOf: sampleURL), sourceBytes)

        model.isDirty = false
        model.busy = true
        model.setSoundName("BLOCKED")
        XCTAssertEqual(model.program?.bytes, expected.bytes)
        XCTAssertEqual(model.sound?.name, "SOULKICK")
        XCTAssertFalse(model.isDirty)
        model.busy = false
        model.setSoundName("SOULKICK")
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func testPendingDiscardBlocksDocumentActionsCancelKeepsTheKitAndApprovalCreatesANewKit() async throws {
        let source = try directory("Source")
        let sample = try nativeSound("KICK", in: source)
        var decisions: [(Bool) -> Void] = []
        let model = try testModel(discardPresenter: { decisions.append($0) })
        await model.importURLs([sample], atPad: 20)?.value
        model.setKitName("KEEP")
        let beforeProgram = try XCTUnwrap(model.program?.bytes)
        let beforeSound = try XCTUnwrap(model.sound)
        let beforeMemory = model.memoryBytes
        let beforeStatus = model.status
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(sample.dataRepresentation, nil)
            return nil
        }
        func assertUnchanged(_ action: String) {
            XCTAssertEqual(model.program?.bytes, beforeProgram, action)
            XCTAssertEqual(model.sound?.channels, beforeSound.channels, action)
            XCTAssertEqual(model.sound?.name, beforeSound.name, action)
            XCTAssertEqual(model.sound?.start, beforeSound.start, action)
            XCTAssertEqual(model.sound?.end, beforeSound.end, action)
            XCTAssertEqual(model.memoryBytes, beforeMemory, action)
            XCTAssertEqual(model.kitName, "KEEP", action)
            XCTAssertEqual(model.selectedPad, 20, action)
            XCTAssertEqual(model.bank, 1, action)
            XCTAssertEqual(model.status, beforeStatus, action)
            XCTAssertTrue(model.isDirty, action)
            XCTAssertFalse(model.busy, action)
        }

        model.newKit()
        XCTAssertTrue(model.awaitingDiscardConfirmation)
        XCTAssertTrue(model.documentActionsDisabled)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertNil(model.importURLs([sample], atPad: 0))
        assertUnchanged("import")
        XCTAssertFalse(model.dropFiles([provider], onPad: 0))
        assertUnchanged("drop")
        XCTAssertNil(model.exportKit(to: source))
        assertUnchanged("direct export")
        model.exportKit()
        XCTAssertFalse(model.showExportSheet)
        assertUnchanged("export sheet")
        model.newKit()
        model.openProgram(source.appendingPathComponent("OTHER.PGM"))
        XCTAssertEqual(decisions.count, 1, "A pending decision must not open a second confirmation.")
        assertUnchanged("new/open")
        model.setKitName("BLOCKED")
        assertUnchanged("kit name")
        model.setSoundName("BLOCKED")
        assertUnchanged("sample name")
        model.setTrim(start: 22, end: 400)
        assertUnchanged("trim")
        model.transform("normalize")
        assertUnchanged("transform")
        model.clearPad()
        assertUnchanged("clear")
        model.setPadTune(120)
        assertUnchanged("tune")
        model.selectPad(0)
        assertUnchanged("pad selection")
        model.assignSample(sample)
        assertUnchanged("sample assignment")

        let cancel = decisions.removeFirst()
        cancel(false)
        XCTAssertFalse(model.awaitingDiscardConfirmation)
        XCTAssertFalse(model.documentActionsDisabled)
        assertUnchanged("cancel")
        model.setKitName("UNLOCKED")
        XCTAssertEqual(model.kitName, "UNLOCKED")
        model.newKit()
        XCTAssertTrue(model.awaitingDiscardConfirmation)
        XCTAssertEqual(decisions.count, 1)
        let approve = decisions.removeFirst()
        approve(true)

        XCTAssertFalse(model.awaitingDiscardConfirmation)
        XCTAssertFalse(model.documentActionsDisabled)
        XCTAssertEqual(model.kitName, "NEWPROG")
        XCTAssertEqual(model.program?.name, "NEWPROG")
        XCTAssertTrue(model.program?.referencedSlots.isEmpty == true,
                      "The confirmation flag must clear before the approved continuation creates the blank document.")
        XCTAssertEqual(model.memoryBytes, 0)
        XCTAssertNil(model.sound)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.selectedPad, 0)
        XCTAssertEqual(model.bank, 0)
    }

    @MainActor
    func testExportSheetLocksDocumentEditingAndCancellationPreservesTheKit() async throws {
        let source = try directory("Source")
        let sample = try nativeSound("KICK", in: source)
        var confirmations = 0
        let model = try testModel(discardPresenter: { completion in
            confirmations += 1
            completion(false)
        })
        await model.importURLs([sample], atPad: 20)?.value
        let beforeProgram = try XCTUnwrap(model.program?.bytes)
        let beforeSound = try XCTUnwrap(model.sound)
        let beforeMemory = model.memoryBytes
        let beforeStatus = model.status
        let beforeName = model.kitName
        let beforeDirty = model.isDirty
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(sample.dataRepresentation, nil)
            return nil
        }

        model.exportKit()
        XCTAssertTrue(model.showExportSheet)
        XCTAssertTrue(model.documentActionsDisabled)
        XCTAssertFalse(model.documentLocked)
        model.setKitName("SHEETNAME")
        XCTAssertEqual(model.kitName, beforeName)
        XCTAssertNil(model.importURLs([sample], atPad: 0))
        XCTAssertFalse(model.dropFiles([provider], onPad: 0))
        XCTAssertNil(model.exportKit(to: source))
        model.newKit()
        model.openProgram(source.appendingPathComponent("OTHER.PGM"))
        model.setSoundName("BLOCKED")
        model.setTrim(start: 22, end: 400)
        model.transform("normalize")
        model.clearPad()
        model.setPadTune(120)
        model.selectPad(0)
        model.assignSample(sample)

        XCTAssertEqual(model.program?.bytes, beforeProgram)
        XCTAssertEqual(model.sound?.channels, beforeSound.channels)
        XCTAssertEqual(model.sound?.name, beforeSound.name)
        XCTAssertEqual(model.sound?.start, beforeSound.start)
        XCTAssertEqual(model.sound?.end, beforeSound.end)
        XCTAssertEqual(model.memoryBytes, beforeMemory)
        XCTAssertEqual(model.kitName, beforeName)
        XCTAssertEqual(model.selectedPad, 20)
        XCTAssertEqual(model.bank, 1)
        XCTAssertEqual(model.status, beforeStatus)
        XCTAssertEqual(model.isDirty, beforeDirty)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(confirmations, 0, "An export sheet must block attempts to open a discard confirmation.")
        model.showExportSheet = false
        XCTAssertFalse(model.documentActionsDisabled)
        XCTAssertEqual(model.program?.bytes, beforeProgram)
        XCTAssertEqual(model.kitName, beforeName)
        XCTAssertEqual(model.isDirty, beforeDirty)
        XCTAssertNil(model.lastExportURL)
        model.setKitName("AFTERCANCEL")
        XCTAssertEqual(model.kitName, "AFTERCANCEL")
        model.selectPad(21)
        XCTAssertEqual(model.selectedPad, 21)
    }

    @MainActor
    func testTreeNeverOpensAFolderWhoseAncestorBecameAnOutsideSymlink() async throws {
        let root = try directory("Samples")
        let outside = try directory("Outside")
        let ancestor = root.appendingPathComponent("Selected", isDirectory: true)
        let child = ancestor.appendingPathComponent("Drums", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let inside = try nativeSound("INSIDE", in: child)
        let outsideChild = outside.appendingPathComponent("Drums", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideChild, withIntermediateDirectories: false)
        _ = try nativeSound("OUTSIDE", in: outsideChild)
        let model = try testModel()
        await model.selectSampleRoot(root)?.value
        await model.toggleSampleFolder(ancestor)?.value
        await model.toggleSampleFolder(child)?.value
        XCTAssertTrue(model.sampleTreeRows.contains { $0.url == inside.standardizedFileURL })
        try FileManager.default.removeItem(at: ancestor)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: outside)

        model.selectSample(inside.standardizedFileURL)
        model.sampleQuery = "inside"
        await model.refreshLocations().value

        XCTAssertNil(model.selectedSampleURL, "A refresh must not leave a cached selection pointing outside its source.")
        XCTAssertFalse(model.samplePreviewBusy)
        XCTAssertEqual(model.sampleQuery, "inside")
        XCTAssertFalse(model.sampleTreeRows.contains { $0.name == "OUTSIDE.SND" })
        XCTAssertFalse(model.sampleTreeRows.contains { $0.name == "Selected" }, "A symbolic link is not a folder of the tree")
        XCTAssertFalse(model.sampleTreeListings.keys.contains { $0.path == child.standardizedFileURL.path })
        XCTAssertNil(model.program)
        XCTAssertFalse(model.isDirty)
    }


    private func fixtureMountedReceipt(_ url: URL) throws -> ExportDestination {
        let resolved = try XCTUnwrap(url.path.withCString { realpath($0, nil) })
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var info = stat()
        XCTAssertEqual(canonical.path.withCString { lstat($0, &info) }, 0)
        let occupied = Int64(info.st_blocks) * 512
        let environment = ExportDestination.Environment(
            mount: { _ in .init(filesystem: "msdos", identifier: "fixture", mountedFrom: "fixture", mountPoint: canonical) },
            fatUsage: { _ in .init(allocationUnitBytes: 8192, occupiedBytes: occupied) }
        )
        return try ExportDestination.capture(at: url, environment: environment)
    }

    @MainActor
    func testCopySizeEstimateMatchesExportAfterSharedAssignmentsAndSampleChanges() async throws {
        let source = try directory("Source")
        let destination = try directory("Destination")
        let url = source.appendingPathComponent("STEREO.SND")
        let audio = MPCSound(name: "STEREO", channels: [Array(repeating: 0.25, count: 512), Array(repeating: -0.25, count: 512)])
        var sourceBytes = try audio.encoded()
        sourceBytes.append(Data(repeating: 0xA5, count: 79))
        try sourceBytes.write(to: url)
        let model = try testModel()
        await model.importURLs([url], atPad: 0)?.value
        var program = try XCTUnwrap(model.program)
        let slot = try XCTUnwrap(program.slot(forNote: program.midiNote(forPad: 0)))
        program.assign(slot: slot, toNote: program.midiNote(forPad: 1))
        program.setSound(slot: 91, name: "UNUSED", wordCount: 999_999)
        model.program = program
        let stereoSize = try XCTUnwrap(model.estimatedExportBytes)
        XCTAssertEqual(stereoSize, Int64(try audio.encoded().count + program.bytes.count))
        model.selectPad(0)
        model.transform("mono")
        let monoSize = try XCTUnwrap(model.estimatedExportBytes)
        XCTAssertEqual(stereoSize - monoSize, 512 * 2)

        await model.exportKit(to: destination)?.value
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastExportURL)
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { ["SND", "PGM"].contains($0.pathExtension.uppercased()) }
        XCTAssertEqual(files.count, 2, "A shared slot is exported once; an unused inventory name is omitted.")
        let actual = try files.reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: $1).count) }
        XCTAssertEqual(monoSize, actual)
        XCTAssertEqual(try Data(contentsOf: url), sourceBytes, "Estimation and export preserve the original SND, including its trailing bytes.")
    }

    @MainActor
    func testMissingCopyContentHasNoSizeOrAutomaticCapacityRecommendation() async throws {
        let source = try directory("Source")
        let sample = try nativeSound("KICK", in: source)
        let model = try testModel()
        await model.importURLs([sample], atPad: 0)?.value
        var program = try XCTUnwrap(model.program)
        program.assign(slot: 91, toNote: program.midiNote(forPad: 1))
        model.program = program
        XCTAssertNil(model.estimatedExportBytes)
        XCTAssertEqual(model.exportSizeLabel, "Taille indisponible")
        XCTAssertEqual(model.requiredExportFreeBytes, Int64.max)
        let part = try directory("MPC-PART--S")
        model.partitions = [LibraryPartition(url: part, letter: "S", kits: [], fileCount: 0,
                                             folderCount: 0, audioCount: 0, sequenceCount: 0, issues: [],
                                             availableBytes: 8_000_000, exportDestination: try fixtureMountedReceipt(part))]
        XCTAssertNil(model.recommendedSDPartition)
    }

    @MainActor
    func testAutomaticExportRecommendationRequiresAnEmptyPartWithKnownSufficientSpace() async throws {
        let folder = try directory("Source")
        let sample = try nativeSound("KICK", in: folder)
        let model = try testModel()
        await model.importURLs([sample], atPad: 0)?.value
        let required = model.requiredExportFreeBytes
        XCTAssertGreaterThan(required, try XCTUnwrap(model.estimatedExportBytes),
                             "Allocation and directory overhead must be reserved in addition to file bytes.")
        func part(_ letter: String, files: Int = 0, folders: Int = 0, audio: Int = 0,
                  issues: [String] = [], available: Int64?, verifiedMount: Bool = true) throws -> LibraryPartition {
            let url = folder.appendingPathComponent("MPC-PART--" + letter, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let receipt = verifiedMount ? try fixtureMountedReceipt(url) : nil
            return LibraryPartition(url: url, letter: letter,
                                    kits: [], fileCount: files, folderCount: folders, audioCount: audio,
                                    sequenceCount: 0, issues: issues, availableBytes: available,
                                    exportDestination: receipt)
        }
        let occupiedWithSamplesOnly = try part("A", files: 1, audio: 1, available: required * 2)
        let occupiedWithUnknownFile = try part("B", files: 1, available: required * 2)
        let occupiedWithFolder = try part("C", folders: 1, available: required * 2)
        let incompleteScan = try part("D", issues: ["Read incomplete"], available: required * 2)
        let tooSmall = try part("E", available: required - 1)
        let unknownSpace = try part("F", available: nil)
        let exactFit = try part("S", available: required)
        let larger = try part("Z", available: required * 2)
        let unverifiedMount = try part("G", available: required * 2, verifiedMount: false)
        let unsuitable = [occupiedWithSamplesOnly, occupiedWithUnknownFile, occupiedWithFolder,
                          incompleteScan, tooSmall, unknownSpace, unverifiedMount]
        model.partitions = unsuitable + [exactFit, larger]
        model.exportDestinationURL = folder

        XCTAssertEqual(model.recommendedSDPartition, exactFit)
        model.exportKit()

        XCTAssertEqual(model.exportDestinationURL, exactFit.url)
        XCTAssertTrue(model.exportDestinationReceipt?.requireEmpty == true,
                      "The original proposal identity must remain coupled to a fresh empty check at write time.")
        XCTAssertTrue(model.showExportSheet, "A recommended destination still requires the export review sheet.")
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
        model.showExportSheet = false
        model.partitions = unsuitable
        XCTAssertNil(model.recommendedSDPartition)
        model.exportKit()
        XCTAssertNil(model.exportDestinationURL)
        XCTAssertTrue(model.showExportSheet)
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testLocationFilterNarrowsProgramsToOneSource() throws {
        let a = try directory("MPC-PART--A")
        let s = try directory("MPC-PART--S")
        let first = LibraryKit(url: a.appendingPathComponent("KIT.PGM"), rootURL: a, partitionLetter: "A", relativeFolder: "")
        let second = LibraryKit(url: s.appendingPathComponent("Live/KIT.PGM"), rootURL: s, partitionLetter: "S", relativeFolder: "Live")
        let model = try testModel()
        model.libraryKits = [first, second]
        model.filterPrograms(to: a)
        XCTAssertEqual(model.filteredKits, [first])
        model.filterPrograms(to: s)
        XCTAssertEqual(model.filteredKits, [second])
        model.filterPrograms(to: nil)
        XCTAssertEqual(model.filteredKits, [first, second])
    }

    @MainActor
    func testExportSheetCarriesSelectedFolderIdentityAndRefusesAReplacementBeforeAnyWrite() async throws {
        let source = try directory("Source")
        let destination = try directory("LocalDestination")
        let original = destination.appendingPathComponent("KEEP.SND")
        let originalBytes = Data("preserve the selected folder".utf8)
        try originalBytes.write(to: original)
        let sample = try nativeSound("KICK", in: source)
        let model = try testModel()
        await model.importURLs([sample], atPad: 0)?.value
        model.exportKit()
        await model.selectExportFolder(destination)?.value
        XCTAssertNotNil(model.exportDestinationReceipt)
        XCTAssertNil(model.exportDestinationIssue)
        let displaced = destination.deletingLastPathComponent().appendingPathComponent("OriginalDestination")
        try FileManager.default.moveItem(at: destination, to: displaced)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let finished = expectation(description: "Stale selected destination refused")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }

        model.exportKitToDestination()
        await fulfillment(of: [finished], timeout: 3)
        observation.cancel()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.lastExportURL)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.padName(0), "KICK")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: displaced.appendingPathComponent("KEEP.SND")), originalBytes)
    }

    @MainActor
    func testManualPartSelectionRefusesUnverifiedSnapshotsAndLocksAPreviouslyEmptyChoice() async throws {
        let source = try directory("Source")
        let local = try directory("LocalDestination")
        let partURL = try directory("MPC-PART--S")
        let receipt = try fixtureMountedReceipt(partURL)
        let empty = LibraryPartition(url: partURL, letter: "S", kits: [], fileCount: 0, folderCount: 0,
                                     audioCount: 0, sequenceCount: 0, issues: [], availableBytes: 8_000_000,
                                     exportDestination: receipt)
        let suspect = LibraryPartition(url: partURL, letter: "S", kits: [], fileCount: 0, folderCount: 0,
                                       audioCount: 0, sequenceCount: 0, issues: ["FAT inventory incomplete"],
                                       availableBytes: 8_000_000, exportDestination: receipt)
        let sample = try nativeSound("KICK", in: source)
        let model = try testModel()
        await model.importURLs([sample], atPad: 0)?.value
        model.exportKit()
        await model.selectExportFolder(local)?.value
        let originalReceipt = model.exportDestinationReceipt

        model.selectExportPartition(suspect)
        XCTAssertEqual(model.exportDestinationURL, local)
        XCTAssertEqual(model.exportDestinationReceipt, originalReceipt)
        model.selectExportPartition(empty)
        XCTAssertEqual(model.exportDestinationURL, partURL)
        XCTAssertTrue(model.exportDestinationReceipt?.requireEmpty == true)
        model.partitions = [suspect]
        XCTAssertNotNil(model.exportDestinationIssue)
        model.exportKitToDestination()

        XCTAssertTrue(model.showExportSheet)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.lastExportURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: partURL.path).isEmpty)
    }
}

private final class LibraryDeferredProvider: @unchecked Sendable {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?

    func store(_ value: @escaping (Data?, Error?) -> Void) {
        lock.lock()
        completion = value
        lock.unlock()
    }

    func complete(_ data: Data) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(data, nil)
    }
}

// Only the background loader waits; the test controls exactly when an old snapshot returns.
private final class LibraryListingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var listing: LibraryFolderListing?

    func wait() -> LibraryFolderListing {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while listing == nil {
            if !condition.wait(until: deadline) {
                return LibraryFolderListing(folders: [], samples: [], issue: "Test gate timed out")
            }
        }
        return listing!
    }

    func release(_ value: LibraryFolderListing) {
        condition.lock()
        listing = value
        condition.broadcast()
        condition.unlock()
    }
}
