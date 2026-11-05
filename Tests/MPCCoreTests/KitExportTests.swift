import Foundation
import XCTest
@testable import MPCCore

final class KitExportTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitExportTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func sound(_ name: String, stereo: Bool = false) -> MPCSound {
        let channel = (0..<512).map { Float($0 % 32) / 64 - 0.25 }
        return MPCSound(name: name, channels: stereo ? [channel, channel.map { -$0 }] : [channel])
    }

    func testPreparedCopySizesMatchActualExportWithSharedSlotsAndUnusedSounds() throws {
        var sourceWithTrailingBytes = try sound("TRAILING", stereo: true).encoded()
        sourceWithTrailingBytes.append(Data(repeating: 0xA5, count: 127))
        let trailing = try MPCSound.decode(sourceWithTrailingBytes)
        var trimmed = trailing
        trimmed.start = 50
        trimmed.end = 500
        let cases = [sound("MONO"), sound("STEREO", stereo: true), trailing, trimmed.trimmed().mono()]

        for audio in cases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var program = MPCProgram.blank(name: "SIZES")
            program.assign(slot: 5, toNote: 35)
            program.assign(slot: 5, toNote: 36)
            program.assign(slot: 17, toNote: 98)
            program.setSound(slot: 5, name: "SAME", wordCount: 1)
            program.setSound(slot: 17, name: "SAME", wordCount: 1)
            program.setSound(slot: 91, name: "UNUSED", wordCount: 999_999)
            // Equal sound values in different slots remain separate SNDs. The unused
            // sound is deliberately invalid and must not enter preparation or export.
            let sounds = [5: audio, 17: audio, 91: MPCSound(name: "UNUSED", channels: [])]
            let prepared = try KitExport.prepareCopy(program: program, sounds: sounds)
            let nativeSize = try audio.encoded().count
            XCTAssertEqual(prepared.fileSizes, [nativeSize, nativeSize, program.bytes.count])

            let output = try KitExport.export(program: program, sounds: sounds, name: "SIZES", to: directory)
            let copiedProgram = try MPCProgram(data: Data(contentsOf: output))
            let actualSizes = try [5, 17].map { slot in
                try Data(contentsOf: directory.appendingPathComponent(copiedProgram.soundName(slot: slot) + ".SND")).count
            } + [Data(contentsOf: output).count]
            XCTAssertEqual(prepared.fileSizes, actualSizes)
            XCTAssertEqual(prepared.nominalBytes, actualSizes.reduce(0) { $0 + Int64($1) })
            XCTAssertEqual(copiedProgram.referencedSlots, [5, 17])
            XCTAssertEqual(copiedProgram.soundName(slot: 91), "")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
            if audio.trailingByteCount > 0 {
                XCTAssertLessThan(nativeSize, sourceWithTrailingBytes.count)
            }
        }
    }

    func testPreparedCopyRejectsMissingOrMalformedContentInsteadOfUnderestimating() throws {
        var program = MPCProgram.blank(name: "INVALID")
        program.assign(slot: 3, toNote: 35)
        XCTAssertThrowsError(try KitExport.prepareCopy(program: program, sounds: [:])) { error in
            guard case KitExportError.missingSounds([3]) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        var mismatched = sound("MISMATCH", stereo: true)
        mismatched.channels[1].removeLast()
        XCTAssertThrowsError(try KitExport.prepareCopy(program: program, sounds: [3: mismatched]))
        var malformed = program
        malformed.bytes.removeLast()
        XCTAssertThrowsError(try KitExport.prepareCopy(program: malformed, sounds: [3: sound("VALID")]))
    }

    func testCopySizePreparationDoesNotReplacePCMValidationAtExport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var program = MPCProgram.blank(name: "NONFINITE")
        program.assign(slot: 3, toNote: 35)
        var audio = sound("NONFINITE")
        let prepared = try KitExport.prepareCopy(program: program, sounds: [3: audio])
        audio.channels[0][0] = .nan
        XCTAssertEqual(try KitExport.prepareCopy(program: program, sounds: [3: audio]).fileSizes,
                       prepared.fileSizes, "Preparation only inspects shape, never each PCM sample.")
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: [3: audio], name: "FAIL", to: directory)) { error in
            guard case KitExportError.invalidPCM16Range(let slot, _, _, let nonFinite) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(slot, 3)
            XCTAssertEqual(nonFinite, 1)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPreparationAppliesAggregatePCMBudgetOncePerReferencedSlot() throws {
        var program = MPCProgram.blank(name: "BUDGET")
        program.assign(slot: 0, toNote: 35)
        program.assign(slot: 0, toNote: 36)
        program.assign(slot: 1, toNote: 98)
        let frames = KitExport.maximumPCMBytes / 4
        var audio = MPCSound(name: "LARGE", channels: [Array(repeating: 0, count: frames)])
        let accepted = try KitExport.prepareCopy(program: program, sounds: [0: audio, 1: audio])
        XCTAssertEqual(accepted.fileSizes.count, 3)
        audio.channels[0].append(0)
        audio.end += 1
        XCTAssertThrowsError(try KitExport.prepareCopy(program: program, sounds: [0: audio, 1: audio])) { error in
            guard case KitExportError.memoryLimitExceeded = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNewNamesAvoidExistingFilesIgnoringCaseAndNeverOverwrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldSound = Data("existing sample".utf8)
        let oldProgram = Data("existing program".utf8)
        try oldSound.write(to: directory.appendingPathComponent("kick.snd"))
        try oldProgram.write(to: directory.appendingPathComponent("kit.pgm"))

        var program = MPCProgram.blank(name: "Original title")
        program.assign(slot: 0, toNote: program.midiNote(forPad: 0))
        program.assign(slot: 17, toNote: 98)
        program.setSound(slot: 0, name: "KICK", wordCount: 512)
        program.setSound(slot: 17, name: "KICK", wordCount: 1024)
        let url = try KitExport.export(
            program: program, sounds: [0: sound("KICK"), 17: sound("KICK", stereo: true)],
            name: "KIT", to: directory
        )

        XCTAssertEqual(url.lastPathComponent, "KIT1.PGM")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("kick.snd")), oldSound)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("kit.pgm")), oldProgram)
        let exported = try MPCProgram(data: Data(contentsOf: url))
        XCTAssertEqual(exported.soundName(slot: 0), "KICK1")
        XCTAssertEqual(exported.soundName(slot: 17), "KICK2")
        for slot in [0, 17] {
            let stem = exported.soundName(slot: slot)
            XCTAssertLessThanOrEqual(stem.utf8.count, 8)
            XCTAssertEqual(stem, stem.uppercased())
            let data = try Data(contentsOf: directory.appendingPathComponent(stem + ".SND"))
            let decoded = try MPCSound.decode(data)
            XCTAssertEqual(decoded.name, stem)
            XCTAssertEqual(decoded.frameCount, 512)
            XCTAssertEqual(decoded.channels.count, slot == 17 ? 2 : 1)
        }
    }

    func testMissingSoundsLeaveDestinationUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = Data("keep".utf8)
        try keep.write(to: directory.appendingPathComponent("KEEP.SND"))
        var program = MPCProgram.blank(name: "Missing")
        program.assign(slot: 9, toNote: 98)
        program.setSound(slot: 9, name: "ABSENT", wordCount: 512)

        XCTAssertThrowsError(try KitExport.export(
            program: program, sounds: [:], name: "KIT", to: directory
        )) { error in
            guard case KitExportError.missingSounds(let slots) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(slots, [9])
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["KEEP.SND"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("KEEP.SND")), keep)
    }

    func testOnlyInventoryChangesAndUnusedInventoryIsCleared() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var program = MPCProgram.blank(name: "Preserved title")
        program.assign(slot: 17, toNote: 98)
        program.setSound(slot: 17, name: "Long sample name", wordCount: 99)
        program.setSound(slot: 91, name: "UNUSED", wordCount: 999)
        let before = program.bytes
        let audio = sound("Long sample name", stereo: true)
        let url = try KitExport.export(
            program: program, sounds: [17: audio], name: "NEW FILE", to: directory
        )
        let output = try Data(contentsOf: url)
        let exported = try MPCProgram(data: output)
        XCTAssertEqual(exported.name, program.name)
        XCTAssertEqual(exported.referencedSlots, Set([17]))
        XCTAssertEqual(exported.soundName(slot: 91), "")

        var expected = program
        for slot in 0..<128 {
            expected.setSound(
                slot: slot, name: slot == 17 ? exported.soundName(slot: 17) : "",
                wordCount: slot == 17 ? 1024 : 0
            )
        }
        XCTAssertEqual(output, expected.bytes)
        // Native PGM: 128 names (17 bytes) plus 128 sizes (four bytes).
        // Everything after this inventory, including routing, remains exact.
        XCTAssertEqual(output.suffix(from: 2690), before.suffix(from: 2690))
        let snd = directory.appendingPathComponent(exported.soundName(slot: 17) + ".SND")
        let decoded = try MPCSound.decode(Data(contentsOf: snd))
        XCTAssertEqual(decoded.channels.count, 2)
        XCTAssertEqual(decoded.frameCount, audio.frameCount)
    }

    func testInvalidAudioFailsBeforeCreatingAnyFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var program = MPCProgram.blank(name: "Short")
        program.assign(slot: 0, toNote: 35)
        program.setSound(slot: 0, name: "SHORT", wordCount: 100)
        let audio = MPCSound(name: "SHORT", channels: [Array(repeating: 0, count: 100)])
        XCTAssertThrowsError(try KitExport.export(
            program: program, sounds: [0: audio], name: "KIT", to: directory
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testEmptyProgramExportsJustProgramAndDoesNotModifyInput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = MPCProgram.blank(name: "Empty")
        let original = program.bytes
        let url = try KitExport.export(program: program, sounds: [:], name: "EMPTY", to: directory)
        XCTAssertEqual(url.lastPathComponent, "EMPTY.PGM")
        XCTAssertEqual(program.bytes, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["EMPTY.PGM"])
        let exported = try MPCProgram(data: Data(contentsOf: url))
        XCTAssertTrue(exported.referencedSlots.isEmpty)
    }

    func testOrphanAppleDoubleReservesItsNativeNameWithoutChangingTheSidecar() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("._sound.snd")
        let metadata = Data("preexisting orphan metadata".utf8)
        try metadata.write(to: sidecar)
        var program = MPCProgram.blank(name: "KIT")
        program.assign(slot: 0, toNote: program.midiNote(forPad: 0))
        program.setSound(slot: 0, name: "SOUND", wordCount: 512)

        let output = try KitExport.export(program: program, sounds: [0: sound("SOUND")], name: "KIT", to: directory)

        let exported = try MPCProgram(data: Data(contentsOf: output))
        XCTAssertEqual(exported.soundName(slot: 0), "SOUND1")
        XCTAssertEqual(try Data(contentsOf: sidecar), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SOUND.SND").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SOUND1.SND").path))
    }
    func testOrphanProgramTemporaryAppleDoubleReservesTheProgramStem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent("._kit.tmp")
        let metadata = Data("orphan temporary metadata must stay".utf8)
        try metadata.write(to: sidecar)
        let output = try KitExport.export(program: MPCProgram.blank(name: "KIT"), sounds: [:], name: "KIT", to: directory)
        XCTAssertEqual(output.lastPathComponent, "KIT1.PGM")
        XCTAssertEqual(try Data(contentsOf: sidecar), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("KIT.TMP").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("KIT.PGM").path))
    }

    func testOutOfRangeWorkingAudioIsExplicitlyRejectedWithoutClippingOrCreatingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = Data("original card sample".utf8)
        try existing.write(to: directory.appendingPathComponent("KEEP.SND"))
        var program = MPCProgram.blank(name: "OVER")
        program.assign(slot: 3, toNote: 35)
        program.setSound(slot: 3, name: "LOUD", wordCount: 512)
        var channel = Array(repeating: Float(0.25), count: 512)
        channel[0] = 1.25
        channel[1] = -1.5
        let sound = MPCSound(name: "LOUD", channels: [channel])
        let originalProgram = program.bytes
        XCTAssertThrowsError(try KitExport.export(program: program, sounds: [3: sound], name: "OVER", to: directory)) { error in
            guard case KitExportError.invalidPCM16Range(let slot, let peak, let outOfRange, let nonFinite) = error else {
                return XCTFail("Range diagnostic must precede any PCM clipping: \(error)")
            }
            XCTAssertEqual(slot, 3)
            XCTAssertEqual(peak, 1.5)
            XCTAssertEqual(outOfRange, 2)
            XCTAssertEqual(nonFinite, 0)
        }
        XCTAssertEqual(sound.channels, [channel], "Export must not normalize or clip working audio")
        XCTAssertEqual(program.bytes, originalProgram)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["KEEP.SND"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("KEEP.SND")), existing)
    }

}
