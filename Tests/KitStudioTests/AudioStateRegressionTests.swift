import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers
import XCTest
import MPCCore
@testable import KitStudio

final class AudioStateRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AudioStateRegression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func model() throws -> StudioModel {
        let suite = "AudioStateRegression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return StudioModel(defaults: defaults, localLibraryURL: FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString), discardPresenter: { $0(false) }, volumeProvider: { [] })
    }

    @MainActor
    private func open(_ url: URL, in model: StudioModel) async throws {
        let loaded = expectation(description: "Opened")
        let observation = model.$busy.dropFirst().filter { !$0 }.sink { _ in loaded.fulfill() }
        model.openProgram(url)
        await fulfillment(of: [loaded], timeout: 3)
        observation.cancel()
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testUneditedInternalTitleSurvivesCollisionAndTwoExports() async throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("DISK.PGM")
        let original = MPCProgram.blank(name: "INTERNAL TITLE")
        try original.bytes.write(to: source)
        let destination = folder.appendingPathComponent("Copies")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let collision = destination.appendingPathComponent("DISK.PGM")
        let untouched = Data("existing program".utf8)
        try untouched.write(to: collision)
        let model = try model()
        try await open(source, in: model)
        XCTAssertEqual(model.kitName, "DISK")
        XCTAssertEqual(model.programTitle, "INTERNAL TITLE")

        for expected in ["DISK1.PGM", "DISK2.PGM"] {
            try await XCTUnwrap(model.exportKit(to: destination)).value
            let output = try XCTUnwrap(model.lastExportURL)
            XCTAssertEqual(output.lastPathComponent, expected)
            XCTAssertEqual(try MPCProgram(data: Data(contentsOf: output)).name, "INTERNAL TITLE")
            XCTAssertEqual(model.program?.bytes, original.bytes)
            XCTAssertEqual(model.programURL, source)
            XCTAssertFalse(model.isDirty)
        }
        XCTAssertEqual(try Data(contentsOf: source), original.bytes)
        XCTAssertEqual(try Data(contentsOf: collision), untouched)

        model.setKitName("RENAMED")
        XCTAssertEqual(model.programTitle, "RENAMED")
        XCTAssertTrue(model.isDirty)
        await model.exportKit(to: destination)?.value
        let renamed = try XCTUnwrap(model.lastExportURL)
        XCTAssertEqual(try MPCProgram(data: Data(contentsOf: renamed)).name, "RENAMED")
        XCTAssertEqual(try Data(contentsOf: source), original.bytes)
    }

    @MainActor
    func testTwentyCancelledProvidersPreserveDirtyKitAndPermitExportDespiteLateCallbacks() async throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("OLD.SND")
        let sound = MPCSound(name: "OLD", channels: [[Float](repeating: 0.25, count: 441)])
        let sourceBytes = try sound.encoded()
        try sourceBytes.write(to: source)
        let model = try model()
        await model.importURLs([source], atPad: 0)?.value

        for cycle in 0..<20 {
            model.setKitName("KEEP\(cycle)")
            model.selectPad(20)
            let before = model.program?.bytes
            let requested = expectation(description: "Provider \(cycle) waits")
            let gate = ProviderCallbackGate()
            let provider = NSItemProvider()
            let progress = Progress(totalUnitCount: 1)
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                gate.store(completion)
                requested.fulfill()
                return progress
            }
            XCTAssertTrue(model.dropFiles([provider], onPad: 1))
            XCTAssertTrue(model.resolvingDroppedFiles)
            await fulfillment(of: [requested], timeout: 3)
            XCTAssertTrue(model.busy)
            XCTAssertNil(model.exportKit(to: folder))
            model.cancelDroppedFiles()
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.resolvingDroppedFiles)
            XCTAssertFalse(model.documentActionsDisabled)
            XCTAssertTrue(model.isDirty)
            XCTAssertEqual(model.program?.bytes, before)
            XCTAssertEqual(model.selectedPad, 20)
            XCTAssertEqual(model.padName(1), "—")

            // An uncooperative provider still calls back from its own queue.
            await Task.detached { gate.complete(source.dataRepresentation) }.value
            await Task.yield()
            XCTAssertEqual(model.program?.bytes, before)
            let destination = folder.appendingPathComponent("Copy\(cycle)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let exported = try XCTUnwrap(model.exportKit(to: destination))
            await exported.value
            XCTAssertNil(model.errorMessage)
            XCTAssertNotNil(model.lastExportURL)
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        }
    }

    @MainActor
    func testResolutionCancellationWinsBeforeProgressReturnsAndDuplicateLateCallbacksAreIgnored() async throws {
        let bridge = ItemProviderResolution()
        let progress = Progress(totalUnitCount: 1)
        let data = URL(fileURLWithPath: "/tmp/fixture.SND").dataRepresentation
        do {
            _ = try await bridge.resolve(index: 0) { completion in
                bridge.cancel()
                completion(data, nil)
                completion(nil, NSError(domain: "Duplicate", code: 1))
                return progress
            }
            XCTFail("Cancellation must win")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(progress.isCancelled)
    }

    @MainActor
    func testResolutionAcceptsExactlyOneOfConcurrentCallbacksAndCancellation() async throws {
        let data = URL(fileURLWithPath: "/tmp/fixture.SND").dataRepresentation
        for _ in 0..<20 {
            let bridge = ItemProviderResolution()
            do {
                let url = try await bridge.resolve(index: 0) { completion in
                    DispatchQueue.global().async { completion(data, nil) }
                    DispatchQueue.global().async { completion(data, nil) }
                    DispatchQueue.global().async { bridge.cancel() }
                    return Progress(totalUnitCount: 1)
                }
                XCTAssertEqual(url, URL(fileURLWithPath: "/tmp/fixture.SND"))
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    @MainActor
    func testOverrangeFloatImportWarnsBlocksExportAndOnlyExplicitNormalizationChangesAudio() async throws {
        let folder = try directory()
        let source = folder.appendingPathComponent("OVER.WAV")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        do {
            let file = try AVAudioFile(forWriting: source, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4410))
            buffer.frameLength = 4410
            let pcm = try XCTUnwrap(buffer.floatChannelData)
            for index in 0..<4410 { pcm[0][index] = index < 1470 ? 1.25 : index < 2940 ? -1.25 : 0.625 }
            try file.write(from: buffer)
        }
        let originalSource = try Data(contentsOf: source)
        let model = try model()
        await model.importURLs([source], atPad: 0)?.value
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.sound?.channels[0][100], 1.25)
        XCTAssertEqual(model.sound?.channels[0][2000], -1.25)
        XCTAssertEqual(model.exportAudioWarnings.count, 1)
        XCTAssertEqual(model.selectedAudioRangeWarning?.report.outOfRangeSampleCount, 2940)
        XCTAssertNotNil(model.exportAudioIssue)
        XCTAssertTrue(model.status.contains("écrêterait"))
        let destination = folder.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        XCTAssertNil(model.exportKit(to: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(model.sound?.channels[0][100], 1.25)

        model.errorMessage = nil
        model.exportKit()
        XCTAssertTrue(model.showExportSheet)
        XCTAssertNotNil(model.exportAudioIssue)
        model.normalizeOverrangeSamples()
        XCTAssertNil(model.exportAudioIssue)
        XCTAssertEqual(model.sound?.channels[0][100], 1)
        XCTAssertEqual(model.sound?.channels[0][2000], -1)
        XCTAssertEqual(model.sound?.channels[0][3500], 0.5)
        XCTAssertTrue(model.isDirty)
        model.showExportSheet = false
        model.undo()
        XCTAssertEqual(model.sound?.channels[0][100], 1.25)
        XCTAssertEqual(model.exportAudioWarnings.count, 1)
        model.redo()
        XCTAssertEqual(model.sound?.channels[0][100], 1)
        XCTAssertTrue(model.exportAudioWarnings.isEmpty)
        try await XCTUnwrap(model.exportKit(to: destination)).value
        XCTAssertNil(model.errorMessage)
        let loaded = try KitLoader.load(programURL: XCTUnwrap(model.lastExportURL))
        let exported = try XCTUnwrap(loaded.sounds.values.first)
        XCTAssertEqual(exported.channels[0][100], 32767.0 / 32768)
        XCTAssertEqual(exported.channels[0][2000], -1)
        XCTAssertEqual(exported.channels[0][3500], 0.5)
        XCTAssertEqual(try Data(contentsOf: source), originalSource)
    }
}

/// Provider-owned callback storage is accessed only while locked; invoking it
/// happens after releasing the lock so cancellation may call back reentrantly.
private final class ProviderCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Data?, Error?) -> Void)?
    func store(_ callback: @escaping (Data?, Error?) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func complete(_ data: Data) {
        lock.lock(); let value = callback; callback = nil; lock.unlock()
        value?(data, nil)
    }
}
