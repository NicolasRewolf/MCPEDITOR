import Combine
import Foundation
@testable import MPCCore
@testable import KitStudio
import XCTest

final class KitTrashTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let program: URL
        let sample: URL
        let sequence: URL
        let trash: URL
        var kit: LibraryKit { LibraryKit(url: program, rootURL: root, partitionLetter: nil, relativeFolder: "") }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KitTrashTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let programURL = root.appendingPathComponent("SOUL.PGM")
        let sampleURL = root.appendingPathComponent("KICK.SND")
        let sequenceURL = root.appendingPathComponent("GROOVE.SEQ")
        let trash = root.appendingPathComponent("TestTrash", isDirectory: true)
        let sound = MPCSound(name: "KICK", channels: [Array(repeating: 0.25, count: 441)])
        try sound.encoded().write(to: sampleURL)
        var program = MPCProgram.blank(name: "SOUL")
        program.setSound(slot: 0, name: "KICK", wordCount: 441)
        program.assign(slot: 0, toNote: program.midiNote(forPad: 0))
        try program.bytes.write(to: programURL)
        try Data("sequence stays untouched".utf8).write(to: sequenceURL)
        return Fixture(root: root, program: programURL, sample: sampleURL, sequence: sequenceURL, trash: trash)
    }

    @MainActor
    private func model(_ fixture: Fixture, presenter: StudioModel.TrashPresenter? = nil,
                       operation: @escaping KitTrash.Operation) throws -> StudioModel {
        let suite = "KitTrashTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set([fixture.root.path], forKey: "library.kitFolders")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return StudioModel(defaults: defaults, localLibraryURL: FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString), trashPresenter: presenter,
                           trashOperation: operation, volumeProvider: { [] })
    }

    @MainActor
    private func open(_ url: URL, model: StudioModel) async {
        let finished = expectation(description: "Program opened")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        model.openProgram(url)
        await fulfillment(of: [finished], timeout: 3)
        observation.cancel()
        XCTAssertNil(model.errorMessage)
    }

    func testHelperMovesOnlyTheProgramToAnInjectedReversibleTrash() throws {
        let fixture = try fixture()
        let originalProgram = try Data(contentsOf: fixture.program)
        let originalSample = try Data(contentsOf: fixture.sample)
        let originalSequence = try Data(contentsOf: fixture.sequence)
        let recorder = TrashRecorder(destination: fixture.trash)
        let prepared = try KitTrash.prepare(fixture.program)

        let result = try KitTrash.move(prepared, operation: { try recorder.move($0) })

        XCTAssertEqual(recorder.calls, 1)
        XCTAssertEqual(result, fixture.trash.appendingPathComponent("SOUL.PGM"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result)), originalProgram)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.program.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sample), originalSample)
        XCTAssertEqual(try Data(contentsOf: fixture.sequence), originalSequence)
    }

    func testHelperRefusesAReplacedProgramBeforeCallingTrash() throws {
        let fixture = try fixture()
        let recorder = TrashRecorder(destination: fixture.trash)
        let prepared = try KitTrash.prepare(fixture.program)
        let displaced = fixture.root.appendingPathComponent("PRESERVED.PGM")
        try FileManager.default.moveItem(at: fixture.program, to: displaced)
        let replacement = MPCProgram.blank(name: "OTHER").bytes
        try replacement.write(to: fixture.program)

        XCTAssertThrowsError(try KitTrash.move(prepared, operation: { try recorder.move($0) }))

        XCTAssertEqual(recorder.calls, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.program), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
    }

    func testHelperRefusesInPlaceEditsAndNonPrograms() throws {
        let fixture = try fixture()
        let recorder = TrashRecorder(destination: fixture.trash)
        let prepared = try KitTrash.prepare(fixture.program)
        let handle = try FileHandle(forWritingTo: fixture.program)
        try handle.seek(toOffset: 100)
        try handle.write(contentsOf: Data([42]))
        try handle.close()

        XCTAssertThrowsError(try KitTrash.move(prepared, operation: { try recorder.move($0) }))
        XCTAssertThrowsError(try KitTrash.prepare(fixture.sample))

        XCTAssertEqual(recorder.calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.program.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sample.path))
    }

    func testHelperRefusesDuplicateNativeProgramNamesAndSymlinks() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try KitTrash.prepare(fixture.program, directoryEntries: { _ in
            ["SOUL.PGM", "SOUL.PGM", "KICK.SND"]
        })) { error in
            guard case KitTrash.Failure.ambiguous = error else { return XCTFail("Expected duplicate-name refusal, got \(error)") }
        }
        XCTAssertThrowsError(try KitTrash.prepare(fixture.program, directoryEntries: { _ in ["SOUL.PGM", "soul.pgm"] }))
        let link = fixture.root.appendingPathComponent("LINK.PGM")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.program)
        XCTAssertThrowsError(try KitTrash.prepare(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.program.path))
    }

    func testTrashFailureDoesNotFallBackToDeletingTheProgram() throws {
        let fixture = try fixture()
        let before = try Data(contentsOf: fixture.program)
        let prepared = try KitTrash.prepare(fixture.program)

        XCTAssertThrowsError(try KitTrash.move(prepared, operation: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        })) { error in
            XCTAssertTrue(error.localizedDescription.contains("ne force jamais l’effacement"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.program), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sample.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sequence.path))
    }

    func testTrashPreparationRefusesAnOrdinaryFolderPretendingToBeAMountedPart() throws {
        let fixture = try fixture()
        let placeholder = fixture.root.appendingPathComponent("MPC-PART--S", isDirectory: true)
        try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: false)
        let candidate = placeholder.appendingPathComponent("SOUL.PGM")
        let before = try Data(contentsOf: fixture.program)
        try before.write(to: candidate)

        XCTAssertThrowsError(try KitTrash.prepare(candidate))

        XCTAssertEqual(try Data(contentsOf: candidate), before)
        XCTAssertEqual(try Data(contentsOf: fixture.program), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sample.path))
    }

    @MainActor
    func testCancelConfirmationMakesNoTrashCallAndBlocksDocumentMutationsWhilePending() async throws {
        let fixture = try fixture()
        let recorder = TrashRecorder(destination: fixture.trash)
        var decisions: [(Bool) -> Void] = []
        var confirmedURL: URL?
        let model = try model(fixture, presenter: { prepared, completion in
            confirmedURL = prepared.url
            decisions.append(completion)
        }, operation: { try recorder.move($0) })
        await open(fixture.program, model: model)
        model.setKitName("EDITED")
        let before = try XCTUnwrap(model.program?.bytes)
        let sample = try Data(contentsOf: fixture.sample)
        let sequence = try Data(contentsOf: fixture.sequence)

        await model.requestTrashKit(fixture.kit)?.value
        XCTAssertEqual(confirmedURL, fixture.program)
        XCTAssertTrue(model.awaitingKitTrashConfirmation)
        XCTAssertTrue(model.documentActionsDisabled)
        model.setKitName("BLOCKED")
        model.clearPad()
        model.newKit()
        XCTAssertNil(model.importURLs([fixture.sample], atPad: 1))
        XCTAssertNil(model.exportKit(to: fixture.root))
        XCTAssertNil(model.requestTrashKit(fixture.kit))
        XCTAssertEqual(decisions.count, 1)
        decisions.removeFirst()(false)

        XCTAssertEqual(recorder.calls, 0)
        XCTAssertFalse(model.awaitingKitTrashConfirmation)
        XCTAssertFalse(model.documentActionsDisabled)
        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertEqual(model.kitName, "EDITED")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.programURL, fixture.program)
        XCTAssertEqual(try Data(contentsOf: fixture.sample), sample)
        XCTAssertEqual(try Data(contentsOf: fixture.sequence), sequence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.program.path))
    }

    @MainActor
    func testSuccessfulTrashRemovesKitFromLibraryButKeepsOpenMemoryAndAllAudio() async throws {
        let fixture = try fixture()
        let recorder = TrashRecorder(destination: fixture.trash)
        var decision: ((Bool) -> Void)?
        let model = try model(fixture, presenter: { _, completion in decision = completion }, operation: { try recorder.move($0) })
        await model.refreshLocations().value
        XCTAssertTrue(model.libraryKits.contains(fixture.kit))
        await open(fixture.program, model: model)
        let beforeProgram = try XCTUnwrap(model.program?.bytes)
        let beforeSample = try XCTUnwrap(model.sound)
        let sample = try Data(contentsOf: fixture.sample)
        let sequence = try Data(contentsOf: fixture.sequence)
        await model.requestTrashKit(fixture.kit)?.value
        let finished = expectation(description: "Trash finishes")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }

        try XCTUnwrap(decision)(true)
        await fulfillment(of: [finished], timeout: 3)
        observation.cancel()
        await model.refreshLocations().value

        XCTAssertEqual(recorder.calls, 1)
        XCTAssertFalse(model.libraryKits.contains(fixture.kit))
        XCTAssertFalse(model.documentActionsDisabled)
        XCTAssertNil(model.programURL)
        XCTAssertNil(model.lastExportURL)
        XCTAssertTrue(model.isDirty, "The detached open kit must remain available for a new save.")
        XCTAssertEqual(model.program?.bytes, beforeProgram)
        XCTAssertEqual(model.sound?.channels, beforeSample.channels)
        XCTAssertEqual(model.assignedPadCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.sample), sample)
        XCTAssertEqual(try Data(contentsOf: fixture.sequence), sequence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trash.appendingPathComponent("SOUL.PGM").path))
    }

    @MainActor
    func testFailedTrashKeepsLoadedDocumentAndLibraryEntry() async throws {
        let fixture = try fixture()
        var decision: ((Bool) -> Void)?
        let model = try model(fixture, presenter: { _, completion in decision = completion }, operation: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        })
        await model.refreshLocations().value
        await open(fixture.program, model: model)
        let before = try XCTUnwrap(model.program?.bytes)
        await model.requestTrashKit(fixture.kit)?.value
        let finished = expectation(description: "Trash refuses")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }

        try XCTUnwrap(decision)(true)
        await fulfillment(of: [finished], timeout: 3)
        observation.cancel()

        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertEqual(model.programURL, fixture.program)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.documentActionsDisabled)
        XCTAssertTrue(model.libraryKits.contains(fixture.kit))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.program.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sample.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sequence.path))
    }

    @MainActor
    func testDisconnectedKnownPartIsUnavailableEvenIfAnAPFSFolderStillExistsThere() async throws {
        let fixture = try fixture()
        let part = fixture.root.appendingPathComponent("MPC-PART--S", isDirectory: true)
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: false)
        let leftover = part.appendingPathComponent("LEFTOVER.SND")
        try Data("an ordinary APFS directory is not a mounted card".utf8).write(to: leftover)
        let model = try model(fixture, operation: { _ in XCTFail("No trash expected"); return nil })
        model.partitions = [LibraryPartition(url: part, letter: "S", kits: [], fileCount: 0, folderCount: 0,
                                            audioCount: 0, sequenceCount: 0, issues: [], availableBytes: 8_000_000)]

        await model.refreshLocations().value
        let snapshot = try XCTUnwrap(model.partitions.first)

        XCTAssertEqual(snapshot.url, part)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertFalse(snapshot.issues.isEmpty)
        XCTAssertNil(snapshot.availableBytes)
        XCTAssertNil(model.recommendedSDPartition)
        XCTAssertNil(model.selectSampleRoot(part), "An unmounted PART is not read")
        XCTAssertTrue(model.sampleListing.samples.isEmpty)
        XCTAssertNotNil(model.sampleListing.issue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
    }
}

/// Local fixtures exercise reversible moves without using the user's system Trash.
private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let destination: URL
    init(destination: URL) { self.destination = destination }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func move(_ url: URL) throws -> URL? {
        lock.lock(); count += 1; lock.unlock()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = destination.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: output)
        return output
    }
}
