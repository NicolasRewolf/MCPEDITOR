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

    func testMetadataAndDecoderShareNativeValidationMatrix() throws {
        let mono = try sound().encoded()
        let stereo = try sound(stereo: true).encoded()
        func changing(_ data: Data, _ position: Int, _ value: UInt8) -> Data {
            var changed = data; changed[position] = value; return changed
        }
        func word(_ data: Data, _ position: Int, _ value: UInt32) -> Data {
            var changed = data
            for i in 0..<4 { changed[position + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
            return changed
        }
        var short = word(word(mono, 26, 220), 30, 220)
        short = Data(short.prefix(38 + 220 * 2))
        let badMarkers = word(mono, 22, 442)
        let cases: [(String, Data, String?)] = [
            ("mono", mono, nil),
            ("stereo", stereo, nil),
            ("trailing bytes", mono + Data([3, 2, 1]), nil),
            ("positive short sound remains decodable", short, nil),
            ("truncated header", Data(mono.prefix(37)), "en-tête SND tronqué"),
            ("foreign signature before revision", changing(changing(mono, 0, 0), 1, 0x82), "pas un SND natif"),
            ("compressed", changing(mono, 1, 0x82), "révision 82"),
            ("other revision", changing(mono, 1, 3), "révision SND 02"),
            ("invalid channels before length", word(changing(mono, 21, 2), 30, 0), "mono/stéréo"),
            ("zero frames before markers", word(badMarkers, 30, 0), "longueur audio nulle"),
            ("oversized declaration before body", word(mono, 30, UInt32.max), "limite de 32 Mio"),
            ("missing PCM before markers", Data(badMarkers.prefix(38)), "longueur PCM"),
            ("one missing byte", Data(stereo.dropLast()), "longueur PCM"),
            ("start after end", badMarkers, "marqueurs début/fin"),
            ("end beyond frames", word(mono, 26, 442), "marqueurs début/fin")
        ]
        for (label, data, expectedError) in cases {
            let metadata = ProgramSoundResolver.Header(bytes: Data(data.prefix(38)), fileBytes: UInt64(data.count))
            let inspected = Result { try metadata.pcmBytes() }
            let decoded = Result { try MPCSound.decode(data) }
            if let expectedError {
                guard case .failure(let metadataError) = inspected,
                      case .failure(let decodeError) = decoded else {
                    XCTFail("\(label): metadata and decode must both reject this fixture")
                    continue
                }
                XCTAssertTrue(metadataError.localizedDescription.contains(expectedError), label)
                XCTAssertEqual(metadataError.localizedDescription, decodeError.localizedDescription, label)
            } else {
                let pcmBytes = try inspected.get()
                let sound = try decoded.get()
                XCTAssertEqual(pcmBytes, sound.frameCount * sound.channels.count * 2, label)
                XCTAssertEqual(sound.trailingByteCount, data.count - 38 - pcmBytes, label)
                XCTAssertEqual(sound.header, data.prefix(38), label)
            }
        }

        // Total-file bounds win even when the header itself is invalid. Metadata
        // validation needs only 38 bytes and the size, never the sparse/huge body.
        let hugeCount = MPCSound.maximumFileBytes + 1
        let invalidHeader = changing(mono, 0, 0).prefix(38)
        let inspected = ProgramSoundResolver.Header(bytes: Data(invalidHeader), fileBytes: UInt64(hugeCount))
        XCTAssertThrowsError(try inspected.pcmBytes()) { error in
            guard case MPCFormatError.tooLarge = error else { return XCTFail("\(error)") }
        }
        var oversized = Data(repeating: 0, count: hugeCount)
        oversized.replaceSubrange(0..<38, with: invalidHeader)
        XCTAssertThrowsError(try MPCSound.decode(oversized)) { error in
            guard case MPCFormatError.tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testNativeIdentitySurvivesBrokenPCMAndNonzeroDataIndices() throws {
        let valid = try sound().encoded()
        var badChannels = Data(valid.prefix(38)); badChannels[21] = 255
        var badLength = Data(valid.prefix(38))
        for index in 30..<34 { badLength[index] = 255 }
        for data in [Data(valid.prefix(38)), badChannels, badLength] {
            let metadata = ProgramSoundResolver.Header(bytes: data, fileBytes: UInt64(data.count))
            XCTAssertEqual(metadata.nativeName, "KICK")
            XCTAssertThrowsError(try metadata.pcmBytes())
        }
        var foreign = valid; foreign[0] = 0
        var compressed = valid; compressed[1] = 0x82
        var invalidName = valid; invalidName[2] = 255
        for data in [foreign, compressed, Data(valid.prefix(37)), invalidName] {
            XCTAssertNil(MPCSoundHeader(data).nativeName)
        }
        XCTAssertEqual(try MPCSound.decode(invalidName).name, "")
        let slice = (Data([0xEE]) + valid).dropFirst()
        XCTAssertEqual(MPCSoundHeader(slice).nativeName, "KICK")
        XCTAssertEqual(try MPCSound.decode(slice).channels, try MPCSound.decode(valid).channels)
    }

    func testEncodedByteCountUsesShapeWithoutScanningOrEncodingAudio() throws {
        for stereo in [false, true] {
            var source = sound(stereo: stereo)
            XCTAssertEqual(try source.encodedByteCount, try source.encoded().count)
            // A size is not certification of PCM values: computing it remains cheap
            // and succeeds while the encoder still refuses non-finite audio.
            source.channels[0][0] = .nan
            XCTAssertEqual(try source.encodedByteCount, 38 + 441 * 2 * (stereo ? 2 : 1))
            XCTAssertThrowsError(try source.encoded())
        }
        var unequal = sound(stereo: true); unequal.channels[1].removeLast()
        var badMarkers = sound(); badMarkers.start = -1
        let invalid = [MPCSound(name: "EMPTY", channels: []),
                       MPCSound(name: "SHORT", channels: [[0]]), unequal, badMarkers]
        for source in invalid {
            let counted = Result { try source.encodedByteCount }
            let encoded = Result { try source.encoded() }
            guard case .failure(let countError) = counted,
                  case .failure(let encodeError) = encoded else {
                XCTFail("An invalid shape must be rejected by both size and encoding")
                continue
            }
            XCTAssertEqual(countError.localizedDescription, encodeError.localizedDescription)
        }
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
        XCTAssertTrue((0..<128).allSatisfy { program.soundName(slot: $0).isEmpty })
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

    func testPCM16RangeReportIdentifiesRealClippingWithoutEditingAudio() throws {
        let source = MPCSound(name: "FLOAT", channels: [
            [Float](repeating: 0, count: 435) + [-1.25, -1, 0, Float(32767) / 32768, 1, 1.25]
        ])
        let report = source.pcm16RangeReport
        XCTAssertEqual(report.peakMagnitude, 1.25)
        XCTAssertEqual(report.outOfRangeSampleCount, 2)
        XCTAssertEqual(report.nonFiniteSampleCount, 0)
        let encoded = try source.encoded()
        XCTAssertEqual(source.channels[0].suffix(6), [-1.25, -1, 0, Float(32767) / 32768, 1, 1.25])
        let decoded = try MPCSound.decode(encoded)
        XCTAssertEqual(decoded.channels[0].suffix(6), [-1, -1, 0, Float(32767) / 32768,
                                                       Float(32767) / 32768, Float(32767) / 32768])
        XCTAssertEqual(source.normalized().pcm16RangeReport.outOfRangeSampleCount, 0)
        XCTAssertEqual(decoded.pcm16RangeReport.outOfRangeSampleCount, 0)
        let nonFinite = MPCSound(name: "INVALID", channels: [[.nan, .infinity, -.infinity, -0.5]])
            .pcm16RangeReport
        XCTAssertEqual(nonFinite.peakMagnitude, 0.5)
        XCTAssertEqual(nonFinite.outOfRangeSampleCount, 0)
        XCTAssertEqual(nonFinite.nonFiniteSampleCount, 3)
    }

    func testAll65536PCM16WordsSurviveDecodeAndReencodeExactly() throws {
        var bytes = [UInt8](repeating: 0, count: 38)
        bytes[0] = 1; bytes[1] = 2; bytes[2] = 65; bytes[19] = 100
        for offset in [26, 30] { bytes[offset + 2] = 1 } // 65,536 frames, little endian.
        for integer in Int(Int16.min)...Int(Int16.max) {
            let bits = UInt16(bitPattern: Int16(integer))
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        let source = Data(bytes)
        let decoded = try MPCSound.decode(source)
        XCTAssertEqual(decoded.frameCount, 65536)
        XCTAssertEqual(decoded.pcm16RangeReport.outOfRangeSampleCount, 0)
        XCTAssertEqual(try decoded.encoded().dropFirst(38), source.dropFirst(38))
    }

    func testSeededMalformedInputsAndKnownByteMutationsStayBounded() throws {
        var state: UInt64 = 0x4d504333303030
        func random() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        for index in 0..<3000 {
            let count = Int(random() % 4700)
            var data = Data((0..<count).map { _ in UInt8(truncatingIfNeeded: random() >> 32) })
            if index % 3 == 0 && data.count >= 2 { data[0] = 1; data[1] = 2 }
            if index % 5 == 0 && data.count >= 38 {
                data[21] = UInt8(index % 2)
                for offset in 22..<34 { data[offset] = 0 }
                data[30] = UInt8(index % 255 + 1)
            }
            if let sound = try? MPCSound.decode(data) {
                XCTAssertTrue((1...2).contains(sound.channels.count))
                XCTAssertLessThanOrEqual(sound.start, sound.end)
                XCTAssertLessThanOrEqual(sound.end, sound.frameCount)
                XCTAssertTrue(sound.channels.allSatisfy {
                    $0.count == sound.frameCount && $0.allSatisfy(\.isFinite)
                })
            }
            if let program = try? MPCProgram(data: data) {
                XCTAssertEqual(program.bytes, data)
                _ = try? program.validateKnownFields()
            }
        }
        let source = MPCProgram.blank(name: "MUTATE").bytes
        for position in [0, 1, 2690, 2752, 2753, 2761, 4544, 4607] {
            for value in UInt8.min...UInt8.max {
                var bytes = source
                bytes[position] = value
                if let program = try? MPCProgram(data: bytes) {
                    XCTAssertEqual(program.bytes, bytes)
                    _ = try? program.validateKnownFields()
                    _ = program.name; _ = program.soundName(slot: 0); _ = program.referencedSlots
                    for pad in 0..<64 { _ = program.midiNote(forPad: pad) }
                    for note in 35...98 { _ = program.tune(forNote: note) }
                }
            }
        }
    }
}
