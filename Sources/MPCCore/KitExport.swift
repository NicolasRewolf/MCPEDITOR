import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum KitExportError: LocalizedError, Sendable {
    case invalidDestination
    case missingSounds([Int])
    case invalidSlot(Int)
    case invalidSound(Int)
    case invalidPCM16Range(slot: Int, peak: Float, outOfRange: Int, nonFinite: Int)
    case memoryLimitExceeded
    case namesExhausted
    case io(file: String, code: Int32)
    case destinationChangedDuringWrite(selected: String, actual: String?)
    case publishedFileChanged(String)
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
        case .invalidPCM16Range(let slot, let peak, let outOfRange, let nonFinite):
            return "Le son de l’emplacement MPC \(slot + 1) dépasse la plage PCM16 : crête \(String(format: "%.3f", peak)), \(outOfRange) valeurs hors plage et \(nonFinite) valeurs non finies. Réduis son gain ou normalise-le avant l’enregistrement."
        case .memoryLimitExceeded:
            return "Les samples de ce .PGM dépassent la limite de 32 Mio de données audio du prototype."
        case .namesExhausted:
            return "Impossible de trouver un nom MPC libre de huit caractères."
        case .io(let file, let code):
            return "Écriture impossible de \(file) : " + NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
        case .destinationChangedDuringWrite(let selected, let actual):
            let location = actual.map { " Ils se trouvent dans le dossier ouvert : \($0)." } ?? " Leur emplacement actuel doit être vérifié dans le Finder."
            return "La destination a changé pendant l’enregistrement : \(selected)." + location
        case .publishedFileChanged(let filename):
            return "Le fichier \(filename) a changé pendant l’enregistrement. L’enregistrement du .PGM n’a pas été confirmé."
        case .incompleteRollback(let cause, let files):
            return cause + " Par sécurité, aucun fichier créé n’a été supprimé automatiquement. Fichiers à vérifier : " + files.joined(separator: ", ") + "."
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
        var name: String
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
        /// There is deliberately no injected unlink: failure handling never removes a public name.
        var publishProgram: (Int32, String, String) -> Int32 = { directory, temporary, final in
            KitExport.publishExclusively(directoryFD: directory, temporary: temporary, final: final)
        }
        var synchronize: (Int32) -> Int32 = { fsync($0) }
        var closeFile: (Int32) -> Int32 = { close($0) }
        var volumeSpace: (Int32) throws -> ExportVolumeSpace = { try ExportSpace.volume(directoryFD: $0) }
        var destinationEnvironment = ExportDestination.Environment()
    }

    /// `name` chooses the new PGM filename. The program's internal title and
    /// all note, pad, mixer and routing bytes are preserved.
    public static func export(
        program: MPCProgram,
        sounds: [Int: MPCSound],
        name: String,
        to destination: URL,
        expectedDestination: ExportDestination? = nil
    ) throws -> URL {
        try export(program: program, sounds: sounds, name: name, to: destination, expectedDestination: expectedDestination, io: FileIO())
    }

    static func export(
        program: MPCProgram,
        sounds: [Int: MPCSound],
        name: String,
        to destination: URL,
        expectedDestination: ExportDestination? = nil,
        io: FileIO
    ) throws -> URL {
        try program.validateKnownFields()
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
            let range = sound.pcm16RangeReport
            guard range.outOfRangeSampleCount == 0, range.nonFiniteSampleCount == 0 else {
                throw KitExportError.invalidPCM16Range(slot: slot, peak: range.peakMagnitude,
                                                       outOfRange: range.outOfRangeSampleCount,
                                                       nonFinite: range.nonFiniteSampleCount)
            }
            pcmBytes = nextTotal
        }

        let receipt = try expectedDestination ?? ExportDestination.capture(
            at: destination, environment: io.destinationEnvironment)
        let directory = receipt.url
        let directoryFD = try receipt.openWriteDirectory(selectedURL: destination)
        defer { _ = close(directoryFD) }
        try receipt.validate(directoryFD: directoryFD, selectedURL: destination,
                             environment: io.destinationEnvironment)

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
        // DOS 8.3 staging uses the same allocation as the final PGM, without any extra
        // directory or audio copy. A process interruption can leave a .TMP, never a
        // partly written .PGM that the library or MPC could interpret as a kit.
        let temporaryProgramFilename = programStem + ".TMP"
        assets.append(Asset(filename: temporaryProgramFilename, data: exported.bytes))

        let volume = try io.volumeSpace(directoryFD)
        let estimate = try ExportSpace.estimate(fileSizes: assets.map { $0.data.count }, volume: volume)
        guard estimate.requiredBytes <= volume.availableBytes else {
            throw ExportSpaceError.insufficientSpace(required: estimate.requiredBytes, available: volume.availableBytes)
        }

        // Recheck after encoding and capacity probes, immediately before the first exclusive creation.
        try receipt.validate(directoryFD: directoryFD, selectedURL: destination,
                             environment: io.destinationEnvironment)

        var created: [CreatedFile] = []
        var closedDescriptors: Set<Int32> = []
        do {
            for asset in assets {
                try writeExclusively(
                    asset.data, filename: asset.filename,
                    directoryFD: directoryFD, created: &created, io: io
                )
            }
            try verifyPublishedFiles(created, directoryFD: directoryFD, io: io)
            try synchronizeDirectory(directoryFD, filename: programFilename, io: io)
            try validateLocationAfterCreation(receipt, directoryFD: directoryFD,
                                              selectedURL: destination, io: io)
            // Both the program body and every SND are fully synchronized before this
            // one atomic, exclusive publication. Never fall back to replacing rename.
            guard io.publishProgram(directoryFD, temporaryProgramFilename, programFilename) == 0 else {
                throw KitExportError.io(file: programFilename, code: errno)
            }
            created[created.count - 1].name = programFilename
            try synchronizeDirectory(directoryFD, filename: programFilename, io: io)
            // A concurrent writer can also replace a completed SND or PGM. Refuse a
            // success result unless every published name still identifies our open body.
            try verifyPublishedFiles(created, directoryFD: directoryFD, io: io)
            for file in created {
                let result = io.closeFile(file.descriptor)
                closedDescriptors.insert(file.descriptor)
                guard result == 0 else { throw KitExportError.io(file: file.name, code: errno) }
            }
            try validateLocationAfterCreation(receipt, directoryFD: directoryFD,
                                              selectedURL: destination, io: io)
        } catch {
            let artifacts = preservedArtifacts(created, directoryFD: directoryFD, io: io)
            for file in created where !closedDescriptors.contains(file.descriptor) {
                _ = io.closeFile(file.descriptor)
            }
            // A stat-then-unlink pair cannot conditionally delete the checked inode.
            // Even a matching live descriptor does not close that race. Retain all
            // created names on failure; report their names and never claim rollback.
            if !artifacts.isEmpty {
                let location = currentDirectoryPath(directoryFD).map { " Dossier ouvert : \($0)." } ?? ""
                throw KitExportError.incompleteRollback(cause: error.localizedDescription + location, files: artifacts)
            }
            throw error
        }
        return directory.appendingPathComponent(programFilename)
    }

    private static func synchronizeDirectory(_ descriptor: Int32, filename: String, io: FileIO) throws {
        // Some mounted filesystems do not support synchronizing directories.
        if io.synchronize(descriptor) != 0 {
            let code = errno
            if code != EINVAL && code != ENOTSUP { throw KitExportError.io(file: filename, code: code) }
        }
    }

    private static func validateLocationAfterCreation(
        _ receipt: ExportDestination, directoryFD: Int32, selectedURL: URL, io: FileIO
    ) throws {
        do {
            try receipt.validateLocation(directoryFD: directoryFD, selectedURL: selectedURL,
                                         environment: io.destinationEnvironment)
        } catch {
            throw KitExportError.destinationChangedDuringWrite(selected: selectedURL.path,
                                                               actual: currentDirectoryPath(directoryFD))
        }
    }

    private static func currentDirectoryPath(_ descriptor: Int32) -> String? {
        #if canImport(Darwin)
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { return nil }
        return String(cString: bytes)
        #else
        return nil
        #endif
    }

    private static func verifyPublishedFiles(_ created: [CreatedFile], directoryFD: Int32, io: FileIO) throws {
        for file in created {
            var owned = stat()
            var current = stat()
            guard io.descriptorInfo(file.descriptor, &owned) == 0,
                  io.entryInfo(directoryFD, file.name, &current) == 0,
                  owned.st_dev == current.st_dev, owned.st_ino == current.st_ino,
                  owned.st_size == current.st_size,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw KitExportError.publishedFileChanged(file.name)
            }
        }
    }

    private static func publishExclusively(directoryFD: Int32, temporary: String, final: String) -> Int32 {
        #if canImport(Darwin)
        return temporary.withCString { source in
            final.withCString { target in
                renameatx_np(directoryFD, source, directoryFD, target, UInt32(RENAME_EXCL))
            }
        }
        #else
        // The app is macOS-only. On platforms without exclusive atomic rename, refuse
        // publication rather than introduce a replacing rename or copy/delete fallback.
        errno = ENOTSUP
        return -1
        #endif
    }

    private static func preservedArtifacts(_ created: [CreatedFile], directoryFD: Int32, io: FileIO) -> [String] {
        var names: [String] = []
        for file in created {
            // Include native names even when unavailable or concurrently moved: they
            // describe what this attempt created, not a claim that it still owns them.
            names.append(file.name)
            let sidecar = "._" + file.name
            var info = stat()
            if io.entryInfo(directoryFD, sidecar, &info) == 0 || errno != ENOENT {
                names.append(sidecar)
            }
        }
        return names
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
        try ExportDestination.nativeNames(directoryFD: directoryFD)
    }

    private static func writeExclusively(
        _ data: Data, filename: String, directoryFD: Int32,
        created: inout [CreatedFile], io: FileIO
    ) throws {
        let fd = filename.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o644))
        }
        guard fd >= 0 else { throw KitExportError.io(file: filename, code: errno) }
        // Retain the live descriptor for post-write verification. On FAT,
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

}
