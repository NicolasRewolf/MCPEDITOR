import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared, bounded metadata inspection for opening a PGM and displaying its associations.
/// One instance owns one snapshot: sibling programs reuse directory listings and SND headers.
final class ProgramSoundResolver {
    struct Header {
        let bytes: Data
        let fileBytes: UInt64

        var nativeName: String? {
            guard bytes.count == 38, bytes[0] == 1, bytes[1] == 2 else { return nil }
            return String(bytes: bytes[2..<18].prefix { $0 != 0 }, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces)
        }

        func pcmBytes() throws -> Int {
            guard fileBytes <= UInt64(MPCSound.maximumFileBytes) else { throw MPCFormatError.tooLarge }
            guard bytes.count == 38 else { throw MPCFormatError.invalid("en-tête SND tronqué.") }
            let b = Array(bytes)
            guard b[0] == 1 else { throw MPCFormatError.unsupported("ce fichier n'est pas un SND natif.") }
            if b[1] == 0x82 { throw MPCFormatError.unsupported("SND compressé 12 bits (révision 82).") }
            guard b[1] == 2 else { throw MPCFormatError.unsupported("seule la révision SND 02 est prise en charge.") }
            guard b[21] <= 1 else { throw MPCFormatError.invalid("indicateur mono/stéréo incorrect.") }
            func u32(_ position: Int) -> Int {
                Int(UInt32(b[position]) | UInt32(b[position + 1]) << 8 |
                    UInt32(b[position + 2]) << 16 | UInt32(b[position + 3]) << 24)
            }
            let count = u32(30), channelCount = Int(b[21]) + 1
            guard count > 0 else { throw MPCFormatError.invalid("longueur audio nulle.") }
            guard count <= (MPCSound.maximumFileBytes - 38) / (2 * channelCount) else {
                throw MPCFormatError.tooLarge
            }
            let pcm = count * channelCount * 2
            guard fileBytes >= UInt64(38 + pcm) else {
                throw MPCFormatError.invalid("la longueur PCM ne correspond pas à l'en-tête.")
            }
            let start = u32(22), end = u32(26)
            guard start <= end && end <= count else {
                throw MPCFormatError.invalid("marqueurs début/fin hors du son.")
            }
            return pcm
        }
    }

    struct ResolvedSound {
        let slot: Int
        let name: String
        let url: URL
        let header: Header
    }

    struct Resolution {
        let program: MPCProgram
        let sounds: [ResolvedSound]
        let issues: [String]
    }

    private final class Folder {
        let filenames: [String: [URL]]
        let files: [URL]
        var headers: [URL: Result<Header, Error>] = [:]
        var internalNames: Result<[String: [URL]], Error>?

        init(files: [URL]) {
            self.files = files
            filenames = Dictionary(grouping: files) {
                $0.deletingPathExtension().lastPathComponent.uppercased()
            }
        }

        func header(for url: URL) throws -> Header {
            if let cached = headers[url] { return try cached.get() }
            let result = Result { () throws -> Header in
                let handle = try ProgramSoundResolver.openRegularFile(url)
                defer { try? handle.close() }
                return Header(bytes: try ProgramSoundResolver.read(handle, limit: 38),
                              fileBytes: try handle.seekToEnd())
            }
            headers[url] = result
            return try result.get()
        }

        func files(named name: String) throws -> [URL] {
            if internalNames == nil {
                internalNames = Result {
                    var result: [String: [URL]] = [:]
                    for url in files {
                        let inspected = try header(for: url)
                        // An unreadable/truncated header could hide a second native name.
                        // Do not turn an incomplete inventory into a unique association.
                        guard inspected.bytes.count == 38 else {
                            throw MPCFormatError.invalid("en-tête SND tronqué : \(url.lastPathComponent).")
                        }
                        if let name = inspected.nativeName, !name.isEmpty {
                            result[name.uppercased(), default: []].append(url)
                        }
                    }
                    return result
                }
            }
            return try internalNames!.get()[name.uppercased()] ?? []
        }
    }

    private var folders: [URL: Result<Folder, Error>] = [:]
    private var remainingEntries: Int

    init(maximumDirectoryEntries: Int = 50_000) {
        remainingEntries = max(0, maximumDirectoryEntries)
    }

    func resolve(programURL: URL) throws -> Resolution {
        let program = try MPCProgram(data: Self.readFile(programURL, limit: 4609))
        try program.validateKnownFields()
        let slots = program.referencedSlots.sorted()
        guard !slots.isEmpty else {
            return Resolution(program: program, sounds: [], issues: [])
        }
        let folder = try folder(at: programURL.deletingLastPathComponent())
        var resolved: [ResolvedSound] = []
        var issues: [String] = []
        for slot in slots {
            let name = program.soundName(slot: slot)
            let label = name.isEmpty ? "slot \(slot + 1)" : name
            guard !name.isEmpty else { issues.append(label); continue }
            let filenameMatches = folder.filenames[name.uppercased()] ?? []
            let file: URL
            if filenameMatches.count == 1 {
                file = filenameMatches[0]
            } else if filenameMatches.count > 1 {
                issues.append("\(label) (nom de fichier ambigu)")
                continue
            } else {
                do {
                    let matches = try folder.files(named: name)
                    guard matches.count == 1 else {
                        issues.append(matches.isEmpty ? label : "\(label) (nom interne SND ambigu)")
                        continue
                    }
                    file = matches[0]
                } catch {
                    issues.append("\(label) (noms internes non vérifiés : \(error.localizedDescription))")
                    continue
                }
            }
            do {
                let inspected = try folder.header(for: file)
                _ = try inspected.pcmBytes()
                resolved.append(ResolvedSound(slot: slot, name: name, url: file, header: inspected))
            } catch { issues.append("\(label) (\(error.localizedDescription))") }
        }
        return Resolution(program: program, sounds: resolved, issues: issues)
    }

    private func folder(at source: URL) throws -> Folder {
        let url = source.standardizedFileURL
        if let cached = folders[url] { return try cached.get() }
        let result = Result { () throws -> Folder in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            var root = url
            root.removeAllCachedResourceValues()
            let values = try root.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MPCFormatError.invalid("le dossier du .PGM est indisponible ou constitue un lien.")
            }
            var enumerationError: Error?
            guard let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else { throw MPCFormatError.invalid("le dossier du .PGM ne peut pas être parcouru.") }
            var files: [URL] = []
            while let entry = entries.nextObject() as? URL {
                guard remainingEntries > 0 else {
                    throw MPCFormatError.invalid("inventaire des associations incomplet : limite de lecture atteinte.")
                }
                remainingEntries -= 1
                let values = try entry.resourceValues(forKeys: keys)
                guard entry.pathExtension.caseInsensitiveCompare("snd") == .orderedSame else { continue }
                guard values.isSymbolicLink != true else {
                    throw MPCFormatError.invalid("un fichier SND est un lien : \(entry.lastPathComponent).")
                }
                if values.isRegularFile == true { files.append(entry.standardizedFileURL) }
            }
            if let enumerationError { throw enumerationError }
            return Folder(files: files.sorted { $0.path < $1.path })
        }
        folders[url] = result
        return try result.get()
    }

    static func readFile(_ url: URL, limit: Int) throws -> Data {
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        return try read(handle, limit: limit)
    }

    private static func openRegularFile(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw MPCFormatError.invalid("un fichier local est nécessaire.") }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            _ = close(descriptor)
            throw MPCFormatError.invalid("un fichier régulier est nécessaire.")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func read(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data()
        while data.count < limit {
            guard let part = try handle.read(upToCount: limit - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        return data
    }
}
