import Foundation
import XCTest
@testable import MPCCore

final class NativeFormatsTests: XCTestCase {
    private func sound(stereo: Bool = false) -> MPCSound {
        var left = [Float](repeating: 0, count: 441)
        left.replaceSubrange(0..<5, with: [-1, -0.5, 0, 0.5, Float(32767) / 32768])
        let channels = stereo ? [left, [Float](repeating: 0.25, count: 441)] : [left]
        return MPCSound(name: "KICK", channels: channels, start: 2, end: 430, volume: 91, tune: -7)
    }

    func testNativeSoundOffsetsPlanarPCMAndRoundTrip() throws {
        var source = sound(stereo: true)
        source.header[18] = 0xA5 // Unknown descriptor byte must survive.
        source.header[34] = 0xFF // Runtime pointer must be reset.
        let bytes = try source.encoded()
        XCTAssertEqual(bytes.count, 38 + 441 * 2 * 2)
        XCTAssertEqual(Array(bytes.prefix(2)), [1, 2])
        XCTAssertEqual(bytes[18], 0xA5)
        XCTAssertEqual(bytes[19], 91)
        XCTAssertEqual(bytes[20], 249)
        XCTAssertEqual(bytes[21], 1)
        XCTAssertEqual(Array(bytes[22..<26]), [2, 0, 0, 0])
        XCTAssertEqual(Array(bytes[30..<34]), [185, 1, 0, 0])
        XCTAssertEqual(Array(bytes[34..<38]), [0, 0, 0, 0])
        XCTAssertEqual(Array(bytes[38..<40]), [0, 128]) // Left -1.
        XCTAssertEqual(Array(bytes[(38 + 882)..<(40 + 882)]), [0, 32]) // Right .25.
        let decoded = try MPCSound.decode(bytes)
        XCTAssertEqual(decoded.channels, source.channels)
        XCTAssertEqual(decoded.start, 2)
        XCTAssertEqual(decoded.end, 430)
        XCTAssertEqual(decoded.volume, 91)
        XCTAssertEqual(decoded.tune, -7)
        XCTAssertEqual(try decoded.encoded(), bytes)
    }

    func testRejectsTruncatedInvalidStereoMarkersAndRevisions() throws {
        let valid = try sound().encoded()
        XCTAssertThrowsError(try MPCSound.decode(Data(valid.prefix(37))))
        XCTAssertThrowsError(try MPCSound.decode(Data(valid.dropLast())))
        var stereo = valid; stereo[21] = 2
        XCTAssertThrowsError(try MPCSound.decode(stereo))
        var marker = valid; marker[22] = 255; marker[23] = 255
        XCTAssertThrowsError(try MPCSound.decode(marker))
        var compressed = valid; compressed[1] = 0x82
        XCTAssertThrowsError(try MPCSound.decode(compressed))
        var legacy = valid; legacy[1] = 1
        XCTAssertThrowsError(try MPCSound.decode(legacy))
        var huge = valid
        for i in 30..<34 { huge[i] = 255 }
        XCTAssertThrowsError(try MPCSound.decode(huge))
    }

    func testTrailingBytesAreReportedAndCanonicalExportOmitsThem() throws {
        let canonical = try sound().encoded()
        var input = canonical; input.append(contentsOf: [1, 2, 3, 4])
        let decoded = try MPCSound.decode(input, name: "FROMFILE")
        XCTAssertEqual(decoded.trailingByteCount, 4)
        XCTAssertEqual(decoded.name, "FROMFILE")
        XCTAssertEqual(try decoded.encoded().count, canonical.count)
        XCTAssertEqual(decoded.channels, try MPCSound.decode(canonical).channels)
    }

    func testExportRejectsUnsafeSamplesAndShortLengths() {
        XCTAssertThrowsError(try MPCSound(name: "SHORT", channels: [[0, 1]]).encoded())
        XCTAssertThrowsError(try MPCSound(name: "EMPTY", channels: []).encoded())
        var unequal = sound(stereo: true); unequal.channels[1].removeLast()
        XCTAssertThrowsError(try unequal.encoded())
        var invalid = sound(); invalid.channels[0][10] = .nan
        XCTAssertThrowsError(try invalid.encoded())
        invalid = sound(); invalid.start = -1
        XCTAssertThrowsError(try invalid.encoded())
    }

    func testTransformsAreFiniteAndHandleEmptyAudio() {
        let original = MPCSound(name: "TEST", channels: [[0.25, 0.5, -0.5, 1]], start: 1, end: 3)
        let trimmed = original.trimmed()
        XCTAssertEqual(trimmed.channels, [[0.5, -0.5]])
        XCTAssertEqual(trimmed.start, 0)
        XCTAssertEqual(trimmed.end, 2)
        XCTAssertEqual(original.frameCount, 4)
        let mono = MPCSound(name: "STEREO", channels: [[1, -1], [-1, 1]]).mono()
        XCTAssertEqual(mono.channels, [[0, 0]])
        let normalized = MPCSound(name: "N", channels: [[.nan, 0.25, -0.5, .infinity]]).normalized()
        XCTAssertEqual(normalized.channels, [[0, 0.5, -1, 0]])
        let faded = MPCSound(name: "F", channels: [[1, 1, 1, 1]]).faded(milliseconds: 100)
        XCTAssertEqual(faded.channels, [[0, 1, 1, 0]])
        let selected = MPCSound(name: "ZONE", channels: [[Float](repeating: 1, count: 8)], start: 2, end: 6)
        XCTAssertEqual(selected.faded(milliseconds: 100).channels, [[1, 1, 0, 1, 1, 0, 1, 1]])
        XCTAssertEqual(selected.faded(milliseconds: 0).channels, selected.channels)
        let clamped = MPCSound(name: "CLAMP", channels: [[1, 1, 1, 1]], start: -10, end: 100)
        XCTAssertEqual(clamped.faded(milliseconds: 100).channels, [[0, 1, 1, 0]])
        let inputs: [[[Float]]] = [[], [[]], [[0, 0]]]
        for channels in inputs {
            let empty = MPCSound(name: "EMPTY", channels: channels)
            for transformed in [empty.trimmed(), empty.normalized(), empty.mono(), empty.faded(milliseconds: .infinity)] {
                XCTAssertTrue(transformed.channels.flatMap { $0 }.allSatisfy(\.isFinite))
            }
        }
    }

    func testNamesAreBoundedASCIIWithPathCharactersRemoved() throws {
        XCTAssertEqual(MPCSound.safeName("café/kick:snare"), "cafe_kick_snare")
        let encoded = try sound().encoded(name: "ABCDEFGHIJKLMNOPQé")
        XCTAssertEqual(String(bytes: encoded[2..<18], encoding: .ascii), "ABCDEFGHIJKLMNOP")
        XCTAssertEqual(MPCSound.safeName("  "), "UNTITLED")
    }

    func testReferenceTemplateAndProgramAssignmentOffsets() throws {
        var program = MPCProgram.blank(name: "NEWKIT")
        XCTAssertEqual(program.bytes.count, 4608)
        XCTAssertEqual(program.midiNote(forPad: 0), 37)
        XCTAssertEqual(program.midiNote(forPad: 1), 36)
        XCTAssertEqual(program.midiNote(forPad: 63), 98)
        XCTAssertTrue(program.referencedSlots.isEmpty)
        XCTAssertTrue(program.soundNames.allSatisfy(\.isEmpty))
        program.assign(slot: 127, toNote: 37)
        program.setSound(slot: 127, name: "SNARE", wordCount: 882)
        XCTAssertEqual(program.bytes[2690 + 62 + 2 * 24], 127)
        XCTAssertEqual(Array(program.bytes[2686..<2690]), [114, 3, 0, 0])
        XCTAssertEqual(program.soundName(slot: 127), "SNARE")
        XCTAssertEqual(program.referencedSlots, Set([127]))
        program.assign(slot: nil, toNote: 37)
        XCTAssertEqual(program.bytes[2800], 255)
        XCTAssertNil(program.slot(forNote: 37))
        XCTAssertEqual(try MPCProgram(data: program.bytes).bytes, program.bytes)
    }

    func testProgramEditsPreserveUnknownBytesAndSignedTune() throws {
        var program = MPCProgram.blank(name: "ORIGINAL")
        let noteBase = 2690 + 62 + 2 * 24
        program.bytes[2690 + 17] = 0xA6
        program.bytes[noteBase + 23] = 0xB7
        let before = program.bytes
        program.setTune(-125, forNote: 37)
        program.name = "RENAMED"
        XCTAssertEqual(program.tune(forNote: 37), -125)
        XCTAssertEqual(program.bytes[noteBase + 9], 131)
        XCTAssertEqual(program.bytes[noteBase + 10], 255)
        XCTAssertEqual(program.bytes[2690 + 17], 0xA6)
        XCTAssertEqual(program.bytes[noteBase + 23], 0xB7)
        for i in before.indices where !(2690..<2707).contains(i) && i != noteBase + 9 && i != noteBase + 10 {
            XCTAssertEqual(program.bytes[i], before[i], "Unexpected modification at \(i)")
        }
        XCTAssertEqual(try MPCProgram(data: program.bytes).bytes, program.bytes)
        XCTAssertThrowsError(try MPCProgram(data: Data(program.bytes.dropLast())))
        var invalid = program.bytes; invalid[0] = 1
        XCTAssertThrowsError(try MPCProgram(data: invalid))
    }
}
