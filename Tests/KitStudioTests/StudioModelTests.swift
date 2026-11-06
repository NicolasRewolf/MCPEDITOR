import Foundation
import XCTest
import AppKit
import Combine
import UniformTypeIdentifiers
import MPCCore
@testable import KitStudio

final class StudioModelTests: XCTestCase {
    private let urls = [URL(fileURLWithPath: "/FIRST.wav"), URL(fileURLWithPath: "/SECOND.wav")]

    private func sample(_ name: String = "TEST", frames: Int = 441) -> MPCSound {
        MPCSound(name: name, channels: [Array(repeating: 0.25, count: frames)])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioModelTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testImportRejectsBatchPastD16BeforeDecodingAnyFile() throws {
        var attempts = 0
        XCTAssertThrowsError(try StudioModel.prepareImport(
            urls, atPad: 63, program: .blank(name: "BEFORE"), sounds: [:]
        ) { _, _ in
            attempts += 1
            return self.sample()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("2 samples"))
            XCTAssertTrue(error.localizedDescription.contains("1 pads"))
            XCTAssertTrue(error.localizedDescription.contains("D16"))
        }
        XCTAssertEqual(attempts, 0)
    }

    func testImportRejectsInvalidStartingPadBeforeDecoding() throws {
        for pad in [-1, 64, 100] {
            XCTAssertThrowsError(try StudioModel.prepareImport(
                [urls[0]], atPad: pad, program: .blank(name: "BEFORE"), sounds: [:]
            ) { _, _ in
                XCTFail("An invalid pad must not decode a file.")
                return self.sample()
            })
        }
    }

    func testImportRejectsAliasedTargetPadsBeforeDecodingAndPreservesProgram() throws {
        var initial = MPCProgram.blank(name: "ALIASED")
        let padMap = 2690 + 1854
        initial.bytes[padMap + 1] = initial.bytes[padMap]
        initial.assign(slot: 9, toNote: initial.midiNote(forPad: 0))
        initial.setSound(slot: 9, name: "OLD", wordCount: 441)
        let before = initial.bytes
        XCTAssertThrowsError(try StudioModel.prepareImport(
            urls, atPad: 0, program: initial, sounds: [9: sample("OLD")]
        ) { _, _ in
            XCTFail("Aliased target pads must fail before any file is decoded.")
            return self.sample()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("même note MIDI"))
        }
        XCTAssertEqual(initial.bytes, before)
        XCTAssertEqual(initial.slot(forNote: initial.midiNote(forPad: 0)), 9)
    }

    func testImportRejectsInvalidTargetNoteBeforeDecoding() throws {
        var initial = MPCProgram.blank(name: "INVALID")
        initial.bytes[2690 + 1854] = 255
        XCTAssertThrowsError(try StudioModel.prepareImport(
            [urls[0]], atPad: 0, program: initial, sounds: [:]
        ) { _, _ in
            XCTFail("An invalid target note must fail before decoding.")
            return self.sample()
        })
    }

    func testBatchLoadsSequentiallyUsingRemainingBudget() throws {
        let initial = MPCProgram.blank(name: "BEFORE")
        var budgets: [Int] = []
        var loadedURLs: [URL] = []
        let prepared = try StudioModel.prepareImport(
            urls, atPad: 0, program: initial, sounds: [:], maximumPCMBytes: 2_000
        ) { url, budget in
            loadedURLs.append(url)
            budgets.append(budget)
            return self.sample(url.deletingPathExtension().lastPathComponent)
        }
        XCTAssertEqual(loadedURLs, urls)
        XCTAssertEqual(budgets, [2_000, 1_118])
        XCTAssertEqual(prepared.importedCount, 2)
        XCTAssertEqual(prepared.sounds.count, 2)
        XCTAssertEqual(prepared.program.referencedSlots.count, 2)
        XCTAssertTrue(initial.referencedSlots.isEmpty)
    }

    func testExclusiveReplacementReclaimsItsOwnMemoryBeforeDecoding() throws {
        var initial = MPCProgram.blank(name: "BEFORE")
        initial.assign(slot: 0, toNote: initial.midiNote(forPad: 0))
        initial.setSound(slot: 0, name: "OLD", wordCount: 2_400)
        let old = sample("OLD", frames: 2_400)
        var budgets: [Int] = []
        let prepared = try StudioModel.prepareImport(
            [urls[0]], atPad: 0, program: initial, sounds: [0: old], maximumPCMBytes: 5_000
        ) { _, budget in
            budgets.append(budget)
            return self.sample("NEW", frames: 1_000)
        }
        XCTAssertEqual(budgets, [5_000])
        XCTAssertEqual(prepared.sounds.count, 1)
        XCTAssertEqual(prepared.sounds.values.first?.name, "NEW")
        XCTAssertEqual(initial.soundName(slot: 0), "OLD")
        XCTAssertEqual(old.frameCount, 2_400)
    }

    func testSharedReplacementRetainsOldSampleAndCountsItsMemoryOnce() throws {
        var initial = MPCProgram.blank(name: "SHARED")
        for pad in 0...1 { initial.assign(slot: 0, toNote: initial.midiNote(forPad: pad)) }
        initial.setSound(slot: 0, name: "OLD", wordCount: 441)
        var budgets: [Int] = []
        let prepared = try StudioModel.prepareImport(
            [urls[0]], atPad: 0, program: initial, sounds: [0: sample("OLD")], maximumPCMBytes: 2_000
        ) { _, budget in
            budgets.append(budget)
            return self.sample("NEW")
        }
        XCTAssertEqual(budgets, [1_118])
        XCTAssertEqual(prepared.program.slot(forNote: initial.midiNote(forPad: 1)), 0)
        XCTAssertNotEqual(prepared.program.slot(forNote: initial.midiNote(forPad: 0)), 0)
        XCTAssertEqual(prepared.sounds[0]?.name, "OLD")
        XCTAssertEqual(prepared.sounds.count, 2)
    }

    func testFullMemorySharedReplacementFailsBeforeDecoding() throws {
        var initial = MPCProgram.blank(name: "SHARED")
        for pad in 0...1 { initial.assign(slot: 0, toNote: initial.midiNote(forPad: pad)) }
        XCTAssertThrowsError(try StudioModel.prepareImport(
            [urls[0]], atPad: 0, program: initial, sounds: [0: sample("OLD")], maximumPCMBytes: 882
        ) { _, _ in
            XCTFail("A full retained pool must fail before decoding.")
            return self.sample()
        })
    }

    func testBatchRejectsOversizedLoaderResultAndPreservesInputs() throws {
        let initial = MPCProgram.blank(name: "BEFORE")
        let originalBytes = initial.bytes
        var budgets: [Int] = []
        XCTAssertThrowsError(try StudioModel.prepareImport(
            urls, atPad: 0, program: initial, sounds: [:], maximumPCMBytes: 1_000
        ) { _, budget in
            budgets.append(budget)
            return self.sample()
        })
        XCTAssertEqual(budgets, [1_000, 118])
        XCTAssertEqual(initial.bytes, originalBytes)
        XCTAssertTrue(initial.referencedSlots.isEmpty)
    }

    func testLaterInvalidFileDoesNotChangeOriginalProgramOrSound() throws {
        var initial = MPCProgram.blank(name: "BEFORE")
        initial.assign(slot: 0, toNote: initial.midiNote(forPad: 0))
        initial.setSound(slot: 0, name: "OLD", wordCount: 441)
        let sounds = [0: sample("OLD")]
        let originalBytes = initial.bytes
        var attempts = 0
        XCTAssertThrowsError(try StudioModel.prepareImport(
            urls, atPad: 0, program: initial, sounds: sounds
        ) { _, _ in
            attempts += 1
            if attempts == 2 { throw StudioError.message("Invalid second file") }
            return self.sample("NEW")
        })
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(initial.bytes, originalBytes)
        XCTAssertEqual(sounds.count, 1)
        XCTAssertEqual(sounds[0]?.name, "OLD")
        XCTAssertEqual(sounds[0]?.channels, sample("OLD").channels)
    }

    @MainActor
    func testNameBindingSameValueDoesNotMarkKitDirty() {
        let model = StudioModel()
        model.newKit()
        model.setKitName("NEWPROG")
        XCTAssertFalse(model.isDirty)
        model.setKitName("EDITED")
        XCTAssertEqual(model.kitName, "EDITED")
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testFailedImportIntoEmptyModelKeepsItEmpty() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let invalid = folder.appendingPathComponent("INVALID.SND")
        try Data("invalid".utf8).write(to: invalid)
        let model = StudioModel()
        let task = try XCTUnwrap(model.importURLs([invalid], atPad: 0))
        await task.value
        XCTAssertNil(model.program)
        XCTAssertNil(model.sound)
        XCTAssertEqual(model.memoryBytes, 0)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testFailedBatchKeepsLoadedModelIncludingDirtyStateAndSelection() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("GOOD.SND")
        let invalid = folder.appendingPathComponent("INVALID.SND")
        try sample("GOOD").encoded().write(to: good)
        try Data("invalid".utf8).write(to: invalid)
        let model = StudioModel()
        await model.importURLs([good], atPad: 0)?.value
        model.selectPad(4)
        let originalBytes = try XCTUnwrap(model.program?.bytes)
        let originalMemory = model.memoryBytes
        XCTAssertEqual(model.padName(0), "GOOD")
        XCTAssertTrue(model.isDirty)
        await model.importURLs([good, invalid], atPad: 0)?.value
        XCTAssertEqual(model.program?.bytes, originalBytes)
        XCTAssertEqual(model.padName(0), "GOOD")
        XCTAssertEqual(model.memoryBytes, originalMemory)
        XCTAssertEqual(model.selectedPad, 4)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testModelRejectsOverflowWithoutImportingPrefix() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("GOOD.SND")
        try sample().encoded().write(to: good)
        let model = StudioModel()
        await model.importURLs([good, good], atPad: 63)?.value
        XCTAssertNil(model.program)
        XCTAssertEqual(model.memoryBytes, 0)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.errorMessage?.contains("D16") == true)
    }

    private func fileProvider(_ result: Result<Data, Error>) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            switch result {
            case .success(let data): completion(data, nil)
            case .failure(let error): completion(nil, error)
            }
            return nil
        }
        return provider
    }

    @MainActor
    func testDropProviderFailureDoesNotShiftLaterFileOntoFirstPad() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("GOOD.SND")
        try sample("GOOD").encoded().write(to: good)
        let failed = fileProvider(.failure(NSError(domain: "DropTest", code: 1)))
        let valid = fileProvider(.success(good.dataRepresentation))
        let model = StudioModel()
        let finished = expectation(description: "Failed drop completes")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }

        XCTAssertTrue(model.dropFiles([failed, valid], onPad: 0))
        XCTAssertTrue(model.busy, "Resolution must reserve the model before the task starts.")
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertNil(model.program)
        XCTAssertNil(model.sound)
        XCTAssertEqual(model.memoryBytes, 0)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.errorMessage?.contains("fichier déposé 1") == true)
    }

    @MainActor
    func testDropLaterProviderFailurePreservesLoadedKitAndSelection() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("OLD.SND")
        let replacement = folder.appendingPathComponent("NEW.SND")
        try sample("OLD").encoded().write(to: old)
        try sample("NEW").encoded().write(to: replacement)
        let model = StudioModel()
        await model.importURLs([old], atPad: 0)?.value
        model.selectPad(20)
        model.setKitName("BEFORE")
        let before = try XCTUnwrap(model.program?.bytes)
        let memory = model.memoryBytes
        let failed = fileProvider(.failure(NSError(domain: "DropTest", code: 2)))
        let valid = fileProvider(.success(replacement.dataRepresentation))
        let finished = expectation(description: "Later provider failure completes")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }

        XCTAssertTrue(model.dropFiles([valid, failed], onPad: 0))
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertEqual(model.padName(0), "OLD")
        XCTAssertEqual(model.padName(1), "—")
        XCTAssertEqual(model.memoryBytes, memory)
        XCTAssertEqual(model.kitName, "BEFORE")
        XCTAssertEqual(model.selectedPad, 20)
        XCTAssertEqual(model.bank, 1)
        XCTAssertNil(model.sound)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.errorMessage?.contains("fichier déposé 2") == true)
        XCTAssertTrue(model.status.contains(".PGM est conservé"))
    }

    @MainActor
    func testDropImportsEveryProviderInOrder() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("FIRST.SND")
        let second = folder.appendingPathComponent("SECOND.SND")
        try sample("FIRST").encoded().write(to: first)
        try sample("SECOND").encoded().write(to: second)
        let providers = [first, second].map { fileProvider(.success($0.dataRepresentation)) }
        let model = StudioModel()
        let finished = expectation(description: "Successful drop completes")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }

        XCTAssertTrue(model.dropFiles(providers, onPad: 15))
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertEqual(model.padName(15), "FIRST")
        XCTAssertEqual(model.padName(16), "SECOND")
        XCTAssertEqual(model.memoryBytes, 1_764)
        XCTAssertEqual(model.selectedPad, 15)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.status, "2 samples importés.")
    }

    @MainActor
    func testDropRejectsCompetitorWhileFirstProviderIsStillResolving() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("FIRST.SND")
        let second = folder.appendingPathComponent("SECOND.SND")
        try sample("FIRST").encoded().write(to: first)
        try sample("SECOND").encoded().write(to: second)
        let requested = expectation(description: "Delayed provider requested")
        let gate = DeferredDropProvider()
        gate.provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            gate.store(completion)
            requested.fulfill()
            return nil
        }
        let model = StudioModel()
        let finished = expectation(description: "Delayed drop completes")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }

        XCTAssertTrue(model.dropFiles([gate.provider], onPad: 0))
        XCTAssertTrue(model.busy)
        await fulfillment(of: [requested], timeout: 3)
        XCTAssertFalse(model.dropFiles([fileProvider(.success(second.dataRepresentation))], onPad: 1))
        XCTAssertNil(model.importURLs([second], atPad: 1))
        XCTAssertTrue(model.busy)
        gate.complete(first.dataRepresentation)
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertEqual(model.padName(0), "FIRST")
        XCTAssertEqual(model.padName(1), "—")
        XCTAssertEqual(model.memoryBytes, 882)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testDropRejectsNonFileURLWithoutCreatingKit() async throws {
        let model = StudioModel()
        let provider = fileProvider(.success(URL(string: "https://example.invalid/sample.wav")!.dataRepresentation))
        let finished = expectation(description: "Invalid file URL completes")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        defer { observation.cancel() }

        XCTAssertTrue(model.dropFiles([provider], onPad: 0))
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertNil(model.program)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.isDirty)
        XCTAssertNotNil(model.errorMessage)
    }

}


// The callback can arrive on a provider queue; access to its completion is locked.
private final class DeferredDropProvider: @unchecked Sendable {
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
        let value = completion
        completion = nil
        lock.unlock()
        value?(data, nil)
    }
}
