import Foundation
import XCTest
@testable import MPCCore

final class ProgramPadEditingTests: XCTestCase {
    private let noteBase = 2690 + 62
    private let mixerBase = 2690 + 1598
    private let mapBase = 2690 + 1854

    /// Distinct bytes exercise unknown fields as well as known controls. The
    /// program is never played; these tests concern lossless native editing.
    private func program() -> MPCProgram {
        var program = MPCProgram.blank(name: "PADTEST")
        for pad in 0..<64 { program.bytes[mapBase + pad] = UInt8(35 + pad) }
        for note in 0..<64 {
            for offset in 1..<24 {
                program.bytes[noteBase + note * 24 + offset] = UInt8((note * 7 + offset) % 256)
            }
            for offset in 0..<4 {
                program.bytes[mixerBase + note * 4 + offset] = UInt8((note * 3 + offset) % 256)
            }
        }
        program.assign(slot: 0, toNote: 35)
        program.setSound(slot: 0, name: "KICK", wordCount: 100)
        program.setTune(-437, forNote: 35)
        return program
    }

    func testMoveToEmptyPadPreservesAllNativeBytesExceptTheTwoMapEntries() throws {
        var program = program()
        let before = program.bytes

        try program.transferPad(from: 0, to: 63)

        XCTAssertNil(program.slot(forNote: program.midiNote(forPad: 0)))
        XCTAssertEqual(program.slot(forNote: program.midiNote(forPad: 63)), 0)
        XCTAssertEqual(program.tune(forNote: program.midiNote(forPad: 63)), -437)
        var expected = before
        expected[mapBase] = 98
        expected[mapBase + 63] = 35
        XCTAssertEqual(program.bytes, expected)
        XCTAssertEqual(program.referencedSlots, [0])

        // A move is reversible, including every opaque native byte.
        try program.transferPad(from: 63, to: 0)
        XCTAssertEqual(program.bytes, before)
    }

    func testOccupiedPadsExchangeTheirCompleteBehaviorAcrossBanks() throws {
        var program = program()
        program.assign(slot: 127, toNote: 67)
        program.setSound(slot: 127, name: "SNARE", wordCount: 200)
        program.setTune(812, forNote: 67)
        let before = program.bytes

        try program.transferPad(from: 0, to: 32)

        XCTAssertEqual(program.slot(forNote: program.midiNote(forPad: 0)), 127)
        XCTAssertEqual(program.tune(forNote: program.midiNote(forPad: 0)), 812)
        XCTAssertEqual(program.slot(forNote: program.midiNote(forPad: 32)), 0)
        XCTAssertEqual(program.tune(forNote: program.midiNote(forPad: 32)), -437)
        XCTAssertEqual(program.bytes.prefix(mapBase), before.prefix(mapBase))
        XCTAssertEqual(program.referencedSlots, [0, 127])

        try program.transferPad(from: 0, to: 32)
        XCTAssertEqual(program.bytes, before)
    }

    func testCopyReplacesOnlyDestinationNoteAndMixerAndPreservesReferences() throws {
        var program = program()
        program.assign(slot: 127, toNote: 98)
        program.setSound(slot: 127, name: "REPLACED", wordCount: 50)
        let before = program.bytes
        var expected = before
        expected.replaceSubrange((noteBase + 63 * 24)..<(noteBase + 64 * 24),
                                 with: before[noteBase..<(noteBase + 24)])
        expected.replaceSubrange((mixerBase + 63 * 4)..<(mixerBase + 64 * 4),
                                 with: before[mixerBase..<(mixerBase + 4)])

        try program.transferPad(from: 0, to: 63, copy: true)

        XCTAssertEqual(program.bytes, expected)
        XCTAssertEqual(program.slot(forNote: 35), 0)
        XCTAssertEqual(program.slot(forNote: 98), 0)
        XCTAssertEqual(program.tune(forNote: 98), -437)
        XCTAssertEqual(program.soundName(slot: 127), "REPLACED", "Sound inventory is not implicitly deleted")
        XCTAssertEqual(program.midiNote(forPad: 63), 98)
    }

    func testNonIdentityPadMapUsesMappedNotesForCopy() throws {
        var program = program()
        try program.transferPad(from: 0, to: 16)
        let before = program.bytes

        try program.transferPad(from: 16, to: 1, copy: true)

        XCTAssertEqual(program.slot(forNote: program.midiNote(forPad: 1)), 0)
        XCTAssertEqual(program.tune(forNote: program.midiNote(forPad: 1)), -437)
        XCTAssertEqual(program.bytes[mapBase..<(mapBase + 64)], before[mapBase..<(mapBase + 64)])
    }

    func testInvalidPadsEmptySourceAndMalformedProgramNeverMutate() {
        let original = program()
        for (source, destination) in [(-1, 0), (0, 64), (64, 0), (0, -1), (1, 2)] {
            var program = original
            XCTAssertThrowsError(try program.transferPad(from: source, to: destination))
            XCTAssertEqual(program.bytes, original.bytes)
        }
        for invalid in [Data(original.bytes.dropLast()), Data([9]) + original.bytes.dropFirst()] {
            var program = original
            program.bytes = invalid
            XCTAssertThrowsError(try program.transferPad(from: 0, to: 1))
            XCTAssertEqual(program.bytes, invalid)
        }
    }

    func testAliasedSourceOrDestinationIsRejectedBeforeMutation() {
        for copy in [false, true] {
            for aliasNote: UInt8 in [35, 36] {
                var program = program()
                program.bytes[mapBase + 2] = aliasNote
                let before = program.bytes
                XCTAssertThrowsError(try program.transferPad(from: 0, to: 1, copy: copy)) { error in
                    XCTAssertEqual(error as? ProgramPadEditingError, .sharedNote(Int(aliasNote)))
                }
                XCTAssertEqual(program.bytes, before)
            }
        }
    }

    func testSamePadIsANoopButEmptySamePadIsAnError() throws {
        var program = program()
        let before = program.bytes
        try program.transferPad(from: 0, to: 0)
        try program.transferPad(from: 0, to: 0, copy: true)
        XCTAssertEqual(program.bytes, before)
        XCTAssertThrowsError(try program.transferPad(from: 1, to: 1))
        XCTAssertEqual(program.bytes, before)
    }

    func testPublicDataSliceIsAcceptedWithoutOffsetConfusion() throws {
        var program = program()
        var sliced = Data([0]) + program.bytes
        sliced.removeFirst()
        program.bytes = sliced
        try program.transferPad(from: 0, to: 63)
        XCTAssertEqual(program.slot(forNote: program.midiNote(forPad: 63)), 0)
        XCTAssertEqual(program.bytes.count, 4608)
    }
}
