import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import MPCCore

final class KitExportRollbackTests: XCTestCase {
    private func fixture() throws -> (URL, MPCProgram, [Int: MPCSound]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitExportRollbackTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("original must stay".utf8).write(to: directory.appendingPathComponent("KEEP.SND"))
        var program = MPCProgram.blank(name: "KIT")
        let names = ["FIRST", "SECOND"]
        var sounds: [Int: MPCSound] = [:]
        for (slot, name) in names.enumerated() {
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

    func testPartialWriteFailureRemovesEveryOwnedNewFileAndClosesTheirHandles() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        failDuringSecondFile(&io)
        var closed: [Int32] = []
        io.closeFile = { descriptor in
            closed.append(descriptor)
            return close(descriptor)
        }

        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.io(let name, let code) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, "SECOND.SND")
            XCTAssertEqual(code, ENOSPC)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["KEEP.SND"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("KEEP.SND")), Data("original must stay".utf8))
        XCTAssertEqual(closed.count, 2)
        for descriptor in closed {
            var info = stat()
            XCTAssertEqual(fstat(descriptor, &info), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testRollbackUsesLiveAllocatedIdentityInsteadOfTheEmptyFilesInitialIdentity() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        failDuringSecondFile(&io)
        var observedDescriptorSizes: [off_t] = []
        io.descriptorInfo = { descriptor, info in
            let result = fstat(descriptor, &info)
            if result == 0 {
                observedDescriptorSizes.append(info.st_size)
                if info.st_size > 0 { info.st_ino &+= 10_000 }
            }
            return result
        }
        io.entryInfo = { descriptor, name, info in
            let result = name.withCString { fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
            if result == 0, info.st_size > 0 { info.st_ino &+= 10_000 }
            return result
        }

        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.io(_, ENOSPC) = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(observedDescriptorSizes.sorted(), [16, 1_062])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["KEEP.SND"])
    }

    func testConcurrentReplacementIsPreservedAndReportedInsteadOfSilentlySkipped() throws {
        let (directory, program, sounds) = try fixture()
        let replacement = Data("another writer owns this path".utf8)
        let first = directory.appendingPathComponent("FIRST.SND")
        var io = KitExport.FileIO()
        var calls = 0
        io.writeBytes = { descriptor, bytes, count in
            calls += 1
            if calls == 2 {
                do {
                    try FileManager.default.removeItem(at: first)
                    try replacement.write(to: first)
                } catch { XCTFail("Could not install replacement: \(error)") }
                errno = ENOSPC
                return -1
            }
            return write(descriptor, bytes, count)
        }

        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else {
                return XCTFail("Unverified cleanup must be reported: \(error)")
            }
            XCTAssertEqual(files, ["FIRST.SND"])
        }

        XCTAssertEqual(try Data(contentsOf: first), replacement)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["KEEP.SND", "FIRST.SND"])
    }

    func testEmptyFATIdentityIsAmbiguousSoTheFileIsLeftAndExplicitlyReported() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        io.writeBytes = { _, _, _ in errno = ENOSPC; return -1 }
        io.canIdentifyEmptyFile = { _ in false }
        var removals: [String] = []
        io.removeEntry = { _, name in removals.append(name); return 0 }

        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else {
                return XCTFail("Ambiguous FAT ownership must be reported: \(error)")
            }
            XCTAssertEqual(files, ["FIRST.SND"])
        }

        XCTAssertTrue(removals.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("FIRST.SND")).count, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["KEEP.SND", "FIRST.SND"])
    }

    func testUnavailableIdentityAndUnlinkFailureAreAlwaysReported() throws {
        for failure in ["descriptor", "entry", "unlink"] {
            let (directory, program, sounds) = try fixture()
            var io = KitExport.FileIO()
            failDuringSecondFile(&io)
            switch failure {
            case "descriptor": io.descriptorInfo = { _, _ in errno = EIO; return -1 }
            case "entry": io.entryInfo = { _, _, _ in errno = EIO; return -1 }
            default: io.removeEntry = { _, _ in errno = EPERM; return -1 }
            }

            XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
                guard case KitExportError.incompleteRollback(_, let files) = error else {
                    return XCTFail("Failed \(failure) verification must be reported: \(error)")
                }
                XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND"])
            }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["KEEP.SND", "FIRST.SND", "SECOND.SND"])
        }
    }

    func testFileSynchronizationFailureRollsBackTheOwnedFile() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        var calls = 0
        io.synchronize = { descriptor in
            calls += 1
            if calls == 1 { errno = EIO; return -1 }
            return fsync(descriptor)
        }

        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.io("FIRST.SND", EIO) = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["KEEP.SND"])
    }

    func testCloseFailureAfterCommitReportsCopiesForReviewAndNeverRemovesThem() throws {
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
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["KEEP.SND", "FIRST.SND", "SECOND.SND", "KIT.PGM"])
        let loaded = try KitLoader.load(programURL: directory.appendingPathComponent("KIT.PGM"))
        XCTAssertTrue(loaded.missing.isEmpty)
        XCTAssertEqual(loaded.sounds.count, 2)
    }

    func testMetadataLeftAfterNativeUnlinkIsReportedAndNeverExplicitlyDeleted() throws {
        let (directory, program, sounds) = try fixture()
        var io = KitExport.FileIO()
        failDuringSecondFile(&io)
        let metadata = Data("metadata whose cleanup failed".utf8)
        var removedNames: [String] = []
        io.removeEntry = { descriptor, name in
            removedNames.append(name)
            let result = name.withCString { unlinkat(descriptor, $0, 0) }
            if name == "FIRST.SND", result == 0 {
                do { try metadata.write(to: directory.appendingPathComponent("._FIRST.SND")) }
                catch { XCTFail("Could not simulate metadata residue: \(error)") }
            }
            return result
        }

        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["._FIRST.SND"])
        }

        XCTAssertEqual(Set(removedNames), ["FIRST.SND", "SECOND.SND"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("._FIRST.SND")), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("FIRST.SND").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SECOND.SND").path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("KEEP.SND")), Data("original must stay".utf8))
    }

    func testInsufficientOrUnavailableSpaceRejectsExportBeforeAnyWrite() throws {
        for unavailable in [false, true] {
            let (directory, program, sounds) = try fixture()
            let volume = ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: Int64.max,
                                           reservesAppleDouble: true)
            let sizes = try [sounds[0]!.encoded().count, sounds[1]!.encoded().count, program.bytes.count]
            let required = try ExportSpace.estimate(fileSizes: sizes, volume: volume).requiredBytes
            var io = KitExport.FileIO()
            io.volumeSpace = { _ in
                if unavailable { throw ExportSpaceError.unavailable }
                return ExportVolumeSpace(allocationUnitBytes: 8192, availableBytes: required - 1,
                                         reservesAppleDouble: true)
            }
            var writes = 0
            io.writeBytes = { descriptor, bytes, count in
                writes += 1
                return write(descriptor, bytes, count)
            }

            XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: directory, io: io)) { error in
                if unavailable {
                    guard case ExportSpaceError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
                } else {
                    guard case ExportSpaceError.insufficientSpace(let needed, let available) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(needed, required)
                    XCTAssertEqual(available, required - 1)
                }
            }

            XCTAssertEqual(writes, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["KEEP.SND"])
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("KEEP.SND")), Data("original must stay".utf8))
        }
    }
}
