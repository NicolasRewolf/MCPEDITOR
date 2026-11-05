import AppKit
import Combine
import Foundation
import MPCCore
import XCTest
@testable import KitStudio

final class WorkflowEditingTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Workflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func model(root: URL, decision: StudioModel.UnsavedPresenter? = nil,
                       folders: [URL] = []) throws -> StudioModel {
        let suite = "Workflow-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(folders.map(\.path), forKey: "library.kitFolders")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return StudioModel(defaults: defaults, localLibraryURL: root,
                           unsavedPresenter: decision, volumeProvider: { [] })
    }

    private func sample(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("KICK.SND")
        let pcm = (0..<1024).map { Float($0 % 100) / 200 }
        try MPCSound(name: "KICK", channels: [pcm]).encoded().write(to: url)
        return url
    }

    @MainActor
    private func open(_ url: URL, in model: StudioModel) async throws {
        let done = expectation(description: "program opened")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in done.fulfill() }
        model.openProgram(url)
        await fulfillment(of: [done], timeout: 5)
        observation.cancel()
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testFiveEditsUndoToSavedAudioAndProgramThenRedoExactly() async throws {
        let folder = try directory()
        let model = try model(root: folder.appendingPathComponent("Library"))
        model.newKit()
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        await model.saveProgram()?.value
        let originalBytes = model.program?.bytes
        let originalSound = try XCTUnwrap(model.sound)
        model.setSoundName("SNARE")
        model.setTrim(start: 10, end: 900)
        model.transform("reverse")
        model.setPadTune(12)
        model.clearPad()
        let finalBytes = model.program?.bytes
        XCTAssertTrue(model.isDirty)
        for _ in 0..<5 { XCTAssertTrue(model.canUndo); model.undo() }
        XCTAssertEqual(model.program?.bytes, originalBytes)
        XCTAssertEqual(model.sound?.channels, originalSound.channels)
        XCTAssertEqual(model.sound?.start, originalSound.start)
        XCTAssertEqual(model.sound?.end, originalSound.end)
        XCTAssertEqual(model.sound?.name, originalSound.name)
        XCTAssertFalse(model.isDirty)
        for _ in 0..<5 { XCTAssertTrue(model.canRedo); model.redo() }
        XCTAssertEqual(model.program?.bytes, finalBytes)
        XCTAssertNil(model.sound)
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testRepeatedSaveKeepsOneVisibleProgramAndReopensWithoutSource() async throws {
        let folder = try directory()
        let root = folder.appendingPathComponent("Library")
        let source = try sample(in: folder)
        let sourceBytes = try Data(contentsOf: source)
        let model = try model(root: root)
        await model.importURLs([source], atPad: 0)?.value
        model.setKitName("SOUL")
        await model.saveProgram()?.value
        let first = try XCTUnwrap(model.localSaveURL)
        model.setPadTune(15)
        model.selectedLocation = folder.appendingPathComponent("OtherSource")
        model.kitSearch = "hidden by a previous search"
        await model.saveProgram()?.value
        let latest = try XCTUnwrap(model.localSaveURL)
        XCTAssertNotEqual(first, latest)
        await model.refreshLocations().value
        // A refresh requested during an existing scan is deliberately coalesced.
        await model.refreshLocations().value
        XCTAssertEqual(model.libraryKits.map(\.url), [latest])
        XCTAssertEqual(model.filteredKits.map(\.url), [latest])
        XCTAssertEqual(model.libraryMode, .kits)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        try FileManager.default.removeItem(at: source)
        let reopened = try self.model(root: root)
        await reopened.refreshLocations().value
        XCTAssertEqual(reopened.libraryKits.map(\.url), [latest])
        try await open(latest, in: reopened)
        XCTAssertEqual(reopened.padTune, 15)
        XCTAssertEqual(reopened.padName(0), "KICK")
        XCTAssertEqual(reopened.localSaveURL, latest)
        XCTAssertEqual(reopened.documentSaveLabel, "Enregistré sur le Mac")
    }

    @MainActor
    func testCopyDoesNotRenameOrSaveEditedLocalMaster() async throws {
        let folder = try directory()
        let model = try model(root: folder.appendingPathComponent("Library"))
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        model.setKitName("SOUL")
        await model.saveProgram()?.value
        let master = try XCTUnwrap(model.localSaveURL)
        let before = try Data(contentsOf: master)
        model.setPadTune(8)
        let copies = folder.appendingPathComponent("Transport")
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: false)
        try Data("existing".utf8).write(to: copies.appendingPathComponent("SOUL.PGM"))
        await model.exportKit(to: copies)?.value
        XCTAssertEqual(model.lastExportURL?.lastPathComponent, "SOUL1.PGM")
        XCTAssertEqual(model.localSaveURL, master)
        XCTAssertEqual(model.programURL, master)
        XCTAssertEqual(model.kitName, "SOUL")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(try Data(contentsOf: master), before)
        model.undo()
        XCTAssertFalse(model.isDirty)
        model.redo()
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testSaveChoiceBeforeNewPreservesProgramOnMac() async throws {
        let folder = try directory()
        let root = folder.appendingPathComponent("Library")
        let model = try model(root: root, decision: { $0(.save) })
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        model.setKitName("KEEP")
        let newDocument = expectation(description: "new after save")
        let observation = model.$kitName.filter { $0 == "NEWPROG" }.sink { _ in newDocument.fulfill() }
        model.newKit()
        await fulfillment(of: [newDocument], timeout: 5)
        observation.cancel()
        XCTAssertEqual(model.assignedPadCount, 0)
        XCTAssertFalse(model.isDirty)
        let entries = try LocalProgramStore(rootURL: root).scanKits()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(try KitLoader.load(programURL: XCTUnwrap(entries.first?.url)).sounds.count, 1)
    }

    @MainActor
    func testFailedSaveChoiceDoesNotCloseOrDiscard() async throws {
        let folder = try directory()
        let blocked = folder.appendingPathComponent("NotDirectory")
        try Data("preserve".utf8).write(to: blocked)
        let model = try model(root: blocked, decision: { $0(.save) })
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        let before = model.program?.bytes
        let finished = expectation(description: "save refused")
        model.requestClose { approved in XCTAssertFalse(approved); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.assignedPadCount, 1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("preserve".utf8))
    }

    @MainActor
    func testMoveEditedPadAcrossBanksAndUndoPreservesAudioAndTune() async throws {
        let folder = try directory()
        let model = try model(root: folder.appendingPathComponent("Library"))
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        model.transform("reverse")
        model.setPadTune(25)
        let pcm = model.sound?.channels
        let before = model.program?.bytes
        model.padTransfer(from: 0, to: 49)
        XCTAssertEqual(model.padName(0), "—")
        XCTAssertEqual(model.selectedPad, 49)
        XCTAssertEqual(model.padTune, 25)
        XCTAssertEqual(model.sound?.channels, pcm)
        model.undo()
        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertEqual(model.selectedPad, 0)
        XCTAssertEqual(model.sound?.channels, pcm)
        model.redo()
        model.padTransfer(from: 49, to: 1, copy: true)
        XCTAssertEqual(model.assignedPadCount, 2)
        XCTAssertEqual(model.padTune, 25)
        XCTAssertEqual(model.sound?.channels, pcm)
    }

    @MainActor
    func testLibrarySamplesVisibleWithoutSDAndBackRestoresSearchAndSelection() async throws {
        let folder = try directory()
        let model = try model(root: folder.appendingPathComponent("Library"))
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        await model.saveProgram()?.value
        await model.refreshLocations().value
        await model.refreshLocations().value
        XCTAssertEqual(model.sampleScope, .library)
        let sample = try XCTUnwrap(model.filteredSamples.first)
        model.sampleQuery = "KICK"
        model.selectSample(sample)
        let saved = try XCTUnwrap(model.libraryKits.first)
        model.showSamples(in: saved)
        model.goBackInSamples()
        XCTAssertEqual(model.sampleScope, .library)
        XCTAssertEqual(model.sampleQuery, "KICK")
        XCTAssertEqual(model.selectedSampleURL, sample)
        XCTAssertEqual(model.filteredSamples, [sample])
    }
    @MainActor
    func testTrashingLocalMasterAfterCopyInvalidatesSavedStateButPreservesAudio() async throws {
        let folder = try directory()
        let root = folder.appendingPathComponent("Library")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkflowTrash-" + UUID().uuidString))
        let trash = folder.appendingPathComponent("Trashed.PGM")
        let model = StudioModel(defaults: defaults, localLibraryURL: root,
            trashPresenter: { _, decide in decide(true) }, trashOperation: { source in
                try FileManager.default.moveItem(at: source, to: trash)
                return trash
            }, volumeProvider: { [] })
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        await model.saveProgram()?.value
        let saved = try XCTUnwrap(model.localSaveURL)
        await model.exportKit(to: folder)?.value
        let copy = try XCTUnwrap(model.lastExportURL)
        let finished = expectation(description: "local program trashed")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        let kit = LibraryKit(url: saved, rootURL: root, partitionLetter: nil, relativeFolder: "")
        await model.requestTrashKit(kit)?.value
        await fulfillment(of: [finished], timeout: 5)
        observation.cancel()
        XCTAssertNil(model.localSaveURL)
        XCTAssertNil(model.programURL)
        XCTAssertEqual(model.lastExportURL, copy)
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.sound)
        model.undo()
        XCTAssertTrue(model.isDirty, "Undo cannot claim a deleted source is still saved.")
        model.redo()
        XCTAssertEqual(model.assignedPadCount, 1)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
    }

    @MainActor
    func testCleanSaveDoesNotGenerateAnotherRevision() async throws {
        let folder = try directory()
        let model = try model(root: folder.appendingPathComponent("Library"))
        await model.importURLs([try sample(in: folder)], atPad: 0)?.value
        await model.saveProgram()?.value
        let saved = model.localSaveURL
        XCTAssertNil(model.saveProgram())
        XCTAssertEqual(model.localSaveURL, saved)
        XCTAssertFalse(model.isDirty)
    }

}
