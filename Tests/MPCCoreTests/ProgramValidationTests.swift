import Foundation
import XCTest
@testable import MPCCore

final class ProgramValidationTests: XCTestCase {
    private let assignmentBase = 2690 + 62
    private let padMapBase = 2690 + 1854

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgramValidationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testKnownAssignmentsAcceptOnlySoundSlotsOrEmptyWithoutChangingImage() throws {
        let original = MPCProgram.blank(name: "VALIDATE")
        for note in 35...98 {
            for value: UInt8 in [0, 127, 128, 254, 255] {
                var program = original
                program.bytes[assignmentBase + (note - 35) * 24] = value
                let before = program.bytes
                if value < 128 || value == 255 {
                    XCTAssertNoThrow(try program.validateKnownFields())
                } else {
                    XCTAssertThrowsError(try program.validateKnownFields()) { error in
                        XCTAssertTrue(error.localizedDescription.contains("note MIDI \(note)"))
                        XCTAssertTrue(error.localizedDescription.contains("index de son \(value)"))
                    }
                }
                XCTAssertEqual(program.bytes, before)
            }
        }
    }

    func testPadMapRejectsOutOfRangeNotesAndIdentifiesBankAndPad() throws {
        let original = MPCProgram.blank(name: "PADMAP")
        for pad in 0..<64 {
            for value: UInt8 in [0, 34, 35, 98, 99, 255] {
                var program = original
                program.bytes[padMapBase + pad] = value
                let before = program.bytes
                if (35...98).contains(value) {
                    XCTAssertNoThrow(try program.validateKnownFields())
                } else {
                    XCTAssertThrowsError(try program.validateKnownFields()) { error in
                        let label = ["A", "B", "C", "D"][pad / 16] + String(format: "%02d", pad % 16 + 1)
                        XCTAssertTrue(error.localizedDescription.contains("pad \(label)"))
                        XCTAssertTrue(error.localizedDescription.contains("note MIDI \(value)"))
                    }
                }
                XCTAssertEqual(program.bytes, before)
            }
        }
    }

    func testValidationRechecksPubliclyMutableShapeAndSignature() throws {
        let original = MPCProgram.blank(name: "MUTABLE")
        var shortened = original
        shortened.bytes.removeLast()
        XCTAssertThrowsError(try shortened.validateKnownFields())
        var sliced = original
        sliced.bytes = Data([0]) + original.bytes
        sliced.bytes.removeFirst()
        XCTAssertNoThrow(try sliced.validateKnownFields())
        var wrongSignature = original
        wrongSignature.bytes[1] = 1
        XCTAssertThrowsError(try wrongSignature.validateKnownFields())
    }

    func testLoaderRejectsMalformedKnownFieldsAndPreservesOriginalBytes() throws {
        let folder = try directory()
        let input = folder.appendingPathComponent("INPUT.PGM")
        let original = MPCProgram.blank(name: "INPUT")
        for (position, value, expected) in [
            (assignmentBase + 2 * 24, UInt8(128), "note MIDI 37"),
            (assignmentBase + 63 * 24, UInt8(254), "note MIDI 98"),
            (padMapBase, UInt8(34), "pad A01"),
            (padMapBase + 63, UInt8(99), "pad D16")
        ] {
            var bytes = original.bytes
            bytes[position] = value
            try bytes.write(to: input)
            // Inspection keeps the invalid value available; loading a kit refuses it.
            XCTAssertEqual(try MPCProgram(data: bytes).bytes, bytes)
            XCTAssertThrowsError(try KitLoader.load(programURL: input)) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected))
            }
            XCTAssertEqual(try Data(contentsOf: input), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["INPUT.PGM"])
        }
    }

    func testLoaderAndExporterAcceptZeroLastSlotAndEmptyAssignments() throws {
        let sourceFolder = try directory()
        let outputFolder = try directory()
        var program = MPCProgram.blank(name: "BOUNDARIES")
        for (slot, note) in [(0, 35), (127, 98)] {
            program.assign(slot: slot, toNote: note)
            program.setSound(slot: slot, name: "SHARED", wordCount: 441)
        }
        let sound = MPCSound(name: "SHARED", channels: [[Float](repeating: 0.25, count: 441)])
        let input = sourceFolder.appendingPathComponent("SOURCE.PGM")
        try program.bytes.write(to: input)
        let sourceSound = try sound.encoded()
        try sourceSound.write(to: sourceFolder.appendingPathComponent("SHARED.SND"))
        let loaded = try KitLoader.load(programURL: input)
        XCTAssertTrue(loaded.missing.isEmpty)
        XCTAssertEqual(Set(loaded.sounds.keys), [0, 127])
        XCTAssertEqual(loaded.program.bytes, program.bytes)
        let exported = try KitExport.export(program: loaded.program, sounds: loaded.sounds,
                                            name: "COPY", to: outputFolder)
        let reloaded = try KitLoader.load(programURL: exported)
        XCTAssertTrue(reloaded.missing.isEmpty)
        XCTAssertEqual(reloaded.program.slot(forNote: 35), 0)
        XCTAssertEqual(reloaded.program.slot(forNote: 98), 127)
        for note in 36..<98 { XCTAssertNil(reloaded.program.slot(forNote: note)) }
        XCTAssertEqual(try Data(contentsOf: input), program.bytes)
        XCTAssertEqual(try Data(contentsOf: sourceFolder.appendingPathComponent("SHARED.SND")), sourceSound)
    }

    func testExporterRejectsMalformedKnownFieldsBeforeAnyFileCreation() throws {
        let folder = try directory()
        let sentinel = folder.appendingPathComponent("KEEP.SND")
        let sentinelBytes = Data([1, 2, 3, 4])
        try sentinelBytes.write(to: sentinel)
        let original = MPCProgram.blank(name: "INVALID")
        for (position, value) in [
            (assignmentBase + 2 * 24, UInt8(128)),
            (assignmentBase + 63 * 24, UInt8(254)),
            (padMapBase, UInt8(34)),
            (padMapBase + 63, UInt8(99))
        ] {
            var program = original
            program.bytes[position] = value
            let before = program.bytes
            XCTAssertThrowsError(try KitExport.export(program: program, sounds: [:], name: "COPY", to: folder)) { error in
                guard case MPCFormatError.invalid = error else {
                    return XCTFail("Expected the explicit format preflight, got \(error)")
                }
            }
            XCTAssertEqual(program.bytes, before)
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["KEEP.SND"])
        }
    }

    func testRepositoryReferenceProgramsRemainValidAndByteExact() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../..", isDirectory: true).standardizedFileURL
        let folders = [
            "ressources/incoming/03_physical_vailixi350",
            "ressources/incoming/01_izzyreal_mpc/test-resources/RealMpc3000"
        ].map { root.appendingPathComponent($0, isDirectory: true) }
        guard folders.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("The full repository's reference corpus is not included with a standalone KitStudio package.")
        }
        var programs: [URL] = []
        for folder in folders {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
            programs += enumerator.compactMap { $0 as? URL }.filter {
                $0.pathExtension.lowercased() == "pgm" &&
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
        XCTAssertEqual(programs.count, 17)
        for url in programs {
            let bytes = try Data(contentsOf: url)
            let program = try MPCProgram(data: bytes)
            XCTAssertNoThrow(try program.validateKnownFields(), url.path)
            XCTAssertEqual(program.bytes, bytes, url.path)
            XCTAssertEqual(try Data(contentsOf: url), bytes, url.path)
        }
    }

    func testProgramAndSoundTransfersKeepIndependentValueCopies() async throws {
        let originalProgram = MPCProgram.blank(name: "SOURCE")
        let originalSound = MPCSound(name: "SOURCE", channels: [[Float](repeating: 0.25, count: 441)])
        let snapshot = LoadedKit(program: originalProgram, sounds: [0: originalSound], missing: [])
        let edited = await Task.detached {
            var program = snapshot.program
            var sound = snapshot.sounds[0]!
            program.name = "COPY"
            sound.name = "COPY"
            sound.channels[0][0] = -0.5
            return LoadedKit(program: program, sounds: [0: sound], missing: [])
        }.value
        XCTAssertEqual(edited.program.name, "COPY")
        XCTAssertEqual(edited.sounds[0]?.channels[0][0], -0.5)
        XCTAssertEqual(snapshot.program.bytes, originalProgram.bytes)
        XCTAssertEqual(snapshot.sounds[0]?.channels[0][0], 0.25)
    }
}
