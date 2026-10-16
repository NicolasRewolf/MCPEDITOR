import Foundation

public struct LoadedKit: Sendable {
    public let program: MPCProgram
    public let sounds: [Int: MPCSound]
    /// Referenced sounds that are absent, ambiguous, unreadable or unsupported.
    public let missing: [String]
}

public enum KitLoaderError: LocalizedError, Sendable {
    case memoryLimitExceeded

    public var errorDescription: String? {
        "Ce kit dépasse la limite de 32 Mio de données audio du prototype."
    }
}

/// Reads native programs and samples without changing any source file.
public enum KitLoader {
    public static let maximumPCMBytes = 32 * 1024 * 1024

    private struct Header {
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

    private struct ResolvedSound {
        let slot: Int
        let name: String
        let url: URL
        let header: Header
    }

    public static func load(programURL: URL) throws -> LoadedKit {
        // Read one byte beyond the native size, rather than allocating an arbitrary PGM file.
        let program = try MPCProgram(data: readFile(programURL, limit: 4609))
        try program.validateKnownFields()
        let folder = programURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ).filter {
            $0.pathExtension.caseInsensitiveCompare("snd") == .orderedSame &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        var headers: [URL: Result<Header, Error>] = [:]
        func header(for url: URL) throws -> Header {
            if let cached = headers[url] { return try cached.get() }
            let result = Result { () throws -> Header in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let bytes = try read(handle, limit: 38)
                let fileBytes = try handle.seekToEnd()
                return Header(bytes: bytes, fileBytes: fileBytes)
            }
            headers[url] = result
            return try result.get()
        }

        var internalNames: [(URL, String)]?
        var resolved: [ResolvedSound] = []
        var missing: [String] = []
        var totalPCMBytes = 0
        for slot in program.referencedSlots.sorted() {
            let name = program.soundName(slot: slot)
            let label = name.isEmpty ? "slot \(slot + 1)" : name
            guard !name.isEmpty else { missing.append(label); continue }
            let filenameMatches = files.filter {
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
            }
            let file: URL
            if filenameMatches.count == 1 {
                file = filenameMatches[0]
            } else if filenameMatches.count > 1 {
                missing.append("\(label) (nom de fichier ambigu)")
                continue
            } else {
                if internalNames == nil {
                    // Native DOS filenames can be shorter than the 16-byte SND name.
                    // Index headers only; unrelated sample bodies are never decoded.
                    internalNames = files.compactMap { url in
                        guard let name = try? header(for: url).nativeName, !name.isEmpty else { return nil }
                        return (url, name)
                    }
                }
                let matches = internalNames!.filter { $0.1.caseInsensitiveCompare(name) == .orderedSame }
                guard matches.count == 1 else {
                    missing.append(matches.isEmpty ? label : "\(label) (nom interne SND ambigu)")
                    continue
                }
                file = matches[0].0
            }
            do {
                let inspected = try header(for: file)
                let pcm = try inspected.pcmBytes()
                let (nextTotal, overflow) = totalPCMBytes.addingReportingOverflow(pcm)
                guard !overflow, nextTotal <= maximumPCMBytes else { throw KitLoaderError.memoryLimitExceeded }
                totalPCMBytes = nextTotal
                resolved.append(ResolvedSound(slot: slot, name: name, url: file, header: inspected))
            } catch let error as KitLoaderError { throw error }
              catch { missing.append("\(label) (\(error.localizedDescription))") }
        }

        // The complete valid kit budget is known before the first PCM array is allocated.
        var sounds: [Int: MPCSound] = [:]
        for source in resolved {
            do {
                let data = try readFile(source.url, limit: MPCSound.maximumFileBytes + 1)
                guard data.count == source.header.fileBytes,
                      data.prefix(38) == source.header.bytes else {
                    throw MPCFormatError.invalid("le son a changé pendant son ouverture ; réessayez.")
                }
                sounds[source.slot] = try MPCSound.decode(data, name: source.name)
            } catch { missing.append("\(source.name) (\(error.localizedDescription))") }
        }
        return LoadedKit(program: program, sounds: sounds, missing: missing)
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw MPCFormatError.invalid("un fichier régulier est nécessaire.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try read(handle, limit: limit)
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
