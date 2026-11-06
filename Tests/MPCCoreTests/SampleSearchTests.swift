import Foundation
import XCTest
@testable import MPCCore

/// The typed search below a sample source: bounded, read-only, never following links.
final class SampleSearchTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleSearchTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    @discardableResult
    private func file(_ relative: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
        return url.standardizedFileURL
    }

    func testEveryWordMustAppearInThePathBelowTheSource() {
        XCTAssertTrue(LibraryIndex.sampleMatches(relativePath: "SONG003 - Sloppy Drums/LOOPS/A — DRUMS 22.wav", query: "sloppy loops"))
        XCTAssertTrue(LibraryIndex.sampleMatches(relativePath: "Rap/Caisse claire.WAV", query: "CAISSE"))
        XCTAssertTrue(LibraryIndex.sampleMatches(relativePath: "Rap/Caisse claire.wav", query: "claire caisse"))
        XCTAssertFalse(LibraryIndex.sampleMatches(relativePath: "Rap/Kick.wav", query: "kick snare"))
        XCTAssertFalse(LibraryIndex.sampleMatches(relativePath: "Rap/Kick.wav", query: "   "))
    }

    func testFindsAudioAtAnyDepthAndSkipsOtherFiles() throws {
        let root = try root()
        let deep = try file("Soul/SONG003/LOOPS/kick loop.wav", in: root)
        let shallow = try file("Kick.aif", in: root)
        try file("Soul/SONG003/LOOPS/kick loop.wav.asd", in: root)
        try file("Soul/.hidden/kick.wav", in: root)
        try file("Soul/._kick.wav", in: root)

        let result = LibraryIndex.searchSamples(in: root, matching: "kick")

        XCTAssertEqual(Set(result.samples), [deep, shallow])
        XCTAssertFalse(result.truncated)
        XCTAssertNil(result.issue)
    }

    func testSymbolicLinksAreNeverFollowed() throws {
        let root = try root()
        let outside = try self.root()
        try file("kick outside.wav", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("kick link.wav"),
                                                   withDestinationURL: outside.appendingPathComponent("kick outside.wav"))

        XCTAssertTrue(LibraryIndex.searchSamples(in: root, matching: "kick").samples.isEmpty)
    }

    func testLimitsStopTheSearchAndSaySo() throws {
        let root = try root()
        for index in 0..<5 { try file("Kicks/kick \(index).wav", in: root) }
        try file("A/B/C/kick deep.wav", in: root)

        let few = LibraryIndex.searchSamples(in: root, matching: "kick", maximumResults: 2)
        XCTAssertEqual(few.samples.count, 2)
        XCTAssertTrue(few.truncated)

        let shallow = LibraryIndex.searchSamples(in: root, matching: "deep", maximumDepth: 2)
        XCTAssertTrue(shallow.samples.isEmpty)
        XCTAssertTrue(shallow.truncated)
    }

    func testCancellationEndsTheSearch() throws {
        let root = try root()
        for index in 0..<20 { try file("kick \(index).wav", in: root) }
        let result = LibraryIndex.searchSamples(in: root, matching: "kick", isCancelled: { true })
        XCTAssertTrue(result.samples.isEmpty)
    }

    func testMissingSourceIsAnIssueNotAnEmptyAnswer() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let result = LibraryIndex.searchSamples(in: missing, matching: "kick")
        XCTAssertTrue(result.samples.isEmpty)
        XCTAssertNotNil(result.issue)
    }
}
