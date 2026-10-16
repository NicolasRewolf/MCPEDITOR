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
        let descriptor: Int32
    }

    /// Narrow syscall injection for deterministic partial-write and ownership tests.
    /// Production always uses the native implementations below.
    struct FileIO {
        var writeBytes: (Int32, UnsafeRawPointer, Int) -> Int = { write($0, $1, $2) }
        var descriptorInfo: (Int32, inout stat) -> Int32 = { fstat($0, &$1) }
        var entryInfo: (Int32, String, inout stat) -> Int32 = { directory, name, info in
            name.withCString { fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }
        }
        var removeEntry: (Int32, String) -> Int32 = { directory, name in
            name.withCString { unlinkat(directory, $0, 0) }
        }
        var synchronize: (Int32) -> Int32 = { fsync($0) }
        var closeFile: (Int32) -> Int32 = { close($0) }
        var canIdentifyEmptyFile: (Int32) -> Bool = { KitExport.canIdentifyEmptyFile($0) }
        var volumeSpace: (Int32) throws -> ExportVolumeSpace = { try ExportSpace.volume(directoryFD: $0) }
    }

    /// `name` chooses the new PGM filename. The program's internal title and
    /// all note, pad, mixer and routing bytes are preserved.
    public static func export(
        program: MPCProgram,
        sounds: [Int: MPCSound],
        name: String,
        to destination: URL
    ) throws -> URL {
        try export(program: program, sounds: sounds, name: name, to: destination, io: FileIO())
    }

    static func export(
        program: MPCProgram,
        sounds: [Int: MPCSound],
        name: String,
        to destination: URL,
        io: FileIO
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

        // Foundation filters AppleDouble entries even without skipHiddenFiles. Read the
        // complete native name inventory so orphan metadata can reserve its counterpart.
        let existing = try existingNames(directoryFD: directoryFD)
        // Reserve stems across all extensions: a sample and a program never
        // receive the same name, even on a case-sensitive test volume.
        var reserved = Set(existing.flatMap { name -> [String] in
            let stem = (name as NSString).deletingPathExtension.uppercased()
            // Creating the native counterpart of an orphan AppleDouble can cause the
            // filesystem to consume or discard its metadata. Reserve that native name too.
            return stem.hasPrefix("._") ? [stem, String(stem.dropFirst(2))] : [stem]
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

        let volume = try io.volumeSpace(directoryFD)
        let estimate = try ExportSpace.estimate(fileSizes: assets.map { $0.data.count }, volume: volume)
        guard estimate.requiredBytes <= volume.availableBytes else {
            throw ExportSpaceError.insufficientSpace(required: estimate.requiredBytes, available: volume.availableBytes)
        }

        var created: [CreatedFile] = []
        do {
            for asset in assets {
                try writeExclusively(
                    asset.data, filename: asset.filename,
                    directoryFD: directoryFD, created: &created, io: io
                )
            }
            // Some mounted filesystems do not support synchronizing directories.
            if io.synchronize(directoryFD) != 0 {
                let code = errno
                if code != EINVAL && code != ENOTSUP {
                    throw KitExportError.io(file: programFilename, code: code)
                }
            }
        } catch {
            let leftovers = rollback(created, directoryFD: directoryFD, io: io)
            for file in created { _ = io.closeFile(file.descriptor) }
            if !leftovers.isEmpty {
                throw KitExportError.incompleteRollback(
                    cause: error.localizedDescription, files: leftovers
                )
            }
            throw error
        }
        var closingError: KitExportError?
        for file in created {
            if io.closeFile(file.descriptor) != 0, closingError == nil {
                closingError = .io(file: file.name, code: errno)
            }
        }
        if let closingError {
            // All bodies and the directory have already been synchronized. Some handles are
            // now closed, so ownership cannot safely be proved for a destructive rollback.
            throw KitExportError.incompleteRollback(cause: closingError.localizedDescription,
                                                     files: created.map(\.name))
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

    private static func existingNames(directoryFD: Int32) throws -> [String] {
        let descriptor = dup(directoryFD)
        guard descriptor >= 0 else { throw KitExportError.io(file: "dossier d’export", code: errno) }
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            _ = close(descriptor)
            throw KitExportError.io(file: "dossier d’export", code: code)
        }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw KitExportError.io(file: "dossier d’export", code: errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private static func writeExclusively(
        _ data: Data, filename: String, directoryFD: Int32,
        created: inout [CreatedFile], io: FileIO
    ) throws {
        let fd = filename.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o644))
        }
        guard fd >= 0 else { throw KitExportError.io(file: filename, code: errno) }
        // Keep ownership through the live descriptor until commit or rollback. On FAT,
        // st_ino can change when the first data cluster is allocated: a pre-write snapshot
        // does not identify the completed file reliably.
        created.append(CreatedFile(name: filename, descriptor: fd))
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let count = io.writeBytes(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw KitExportError.io(file: filename, code: errno)
                }
                guard count > 0 else { throw KitExportError.io(file: filename, code: EIO) }
                offset += count
            }
        }
        guard io.synchronize(fd) == 0 else {
            throw KitExportError.io(file: filename, code: errno)
        }
    }

    private static func rollback(_ created: [CreatedFile], directoryFD: Int32, io: FileIO) -> [String] {
        var leftovers: [String] = []
        func recordRemainingSidecar(_ filename: String) {
            let sidecarName = "._" + filename
            var metadata = stat()
            let result = io.entryInfo(directoryFD, sidecarName, &metadata)
            if result == 0 || errno != ENOENT { leftovers.append(sidecarName) }
        }
        for file in created.reversed() {
            var owned = stat()
            guard io.descriptorInfo(file.descriptor, &owned) == 0 else {
                leftovers.append(file.name)
                continue
            }
            // FAT derives nonempty IDs from the first allocated cluster; empty files can
            // share an ID. A matching ID cannot prove ownership of an empty replacement.
            guard owned.st_size != 0 || io.canIdentifyEmptyFile(file.descriptor) else {
                leftovers.append(file.name)
                continue
            }
            var current = stat()
            let result = io.entryInfo(directoryFD, file.name, &current)
            if result != 0 {
                if errno != ENOENT { leftovers.append(file.name) }
                else { recordRemainingSidecar(file.name) }
                continue
            }
            // A changed or unverifiable identity must stay in place and be reported.
            // In particular, do not mistake a replacement entry for our open file.
            guard current.st_dev == owned.st_dev, current.st_ino == owned.st_ino else {
                leftovers.append(file.name)
                continue
            }
            let removed = io.removeEntry(directoryFD, file.name)
            if removed != 0 && errno != ENOENT { leftovers.append(file.name) }
            else { recordRemainingSidecar(file.name) }
        }
        _ = io.synchronize(directoryFD)
        return Array(leftovers.reversed())
    }

    private static func canIdentifyEmptyFile(_ descriptor: Int32) -> Bool {
        #if canImport(Darwin)
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { return false }
        let name = withUnsafePointer(to: &filesystem.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        return name != "msdos" && name != "exfat"
        #else
        // The export app runs on macOS; other filesystems remain conservative for empties.
        return false
        #endif
    }
}
