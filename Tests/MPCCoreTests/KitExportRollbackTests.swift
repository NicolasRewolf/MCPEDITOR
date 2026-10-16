import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import MPCCore

/// Failure handling deliberately preserves artifacts: a public stat/unlink pair
/// cannot guarantee that another writer has not taken over the checked name.
final class KitExportRollbackTests: XCTestCase {
    private func fixture() throws -> (URL, MPCProgram, [Int: MPCSound]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitExportRollbackTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("original must stay".utf8).write(to: directory.appendingPathComponent("KEEP.SND"))
        var program = MPCProgram.blank(name: "KIT")
        var sounds: [Int: MPCSound] = [:]
        for (slot, name) in ["FIRST", "SECOND"].enumerated() {
            program.assign(slot: slot, toNote: program.midiNote(forPad: slot))
            program.setSound(slot: slot, name: name, wordCount: 512)
            sounds[slot] = MPCSound(name: name, channels: [Array(repeating: 0.25, count: 512)])
        }
        return (directory, program, sounds)
    }

    private func failDuringSecondFile(_ io: inout KitExport.FileIO) {
        var calls = 0
        io.writeBytes = { descriptor, bytes, count in
            calls += 1
            if calls == 2 { return write(descriptor, bytes, min(16, count)) }
            if calls == 3 { errno = ENOSPC; return -1 }
            return write(descriptor, bytes, count)
        }
    }

    func testPartialFailurePreservesNamedArtifactsAndClosesAllDescriptors() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        failDuringSecondFile(&io)
        var closed: [Int32] = []
        io.closeFile = { descriptor in closed.append(descriptor); return close(descriptor) }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(let cause, let files) = error else {
                return XCTFail("Artifacts must be reported: \(error)")
            }
            XCTAssertTrue(cause.contains("SECOND.SND"))
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND"])
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("FIRST.SND")).count, 1_062)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("SECOND.SND")).count, 16)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("KEEP.SND")), Data("original must stay".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("KIT.PGM").path))
        XCTAssertEqual(closed.count, 2)
        for descriptor in closed {
            var info = stat()
            XCTAssertEqual(fstat(descriptor, &info), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testConcurrentReplacementSurvivesFailureWithoutAnyDestructiveCleanup() throws {
        let (directory, program, sounds) = try fixture()
        let first = directory.appendingPathComponent("FIRST.SND")
        let replacement = Data("another writer owns this public name".utf8)
        var io = KitExport.FileIO()
        var calls = 0
        io.writeBytes = { descriptor, bytes, count in
            calls += 1
            if calls == 2 {
                do {
                    try FileManager.default.removeItem(at: first)
                    try replacement.write(to: first)
                } catch { XCTFail("Replacement fixture: \(error)") }
                errno = ENOSPC
                return -1
            }
            return write(descriptor, bytes, count)
        }
        // The old rollback could remove a replacement appearing after fstatat.
        // Failure handling no longer examines native identities or calls unlinkat.
        var nativeIdentityReads = 0
        io.entryInfo = { descriptor, name, info in
            if !name.hasPrefix("._") { nativeIdentityReads += 1 }
            return name.withCString { fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND"])
        }
        XCTAssertEqual(try Data(contentsOf: first), replacement)
        XCTAssertEqual(nativeIdentityReads, 0, "No stat/check/delete sequence remains on failure")
    }

    func testZeroLengthFailureRemainsExplicitRatherThanTrustingAnEmptyFATInode() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        io.writeBytes = { _, _, _ in errno = ENOSPC; return -1 }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["FIRST.SND"])
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("FIRST.SND")).count, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["KEEP.SND", "FIRST.SND"])
    }

    func testSynchronizationFailureLeavesBodyForReviewWithoutPublishingKit() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        io.synchronize = { _ in errno = EIO; return -1 }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["FIRST.SND"])
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("FIRST.SND")).count, 1_062)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("KIT.PGM").path))
    }

    func testCloseFailureAfterPublicationReportsCompleteFilesAndClosesOtherHandles() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        var calls = 0
        io.closeFile = { descriptor in
            calls += 1
            let result = close(descriptor)
            if calls == 1 { errno = EIO; return -1 }
            return result
        }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND", "KIT.PGM"])
        }
        XCTAssertEqual(calls, 3)
        let loaded = try KitLoader.load(programURL: directory.appendingPathComponent("KIT.PGM"))
        XCTAssertTrue(loaded.missing.isEmpty)
        XCTAssertEqual(loaded.sounds.count, 2)
    }

    func testExistingAppleDoubleAndNewSidecarArePreservedAndReported() throws {
        let (directory, program, sounds) = try fixture()
        let originalSidecar = Data("original orphan metadata".utf8)
        try originalSidecar.write(to: directory.appendingPathComponent("._ORIGINAL.SND"))
        let newSidecar = Data("metadata accompanying our created sample".utf8)
        var io = KitExport.FileIO()
        var calls = 0
        io.writeBytes = { descriptor, bytes, count in
            calls += 1
            if calls == 2 {
                do { try newSidecar.write(to: directory.appendingPathComponent("._FIRST.SND")) }
                catch { XCTFail("Sidecar fixture: \(error)") }
                errno = ENOSPC
                return -1
            }
            return write(descriptor, bytes, count)
        }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["FIRST.SND", "._FIRST.SND", "SECOND.SND"])
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("._FIRST.SND")), newSidecar)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("._ORIGINAL.SND")), originalSidecar)
    }

    func testUnverifiableSidecarIsNamedWithoutAnyCleanupAttempt() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        failDuringSecondFile(&io)
        io.entryInfo = { _, _, _ in errno = EIO; return -1 }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["FIRST.SND", "._FIRST.SND", "SECOND.SND", "._SECOND.SND"])
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["KEEP.SND", "FIRST.SND", "SECOND.SND"])
    }

    func testInsufficientOrUnavailableSpaceRejectsBeforeAnyWrite() throws {
        for unavailable in [false, true] {
            let (directory, program, sounds) = try fixture()
            let volume = ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: Int64.max, reservesAppleDouble: true)
            let sizes = try [sounds[0]!.encoded().count, sounds[1]!.encoded().count, program.bytes.count]
            let required = try ExportSpace.estimate(fileSizes: sizes, volume: volume).requiredBytes
            var io = KitExport.FileIO()
            io.volumeSpace = { _ in
                if unavailable { throw ExportSpaceError.unavailable }
                return ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: required - 1, reservesAppleDouble: true)
            }
            var writes = 0
            io.writeBytes = { descriptor, bytes, count in writes += 1; return write(descriptor, bytes, count) }
            XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
                if unavailable {
                    guard case ExportSpaceError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
                } else {
                    guard case ExportSpaceError.insufficientSpace(let needed, let available) = error else { return XCTFail("Unexpected error: \(error)") }
                    XCTAssertEqual(needed, required)
                    XCTAssertEqual(available, required - 1)
                }
            }
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["KEEP.SND"])
        }
    }
}
