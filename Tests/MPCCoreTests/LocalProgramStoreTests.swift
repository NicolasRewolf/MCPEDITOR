import Foundation
import XCTest
@testable import MPCCore

final class LocalProgramStoreTests: XCTestCase {
    private var temporary: URL!
    private var store: LocalProgramStore!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalProgramStoreTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        store = LocalProgramStore(rootURL: temporary.appendingPathComponent("Bibliothèque", isDirectory: true))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func fixture(tune: Int = 0) -> (MPCProgram, [Int: MPCSound]) {
        var program = MPCProgram.blank(name: "SOUL")
        program.assign(slot: 4, toNote: program.midiNote(forPad: 0))
        program.assign(slot: 4, toNote: program.midiNote(forPad: 17))
        program.setTune(tune, forNote: program.midiNote(forPad: 0))
        program.setSound(slot: 4, name: "KICK", wordCount: 512)
        var sound = MPCSound(name: "KICK", channels: [(0..<512).map { Float($0 % 32) / 64 - 0.25 }])
        sound.start = 20
        sound.end = 400
        return (program, [4: sound])
    }

    private func save(_ old: URL? = nil, name: String = "SOUL", tune: Int = 0) throws -> URL {
        let (program, sounds) = fixture(tune: tune)
        return try store.save(program: program, sounds: sounds, name: name, existingProgramURL: old)
    }

    func testAbsentLibraryReadsAsEmptyWithoutCreatingFiles() throws {
        XCTAssertEqual(try store.scanKits(), [])
        XCTAssertFalse(store.contains(store.rootURL.appendingPathComponent("SOUL.PGM")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    func testImportCreatesIndependentNativeProgramAndPreservesOriginal() throws {
        let originalFolder = temporary.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: false)
        let (program, sounds) = fixture(tune: 12)
        let source = try KitExport.export(program: program, sounds: sounds, name: "SOUL", to: originalFolder)
        let original = try directoryContents(originalFolder)
        let saved = try store.save(program: program, sounds: sounds, name: "SOUL", existingProgramURL: source)
        XCTAssertNotEqual(saved, source)
        XCTAssertTrue(store.contains(saved))
        XCTAssertFalse(store.contains(source))
        XCTAssertEqual(try directoryContents(originalFolder), original)
        let loaded = try KitLoader.load(programURL: saved)
        XCTAssertTrue(loaded.missing.isEmpty)
        XCTAssertEqual(loaded.program.referencedSlots, [4])
        XCTAssertEqual(loaded.program.tune(forNote: program.midiNote(forPad: 0)), 12)
        XCTAssertEqual(loaded.program.slot(forNote: loaded.program.midiNote(forPad: 17)), 4)
        XCTAssertEqual(loaded.sounds[4]?.start, 20)
        XCTAssertEqual(loaded.sounds[4]?.end, 400)
        XCTAssertEqual(loaded.sounds[4]?.frameCount, 512)
    }

    func testRepeatedSaveKeepsOneVisibleProgramAndPreservesRecoveryRevisions() throws {
        let initial = try save()
        var latest = initial
        for tune in 1...5 { latest = try save(latest, name: "RENAMED", tune: tune) }
        let kits = try store.scanKits()
        XCTAssertEqual(kits.map(\.url), [latest])
        XCTAssertEqual(kits.first?.title, "RENAMED")
        XCTAssertEqual(kits.first?.rootURL, store.rootURL)
        XCTAssertNil(kits.first?.partitionLetter)
        XCTAssertFalse(store.contains(initial))
        XCTAssertTrue(store.contains(latest))
        let document = latest.deletingLastPathComponent().deletingLastPathComponent()
        let revisions = try FileManager.default.contentsOfDirectory(at: document, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(revisions.count, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: initial.path))
        let loaded = try KitLoader.load(programURL: latest)
        XCTAssertEqual(loaded.program.tune(forNote: loaded.program.midiNote(forPad: 0)), 5)
    }

    func testFailureAfterNativeWriteKeepsPublishedVersionByteIdentical() throws {
        enum Interrupted: Error { case simulated }
        let first = try save()
        let before = try directoryContents(first.deletingLastPathComponent())
        let (program, sounds) = fixture(tune: 99)
        XCTAssertThrowsError(try store.save(program: program, sounds: sounds, name: "FAILED",
                                           existingProgramURL: first, beforePublication: { throw Interrupted.simulated }))
        XCTAssertEqual(try store.scanKits().map(\.url), [first])
        XCTAssertTrue(store.contains(first))
        XCTAssertEqual(try directoryContents(first.deletingLastPathComponent()), before)
        XCTAssertEqual(try KitLoader.load(programURL: first).program.tune(forNote: program.midiNote(forPad: 0)), 0)
        // An interrupted revision does not prevent the next ordinary save.
        let next = try save(first)
        XCTAssertEqual(try store.scanKits().map(\.url), [next])
    }

    func testChangedStagedAudioProgramOrDirectoryCannotBePublished() throws {
        let first = try save()
        let document = first.deletingLastPathComponent().deletingLastPathComponent()
        let before = try directoryContents(first.deletingLastPathComponent())
        let (program, sounds) = fixture(tune: 20)
        for change in 0..<3 {
            let previousEntries = Set(try FileManager.default.contentsOfDirectory(atPath: document.path))
            var interventionRan = false
            XCTAssertThrowsError(try store.save(program: program, sounds: sounds, name: "CHANGED",
                                               existingProgramURL: first, beforePublication: {
                let newEntries = Set(try FileManager.default.contentsOfDirectory(atPath: document.path)).subtracting(previousEntries)
                let name = try XCTUnwrap(newEntries.first)
                XCTAssertEqual(newEntries.count, 1)
                let revision = document.appendingPathComponent(name, isDirectory: true)
                switch change {
                case 0:
                    try FileManager.default.removeItem(at: revision.appendingPathComponent("KICK.SND"))
                case 1:
                    try Data("Changed program".utf8).write(to: revision.appendingPathComponent("CHANGED.PGM"))
                default:
                    let moved = self.temporary.appendingPathComponent("Moved-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.moveItem(at: revision, to: moved)
                    try FileManager.default.copyItem(at: moved, to: revision)
                }
                interventionRan = true
            }))
            XCTAssertTrue(interventionRan)
            XCTAssertEqual(try store.scanKits().map(\.url), [first])
            XCTAssertTrue(store.contains(first))
            XCTAssertEqual(try directoryContents(first.deletingLastPathComponent()), before)
        }
    }

    func testOneDamagedManifestDoesNotHideOtherPrograms() throws {
        let valid = try save(name: "VALID")
        let broken = try save(name: "BROKEN")
        let manifest = broken.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".mpc-program.json")
        try Data("Damaged manifest".utf8).write(to: manifest)
        let scan = store.scan()
        XCTAssertEqual(scan.kits.map(\.url), [valid])
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(try store.scanKits().map(\.url), [valid])
        XCTAssertEqual(try Data(contentsOf: manifest), Data("Damaged manifest".utf8))
    }

    func testInvalidAudioAndMissingSoundsNeverReplacePublishedVersion() throws {
        let first = try save()
        let before = try directoryContents(first.deletingLastPathComponent())
        let (program, sounds) = fixture()
        XCTAssertThrowsError(try store.save(program: program, sounds: [:], name: "BAD", existingProgramURL: first))
        var invalid = sounds
        invalid[4]?.channels[0][0] = .nan
        XCTAssertThrowsError(try store.save(program: program, sounds: invalid, name: "BAD", existingProgramURL: first))
        XCTAssertEqual(try store.scanKits().map(\.url), [first])
        XCTAssertEqual(try directoryContents(first.deletingLastPathComponent()), before)
    }

    func testOldProgramURLCannotOverwriteNewerSave() throws {
        let first = try save()
        let next = try save(first, tune: 5)
        XCTAssertThrowsError(try save(first, tune: 7)) { error in
            guard case LocalProgramStore.Failure.staleProgram = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.scanKits().map(\.url), [next])
    }

    func testUnknownOrModifiedFilesRemainUntouchedAcrossSaves() throws {
        let first = try save()
        let firstRevision = first.deletingLastPathComponent()
        let unknown = firstRevision.appendingPathComponent("MY_NOTES.txt")
        try Data("Keep my notes".utf8).write(to: unknown)
        let second = try save(first)
        let modified = second.deletingLastPathComponent().appendingPathComponent("KICK.SND")
        let changedData = Data("Externally modified sample".utf8)
        try changedData.write(to: modified)
        let third = try save(second)
        let fourth = try save(third)
        XCTAssertEqual(try Data(contentsOf: unknown), Data("Keep my notes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: modified), changedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try store.scanKits().map(\.url), [fourth])
    }

    func testTrashedCurrentProgramDisappearsWithoutResurrectingPrevious() throws {
        let first = try save()
        let latest = try save(first)
        let sample = latest.deletingLastPathComponent().appendingPathComponent("KICK.SND")
        try FileManager.default.removeItem(at: latest)
        XCTAssertTrue(try store.scanKits().isEmpty)
        XCTAssertFalse(store.contains(latest))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testPrefixSiblingIsNotOwnedAndIsPreserved() throws {
        let sibling = URL(fileURLWithPath: store.rootURL.path + "-external", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let original = sibling.appendingPathComponent("SOURCE.PGM")
        try Data("External source".utf8).write(to: original)
        let saved = try save(original)
        XCTAssertFalse(store.contains(original))
        XCTAssertTrue(store.contains(saved))
        XCTAssertEqual(try Data(contentsOf: original), Data("External source".utf8))
    }

    func testRootAndRevisionSymlinksAreNeverFollowedForOwnershipOrSave() throws {
        let external = temporary.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: store.rootURL, withDestinationURL: external)
        XCTAssertThrowsError(try save())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        try FileManager.default.removeItem(at: store.rootURL)

        let first = try save()
        let revision = first.deletingLastPathComponent()
        let relocated = external.appendingPathComponent("Preserve", isDirectory: true)
        try FileManager.default.moveItem(at: revision, to: relocated)
        try FileManager.default.createSymbolicLink(at: revision, withDestinationURL: relocated)
        let before = try directoryContents(relocated)
        XCTAssertFalse(store.contains(first))
        XCTAssertThrowsError(try save(first))
        XCTAssertTrue(store.scan().kits.isEmpty)
        XCTAssertEqual(store.scan().issues.count, 1)
        XCTAssertEqual(try directoryContents(relocated), before)
    }

    func testManifestAndProgramLinksOrChangesNeverEstablishOwnership() throws {
        let first = try save()
        let document = first.deletingLastPathComponent().deletingLastPathComponent()
        let manifest = document.appendingPathComponent(".mpc-program.json")
        let bytes = try Data(contentsOf: manifest)
        let externalManifest = temporary.appendingPathComponent("external-manifest.json")
        try bytes.write(to: externalManifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: externalManifest)
        XCTAssertFalse(store.contains(first))
        XCTAssertThrowsError(try save(first))
        XCTAssertEqual(try Data(contentsOf: externalManifest), bytes)
        try FileManager.default.removeItem(at: manifest)
        try bytes.write(to: manifest)
        try Data("Changed program".utf8).write(to: first)
        XCTAssertFalse(store.contains(first))
        XCTAssertThrowsError(try save(first))
        XCTAssertTrue(store.scan().kits.isEmpty)
        XCTAssertEqual(store.scan().issues.count, 1)
        XCTAssertEqual(try Data(contentsOf: first), Data("Changed program".utf8))
    }

    private func directoryContents(_ url: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
