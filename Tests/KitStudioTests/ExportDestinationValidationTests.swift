import Foundation
import MPCCore
import XCTest
@testable import KitStudio

final class ExportDestinationValidationTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DestinationValidation-" + UUID().uuidString)
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return folder.standardizedFileURL
    }

    @MainActor
    private func model(capture: @escaping @Sendable (URL) throws -> ExportDestination) throws -> StudioModel {
        let suite = "DestinationValidation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return StudioModel(defaults: defaults, discardPresenter: { $0(false) }, volumeProvider: { [] },
                           exportDestinationCapture: capture)
    }

    @MainActor
    func testSlowCaptureRunsOffMainActorCancellationUnlocksDirtyKitAndLateSuccessCannotRestoreOldReceipt() async throws {
        let first = try directory("First")
        let waiting = try directory("Waiting")
        let firstReceipt = try ExportDestination.capture(at: first)
        let waitingReceipt = try ExportDestination.capture(at: waiting)
        let requested = expectation(description: "Native capture is waiting on its own thread")
        let gate = DestinationCaptureGate()
        defer { gate.release() }
        let model = try model { url in
            XCTAssertFalse(Thread.isMainThread)
            if url == waiting {
                requested.fulfill()
                gate.wait()
                return waitingReceipt
            }
            return firstReceipt
        }
        model.newKit()
        model.setKitName("KEEP")
        model.exportKit()
        await model.selectExportFolder(first)?.value
        XCTAssertEqual(model.exportDestinationReceipt, firstReceipt)
        let operation = try XCTUnwrap(model.selectExportFolder(waiting))
        XCTAssertTrue(model.validatingExportDestination)
        XCTAssertNil(model.exportDestinationReceipt, "The old receipt must disappear before suspending.")
        XCTAssertEqual(model.exportDestinationURL, waiting)
        XCTAssertNotNil(model.exportDestinationIssue)
        await fulfillment(of: [requested], timeout: 3)

        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.documentLocked, "The save sheet's Cancel button must remain enabled.")
        XCTAssertTrue(model.documentActionsDisabled)
        let programBeforeAttempt = model.program?.bytes
        model.setKitName("EDITED DURING CHECK")
        XCTAssertEqual(model.kitName, "KEEP")
        XCTAssertEqual(model.program?.bytes, programBeforeAttempt,
                       "Choosing a destination must not edit the document behind Cancel.")
        let editedProgram = model.program?.bytes
        model.exportKitToDestination()
        XCTAssertTrue(model.showExportSheet)
        XCTAssertNil(model.lastExportURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: first.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: waiting.path).isEmpty)

        // This returns immediately while the simulated native call remains blocked.
        model.cancelExportDialog()
        XCTAssertFalse(model.showExportSheet)
        XCTAssertFalse(model.validatingExportDestination)
        XCTAssertFalse(model.documentActionsDisabled)
        XCTAssertNil(model.exportDestinationReceipt)
        XCTAssertNil(model.exportDestinationURL)
        XCTAssertEqual(model.program?.bytes, editedProgram)
        XCTAssertTrue(model.isDirty)
        model.setKitName("AFTER CANCEL")
        let afterCancel = model.program?.bytes
        gate.release()
        await operation.value

        XCTAssertEqual(model.program?.bytes, afterCancel)
        XCTAssertNil(model.exportDestinationURL)
        XCTAssertNil(model.exportDestinationReceipt)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.validatingExportDestination)
        XCTAssertTrue(model.isDirty)
        let export = try XCTUnwrap(model.exportKit(to: first))
        await export.value
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastExportURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: waiting.path).isEmpty)
    }

    @MainActor
    func testLatestFolderSelectionWinsEvenWhenEarlierCaptureCompletesLater() async throws {
        let slow = try directory("Slow")
        let latest = try directory("Latest")
        let slowReceipt = try ExportDestination.capture(at: slow)
        let latestReceipt = try ExportDestination.capture(at: latest)
        let requested = expectation(description: "First capture waits")
        let gate = DestinationCaptureGate()
        defer { gate.release() }
        let model = try model { url in
            if url == slow { requested.fulfill(); gate.wait(); return slowReceipt }
            return latestReceipt
        }
        model.newKit()
        model.exportKit()
        let old = try XCTUnwrap(model.selectExportFolder(slow))
        await fulfillment(of: [requested], timeout: 3)
        await model.selectExportFolder(latest)?.value
        XCTAssertEqual(model.exportDestinationURL, latest)
        XCTAssertEqual(model.exportDestinationReceipt, latestReceipt)
        XCTAssertFalse(model.validatingExportDestination)
        gate.release()
        await old.value
        XCTAssertEqual(model.exportDestinationURL, latest)
        XCTAssertEqual(model.exportDestinationReceipt, latestReceipt)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testLateCaptureFailureCannotOverwriteANewDocumentAfterCancellation() async throws {
        let folder = try directory("SlowFailure")
        let requested = expectation(description: "Capture waits then fails")
        let gate = DestinationCaptureGate()
        defer { gate.release() }
        let model = try model { _ in
            requested.fulfill()
            gate.wait()
            throw StudioError.message("Late failure")
        }
        model.newKit()
        model.exportKit()
        let old = try XCTUnwrap(model.selectExportFolder(folder))
        await fulfillment(of: [requested], timeout: 3)
        model.cancelExportDialog()
        model.newKit()
        model.setKitName("NEW DOCUMENT")
        let before = model.program?.bytes
        gate.release()
        await old.value
        XCTAssertEqual(model.program?.bytes, before)
        XCTAssertEqual(model.kitName, "NEW DOCUMENT")
        XCTAssertTrue(model.isDirty)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.exportDestinationReceipt)
        XCTAssertFalse(model.validatingExportDestination)
        XCTAssertFalse(model.documentActionsDisabled)
    }
}

/// Only blocks the worker thread; DispatchSemaphore's wait/signal are thread safe.
private final class DestinationCaptureGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func release() { semaphore.signal() }
}
