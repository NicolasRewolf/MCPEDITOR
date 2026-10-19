import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A program's filesystem identity stays distinct from its display name.
public struct LibraryKit: Identifiable, Equatable, Sendable {
    public let url: URL
    public let rootURL: URL
    public let partitionLetter: String?
    public let relativeFolder: String

    public init(url: URL, rootURL: URL, partitionLetter: String?, relativeFolder: String) {
        self.url = url.standardizedFileURL
        self.rootURL = rootURL.standardizedFileURL
        self.partitionLetter = partitionLetter
        self.relativeFolder = relativeFolder
    }

    public var id: URL { url }
    public var title: String { url.deletingPathExtension().lastPathComponent }
    public var locationLabel: String {
        let root = partitionLetter.map { "PART \($0)" } ?? rootURL.lastPathComponent
        return relativeFolder.isEmpty ? root : "\(root) · \(relativeFolder)"
    }
}

/// Metadata only: scanning never opens program or audio bodies.
public struct LibraryPartition: Equatable, Sendable {
    public let url: URL
    public let letter: String
    public let kits: [LibraryKit]
    public let fileCount: Int
    public let folderCount: Int
    public let audioCount: Int
    public let samples: [URL]
    public let sequenceCount: Int
    public let issues: [String]
    public let availableBytes: Int64?
    public let volumeSpace: ExportVolumeSpace?
    public let exportDestination: ExportDestination?

    public init(url: URL, letter: String, kits: [LibraryKit], fileCount: Int,
                folderCount: Int, audioCount: Int, sequenceCount: Int,
                issues: [String], availableBytes: Int64?, volumeSpace: ExportVolumeSpace? = nil,
                exportDestination: ExportDestination? = nil, samples: [URL] = []) {
        self.url = url.standardizedFileURL
        self.letter = letter
        self.kits = kits
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.audioCount = audioCount
        self.samples = samples.map(\.standardizedFileURL)
        self.sequenceCount = sequenceCount
        self.issues = issues
        self.availableBytes = availableBytes
        self.volumeSpace = volumeSpace
        self.exportDestination = exportDestination
    }

    /// Unknown files, links, folders, read errors and truncation all prevent an empty claim.
    public var isEmpty: Bool { fileCount == 0 && folderCount == 0 && issues.isEmpty }
}

public struct LibraryFolderListing: Equatable, Sendable {
    public let folders: [URL]
    public let samples: [URL]
    public let issue: String?

    public init(folders: [URL], samples: [URL], issue: String?) {
        self.folders = folders.map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: true) }
        self.samples = samples.map(\.standardizedFileURL)
        self.issue = issue
    }
}

public enum LibraryIndexError: LocalizedError, Sendable {
    case incomplete([String])

    public var errorDescription: String? {
        switch self {
        case .incomplete(let issues): return issues.joined(separator: "\n")
        }
    }
}

/// Bounded, read-only snapshots suitable for a background task.
public enum LibraryIndex {
    public static let supportedAudioExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "snd", "caf", "m4a", "mp3", "aac", "flac"
    ]

    public static func partitionLetter(for url: URL) -> String? {
        let name = url.lastPathComponent
        let prefix = "MPC-PART--"
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.utf8.count == 1, let byte = suffix.utf8.first,
              (65...90).contains(byte) else { return nil }
        return String(suffix)
    }

    public static func scanPartition(_ url: URL, maximumDepth: Int = 8,
                                     maximumEntries: Int = 50_000) -> LibraryPartition {
        scanPartition(url, maximumDepth: maximumDepth, maximumEntries: maximumEntries,
                      fatVolumeProbe: fatVolumeUsage,
                      destinationCapture: { try ExportDestination.capture(at: $0, requireEmpty: $1) })
    }

    /// A narrow seam lets tests reproduce a misleading empty directory with occupied FAT clusters.
    struct FATVolumeUsage {
        let allocationUnitBytes: Int64
        let occupiedBytes: Int64
        let rootAllocationIsFixed: Bool

        init(allocationUnitBytes: Int64, occupiedBytes: Int64, rootAllocationIsFixed: Bool = false) {
            self.allocationUnitBytes = allocationUnitBytes
            self.occupiedBytes = occupiedBytes
            self.rootAllocationIsFixed = rootAllocationIsFixed
        }
    }

    static func scanPartition(_ url: URL, maximumDepth: Int = 8, maximumEntries: Int = 50_000,
                              fatVolumeProbe: @escaping (Int32) throws -> FATVolumeUsage?,
                              destinationCapture: ((URL, Bool) throws -> ExportDestination)? = nil) -> LibraryPartition {
        let result = scan(url, recursive: true, maximumDepth: maximumDepth,
                          maximumEntries: maximumEntries)
        let space = result.issues.isEmpty ? try? ExportSpace.volume(at: url) : nil
        var issues = result.issues
        if space == nil && issues.isEmpty { issues.append("L’espace de cette partition ne peut pas être vérifié.") }
        if result.fileCount == 0 && result.folderCount == 0 && issues.isEmpty,
           let issue = verifyEmptyFATInventory(url, maximumDepth: maximumDepth,
                                             maximumEntries: maximumEntries, volumeProbe: fatVolumeProbe) {
            issues.append(issue)
        }
        var destination: ExportDestination?
        if issues.isEmpty, let destinationCapture {
            do { destination = try destinationCapture(url, result.fileCount == 0 && result.folderCount == 0) }
            catch { issues.append(error.localizedDescription) }
        }
        return LibraryPartition(
            url: url, letter: partitionLetter(for: url) ?? url.lastPathComponent,
            kits: result.kits, fileCount: result.fileCount, folderCount: result.folderCount,
            audioCount: result.samples.count, sequenceCount: result.sequenceCount,
            issues: issues, availableBytes: space?.availableBytes, volumeSpace: space,
            exportDestination: destination, samples: result.samples
        )
    }

    private static func fatVolumeUsage(_ descriptor: Int32) throws -> FATVolumeUsage? {
        guard let usage = try ExportDestination.nativeFATUsage(descriptor) else { return nil }
        return FATVolumeUsage(allocationUnitBytes: usage.allocationUnitBytes,
                              occupiedBytes: usage.occupiedBytes, rootAllocationIsFixed: usage.rootAllocationIsFixed)
    }

    /// The same native inventory protects both the recommendation and the eventual write.
    private static func verifyEmptyFATInventory(
        _ url: URL, maximumDepth: Int, maximumEntries: Int,
        volumeProbe: @escaping (Int32) throws -> FATVolumeUsage?
    ) -> String? {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { return "La partition vide ne peut pas être vérifiée." }
        defer { _ = close(descriptor) }
        var environment = ExportDestination.Environment()
        environment.fatUsage = { descriptor in
            guard let usage = try volumeProbe(descriptor) else { return nil }
            return .init(allocationUnitBytes: usage.allocationUnitBytes,
                         occupiedBytes: usage.occupiedBytes, rootAllocationIsFixed: usage.rootAllocationIsFixed)
        }
        do {
            try ExportDestination.verifyFATInventory(directoryFD: descriptor, requireEmpty: true,
                                                       maximumDepth: maximumDepth, maximumEntries: maximumEntries,
                                                       environment: environment, allowNonFAT: true)
            return nil
        } catch ExportDestinationError.notEmpty {
            return "L’inventaire FAT révèle des fichiers absents du premier relevé. Actualise la bibliothèque."
        } catch {
            return "Vérification de la partition vide impossible. \(error.localizedDescription)"
        }
    }

    /// An incomplete kit index is reported rather than presented as an exhaustive empty result.
    public static func scanKits(in url: URL, maximumDepth: Int = 8,
                                maximumEntries: Int = 50_000) throws -> [LibraryKit] {
        let result = scan(url, recursive: true, maximumDepth: maximumDepth,
                          maximumEntries: maximumEntries)
        guard result.issues.isEmpty else { throw LibraryIndexError.incomplete(result.issues) }
        return result.kits
    }

    /// Lists this directory only; choosing a source never recursively scans an entire SSD.
    public static func listSamples(in url: URL, maximumEntries: Int = 50_000) -> LibraryFolderListing {
        let result = scan(url, recursive: false, maximumDepth: 0, maximumEntries: maximumEntries)
        return LibraryFolderListing(folders: result.folders, samples: result.samples,
                                    issue: result.issues.isEmpty ? nil : result.issues.joined(separator: "\n"))
    }

    private struct ScanResult {
        var kits: [LibraryKit] = []
        var folders: [URL] = []
        var samples: [URL] = []
        var fileCount = 0
        var folderCount = 0
        var sequenceCount = 0
        var issues: [String] = []
    }

    private static func scan(_ source: URL, recursive: Bool, maximumDepth: Int,
                             maximumEntries: Int) -> ScanResult {
        var result = ScanResult()
        var root = source.standardizedFileURL
        root.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard root.isFileURL else {
            result.issues.append("Ce dossier n’est pas un emplacement local.")
            return result
        }
        do {
            let values = try root.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                result.issues.append("Le dossier est indisponible ou constitue un lien symbolique : \(root.path).")
                return result
            }
        } catch {
            result.issues.append("Dossier indisponible : \(root.path). \(error.localizedDescription)")
            return result
        }
        guard maximumDepth >= 0, maximumEntries > 0 else {
            result.issues.append("Le parcours est incomplet : limite de lecture atteinte.")
            return result
        }

        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                result.issues.append("Lecture impossible : \(url.path). \(error.localizedDescription)")
                return false
            }
        ) else {
            result.issues.append("Impossible de parcourir le dossier : \(root.path).")
            return result
        }

        var visited = 0
        while let entry = entries.nextObject() as? URL {
            guard visited < maximumEntries else {
                result.issues.append("Le parcours est incomplet : limite de \(maximumEntries) éléments atteinte.")
                break
            }
            visited += 1
            do {
                let values = try entry.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    entries.skipDescendants()
                    result.fileCount += 1
                    continue
                }
                if values.isDirectory == true {
                    result.folderCount += 1
                    result.folders.append(entry)
                    if !recursive {
                        entries.skipDescendants()
                    } else if entries.level > maximumDepth {
                        entries.skipDescendants()
                        result.issues.append("Le parcours est incomplet : profondeur maximale atteinte dans \(entry.lastPathComponent).")
                    }
                    continue
                }
                // Count every visible non-directory entry, including unsupported file types.
                result.fileCount += 1
                guard values.isRegularFile == true else { continue }
                let ext = entry.pathExtension.lowercased()
                if ext == "pgm" {
                    let components = entry.deletingLastPathComponent().standardizedFileURL.pathComponents
                        .dropFirst(root.pathComponents.count)
                    result.kits.append(LibraryKit(
                        url: entry, rootURL: root, partitionLetter: partitionLetter(for: root),
                        relativeFolder: components.joined(separator: "/")
                    ))
                }
                if supportedAudioExtensions.contains(ext) { result.samples.append(entry) }
                if ext == "seq" { result.sequenceCount += 1 }
            } catch {
                entries.skipDescendants()
                result.fileCount += 1
                result.issues.append("Lecture impossible : \(entry.path). \(error.localizedDescription)")
            }
        }
        result.kits = Array(Dictionary(result.kits.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }).values)
        result.kits.sort { ordered($0.url, $1.url) }
        result.folders.sort(by: ordered)
        result.samples.sort(by: ordered)
        return result
    }

    private static func ordered(_ lhs: URL, _ rhs: URL) -> Bool {
        let order = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
        return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
    }
}
