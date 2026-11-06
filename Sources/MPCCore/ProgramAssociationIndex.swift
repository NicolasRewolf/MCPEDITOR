import Foundation

/// References resolved for one exact on-disk PGM, not every file sharing its name.
public struct ProgramAssociation: Sendable {
    public let program: LibraryKit
    public let samples: [URL]
    public let issues: [String]
    /// Program title stored in the PGM header, which can differ from its DOS filename.
    public let title: String?
    public var isComplete: Bool { issues.isEmpty }

    public init(program: LibraryKit, samples: [URL], issues: [String], title: String? = nil) {
        self.program = program
        self.samples = Array(Set(samples.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        self.issues = issues
        self.title = title
    }
}

/// Display-only snapshot of native PGM references. Never authorizes deletion or an SD write.
/// Reads at most 4,609 bytes per PGM and 38 bytes per SND; PCM is neither read nor decoded.
public struct ProgramAssociationIndex: Sendable {
    public let programs: [ProgramAssociation]
    public let issues: [String]
    public var isComplete: Bool { issues.isEmpty }
    private let byProgram: [URL: ProgramAssociation]
    private let bySample: [URL: [LibraryKit]]

    public init() {
        self.init(programs: [], issues: [])
    }

    private init(programs: [ProgramAssociation], issues: [String]) {
        self.programs = programs
        self.issues = issues
        byProgram = Dictionary(uniqueKeysWithValues: programs.map { ($0.program.url, $0) })
        var reverse: [URL: [LibraryKit]] = [:]
        for association in programs {
            for url in association.samples { reverse[url, default: []].append(association.program) }
        }
        bySample = reverse
    }

    public func programs(using sampleURL: URL) -> [LibraryKit] {
        bySample[sampleURL.standardizedFileURL] ?? []
    }

    public func association(for programURL: URL) -> ProgramAssociation? {
        byProgram[programURL.standardizedFileURL]
    }

    public static func scan(programs: [LibraryKit], upstreamIssues: [String] = [],
                            maximumPrograms: Int = 5_000,
                            maximumDirectoryEntries: Int = 50_000) -> ProgramAssociationIndex {
        let resolver = ProgramSoundResolver(maximumDirectoryEntries: maximumDirectoryEntries)
        var associations: [ProgramAssociation] = []
        var issues = upstreamIssues
        var visited: Set<URL> = []
        for program in programs {
            guard !visited.contains(program.url) else { continue }
            guard visited.count < max(0, maximumPrograms) else {
                issues.append(String(localized: "Associations incomplètes : limite de \(max(0, maximumPrograms)) .PGM atteinte."))
                break
            }
            visited.insert(program.url)
            let association: ProgramAssociation
            do {
                let result = try resolver.resolve(programURL: program.url)
                association = ProgramAssociation(program: program, samples: result.sounds.map(\.url),
                                                  issues: result.issues, title: result.program.name)
            } catch {
                association = ProgramAssociation(program: program, samples: [],
                                                  issues: [error.localizedDescription])
            }
            associations.append(association)
            if !association.isComplete {
                issues.append(String(localized: "\(program.title).PGM · \(program.locationLabel) : \(association.issues.joined(separator: "; "))"))
            }
        }
        associations.sort { $0.program.url.path < $1.program.url.path }
        return ProgramAssociationIndex(programs: associations, issues: issues)
    }
}
