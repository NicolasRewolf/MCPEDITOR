import Foundation
import XCTest
@testable import MPCCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class LibraryIndexTests: XCTestCase {
    // These index fixtures are local directories, not mounted MPC cards. Exercise the
    // read-only index and its FAT seam separately from production destination eligibility.
    private func scanPartition(_ url: URL, maximumDepth: Int = 8, maximumEntries: Int = 50_000,
                               fatVolumeProbe: @escaping (Int32) throws -> LibraryIndex.FATVolumeUsage? = { _ in nil }) -> LibraryPartition {
        LibraryIndex.scanPartition(url, maximumDepth: maximumDepth, maximumEntries: maximumEntries,
                                   fatVolumeProbe: fatVolumeProbe)
    }

    private func directory(named name: String = "Library") throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexTests-" + UUID().uuidString)
        let folder = container.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return folder
    }

    private func file(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data([0, 1, 2]).write(to: url)
        return url
    }

    func testPartitionRecognitionRequiresExactlyOneUppercaseLetter() {
        for letter in ["A", "M", "Z"] {
            XCTAssertEqual(LibraryIndex.partitionLetter(for: URL(fileURLWithPath: "/Volumes/MPC-PART--\(letter)")), letter)
        }
        for name in ["MPC-PART--", "MPC-PART--AA", "MPC-PART--a", "MPC-PART--1", "MPC-PART--É", "OTHER-A"] {
            XCTAssertNil(LibraryIndex.partitionLetter(for: URL(fileURLWithPath: "/Volumes/\(name)")))
        }
    }

    func testHiddenFilesAndSidecarsDoNotMakeAnOtherwiseEmptyPartOccupied() throws {
        let folder = try directory(named: "MPC-PART--Z")
        _ = try file(".DS_Store", in: folder)
        _ = try file("._KIT.PGM", in: folder)
        let hidden = folder.appendingPathComponent(".Hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        _ = try file("KIT.PGM", in: hidden)

        let part = scanPartition(folder)
        XCTAssertEqual(part.letter, "Z")
        XCTAssertTrue(part.isEmpty)
        XCTAssertEqual(part.fileCount, 0)
        XCTAssertEqual(part.folderCount, 0)
        XCTAssertTrue(part.kits.isEmpty)
        XCTAssertTrue(part.issues.isEmpty)
    }

    func testRecursiveMetadataCountsKitsSamplesSequencesAndUnknownFiles() throws {
        let folder = try directory(named: "MPC-PART--C")
        let direct = try file("ROOT.PGM", in: folder)
        _ = try file("KICK.SND", in: folder)
        _ = try file("TAKE.Seq", in: folder)
        _ = try file("NOTES.TXT", in: folder)
        let nested = folder.appendingPathComponent("Drums/Live")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let kit = try file("NESTED.pgm", in: nested)
        _ = try file("SNARE.WAV", in: nested)

        let part = scanPartition(folder)
        XCTAssertFalse(part.isEmpty)
        XCTAssertTrue(part.issues.isEmpty)
        XCTAssertEqual(part.fileCount, 6)
        XCTAssertEqual(part.folderCount, 2)
        XCTAssertEqual(part.audioCount, 2)
        XCTAssertEqual(part.sequenceCount, 1)
        XCTAssertEqual(Set(part.kits.map(\.url)), Set([direct, kit]))
        XCTAssertEqual(part.kits.first { $0.url == kit }?.locationLabel, "PART C · Drums/Live")
        XCTAssertEqual(part.kits.first { $0.url == direct }?.locationLabel, "PART C")
        XCTAssertEqual(try LibraryIndex.scanKits(in: folder), part.kits)
    }

    func testSameKitNamesHaveDistinctFilesystemIdentityAndPartLabels() throws {
        let first = try directory(named: "MPC-PART--A")
        let second = try directory(named: "MPC-PART--B")
        _ = try file("KIT.PGM", in: first)
        _ = try file("KIT.PGM", in: second)
        let a = try XCTUnwrap(scanPartition(first).kits.first)
        let b = try XCTUnwrap(scanPartition(second).kits.first)
        XCTAssertEqual(a.title, b.title)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.locationLabel, "PART A")
        XCTAssertEqual(b.locationLabel, "PART B")
    }

    func testSampleListingIsImmediateAndExcludesNonAudioLinksAndHiddenEntries() throws {
        let folder = try directory(named: "Soul")
        let kick = try file("Kick 2.WAV", in: folder)
        let snare = try file("Snare.aiff", in: folder)
        _ = try file("KIT.PGM", in: folder)
        _ = try file("NOTES.txt", in: folder)
        _ = try file("._Kick.WAV", in: folder)
        let nested = folder.appendingPathComponent("Drums")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try file("DEEP.WAV", in: nested)
        let directoryWithAudioExtension = folder.appendingPathComponent("Folder.WAV")
        try FileManager.default.createDirectory(at: directoryWithAudioExtension, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Alias.WAV"), withDestinationURL: kick)

        let listing = LibraryIndex.listSamples(in: folder)
        XCTAssertNil(listing.issue)
        XCTAssertEqual(listing.samples, [kick, snare].map(\.standardizedFileURL))
        XCTAssertEqual(Set(listing.folders.map(\.path)), Set([nested, directoryWithAudioExtension].map { $0.standardizedFileURL.path }))
    }

    func testSymlinkEscapesAreNotTraversedAndStillPreventEmptyClaim() throws {
        let folder = try directory(named: "MPC-PART--D")
        let external = try directory(named: "Outside")
        let outsideKit = try file("OUTSIDE.PGM", in: external)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("LinkedFolder"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("LINK.PGM"), withDestinationURL: outsideKit)

        let part = scanPartition(folder)
        XCTAssertFalse(part.isEmpty)
        XCTAssertEqual(part.fileCount, 2)
        XCTAssertTrue(part.kits.isEmpty)
        XCTAssertTrue(part.issues.isEmpty)
        XCTAssertTrue(LibraryIndex.listSamples(in: folder).folders.isEmpty)
        let linkedRoot = folder.appendingPathComponent("LinkedFolder")
        XCTAssertFalse(scanPartition(linkedRoot).isEmpty)
        XCTAssertThrowsError(try LibraryIndex.scanKits(in: linkedRoot))
    }

    func testDepthLimitReportsPartialScanInsteadOfPretendingToBeComplete() throws {
        let folder = try directory()
        let direct = try file("DIRECT.PGM", in: folder)
        let nested = folder.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try file("DEEP.PGM", in: nested)

        let part = scanPartition(folder, maximumDepth: 0)
        XCTAssertEqual(part.kits.map(\.url), [direct])
        XCTAssertFalse(part.issues.isEmpty)
        XCTAssertFalse(part.isEmpty)
        XCTAssertThrowsError(try LibraryIndex.scanKits(in: folder, maximumDepth: 0))
    }

    func testEntryLimitReportsPartialScanAndBoundsProcessedEntries() throws {
        let folder = try directory()
        for number in 0..<4 { _ = try file("\(number).PGM", in: folder) }
        let part = scanPartition(folder, maximumEntries: 2)
        XCTAssertEqual(part.fileCount, 2)
        XCTAssertEqual(part.kits.count, 2)
        XCTAssertFalse(part.issues.isEmpty)
        XCTAssertFalse(part.isEmpty)
        XCTAssertThrowsError(try LibraryIndex.scanKits(in: folder, maximumEntries: 2))
        XCTAssertNotNil(LibraryIndex.listSamples(in: folder, maximumEntries: 2).issue)
    }

    func testMissingOrNonDirectoryRootCannotBeReportedAsEmpty() throws {
        let folder = try directory()
        let regular = try file("REGULAR", in: folder)
        let missing = folder.appendingPathComponent("Missing")
        for root in [missing, regular] {
            let part = scanPartition(root)
            XCTAssertFalse(part.isEmpty)
            XCTAssertFalse(part.issues.isEmpty)
            XCTAssertThrowsError(try LibraryIndex.scanKits(in: root))
            XCTAssertNotNil(LibraryIndex.listSamples(in: root).issue)
        }
    }

    func testRescanAfterRootDisappearsDoesNotReuseAnEmptySnapshot() throws {
        let folder = try directory()
        XCTAssertTrue(scanPartition(folder).isEmpty)
        try FileManager.default.removeItem(at: folder)
        let disconnected = scanPartition(folder)
        XCTAssertFalse(disconnected.isEmpty)
        XCTAssertFalse(disconnected.issues.isEmpty)
        XCTAssertNil(disconnected.availableBytes)
    }

    func testUnreadableRootCannotBeReportedAsEmpty() throws {
        let folder = try directory()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard !FileManager.default.isReadableFile(atPath: folder.path) else {
            throw XCTSkip("This test process can read directories despite permission bits.")
        }
        let part = scanPartition(folder)
        XCTAssertFalse(part.isEmpty)
        XCTAssertFalse(part.issues.isEmpty)
        XCTAssertThrowsError(try LibraryIndex.scanKits(in: folder))
        XCTAssertNotNil(LibraryIndex.listSamples(in: folder).issue)
    }

    private func allocatedBytes(at url: URL) throws -> Int64 {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Int64(info.st_blocks) * 512
    }

    func testApparentlyEmptyFATWithUnexplainedOccupiedClustersIsNotEmpty() throws {
        let folder = try directory(named: "MPC-PART--A")
        let known = try allocatedBytes(at: folder)
        let part = scanPartition(folder, fatVolumeProbe: { _ in
            .init(allocationUnitBytes: 8192, occupiedBytes: known + 6_103_040)
        })
        XCTAssertEqual(part.fileCount, 0)
        XCTAssertEqual(part.folderCount, 0)
        XCTAssertFalse(part.isEmpty)
        XCTAssertTrue(part.issues.contains { $0.contains("ne sont pas expliqués") })
    }

    func testEmptyFATIsAcceptedWhenRootAndHiddenMetadataExplainEveryOccupiedByte() throws {
        let folder = try directory(named: "MPC-PART--E")
        let hidden = folder.appendingPathComponent(".fseventsd", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        let log = try file("events", in: hidden)
        let known = try [folder, hidden, log].reduce(Int64(0)) { try $0 + allocatedBytes(at: $1) }
        let part = scanPartition(folder, fatVolumeProbe: { _ in
            .init(allocationUnitBytes: 8192, occupiedBytes: known)
        })
        XCTAssertTrue(part.isEmpty)
        XCTAssertTrue(part.issues.isEmpty)
        XCTAssertEqual(part.fileCount, 0)
        XCTAssertEqual(part.folderCount, 0)
    }

    func testEmptyFATHasNoAllowanceForAnUnexplainedAllocationUnit() throws {
        let folder = try directory()
        let known = try allocatedBytes(at: folder)
        let part = scanPartition(folder, fatVolumeProbe: { _ in
            .init(allocationUnitBytes: 8192, occupiedBytes: known + 8192)
        })
        XCTAssertFalse(part.isEmpty)
        XCTAssertFalse(part.issues.isEmpty)
    }

    func testFATProbeFailurePreventsEmptyClaim() throws {
        let folder = try directory()
        let part = scanPartition(folder, fatVolumeProbe: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        })
        XCTAssertFalse(part.isEmpty)
        XCTAssertFalse(part.issues.isEmpty)
    }

    func testNativeInventoryRejectsAVisibleFileMissingFromTheInitialScan() throws {
        let folder = try directory()
        let native = folder.appendingPathComponent("EXISTING.SND")
        let bytes = Data([1, 2, 3])
        var calls = 0
        let part = scanPartition(folder, fatVolumeProbe: { _ in
            calls += 1
            // The initial Foundation scan was empty; the independent native inventory must disagree.
            if calls == 1 { try bytes.write(to: native) }
            return .init(allocationUnitBytes: 8192, occupiedBytes: 0)
        })
        XCTAssertEqual(part.fileCount, 0)
        XCTAssertFalse(part.isEmpty)
        XCTAssertTrue(part.issues.contains { $0.contains("absents du premier relevé") })
        XCTAssertEqual(try Data(contentsOf: native), bytes)
    }

    func testHiddenSymlinkCannotExplainFATAllocation() throws {
        let folder = try directory()
        let outside = try directory(named: "Outside")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(".linked"),
                                                 withDestinationURL: outside)
        let part = scanPartition(folder, fatVolumeProbe: { _ in
            .init(allocationUnitBytes: 8192, occupiedBytes: 0)
        })
        XCTAssertFalse(part.isEmpty)
        XCTAssertTrue(part.issues.contains { $0.contains("lien") })
    }

    func testHiddenFATInventoryLimitsPreventEmptyClaim() throws {
        let folder = try directory()
        let hidden = folder.appendingPathComponent(".metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        _ = try file("one", in: hidden)
        _ = try file("two", in: hidden)
        let probe: (Int32) throws -> LibraryIndex.FATVolumeUsage? = { _ in
            .init(allocationUnitBytes: 8192, occupiedBytes: 0)
        }
        let shallow = scanPartition(folder, maximumDepth: 0, fatVolumeProbe: probe)
        let truncated = scanPartition(folder, maximumEntries: 1, fatVolumeProbe: probe)
        XCTAssertFalse(shallow.isEmpty)
        XCTAssertFalse(truncated.isEmpty)
        XCTAssertFalse(shallow.issues.isEmpty)
        XCTAssertFalse(truncated.issues.isEmpty)
    }

    func testFATAllocationIncreaseDuringInventoryPreventsEmptyClaim() throws {
        let folder = try directory()
        let known = try allocatedBytes(at: folder)
        var calls = 0
        let part = scanPartition(folder, fatVolumeProbe: { _ in
            calls += 1
            return .init(allocationUnitBytes: 8192, occupiedBytes: known + (calls == 1 ? 0 : 8192))
        })
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(part.isEmpty)
        XCTAssertFalse(part.issues.isEmpty)
    }
}
