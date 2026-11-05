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
        "Les samples de ce .PGM dépassent la limite de 32 Mio de données audio du prototype."
    }
}

/// Reads native programs and samples without changing any source file.
public enum KitLoader {
    public static let maximumPCMBytes = 32 * 1024 * 1024

    public static func load(programURL: URL) throws -> LoadedKit {
        let resolution = try ProgramSoundResolver().resolve(programURL: programURL)
        var missing = resolution.issues
        var totalPCMBytes = 0
        for source in resolution.sounds {
            let pcm = try source.header.pcmBytes()
            let (nextTotal, overflow) = totalPCMBytes.addingReportingOverflow(pcm)
            guard !overflow, nextTotal <= maximumPCMBytes else { throw KitLoaderError.memoryLimitExceeded }
            totalPCMBytes = nextTotal
        }

        // The complete valid program budget is known before the first PCM array is allocated.
        var sounds: [Int: MPCSound] = [:]
        for source in resolution.sounds {
            do {
                let data = try ProgramSoundResolver.readFile(source.url, limit: MPCSound.maximumFileBytes + 1)
                guard data.count == source.header.fileBytes,
                      data.prefix(MPCSoundHeader.byteCount) == source.header.bytes else {
                    throw MPCFormatError.invalid("le son a changé pendant son ouverture ; réessayez.")
                }
                sounds[source.slot] = try MPCSound.decode(data, name: source.name)
            } catch { missing.append("\(source.name) (\(error.localizedDescription))") }
        }
        return LoadedKit(program: resolution.program, sounds: sounds, missing: missing)
    }
}
