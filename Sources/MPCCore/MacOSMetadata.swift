import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Files macOS leaves on a FAT PART: AppleDouble `._*` companions written by Finder
/// copies, and system folders such as `.fseventsd` or `.Trashes`. Read-only and
/// informational: it explains clusters in use, it never authorizes a cleanup.
/// Foundation hides AppleDouble entries, so directories are read with readdir.
public struct MacOSMetadata: Equatable, Sendable {
    public let appleDoubleCount: Int
    /// Clusters held by the AppleDouble files, each rounded up to the allocation unit.
    public let appleDoubleBytes: Int64
    /// System folders found at the PART root.
    public let systemFolders: [String]
    /// False when a folder could not be read or a bound was reached.
    public let isComplete: Bool

    public init(appleDoubleCount: Int, appleDoubleBytes: Int64, systemFolders: [String], isComplete: Bool) {
        self.appleDoubleCount = appleDoubleCount
        self.appleDoubleBytes = appleDoubleBytes
        self.systemFolders = systemFolders
        self.isComplete = isComplete
    }

    public var isEmpty: Bool { appleDoubleCount == 0 && systemFolders.isEmpty }

    static let knownFolders: Set<String> = [
        ".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100"
    ]

    public static func inspect(_ url: URL, allocationUnit: Int64, maximumDepth: Int = 8,
                               maximumEntries: Int = 50_000) -> MacOSMetadata? {
        let root = url.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard root >= 0 else { return nil }
        defer { _ = close(root) }
        let unit = max(1, allocationUnit)
        var count = 0
        var bytes: Int64 = 0
        var visited = 0
        var folders: [String] = []

        func walk(_ directory: Int32, depth: Int) -> Bool {
            guard let names = entryNames(in: directory) else { return false }
            var complete = true
            for name in names {
                visited += 1
                guard visited <= maximumEntries else { return false }
                var info = stat()
                guard name.withCString({ fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                    complete = false
                    continue
                }
                let type = info.st_mode & mode_t(S_IFMT)
                if type == mode_t(S_IFDIR) {
                    if depth == 0, knownFolders.contains(name) {
                        folders.append(name)
                        continue
                    }
                    guard !name.hasPrefix("."), depth < maximumDepth else { continue }
                    let child = name.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                    guard child >= 0 else { complete = false; continue }
                    defer { _ = close(child) }
                    if !walk(child, depth: depth + 1) { complete = false }
                } else if type == mode_t(S_IFREG), name.hasPrefix("._") {
                    count += 1
                    let size = Int64(info.st_size)
                    bytes += size == 0 ? 0 : ((size - 1) / unit + 1) * unit
                }
            }
            return complete
        }

        let complete = walk(root, depth: 0)
        return MacOSMetadata(appleDoubleCount: count, appleDoubleBytes: bytes,
                             systemFolders: folders.sorted(), isComplete: complete)
    }

    /// Unlike the write-side inventory, repeated names are tolerated: this is a report.
    private static func entryNames(in directory: Int32) -> [String]? {
        let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else {
            _ = close(copy)
            return nil
        }
        defer { _ = closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 ? names : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }
}
