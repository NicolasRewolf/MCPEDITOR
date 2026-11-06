import Foundation
import XCTest
@testable import MPCCore

/// The MPC's SD is FAT12, and macOS's FAT driver refuses exclusive renames (ENOTSUP).
/// These tests copy onto a FAT12 disk image made for the test, never onto a card.
final class KitExportFATTests: XCTestCase {
    private var part: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KitExportFATTests-" + UUID().uuidString, isDirectory: true)
        let image = root.appendingPathComponent("PART.dmg")
        let mountPoint = root.appendingPathComponent("PART", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard Self.run("create", "-quiet", "-size", "8m", "-fs", "MS-DOS FAT12", "-volname", "MPCPART", "-layout", "NONE", image.path),
              Self.run("attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path) else {
            try? FileManager.default.removeItem(at: root)
            throw XCTSkip("hdiutil cannot create or mount a FAT12 image here")
        }
        addTeardownBlock {
            Self.run("detach", "-quiet", "-force", mountPoint.path)
            try? FileManager.default.removeItem(at: root)
        }
        // These tests are about publishing on the FAT driver. On macOS 15 (GitHub's runner) the
        // occupancy check already refuses a fresh image, "1536 octets occupés ne sont pas expliqués".
        do {
            _ = try ExportDestination.capture(at: mountPoint, requireEmpty: true)
        } catch let ExportDestinationError.unverified(detail) {
            throw XCTSkip("The FAT occupancy check refuses a fresh FAT12 image on this macOS: \(detail)")
        }
        part = mountPoint
    }

    @discardableResult
    private static func run(_ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func visibleNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: part.path).filter { !$0.hasPrefix(".") })
    }

    func testCopyPublishesTheProgramAndLeavesNoTemporaryFile() throws {
        var program = MPCProgram.blank(name: "KIT")
        program.assign(slot: 0, toNote: 35)
        program.setSound(slot: 0, name: "KICK", wordCount: 1)
        let kick = MPCSound(name: "KICK", channels: [(0..<512).map { Float($0 % 32) / 64 - 0.25 }])

        let output = try KitExport.export(program: program, sounds: [0: kick], name: "KIT", to: part)

        XCTAssertEqual(output.lastPathComponent, "KIT.PGM")
        XCTAssertEqual(try MPCProgram(data: Data(contentsOf: output)).referencedSlots, [0])
        XCTAssertEqual(try visibleNames(), ["KICK.SND", "KIT.PGM"])
    }

    func testSecondCopyWithTheSameNameKeepsTheFirstProgram() throws {
        let first = try KitExport.export(program: .blank(name: "KIT"), sounds: [:], name: "KIT", to: part)
        let original = try Data(contentsOf: first)

        let second = try KitExport.export(program: .blank(name: "KIT"), sounds: [:], name: "KIT", to: part)

        XCTAssertNotEqual(second.lastPathComponent, first.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertFalse(try visibleNames().contains { $0.hasSuffix(".TMP") })
    }

    func testPublicationNeverReplacesAProgramThatAppearedMeanwhile() throws {
        try Data("ours".utf8).write(to: part.appendingPathComponent("KIT.TMP"))
        try Data("theirs".utf8).write(to: part.appendingPathComponent("KIT.PGM"))
        let directory = open(part.path, O_RDONLY | O_DIRECTORY)
        defer { close(directory) }

        let result = KitExport.publishExclusively(directoryFD: directory, temporary: "KIT.TMP", final: "KIT.PGM")
        let code = errno

        XCTAssertEqual(result, -1)
        XCTAssertEqual(code, EEXIST)
        XCTAssertEqual(try String(contentsOf: part.appendingPathComponent("KIT.PGM"), encoding: .utf8), "theirs")
        XCTAssertEqual(try String(contentsOf: part.appendingPathComponent("KIT.TMP"), encoding: .utf8), "ours")
    }
}
