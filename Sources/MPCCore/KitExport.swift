import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum KitExportError: LocalizedError {
    case invalidDestination
    case missingSounds([Int])
    case invalidSlot(Int)
    case invalidSound(Int)
    case memoryLimitExceeded
    case namesExhausted
    case io(file: String, code: Int32)
    case incompleteRollback(cause: String, files: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "Choisissez un dossier ou une partition accessible en écriture."
        case .missingSounds(let slots):
            return "Sons manquants pour les emplacements MPC : " + slots.map { String($0 + 1) }.joined(separator: ", ") + "."
        case .invalidSlot(let slot):
            return "Emplacement de son MPC invalide : \(slot)."
        case .invalidSound(let slot):
            return "Données audio invalides pour l’emplacement MPC \(slot + 1)."
        case .memoryLimitExceeded:
            return "Ce kit dépasse la limite de 32 Mio de données audio du prototype."
        case .namesExhausted:
            return "Impossible de trouver un nom MPC libre de huit caractères."
        case .io(let file, let code):
            return "Écriture impossible de \(file) : " + NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        case .incompleteRollback(let cause, let files):
            return cause + " Certains nouveaux fichiers n’ont pas pu être retirés : " + files.joined(separator: ", ") + "."
        }
    }
}

/// Exports a new kit into an existing mounted directory, without replacing files.
/// The caller retains its security-scoped access for this entire synchronous call.
public struct KitExport {
    public static let maximumPCMBytes = 32 * 1024 * 1024

    private struct Asset {
        let filename: String
        let data: Data
    }

    private struct CreatedFile {
        let name: String
        let device: dev_t
        let inode: ino_t
    }

    /// `name` chooses the new PGM filename. The program's internal title and
    /// all note, pad, mixer and routing bytes are preserved.
    public static func export(
        program: MPCProgram,
        sounds: [Int: MPCSound],
        name: String,
        to destination: URL
    ) throws -> URL {
        let slots = program.referencedSlots.sorted()
        for slot in slots where !(0..<128).contains(slot) {
            throw KitExportError.invalidSlot(slot)
        }
        let missing = slots.filter { sounds[$0] == nil }
        guard missing.isEmpty else { throw KitExportError.missingSounds(missing) }

        // Preflight and encode everything before creating anything on the card.
        var pcmBytes = 0
        for slot in slots {
            guard let sound = sounds[slot], (1...2).contains(sound.channels.count) else {
                throw KitExportError.invalidSound(slot)
            }
            let (words, wordOverflow) = sound.frameCount.multipliedReportingOverflow(by: sound.channels.count)
            let (bytes, byteOverflow) = words.multipliedReportingOverflow(by: 2)
            let (nextTotal, totalOverflow) = pcmBytes.addingReportingOverflow(bytes)
            guard !wordOverflow, !byteOverflow, !totalOverflow,
                  bytes >= 0, nextTotal <= maximumPCMBytes else {
                throw KitExportError.memoryLimitExceeded
            }
            pcmBytes = nextTotal
        }

        guard destination.isFileURL else { throw KitExportError.invalidDestination }
        let directory = destination.standardizedFileURL.resolvingSymlinksInPath()
        let directoryFD = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directoryFD >= 0 else { throw KitExportError.invalidDestination }
        defer { _ = close(directoryFD) }

        let existing = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        )
        // Reserve stems across all extensions: a sample and a program never
        // receive the same name, even on a case-sensitive test volume.
        var reserved = Set(existing.map {
            $0.deletingPathExtension().lastPathComponent.uppercased()
        })
        let programStem = try reserveName(name, fallback: "KIT", reserved: &reserved)
        var exported = program
        let referenced = Set(slots)
        for slot in 0..<128 where !referenced.contains(slot) {
            exported.setSound(slot: slot, name: "", wordCount: 0)
        }

        var assets: [Asset] = []
        for slot in slots {
            guard let sound = sounds[slot] else {
                throw KitExportError.missingSounds([slot])
            }
            let stem = try reserveName(
                program.soundName(slot: slot), fallback: "SOUND", reserved: &reserved
            )
            let encoded = try sound.encoded(name: stem)
            exported.setSound(
                slot: slot, name: stem,
                wordCount: sound.frameCount * sound.channels.count
            )
            assets.append(Asset(filename: stem + ".SND", data: encoded))
        }
        let programFilename = programStem + ".PGM"
        assets.append(Asset(filename: programFilename, data: exported.bytes))

        var created: [CreatedFile] = []
        do {
            for asset in assets {
                try writeExclusively(
                    asset.data, filename: asset.filename,
                    directoryFD: directoryFD, created: &created
                )
            }
            // Some mounted filesystems do not support synchronizing directories.
            if fsync(directoryFD) != 0 {
                let code = errno
                if code != EINVAL && code != ENOTSUP {
                    throw KitExportError.io(file: programFilename, code: code)
                }
            }
        } catch {
            let leftovers = rollback(created, directoryFD: directoryFD)
            if !leftovers.isEmpty {
                throw KitExportError.incompleteRollback(
                    cause: error.localizedDescription, files: leftovers
                )
            }
            throw error
        }
        return directory.appendingPathComponent(programFilename)
    }

    private static func reserveName(
        _ source: String, fallback: String, reserved: inout Set<String>
    ) throws -> String {
        let safe = MPCSound.safeName(source).uppercased()
        var cleaned = ""
        for scalar in safe.unicodeScalars {
            let value = scalar.value
            let allowed = (65...90).contains(value) || (48...57).contains(value) || value == 95
            if allowed {
                cleaned.unicodeScalars.append(scalar)
            } else if !cleaned.hasSuffix("_") {
                cleaned.append("_")
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = cleaned.isEmpty ? fallback : cleaned
        let first = String(base.prefix(8))
        if reserved.insert(first).inserted { return first }
        for number in 1...9_999_999 {
            let suffix = String(number)
            let candidate = String(base.prefix(8 - suffix.count)) + suffix
            if reserved.insert(candidate).inserted { return candidate }
        }
        throw KitExportError.namesExhausted
    }

    private static func writeExclusively(
        _ data: Data, filename: String, directoryFD: Int32,
        created: inout [CreatedFile]
    ) throws {
        let fd = filename.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o644))
        }
        guard fd >= 0 else { throw KitExportError.io(file: filename, code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            _ = close(fd)
            // Without an inode identity, leave the newly created entry in place
            // and report it instead of risking removal of a replacement.
            throw KitExportError.incompleteRollback(
                cause: KitExportError.io(file: filename, code: code).localizedDescription,
                files: [filename]
            )
        }
        // Record immediately, so partial writes are also rolled back.
        created.append(CreatedFile(name: filename, device: info.st_dev, inode: info.st_ino))
        do {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw KitExportError.io(file: filename, code: errno)
                    }
                    guard count > 0 else { throw KitExportError.io(file: filename, code: EIO) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else {
                throw KitExportError.io(file: filename, code: errno)
            }
        } catch {
            _ = close(fd)
            throw error
        }
        guard close(fd) == 0 else {
            throw KitExportError.io(file: filename, code: errno)
        }
    }

    private static func rollback(_ created: [CreatedFile], directoryFD: Int32) -> [String] {
        var leftovers: [String] = []
        for file in created.reversed() {
            var current = stat()
            let result = file.name.withCString {
                fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0 {
                if errno != ENOENT { leftovers.append(file.name) }
                continue
            }
            // Another process may have replaced a path since creation.
            // Never remove a file whose identity differs from ours.
            guard current.st_dev == file.device, current.st_ino == file.inode else { continue }
            let removed = file.name.withCString { unlinkat(directoryFD, $0, 0) }
            if removed != 0 && errno != ENOENT { leftovers.append(file.name) }
        }
        _ = fsync(directoryFD)
        return Array(leftovers.reversed())
    }
}
