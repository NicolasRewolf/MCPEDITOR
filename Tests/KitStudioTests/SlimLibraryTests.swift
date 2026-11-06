import Foundation
import XCTest
import MPCCore
@testable import KitStudio

/// The slimmed sample panel: one click plays, sources are named once, only problems speak.
final class SlimLibraryTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlimLibraryTests-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder
    }

    @MainActor
    private func model() throws -> StudioModel {
        let suite = "SlimLibraryTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("UnusedLibrary-" + UUID().uuidString)
        return StudioModel(defaults: defaults, localLibraryURL: library, volumeProvider: { [] })
    }

    private func sound(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".SND")
        try MPCSound(name: name, channels: [Array(repeating: 0.25, count: 441)]).encoded().write(to: url)
        return url.standardizedFileURL
    }

    @MainActor
    func testOneClickSelectsAndPlaysEvenWhileAnotherPreviewLoads() async throws {
        let root = try directory("Samples")
        let kick = try sound("KICK", in: root)
        let snare = try sound("SNARE", in: root)
        let model = try model()
        XCTAssertFalse(model.autoPreviewSamples)

        model.playSample(kick)
        XCTAssertEqual(model.selectedSampleURL, kick)
        XCTAssertTrue(model.samplePreviewBusy)

        model.playSample(snare)
        XCTAssertEqual(model.selectedSampleURL, snare, "The newest click wins over a preview still loading")
        XCTAssertTrue(model.samplePreviewBusy)
        model.stop()
        XCTAssertFalse(model.samplePreviewBusy)
    }

    @MainActor
    func testSamplesAreGroupedByTheirSourceOnce() async throws {
        let root = try directory("SOULS64-final")
        let urls = try ["A01KICK", "A02KICK", "A03SNARE"].map { try sound($0, in: root) }
        let model = try model()
        model.selectSampleRoot(root)
        await model.browseSamplesFolder(root)?.value

        let groups = model.groupedFilteredSamples
        XCTAssertEqual(groups.map(\.title), ["SOULS64-final"])
        XCTAssertEqual(groups.first?.samples, urls)
    }

    @MainActor
    func testOnlyRealProblemsReachTheSamplePanel() throws {
        let model = try model()
        model.samplePreviewStatus = "475 sample(s) visibles. Sélectionne un sample pour voir ses .PGM."
        XCTAssertNil(model.sampleBrowserProblem)
        model.samplePreviewStatus = "Prêt à écouter · KICK.SND"
        XCTAssertNil(model.sampleBrowserProblem)
        model.samplePreviewStatus = "Écoute impossible : le fichier a disparu."
        XCTAssertEqual(model.sampleBrowserProblem, "Écoute impossible : le fichier a disparu.")
        model.samplePreviewStatus = "PART indisponible."
        XCTAssertEqual(model.sampleBrowserProblem, "PART indisponible.")
    }
}
