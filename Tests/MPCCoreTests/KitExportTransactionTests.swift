import Foundation
import XCTest
import Darwin
@testable import MPCCore

final class KitExportTransactionTests: XCTestCase {
    private static let crashEnvironment = "MPC_KIT_EXPORT_INTERRUPTION_TEST"

    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitExportTransactionTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func kit() -> (MPCProgram, [Int: MPCSound]) {
        var program = MPCProgram.blank(name: "KIT")
        var sounds: [Int: MPCSound] = [:]
        for (slot, name) in ["FIRST", "SECOND"].enumerated() {
            program.assign(slot: slot, toNote: program.midiNote(forPad: slot))
            program.setSound(slot: slot, name: name, wordCount: 512)
            sounds[slot] = MPCSound(name: name, channels: [Array(repeating: 0.25, count: 512)])
        }
        return (program, sounds)
    }

    func testInterruptedProgramWriteNeverPublishesOrIndexesATruncatedKit() throws {
        if let path = ProcessInfo.processInfo.environment[Self.crashEnvironment] {
            guard URL(fileURLWithPath: path).lastPathComponent.hasPrefix("KitExportTransactionTests-") else { _exit(87) }
            let (program, sounds) = kit()
            var io = KitExport.FileIO()
            var writes = 0
            io.writeBytes = { descriptor, bytes, count in
                writes += 1
                if writes == 3 {
                    guard write(descriptor, bytes, min(16, count)) == 16 else { _exit(88) }
                    _exit(86) // No catch/defer executes: real process interruption.
                }
                return write(descriptor, bytes, count)
            }
            _ = try KitExport.export(program: program, sounds: sounds, name: "KIT", to: URL(fileURLWithPath: path), io: io)
            return XCTFail("Child export did not interrupt")
        }
        let destination = try directory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "MPCCoreTests.KitExportTransactionTests/testInterruptedProgramWriteNeverPublishesOrIndexesATruncatedKit", Bundle(for: KitExportTransactionTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.crashEnvironment] = destination.path
        process.environment = environment
        let log = destination.appendingPathComponent("child.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let logText = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 86, logText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("KIT.PGM").path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("KIT.TMP")).count, 16)
        XCTAssertTrue(try LibraryIndex.scanKits(in: destination).isEmpty)
        let (program, sounds) = kit()
        let output = try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination)
        XCTAssertEqual(output.lastPathComponent, "KIT1.PGM", "Retained temporary stem is reserved on retry")
        XCTAssertEqual(try Data(contentsOf: output).count, 4_608)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("KIT.TMP")).count, 16, "Retry never removes earlier artifacts")
    }

    func testInterruptionPhaseMatrixNeverExposesPartialFinalProgram() throws {
        let key = "MPC_KIT_EXPORT_PHASE_TEST"
        if let phase = ProcessInfo.processInfo.environment[key],
           let path = ProcessInfo.processInfo.environment[key + "_PATH"] {
            guard URL(fileURLWithPath: path).lastPathComponent.hasPrefix("KitExportTransactionTests-") else { _exit(87) }
            let (program, sounds) = kit()
            var io = KitExport.FileIO()
            if phase == "before-creation" { io.volumeSpace = { _ in _exit(86) } }
            var writes = 0
            io.writeBytes = { descriptor, bytes, count in
                writes += 1
                if (phase == "first-before" && writes == 1) || (phase == "program-before" && writes == 3) { _exit(86) }
                if (phase == "first-partial" && writes == 1) || (phase == "second-partial" && writes == 2) {
                    guard write(descriptor, bytes, min(16, count)) == 16 else { _exit(88) }
                    _exit(86)
                }
                return write(descriptor, bytes, count)
            }
            var synchronizations = 0
            io.synchronize = { descriptor in
                synchronizations += 1
                let result = fsync(descriptor)
                if result == 0 && ((phase == "first-synced" && synchronizations == 1) || (phase == "second-synced" && synchronizations == 2) || (phase == "program-synced" && synchronizations == 3)) { _exit(86) }
                return result
            }
            let publish = io.publishProgram
            io.publishProgram = { descriptor, temporary, final in
                if phase == "before-publication" { _exit(86) }
                let result = publish(descriptor, temporary, final)
                if result == 0 && phase == "after-publication" { _exit(86) }
                return result
            }
            _ = try KitExport.export(program: program, sounds: sounds, name: "KIT", to: URL(fileURLWithPath: path), io: io)
            return XCTFail("Child did not interrupt at \(phase)")
        }
        let phases = ["before-creation", "first-before", "first-partial", "first-synced", "second-partial", "second-synced", "program-before", "program-synced", "before-publication", "after-publication"]
        for phase in phases {
            let destination = try directory()
            let original = Data("original sample must survive every phase".utf8)
            try original.write(to: destination.appendingPathComponent("KEEP.SND"))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "MPCCoreTests.KitExportTransactionTests/testInterruptionPhaseMatrixNeverExposesPartialFinalProgram", Bundle(for: KitExportTransactionTests.self).bundleURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment[key] = phase
            environment[key + "_PATH"] = destination.path
            child.environment = environment
            let log = destination.appendingPathComponent("child.log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let handle = try FileHandle(forWritingTo: log)
            child.standardOutput = handle
            child.standardError = handle
            try child.run()
            child.waitUntilExit()
            try handle.close()
            let logText = String(decoding: try Data(contentsOf: log), as: UTF8.self)
            XCTAssertEqual(child.terminationStatus, 86, "Phase \(phase): \(logText)")
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("KEEP.SND")), original, phase)
            let final = destination.appendingPathComponent("KIT.PGM")
            if phase == "after-publication" {
                XCTAssertEqual(try Data(contentsOf: final).count, 4_608)
                XCTAssertEqual(try KitLoader.load(programURL: final).sounds.count, 2)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: final.path), phase)
                XCTAssertTrue(try LibraryIndex.scanKits(in: destination).isEmpty, phase)
            }
            let retainedNames = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            let retainedBodies = try Dictionary(uniqueKeysWithValues: retainedNames.map {
                ($0, try Data(contentsOf: destination.appendingPathComponent($0)))
            })
            let (program, sounds) = kit()
            let retried = try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination)
            XCTAssertEqual(try KitLoader.load(programURL: retried).sounds.count, 2, phase)
            for (name, data) in retainedBodies {
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), data, "Retry must retain \(name) after \(phase)")
            }
        }
    }

    func testPublicationOccursOnlyAfterCompleteStagedProgramAndSamples() throws {
        let destination = try directory()
        let (program, sounds) = kit()
        var io = KitExport.FileIO()
        let publish = io.publishProgram
        var publications = 0
        io.publishProgram = { descriptor, temporary, final in
            publications += 1
            XCTAssertEqual(temporary, "KIT.TMP")
            XCTAssertEqual(final, "KIT.PGM")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(final).path))
            do {
                let staged = try Data(contentsOf: destination.appendingPathComponent(temporary))
                XCTAssertEqual(staged.count, 4_608)
                for name in ["FIRST.SND", "SECOND.SND"] {
                    let sound = try MPCSound.decode(Data(contentsOf: destination.appendingPathComponent(name)))
                    XCTAssertEqual(sound.frameCount, 512)
                }
            } catch { XCTFail("Incomplete staged bodies: \(error)") }
            return publish(descriptor, temporary, final)
        }
        let output = try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination, io: io)
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("KIT.TMP").path))
        XCTAssertEqual(try KitLoader.load(programURL: output).sounds.count, 2)
    }

    func testLateProgramCollisionIsNeverReplacedAndTemporaryIsReported() throws {
        let destination = try directory()
        let final = destination.appendingPathComponent("KIT.PGM")
        let foreignProgram = Data("another writer's program".utf8)
        let (program, sounds) = kit()
        var io = KitExport.FileIO()
        let publish = io.publishProgram
        io.publishProgram = { descriptor, temporary, name in
            do { try foreignProgram.write(to: final) }
            catch { XCTFail("Collision fixture: \(error)") }
            return publish(descriptor, temporary, name)
        }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination, io: io)) { error in
            guard case KitExportError.incompleteRollback(let cause, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(cause.contains("KIT.PGM"))
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND", "KIT.TMP"])
        }
        XCTAssertEqual(try Data(contentsOf: final), foreignProgram)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("KIT.TMP")).count, 4_608)
    }

    func testLateTemporarySymlinkCollisionPreservesForeignTargetAndPublishesNothing() throws {
        let destination = try directory()
        let target = destination.appendingPathComponent("outside-reference.bin")
        let original = Data("preexisting target must stay untouched".utf8)
        try original.write(to: target)
        var io = KitExport.FileIO()
        io.volumeSpace = { descriptor in
            let volume = try ExportSpace.volume(directoryFD: descriptor)
            try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("KIT.TMP"), withDestinationURL: target)
            return volume
        }
        let (program, sounds) = kit()
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination, io: io)) { error in
            guard case KitExportError.incompleteRollback(let cause, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(cause.contains("KIT.TMP"))
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND"])
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("KIT.TMP").path), target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("KIT.PGM").path))
    }

    func testUnavailableCompletedBodyIdentityPreventsPublicationAndNamesAllArtifacts() throws {
        let destination = try directory()
        let (program, sounds) = kit()
        var io = KitExport.FileIO()
        io.descriptorInfo = { _, _ in errno = EIO; return -1 }
        var publications = 0
        io.publishProgram = { _, _, _ in publications += 1; return 0 }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination, io: io)) { error in
            guard case KitExportError.incompleteRollback(_, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND", "KIT.TMP"])
        }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("KIT.TMP")).count, 4_608)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("KIT.PGM").path))
    }

    func testRenamedDestinationDuringWriteRefusesSuccessAndNamesActualDirectory() throws {
        let parent = try directory()
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let (program, sounds) = kit()
        var io = KitExport.FileIO()
        var writes = 0
        io.writeBytes = { descriptor, bytes, count in
            writes += 1
            let result = write(descriptor, bytes, count)
            if writes == 1 {
                do {
                    try FileManager.default.moveItem(at: selected, to: moved)
                    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
                } catch { XCTFail("Rename fixture: \(error)") }
            }
            return result
        }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: selected, io: io)) { error in
            guard case KitExportError.incompleteRollback(let cause, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(cause.contains("destination a changé"))
            XCTAssertTrue(cause.contains("moved"), "Current descriptor path should be explicit")
            XCTAssertFalse(cause.contains("Aucun fichier n’a été créé"))
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND", "KIT.TMP"])
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: moved.path)), ["FIRST.SND", "SECOND.SND", "KIT.TMP"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("KIT.PGM").path))
    }

    func testRenameAfterPublicationStillRefusesAStaleSuccessURL() throws {
        let parent = try directory()
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        let moved = parent.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let (program, sounds) = kit()
        var io = KitExport.FileIO()
        let publish = io.publishProgram
        io.publishProgram = { descriptor, temporary, final in
            let result = publish(descriptor, temporary, final)
            if result == 0 {
                do {
                    try FileManager.default.moveItem(at: selected, to: moved)
                    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
                } catch { XCTFail("Rename fixture: \(error)") }
            }
            return result
        }
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: selected, io: io)) { error in
            guard case KitExportError.incompleteRollback(let cause, let files) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(cause.contains("moved"))
            XCTAssertEqual(files, ["FIRST.SND", "SECOND.SND", "KIT.PGM"])
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: selected.path).isEmpty)
        XCTAssertEqual(try KitLoader.load(programURL: moved.appendingPathComponent("KIT.PGM")).sounds.count, 2)
    }

    func testEINTRAndShortWritesRetainEveryByte() throws {
        let destination = try directory()
        let (program, sounds) = kit()
        var io = KitExport.FileIO()
        var calls = 0
        io.writeBytes = { descriptor, bytes, count in
            calls += 1
            if calls % 5 == 1 { errno = EINTR; return -1 }
            return write(descriptor, bytes, min(17, count))
        }
        let output = try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination, io: io)
        XCTAssertEqual(try Data(contentsOf: output).count, 4_608)
        for name in ["FIRST.SND", "SECOND.SND"] {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)).count, 1_062)
        }
        XCTAssertGreaterThan(calls, 300)
    }

    func testLateSampleSymlinkCollisionPreservesLinkAndItsTarget() throws {
        let destination = try directory()
        let target = destination.appendingPathComponent("outside-reference.bin")
        let original = Data("preserve existing target".utf8)
        try original.write(to: target)
        var io = KitExport.FileIO()
        io.volumeSpace = { descriptor in
            let volume = try ExportSpace.volume(directoryFD: descriptor)
            try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("FIRST.SND"), withDestinationURL: target)
            return volume
        }
        let (program, sounds) = kit()
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: sounds, name: "KIT", to: destination, io: io)) { error in
            guard case KitExportError.io("FIRST.SND", EEXIST) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("FIRST.SND").path), target.path)
    }
}
