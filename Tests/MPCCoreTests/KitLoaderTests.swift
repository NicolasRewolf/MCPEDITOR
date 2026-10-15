import Foundation
import XCTest
@testable import MPCCore

final class KitLoaderTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KitLoaderTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func program(_ names: [String], in directory: URL) throws -> URL {
        var program = MPCProgram.blank(name: "PRESENT")
        for (slot, name) in names.enumerated() {
            program.assign(slot: slot, toNote: 35 + slot)
            program.setSound(slot: slot, name: name, wordCount: 512)
        }
        let url = directory.appendingPathComponent("PRESENT.PGM")
        try program.bytes.write(to: url)
        return url
    }

    private func sound(_ name: String, value: Float = 0.25) throws -> Data {
        try MPCSound(name: name, channels: [[Float](repeating: value, count: 512)],
                     start: 44, end: 511, volume: 129, tune: -7).encoded()
    }

    func testResolvesTruncatedDOSFilenameUsingNativeNameAndPreservesSources() throws {
        let folder = try directory()
        let pgm = try program(["TAMBOURIN"], in: folder)
        let file = folder.appendingPathComponent("tambouri.SND")
        let data = try sound("TAMBOURIN")
        try data.write(to: file)
        let originalProgram = try Data(contentsOf: pgm)
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertTrue(loaded.missing.isEmpty)
        XCTAssertEqual(loaded.sounds.count, 1)
        XCTAssertEqual(loaded.sounds[0]?.name, "TAMBOURIN")
        XCTAssertEqual(loaded.sounds[0]?.channels, try MPCSound.decode(data).channels)
        XCTAssertEqual(loaded.sounds[0]?.start, 44)
        XCTAssertEqual(loaded.sounds[0]?.end, 511)
        XCTAssertEqual(loaded.sounds[0]?.volume, 129)
        XCTAssertEqual(loaded.sounds[0]?.tune, -7)
        XCTAssertEqual(loaded.program.bytes, originalProgram)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try Data(contentsOf: pgm), originalProgram)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["PRESENT.PGM", "tambouri.SND"])
    }

    func testUniqueFilenameTakesPrecedenceOverInternalName() throws {
        let folder = try directory()
        let pgm = try program(["TAMBOURIN"], in: folder)
        try sound("OTHER", value: 0.5).write(to: folder.appendingPathComponent("tambourin.snd"))
        try sound("TAMBOURIN", value: 0.25).write(to: folder.appendingPathComponent("TRUNC.SND"))
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertTrue(loaded.missing.isEmpty)
        XCTAssertEqual(loaded.sounds[0]?.name, "TAMBOURIN")
        XCTAssertEqual(loaded.sounds[0]?.channels[0][0], 0.5)
    }

    func testCorruptPreferredFilenameDoesNotSilentlyUseAnInternalMatch() throws {
        let folder = try directory()
        let pgm = try program(["TAMBOURIN"], in: folder)
        try Data([1, 2]).write(to: folder.appendingPathComponent("TAMBOURIN.SND"))
        try sound("TAMBOURIN").write(to: folder.appendingPathComponent("TRUNC.SND"))
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertTrue(loaded.sounds.isEmpty)
        XCTAssertEqual(loaded.missing.count, 1)
        XCTAssertTrue(loaded.missing[0].contains("tronqué"))
    }

    func testAmbiguousInternalNamesRemainUnresolvedIncludingTruncatedBody() throws {
        let folder = try directory()
        let pgm = try program(["TAMBOURIN"], in: folder)
        let data = try sound("TAMBOURIN")
        try data.write(to: folder.appendingPathComponent("FIRST.SND"))
        try data.prefix(38).write(to: folder.appendingPathComponent("SECOND.SND"))
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertTrue(loaded.sounds.isEmpty)
        XCTAssertEqual(loaded.missing, ["TAMBOURIN (nom interne SND ambigu)"])
    }

    func testFallbackIgnoresWrongRevisionOtherFormatsHiddenFilesAndDirectories() throws {
        let folder = try directory()
        let pgm = try program(["TAMBOURIN", "MISSING"], in: folder)
        let data = try sound("TAMBOURIN")
        try data.write(to: folder.appendingPathComponent("TRUNC.SND"))
        var compressed = data; compressed[1] = 0x82
        try compressed.write(to: folder.appendingPathComponent("COMPRESS.SND"))
        var foreign = data; foreign[0] = 0
        try foreign.write(to: folder.appendingPathComponent("FOREIGN.SND"))
        try data.write(to: folder.appendingPathComponent("IGNORE.WAV"))
        try data.write(to: folder.appendingPathComponent(".HIDDEN.SND"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("TAMBOURIN.SND"), withIntermediateDirectories: false)
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertEqual(loaded.sounds.count, 1)
        XCTAssertEqual(loaded.missing, ["MISSING"])
    }

    func testInvalidReferencedSoundIsReportedWhileValidSoundLoads() throws {
        let folder = try directory()
        let pgm = try program(["GOOD", "BAD"], in: folder)
        try sound("GOOD").write(to: folder.appendingPathComponent("GOOD.SND"))
        var invalid = try sound("BAD"); invalid[21] = 2
        try invalid.write(to: folder.appendingPathComponent("BAD.SND"))
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertEqual(Set(loaded.sounds.keys), [0])
        XCTAssertEqual(loaded.missing.count, 1)
        XCTAssertTrue(loaded.missing[0].contains("mono/stéréo"))
    }

    private func sparseSound(_ name: String, pcmBytes: Int, at url: URL) throws {
        var header = try sound(name).prefix(38)
        let frames = UInt32(pcmBytes / 2)
        for i in 0..<4 {
            header[26 + i] = UInt8(truncatingIfNeeded: frames >> (8 * i))
            header[30 + i] = UInt8(truncatingIfNeeded: frames >> (8 * i))
        }
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(38 + pcmBytes))
    }

    func testKitBudgetIsRejectedFromHeadersBeforeDecodingSparsePCM() throws {
        let folder = try directory()
        let pgm = try program(["FIRST", "SECOND"], in: folder)
        try sparseSound("FIRST", pcmBytes: 17 * 1024 * 1024, at: folder.appendingPathComponent("FIRST.SND"))
        try sparseSound("SECOND", pcmBytes: 16 * 1024 * 1024, at: folder.appendingPathComponent("SECOND.SND"))
        XCTAssertThrowsError(try KitLoader.load(programURL: pgm)) { error in
            guard case KitLoaderError.memoryLimitExceeded = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
    }

    func testOversizedSampleIsRejectedWithoutReadingItsBody() throws {
        let folder = try directory()
        let pgm = try program(["HUGE"], in: folder)
        let url = folder.appendingPathComponent("HUGE.SND")
        try sparseSound("HUGE", pcmBytes: 33 * 1024 * 1024, at: url)
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertTrue(loaded.sounds.isEmpty)
        XCTAssertEqual(loaded.missing.count, 1)
        XCTAssertTrue(loaded.missing[0].contains("32 Mio"))
    }

    func testInvalidProgramInputsThrowAndEmptyProgramLoads() throws {
        let folder = try directory()
        let pgm = try program([], in: folder)
        let loaded = try KitLoader.load(programURL: pgm)
        XCTAssertTrue(loaded.sounds.isEmpty)
        XCTAssertTrue(loaded.missing.isEmpty)
        XCTAssertThrowsError(try KitLoader.load(programURL: folder))
        XCTAssertThrowsError(try KitLoader.load(programURL: folder.appendingPathComponent("ABSENT.PGM")))
        try Data([7, 0]).write(to: pgm)
        XCTAssertThrowsError(try KitLoader.load(programURL: pgm))
        let handle = try FileHandle(forWritingTo: pgm)
        try handle.truncate(atOffset: 128 * 1024 * 1024)
        try handle.close()
        XCTAssertThrowsError(try KitLoader.load(programURL: pgm))
        var invalid = MPCProgram.blank(name: "BAD").bytes; invalid[0] = 0
        try invalid.write(to: pgm)
        XCTAssertThrowsError(try KitLoader.load(programURL: pgm))
    }
}
