import Foundation
import XCTest
@testable import MPCCore

final class ProgramAssociationIndexTests: XCTestCase {
    private func folder(_ name: String = "Library") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgramAssociationIndexTests-" + UUID().uuidString)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return directory
    }

    private func sound(_ name: String, filename: String? = nil, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(filename ?? "\(name).SND")
        try MPCSound(name: name, channels: [[Float](repeating: 0.25, count: 512)]).encoded().write(to: url)
        return url.standardizedFileURL
    }

    private func program(_ name: String, sounds: [String], in folder: URL,
                         inactive: String? = nil) throws -> LibraryKit {
        var program = MPCProgram.blank(name: name)
        for (slot, name) in sounds.enumerated() {
            program.assign(slot: slot, toNote: 35 + slot)
            program.setSound(slot: slot, name: name, wordCount: 512)
        }
        if let inactive { program.setSound(slot: 127, name: inactive, wordCount: 512) }
        let url = folder.appendingPathComponent("\(name).PGM")
        try program.bytes.write(to: url)
        return LibraryKit(url: url, rootURL: folder, partitionLetter: LibraryIndex.partitionLetter(for: folder),
                          relativeFolder: "")
    }

    func testSharedSampleMapsToEveryProgramAndNeverToAnInactiveNameSlot() throws {
        let folder = try folder("MPC-PART--S")
        let kick = try sound("KICK", in: folder)
        let snare = try sound("SNARE", in: folder)
        let unused = try sound("UNASSIGN", in: folder)
        let soul = try program("SOUL", sounds: ["KICK", "SNARE", "KICK"], in: folder, inactive: "UNASSIGN")
        let funk = try program("FUNK", sounds: ["KICK"], in: folder)
        let index = ProgramAssociationIndex.scan(programs: [soul, funk, soul])

        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.programs.count, 2)
        XCTAssertEqual(Set(index.programs(using: kick).map(\.url)), Set([soul.url, funk.url]))
        XCTAssertEqual(index.programs(using: snare), [soul])
        XCTAssertTrue(index.programs(using: unused).isEmpty)
        XCTAssertEqual(Set(try XCTUnwrap(index.association(for: soul.url)).samples), Set([kick, snare]))
        XCTAssertEqual(index.programs(using: kick).map(\.locationLabel), ["PART S", "PART S"])
    }

    func testSameNamesOnDifferentPartsKeepSeparateSampleAndProgramIdentities() throws {
        let a = try folder("MPC-PART--A"), b = try folder("MPC-PART--B")
        let sampleA = try sound("KICK", in: a), sampleB = try sound("KICK", in: b)
        let programA = try program("SOUL", sounds: ["KICK"], in: a)
        let programB = try program("SOUL", sounds: ["KICK"], in: b)
        let index = ProgramAssociationIndex.scan(programs: [programA, programB])
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.programs(using: sampleA), [programA])
        XCTAssertEqual(index.programs(using: sampleB), [programB])
        XCTAssertEqual(index.programs(using: sampleA).first?.locationLabel, "PART A")
        XCTAssertEqual(index.programs(using: sampleB).first?.locationLabel, "PART B")
    }

    func testFilenamePrecedenceAndNativeNameFallbackAreTheLoaderRules() throws {
        let folder = try folder()
        let preferred = try sound("OTHER", filename: "TAMBOURIN.SND", in: folder)
        let fallback = try sound("TAMBOURIN", filename: "TRUNC.SND", in: folder)
        let pgm = try program("PRIMARY", sounds: ["TAMBOURIN"], in: folder)
        var index = ProgramAssociationIndex.scan(programs: [pgm])
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.programs(using: preferred), [pgm])
        XCTAssertTrue(index.programs(using: fallback).isEmpty)
        try FileManager.default.removeItem(at: preferred)
        index = ProgramAssociationIndex.scan(programs: [pgm])
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.programs(using: fallback), [pgm])
        XCTAssertEqual(try KitLoader.load(programURL: pgm.url).sounds.count, 1)
    }

    func testAmbiguousInternalNamesIncludingBrokenPCMStayUnresolved() throws {
        let folder = try folder()
        let first = try sound("TAMBOURIN", filename: "FIRST.SND", in: folder)
        let second = try sound("TAMBOURIN", filename: "SECOND.SND", in: folder)
        try Data(contentsOf: second).prefix(38).write(to: second)
        let pgm = try program("AMBIG", sounds: ["TAMBOURIN"], in: folder)
        let index = ProgramAssociationIndex.scan(programs: [pgm])
        XCTAssertFalse(index.isComplete)
        XCTAssertTrue(index.programs(using: first).isEmpty)
        XCTAssertTrue(index.programs(using: second).isEmpty)
        XCTAssertEqual(index.association(for: pgm.url)?.issues, ["TAMBOURIN (nom interne SND ambigu)"])
    }

    func testUnknownHeaderBlocksFallbackButDoesNotBlockAnExactValidFilename() throws {
        let folder = try folder()
        let fallback = try sound("TAMBOURIN", filename: "TRUNC.SND", in: folder)
        let exact = try sound("KICK", in: folder)
        try Data([1, 2]).write(to: folder.appendingPathComponent("BROKEN.SND"))
        let pgm = try program("PARTIAL", sounds: ["TAMBOURIN", "KICK"], in: folder)
        let index = ProgramAssociationIndex.scan(programs: [pgm])
        XCTAssertFalse(index.isComplete)
        XCTAssertTrue(index.programs(using: fallback).isEmpty)
        XCTAssertEqual(index.programs(using: exact), [pgm])
        XCTAssertTrue(index.association(for: pgm.url)?.issues.first?.contains("non vérifiés") == true)
        XCTAssertEqual(try KitLoader.load(programURL: pgm.url).sounds.count, 1)
    }

    func testMissingMalformedAndInvalidProgramsAreVisibleAsIncomplete() throws {
        let folder = try folder()
        let broken = try sound("BROKEN", in: folder)
        var bytes = try Data(contentsOf: broken)
        bytes[21] = 2
        try bytes.write(to: broken)
        let pgm = try program("PARTIAL", sounds: ["MISSING", "BROKEN"], in: folder)
        let corrupt = try program("CORRUPT", sounds: [], in: folder)
        try Data([7, 0]).write(to: corrupt.url)
        let index = ProgramAssociationIndex.scan(programs: [pgm, corrupt], upstreamIssues: ["PART M incomplète"])
        XCTAssertFalse(index.isComplete)
        XCTAssertTrue(index.issues.contains("PART M incomplète"))
        XCTAssertEqual(index.association(for: pgm.url)?.issues.count, 2)
        XCTAssertFalse(try XCTUnwrap(index.association(for: corrupt.url)).isComplete)
        XCTAssertTrue(index.programs(using: broken).isEmpty)
    }

    func testTotalDirectoryBudgetIsSharedAndSiblingProgramsReuseTheirListing() throws {
        let a = try folder("MPC-PART--A"), b = try folder("MPC-PART--B")
        let sampleA = try sound("KICK", in: a), sampleB = try sound("SNARE", in: b)
        let first = try program("FIRST", sounds: ["KICK"], in: a)
        let sibling = try program("SECOND", sounds: ["KICK"], in: a)
        let other = try program("THIRD", sounds: ["SNARE"], in: b)
        let index = ProgramAssociationIndex.scan(programs: [first, sibling, other], maximumDirectoryEntries: 3)
        XCTAssertFalse(index.isComplete)
        XCTAssertEqual(Set(index.programs(using: sampleA).map(\.url)), Set([first.url, sibling.url]))
        XCTAssertTrue(index.programs(using: sampleB).isEmpty)
        XCTAssertTrue(try XCTUnwrap(index.association(for: other.url)).issues[0].contains("limite"))
    }

    func testPartialDirectoryCannotClaimUniqueFilenameOrNativeName() throws {
        let folder = try folder()
        let sample = try sound("KICK", in: folder)
        let pgm = try program("SOUL", sounds: ["KICK"], in: folder)
        let index = ProgramAssociationIndex.scan(programs: [pgm], maximumDirectoryEntries: 1)
        XCTAssertFalse(index.isComplete)
        XCTAssertTrue(index.programs(using: sample).isEmpty)
        XCTAssertTrue(try XCTUnwrap(index.association(for: pgm.url)).samples.isEmpty)
    }

    func testProgramLimitAndUpstreamFailuresCannotLookLikeAnExhaustiveEmptyIndex() throws {
        let folder = try folder()
        let first = try program("EMPTY", sounds: [], in: folder)
        let second = try program("EMPTY2", sounds: [], in: folder)
        let index = ProgramAssociationIndex.scan(programs: [first, second], maximumPrograms: 1)
        XCTAssertEqual(index.programs.count, 1)
        XCTAssertFalse(index.isComplete)
        XCTAssertNil(index.association(for: second.url))
        XCTAssertFalse(ProgramAssociationIndex.scan(programs: [], upstreamIssues: ["Déconnecté"]).isComplete)
        XCTAssertTrue(ProgramAssociationIndex.scan(programs: [first], maximumDirectoryEntries: 0).isComplete)
    }

    func testSymlinkedProgramOrSampleCannotProduceAnAssociation() throws {
        let folder = try folder(), external = try self.folder()
        let sample = try sound("KICK", in: external)
        let pgm = try program("SOUL", sounds: ["KICK"], in: folder)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("KICK.SND"), withDestinationURL: sample)
        let original = try program("ORIGINAL", sounds: [], in: external)
        let linked = LibraryKit(url: folder.appendingPathComponent("LINK.PGM"), rootURL: folder,
                                partitionLetter: nil, relativeFolder: "")
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: original.url)
        let index = ProgramAssociationIndex.scan(programs: [pgm, linked])
        XCTAssertFalse(index.isComplete)
        XCTAssertTrue(index.programs(using: sample).isEmpty)
        XCTAssertTrue(index.programs.allSatisfy { !$0.isComplete && $0.samples.isEmpty })
    }

    func testLargeSparseSoundsAreIndexedWithoutLoadingTheAudioBudget() throws {
        let folder = try folder()
        let names = ["FIRST", "SECOND"]
        for name in names {
            let url = try sound(name, in: folder)
            var header = try Data(contentsOf: url).prefix(38)
            let frames = UInt32(17 * 1024 * 1024 / 2)
            for i in 0..<4 {
                header[26 + i] = UInt8(truncatingIfNeeded: frames >> (8 * i))
                header[30 + i] = UInt8(truncatingIfNeeded: frames >> (8 * i))
            }
            try header.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 38 + UInt64(frames) * 2)
            try handle.close()
        }
        let pgm = try program("LARGE", sounds: names, in: folder)
        let index = ProgramAssociationIndex.scan(programs: [pgm])
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.association(for: pgm.url)?.samples.count, 2)
        XCTAssertThrowsError(try KitLoader.load(programURL: pgm.url)) { error in
            guard case KitLoaderError.memoryLimitExceeded = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testUnreadableHeaderCannotHideAnAmbiguousInternalName() throws {
        let folder = try folder()
        let visible = try sound("TAMBOURIN", filename: "FIRST.SND", in: folder)
        let unreadable = try sound("TAMBOURIN", filename: "SECOND.SND", in: folder)
        let pgm = try program("SOUL", sounds: ["TAMBOURIN"], in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        guard !FileManager.default.isReadableFile(atPath: unreadable.path) else {
            throw XCTSkip("This process can read files despite permission bits.")
        }
        let index = ProgramAssociationIndex.scan(programs: [pgm])
        XCTAssertFalse(index.isComplete)
        XCTAssertTrue(index.programs(using: visible).isEmpty)
        XCTAssertTrue(index.association(for: pgm.url)?.issues.first?.contains("non vérifiés") == true)
    }

    func testAssignedNoteSlotsAreIncludedEvenWithoutADirectPadMapping() throws {
        let folder = try folder()
        let first = try sound("KICK", in: folder), second = try sound("CLAP", in: folder)
        let pgm = try program("NOTES", sounds: ["KICK"], in: folder)
        var native = try MPCProgram(data: Data(contentsOf: pgm.url))
        native.setSound(slot: 1, name: "CLAP", wordCount: 512)
        native.assign(slot: 1, toNote: 98)
        // A secondary voice can reference a note which has no direct pad mapping.
        // Use the loader's whole note inventory rather than only the 64 pad selections.
        for pad in 0..<64 { native.bytes[2690 + 1854 + pad] = 35 }
        try native.bytes.write(to: pgm.url)
        let index = ProgramAssociationIndex.scan(programs: [pgm])
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(Set(try XCTUnwrap(index.association(for: pgm.url)).samples), Set([first, second]))
        XCTAssertEqual(Set(try KitLoader.load(programURL: pgm.url).sounds.keys), Set([0, 1]))
    }

    func testScanningLeavesAllSourceBytesAndDirectoryEntriesUnchanged() throws {
        let folder = try folder()
        let sample = try sound("KICK", in: folder)
        let pgm = try program("SOUL", sounds: ["KICK"], in: folder)
        let sampleBytes = try Data(contentsOf: sample), pgmBytes = try Data(contentsOf: pgm.url)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        for _ in 0..<3 { XCTAssertTrue(ProgramAssociationIndex.scan(programs: [pgm]).isComplete) }
        XCTAssertEqual(try Data(contentsOf: sample), sampleBytes)
        XCTAssertEqual(try Data(contentsOf: pgm.url), pgmBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), names)
    }
}
