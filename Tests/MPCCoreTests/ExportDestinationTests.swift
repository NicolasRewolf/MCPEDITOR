import Foundation
import XCTest
@testable import MPCCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ExportDestinationTests: XCTestCase {
    private func fixture(named name: String = "LocalDestination") throws -> URL {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("ExportDestinationTests-" + UUID().uuidString)
        let directory = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return directory
    }

    private func allocatedBytes(in root: URL) throws -> Int64 {
        var info = stat()
        guard root.path.withCString({ lstat($0, &info) }) == 0 else { throw ExportDestinationError.changed }
        var bytes = Int64(info.st_blocks) * 512
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
                bytes += try allocatedBytes(in: root.appendingPathComponent(name))
            }
        }
        return bytes
    }

    /// These probes describe a synthetic FAT mount; no mounted card is ever modified by this suite.
    private func simulatedFAT(root: URL) -> ExportDestination.Environment {
        var environment = ExportDestination.Environment()
        environment.mount = { _ in
            .init(filesystem: "msdos", identifier: "synthetic-mount-1", mountedFrom: "synthetic-device",
                  mountPoint: root.standardizedFileURL)
        }
        environment.fatUsage = { _ in
            .init(allocationUnitBytes: 8192, occupiedBytes: try self.allocatedBytes(in: root))
        }
        return environment
    }

    private func export(to destination: URL, expected: ExportDestination? = nil,
                        environment: ExportDestination.Environment = .init(),
                        beforeFinalValidation: (() throws -> Void)? = nil) throws -> URL {
        var io = KitExport.FileIO()
        io.destinationEnvironment = environment
        io.volumeSpace = { descriptor in
            try beforeFinalValidation?()
            return try ExportSpace.volume(directoryFD: descriptor)
        }
        return try KitExport.export(program: .blank(name: "NEW"), sounds: [:], name: "NEW",
                                    to: destination, expectedDestination: expected, io: io)
    }

    func testOccupiedAfterEmptyProposalRefusesEveryCreationAndPreservesOriginal() throws {
        let root = try fixture()
        let expected = try ExportDestination.capture(at: root, requireEmpty: true)
        let sample = root.appendingPathComponent("KEEP.SND")
        let original = Data("existing sample".utf8)
        try original.write(to: sample)
        XCTAssertThrowsError(try export(to: root, expected: expected)) { error in
            guard case ExportDestinationError.notEmpty = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["KEEP.SND"])
        XCTAssertEqual(try Data(contentsOf: sample), original)
    }

    func testDirectoryReplacedAfterProposalRefusesBothOldAndNewDirectories() throws {
        let root = try fixture()
        let expected = try ExportDestination.capture(at: root, requireEmpty: true)
        let old = root.deletingLastPathComponent().appendingPathComponent("OldDirectory")
        try FileManager.default.moveItem(at: root, to: old)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try export(to: root, expected: expected))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty)
    }

    func testAncestorSwappedForSymlinkCannotRedirectTheWrite() throws {
        let parent = try fixture(named: "Parent")
        let root = parent.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let expected = try ExportDestination.capture(at: root, requireEmpty: true)
        let moved = parent.deletingLastPathComponent().appendingPathComponent("MovedParent")
        let outside = try fixture(named: "Outside")
        let outsideRoot = outside.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        XCTAssertThrowsError(try export(to: root, expected: expected))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.appendingPathComponent("Destination").path).isEmpty)
    }

    func testAPFSFolderImpersonatingAnUnmountedPARTIsNeitherRecommendedNorWritable() throws {
        let root = try fixture(named: "MPC-PART--S")
        let part = LibraryIndex.scanPartition(root)
        XCTAssertFalse(part.isEmpty)
        XCTAssertNil(part.exportDestination)
        XCTAssertFalse(part.issues.isEmpty)
        XCTAssertThrowsError(try ExportDestination.capture(at: root))
        XCTAssertThrowsError(try export(to: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCustomSubfolderCannotBypassAnUnmountedPARTGuard() throws {
        let root = try fixture(named: "MPC-PART--S")
        let custom = root.appendingPathComponent("Custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: false)
        XCTAssertThrowsError(try export(to: custom))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: custom.path).isEmpty)
    }

    func testUnexplainedFATAllocationRejectsManualAndCustomDestinationsBeforeAnyCreation() throws {
        let root = try fixture(named: "MPC-PART--E")
        let original = Data("original PCM".utf8)
        let sample = root.appendingPathComponent("KEEP.SND")
        try original.write(to: sample)
        let custom = root.appendingPathComponent("Custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: false)
        var environment = simulatedFAT(root: root)
        environment.fatUsage = { _ in .init(allocationUnitBytes: 8192, occupiedBytes: try self.allocatedBytes(in: root) + 8192) }
        for destination in [root, custom] {
            XCTAssertThrowsError(try export(to: destination, environment: environment))
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["KEEP.SND", "Custom"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: custom.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: sample), original)
    }

    func testChangedMountIdentityRejectsAStaleRecommendation() throws {
        let root = try fixture(named: "MPC-PART--E")
        var environment = simulatedFAT(root: root)
        let expected = try ExportDestination.capture(at: root, requireEmpty: true, environment: environment)
        XCTAssertTrue(expected.isMountedMPCPartition)
        environment.mount = { _ in
            .init(filesystem: "msdos", identifier: "replacement-mount", mountedFrom: "synthetic-device", mountPoint: root)
        }
        XCTAssertThrowsError(try export(to: root, expected: expected, environment: environment))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testFileArrivingDuringCapacityProbeIsCaughtByFinalDescriptorValidation() throws {
        let root = try fixture()
        let expected = try ExportDestination.capture(at: root).requiringEmpty()
        let original = Data("arrived after allocation probe".utf8)
        XCTAssertThrowsError(try export(to: root, expected: expected, beforeFinalValidation: {
            try original.write(to: root.appendingPathComponent("KEEP.SND"))
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["KEEP.SND"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("KEEP.SND")), original)
    }

    func testDirectoryReplacedDuringCapacityProbeCannotReceiveWritesThroughTheHeldDescriptor() throws {
        let root = try fixture()
        let expected = try ExportDestination.capture(at: root, requireEmpty: true)
        let old = root.deletingLastPathComponent().appendingPathComponent("RenamedAfterOpen")
        XCTAssertThrowsError(try export(to: root, expected: expected, beforeFinalValidation: {
            try FileManager.default.moveItem(at: root, to: old)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: old.path).isEmpty)
    }

    func testFATBecomingUnverifiableImmediatelyBeforeCreationPreservesDestination() throws {
        let root = try fixture(named: "MPC-PART--E")
        var uncertain = false
        var environment = simulatedFAT(root: root)
        environment.fatUsage = { _ in
            if uncertain { throw ExportDestinationError.unverified("simulated read failure") }
            return .init(allocationUnitBytes: 8192, occupiedBytes: try self.allocatedBytes(in: root))
        }
        let expected = try ExportDestination.capture(at: root, requireEmpty: true, environment: environment)
        XCTAssertThrowsError(try export(to: root, expected: expected, environment: environment,
                                       beforeFinalValidation: { uncertain = true }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testDuplicateNativeNamesPreventWritingAnOtherwiseCoherentFATVolume() throws {
        let root = try fixture(named: "MPC-PART--A")
        let original = Data("old kit".utf8)
        try original.write(to: root.appendingPathComponent("KEEP.PGM"))
        var environment = simulatedFAT(root: root)
        environment.names = { descriptor in
            let names = try ExportDestination.nativeNames(directoryFD: descriptor)
            return names + ["KEEP.PGM"]
        }
        XCTAssertThrowsError(try export(to: root, environment: environment))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["KEEP.PGM"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("KEEP.PGM")), original)
    }

    func testFSKitAndLegacyCountersNormalizeToExactlyTheSameAllocatedDataClusters() throws {
        // Captured PART A: 992 data clusters, 744 allocated. FSKit reports 993 blocks.
        let fsKit = try ExportDestination.normalizedFATUsage(allocationUnitBytes: 8192,
            totalBlocks: 993, freeBlocks: 248, isFSKit: true, rootAllocationIsFixed: true)
        let legacy = try ExportDestination.normalizedFATUsage(allocationUnitBytes: 8192,
            totalBlocks: 992, freeBlocks: 248, isFSKit: false, rootAllocationIsFixed: true)
        XCTAssertEqual(fsKit, legacy)
        XCTAssertEqual(fsKit.occupiedBytes, 744 * 8192)
        // Empty E/G/H have two data clusters for .fseventsd and its UUID file.
        let empty = try ExportDestination.normalizedFATUsage(allocationUnitBytes: 8192,
            totalBlocks: 997, freeBlocks: 994, isFSKit: true, rootAllocationIsFixed: true)
        XCTAssertEqual(empty.occupiedBytes, 2 * 8192)
        XCTAssertThrowsError(try ExportDestination.normalizedFATUsage(allocationUnitBytes: 8192,
            totalBlocks: 997, freeBlocks: 997, isFSKit: true, rootAllocationIsFixed: true))
    }

    func testOverreportedRootAllocationCannotMaskAnInconsistentFATUsage() throws {
        let root = try fixture(named: "MPC-PART--E")
        try Data(repeating: 1, count: 16_384).write(to: root.appendingPathComponent(".metadata"))
        var environment = simulatedFAT(root: root)
        environment.fatUsage = { _ in
            .init(allocationUnitBytes: 8192, occupiedBytes: try self.allocatedBytes(in: root) - 8192)
        }
        XCTAssertThrowsError(try export(to: root, environment: environment))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [".metadata"])
    }

    func testCoherentOccupiedFATStillAcceptsANewKitWithoutChangingOriginals() throws {
        let root = try fixture(named: "MPC-PART--E")
        let original = Data("original sample".utf8)
        try original.write(to: root.appendingPathComponent("KEEP.SND"))
        let environment = simulatedFAT(root: root)
        let expected = try ExportDestination.capture(at: root, environment: environment)
        let output = try export(to: root, expected: expected, environment: environment)
        XCTAssertEqual(output.lastPathComponent, "NEW.PGM")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("KEEP.SND")), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["KEEP.SND", "NEW.PGM"])
    }

    func testNormalLocalFolderRemainsExportableAndNativeInventoriesCanBeRepeated() throws {
        let root = try fixture()
        let expected = try ExportDestination.capture(at: root, requireEmpty: true)
        XCTAssertFalse(expected.isMountedMPCPartition)
        let output = try export(to: root, expected: expected)
        let descriptor = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = close(descriptor) }
        XCTAssertEqual(try ExportDestination.nativeNames(directoryFD: descriptor), ["NEW.PGM"])
        XCTAssertEqual(try ExportDestination.nativeNames(directoryFD: descriptor), ["NEW.PGM"])
        XCTAssertEqual(try MPCProgram(data: Data(contentsOf: output)).name, "NEW")
    }
}
